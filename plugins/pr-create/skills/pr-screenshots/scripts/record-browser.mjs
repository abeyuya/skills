#!/usr/bin/env node
// pr-screenshots skill / ブラウザで動く画面を H.264 の mp4 に録画する。
//
// Playwright の recordVideo (と screencast.start の path 指定) は、既定で 800px 以内に縮小し、
// VP8・1Mbps・速度優先の設定で webm にエンコードするため、文字が潰れてカクついた動画になる。
// ここでは screencast のフレーム (JPEG と描画時刻) を受け取り、描画時刻どおりに並べて
// ffmpeg の libx264 でエンコードする。
//
// Playwright はマウスを目標の位置へ一瞬で移し、カーソルも描かないので、そのまま撮ると紙芝居に見える。
// ここではページにカーソルを描き、locator の操作の前にマウスを目標まで滑らせる。
//
// 使い方:
//   node record-browser.mjs --scenario <scenario.mjs> --out <out.mp4> [オプション]
//
// オプション:
//   --scenario <path>    録画する操作を書いた ES module (必須。書き方は下)
//   --out <path>         書き出す .mp4 (必須)
//   --width / --height   viewport と動画の大きさ (既定 1280 x 800。偶数)
//   --fps <n>            動画のフレームレート (既定 60)
//   --crf <n>            libx264 の CRF (既定 20。小さいほど高画質で大きいファイルになる)
//   --chrome <path>      Chrome / Chromium の実行ファイル。省略時はインストール済みの Chrome (channel: 'chrome')
//   --playwright <dir>   playwright-core (または playwright) のパッケージのディレクトリ。
//                        省略時はカレントディレクトリから playwright-core → playwright の順に解決する
//   --no-cursor          カーソルを描かず、マウスも滑らせない
//
// scenario の書き方:
//   export const url = 'http://localhost:3000/';               // 録画の前に開く URL (任意)
//   export const contextOptions = { storageState: '<path>' };   // browser.newContext に足すオプション (任意。viewport と deviceScaleFactor は上書きできない)
//   export async function setup({ page, context }) {}           // 録画しない準備。ログインなど (任意)
//   export default async function ({ page, context, pause, scroll }) {}  // 録画する操作 (必須)
//     pause(ms)               : 画面を見せるために待つ
//     scroll(deltaY)          : マウスのある位置を滑らかにスクロールする (負の値で上へ)
//   録画するのは最初のタブだけ。新しいタブやポップアップを開く操作は、同じタブで開くように書く
//
// カーソルが滑らかに動くのは、最初のタブの locator (page.locator / getByRole など) の
// click / dblclick / hover / tap / check / uncheck / setChecked / fill / clear / pressSequentially / selectOption / dragTo と、
// page.mouse.move / click / dblclick。対象が画面の外にあれば、先に滑らかにスクロールする。
// page.click(selector) や ElementHandle の操作では、カーソルは目標へ一瞬で移る。
// locator.press / page.keyboard.press は、押したキーを画面の下に出す。
//
// 成功すると、書き出した mp4 の絶対パスを stdout に 1 行出す。

import { parseArgs } from 'node:util';
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// onFrame の timestamp は 1.61 で入った
const MIN_PLAYWRIGHT = [1, 61];
const LEAD_IN_MS = 800;
const LEAD_OUT_SECONDS = 1;
// マウスとスクロールを送る間隔。Chrome の描画 (60Hz) より細かく送っても、フレームは増えない
const TICK_MS = 1000 / 60;
// カーソルが着いてから押すまでの間。間が無いと、着いた瞬間に画面が変わって、どこを押したのかを追えない
const SETTLE_MS = 150;
// 対象が現れるのを待つ上限。これを過ぎたらマウスを滑らせずに、元の操作に待ち方と失敗の報告を任せる
const APPROACH_TIMEOUT_MS = 5000;
const OVERLAY_MARKER = '__recordBrowserCursor';

function fail(message) {
  console.error(`record-browser: ${message}`);
  process.exit(1);
}

let opt;
try {
  ({ values: opt } = parseArgs({
    options: {
      scenario: { type: 'string' },
      out: { type: 'string' },
      width: { type: 'string', default: '1280' },
      height: { type: 'string', default: '800' },
      fps: { type: 'string', default: '60' },
      crf: { type: 'string', default: '20' },
      chrome: { type: 'string' },
      playwright: { type: 'string' },
      'no-cursor': { type: 'boolean', default: false },
    },
  }));
} catch (e) {
  fail(e.message);
}

if (!opt.scenario || !opt.out) fail('--scenario と --out は必須');
if (!opt.out.endsWith('.mp4')) fail('--out の拡張子は .mp4 にする');
const width = Number(opt.width);
const height = Number(opt.height);
const fps = Number(opt.fps);
const crf = Number(opt.crf);
for (const [name, value] of Object.entries({ width, height, fps })) {
  if (!Number.isInteger(value) || value <= 0) fail(`--${name} は正の整数にする`);
}
if (!Number.isInteger(crf) || crf < 0 || crf > 51) fail('--crf は 0〜51 の整数にする');
// yuv420p は幅・高さが奇数だとエンコードできない
if (width % 2 || height % 2) fail('--width と --height は偶数にする');

const encoders = spawnSync('ffmpeg', ['-hide_banner', '-encoders'], { encoding: 'utf8' });
if (encoders.error) fail('ffmpeg が見つからない');
if (!/\blibx264\b/.test(encoders.stdout)) fail('ffmpeg に libx264 が入っていない');

function loadPlaywright() {
  const req = createRequire(path.join(process.cwd(), 'noop.js'));
  const candidates = opt.playwright ? [path.resolve(opt.playwright)] : ['playwright-core', 'playwright'];
  for (const candidate of candidates) {
    let pkgPath;
    try {
      pkgPath = req.resolve(`${candidate}/package.json`);
    } catch {
      continue;
    }
    const { version } = req(pkgPath);
    const [major, minor] = version.split('.').map(Number);
    if (!Number.isInteger(major) || !Number.isInteger(minor) || major < MIN_PLAYWRIGHT[0] || (major === MIN_PLAYWRIGHT[0] && minor < MIN_PLAYWRIGHT[1])) {
      fail(`${path.dirname(pkgPath)} の Playwright は ${version}。${MIN_PLAYWRIGHT.join('.')} 以上が要る`);
    }
    return req(path.dirname(pkgPath)).chromium;
  }
  fail(
    opt.playwright
      ? `${opt.playwright} に Playwright が無い`
      : 'カレントディレクトリから Playwright を解決できない。--playwright でパッケージのディレクトリを渡す',
  );
}

function startEncoder(outPath) {
  const ffmpeg = spawn(
    'ffmpeg',
    [
      '-loglevel', 'error', '-y',
      '-f', 'image2pipe', '-c:v', 'mjpeg', '-framerate', String(fps), '-i', 'pipe:0',
      '-an',
      // フレームがウィンドウに切られて viewport より小さく届くことがあるので、出力の大きさに揃える
      '-vf', `scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:white,format=yuv420p`,
      '-c:v', 'libx264', '-preset', 'medium', '-crf', String(crf),
      '-movflags', '+faststart',
      outPath,
    ],
    { stdio: ['pipe', 'ignore', 'inherit'] },
  );
  const exited = new Promise((resolve) => ffmpeg.on('close', resolve));
  let writeError = null;
  ffmpeg.stdin.on('error', (e) => {
    writeError ??= e;
  });
  const write = (data) =>
    new Promise((resolve) => {
      ffmpeg.stdin.write(data, (e) => {
        if (e) writeError ??= e;
        resolve();
      });
    });

  let queue = Promise.resolve();
  let first = null;
  let last = null;
  // 終了時刻は Node の時計で取るので、フレームの時計との差を最初のフレームで控えて換算する。
  // 2 つの時計の起点がずれていても、最後のフレームを繰り返す回数が実際の経過時間を超えない
  let clockOffset = null;
  const indexAt = (timestampMs) => Math.floor(((timestampMs - first) / 1000) * fps);
  // screencast は描画が変わったときだけフレームを送るので、次のフレームまで前のフレームを繰り返して一定の fps にする
  const enqueue = (data, count) => {
    queue = queue.then(async () => {
      for (let i = 0; i < count && !writeError; i++) await write(data);
    });
  };

  return {
    push(data, timestampMs) {
      first ??= timestampMs;
      clockOffset ??= Date.now() - timestampMs;
      const index = indexAt(timestampMs);
      if (last) enqueue(last.data, index - last.index);
      last = { data, index };
    },
    async finish(endMs) {
      if (!last) throw new Error('screencast のフレームが 1 枚も届かなかった');
      enqueue(last.data, Math.max(indexAt(endMs - clockOffset) - last.index, 1) + LEAD_OUT_SECONDS * fps);
      await queue;
      ffmpeg.stdin.end();
      const code = await exited;
      if (writeError || code !== 0) throw new Error(`ffmpeg が失敗した (exit ${code}) ${writeError?.message ?? ''}`);
    },
    abort() {
      ffmpeg.kill('SIGKILL');
    },
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// 手の動きに近い、動き出しと止まり際が緩やかな補間 (minimum jerk)
const ease = (t) => t * t * t * (10 - 15 * t + 6 * t * t);

// duration をかけて 0 → 1 に進む値を step に渡す。待ちがずれても所要時間が変わらないよう、経過時間から値を決める
async function tween(duration, step) {
  const start = performance.now();
  for (let tick = 1; ; tick++) {
    // duration が 0 だと 0 / 0 で NaN になり、1 に届かない
    const t = duration > 0 ? Math.min((performance.now() - start) / duration, 1) : 1;
    await step(ease(t));
    if (t >= 1) return;
    await sleep(Math.max(0, start + tick * TICK_MS - performance.now()));
  }
}

// ページの中で動く。カーソル・クリックの波紋・押したキーの表示を、実際のマウスのイベントに合わせて描く。
// CSP や Trusted Types の下でも動くよう、<style> と innerHTML を使わない
function installOverlay(marker) {
  const key = Symbol.for(marker);
  if (window[key]) return;
  window[key] = true;

  const isTop = window.parent === window;
  const emit = (type, x, y) => (isTop ? draw[type](x, y) : window.parent.postMessage({ [marker]: [type, x, y] }, '*'));
  // HTML のドラッグ&ドロップの間は mousemove と mouseup が来ないので、drag のイベントでも追う
  for (const [event, type] of [['mousemove', 'move'], ['dragover', 'move'], ['mousedown', 'down'], ['mouseup', 'up'], ['dragend', 'up']]) {
    window.addEventListener(event, (e) => e.isTrusted && emit(type, e.clientX, e.clientY), true);
  }
  // iframe の中のマウスのイベントは親の window に届かないので、iframe の位置を足しながら最上位まで送る
  window.addEventListener(
    'message',
    (e) => {
      const message = e.data?.[marker];
      if (!Array.isArray(message)) return;
      e.stopImmediatePropagation();
      const frame = [...document.querySelectorAll('iframe, frame')].find((f) => f.contentWindow === e.source);
      if (!frame) return;
      const rect = frame.getBoundingClientRect();
      const { paddingLeft, paddingTop } = getComputedStyle(frame);
      emit(message[0], message[1] + rect.left + frame.clientLeft + parseFloat(paddingLeft), message[2] + rect.top + frame.clientTop + parseFloat(paddingTop));
    },
    true,
  );
  if (!isTop) return;

  const style = (el, props) => {
    for (const [name, value] of Object.entries(props)) el.style.setProperty(name, value, 'important');
    return el;
  };
  const SVG = 'http://www.w3.org/2000/svg';
  let host, arrow, layer, raisedAt = 0;

  // ページが document を作り直すと消えるので、描くたびに有無を確かめる
  const ensure = () => {
    if (host?.isConnected) return true;
    if (!document.documentElement) return false;
    host = style(document.createElement('x-record-browser-cursor'), {
      all: 'initial', position: 'fixed', left: '0', top: '0', width: '0', height: '0', margin: '0', padding: '0', border: '0',
      background: 'none', overflow: 'visible', 'pointer-events': 'none', 'z-index': '2147483647',
    });
    host.setAttribute('popover', 'manual');
    host.setAttribute('aria-hidden', 'true');
    layer = host.attachShadow({ mode: 'closed' });
    arrow = style(document.createElementNS(SVG, 'svg'), {
      position: 'fixed', left: '-2px', top: '-2px', width: '26px', height: '36px', overflow: 'visible', visibility: 'hidden',
      filter: 'drop-shadow(0 2px 3px rgba(0,0,0,.45))', 'transform-origin': '2px 2px', 'will-change': 'transform',
    });
    arrow.setAttribute('viewBox', '-2 -2 26 36');
    const path = document.createElementNS(SVG, 'path');
    path.setAttribute('d', 'M0 0 L0 26 L6.6 20 L11 30.6 L15.6 28.7 L11.2 18.2 L20 18.2 Z');
    path.setAttribute('fill', '#111');
    path.setAttribute('stroke', '#fff');
    path.setAttribute('stroke-width', '2');
    path.setAttribute('stroke-linejoin', 'round');
    arrow.append(path);
    layer.append(arrow);
    document.documentElement.append(host);
    raise();
    return true;
  };
  // モーダルの <dialog> などは top layer に入り、z-index では上に出られない。後から入ったものほど上になるので、入り直す
  const raise = () => {
    raisedAt = performance.now();
    try {
      if (host.matches(':popover-open')) host.hidePopover();
      host.showPopover();
    } catch {
      host.removeAttribute('popover');
    }
  };
  for (const event of ['toggle', 'fullscreenchange']) {
    window.addEventListener(event, (e) => e.target !== host && host?.isConnected && raise(), true);
  }

  // 新しい document では、マウスのイベントが来るまで位置が分からない。それまでは描かない
  let position;
  let pressed = false;
  const place = () => {
    if (!position) return;
    style(arrow, { visibility: 'visible', transform: `translate(${position[0]}px, ${position[1]}px) scale(${pressed ? 0.82 : 1})` });
  };
  const locate = (x, y) => {
    position = [x, y];
    window[marker]?.(x, y);
  };
  const draw = {
    move(x, y) {
      if (!ensure()) return;
      locate(x, y);
      place();
      // shadow DOM の中の dialog は toggle が外に出ず、上の listener では拾えない
      if (performance.now() - raisedAt > 250) raise();
    },
    down(x, y) {
      if (!ensure()) return;
      locate(x, y);
      pressed = true;
      place();
      const ring = style(document.createElement('div'), {
        position: 'fixed', left: `${x - 26}px`, top: `${y - 26}px`, width: '52px', height: '52px', 'box-sizing': 'border-box',
        'border-radius': '50%', border: '3px solid rgba(37,99,235,.95)', background: 'rgba(59,130,246,.3)',
      });
      layer.insertBefore(ring, arrow);
      ring.animate([{ transform: 'scale(.25)', opacity: 1 }, { transform: 'scale(1)', opacity: 0 }], { duration: 550, easing: 'ease-out' })
        .finished.finally(() => ring.remove());
    },
    // dragend の座標はあてにならないので、位置は動かさない
    up() {
      if (!ensure()) return;
      pressed = false;
      place();
    },
  };

  let badge;
  window.addEventListener(marker, (e) => {
    if (!ensure()) return;
    // マウスを動かさずに位置だけ描く。実際の位置が分かっているときは、そちらが正しい
    if (e.detail.at) {
      position ??= e.detail.at;
      return place();
    }
    badge?.remove();
    badge = style(document.createElement('div'), {
      position: 'fixed', left: '50vw', bottom: '32px', transform: 'translateX(-50%)', padding: '8px 18px', 'border-radius': '10px',
      background: 'rgba(17,17,17,.82)', color: '#fff', font: '600 22px/1.4 system-ui, sans-serif', 'white-space': 'nowrap',
      'box-shadow': '0 4px 14px rgba(0,0,0,.3)',
    });
    badge.textContent = String(e.detail.key);
    layer.append(badge);
    const shown = badge;
    shown.animate([{ opacity: 1, offset: 0.75 }, { opacity: 0 }], { duration: 1400 }).finished.finally(() => shown.remove());
  });
}

// 滑らせる対象にする locator の操作と、その options が何番目の引数か
const POINTER_ACTIONS = {
  click: 0, dblclick: 0, hover: 0, tap: 0, check: 0, uncheck: 0, setChecked: 1,
  fill: 1, clear: 0, type: 1, pressSequentially: 1, selectOption: 1,
};

async function installPointer(page, context) {
  const mouse = page.mouse;
  const raw = { move: mouse.move.bind(mouse), click: mouse.click.bind(mouse) };
  const at = { x: Math.round(width / 2), y: Math.round(height / 2) };
  let gliding = 0;

  const glide = async (x, y) => {
    const from = { ...at };
    const distance = Math.hypot(x - from.x, y - from.y);
    gliding++;
    try {
      // 距離が長いほど時間をかけるが、比例させると遠くへの移動が間延びする
      await tween(distance < 2 ? 0 : Math.min(250 + distance * 0.7, 950), async (k) => {
        at.x = from.x + (x - from.x) * k;
        at.y = from.y + (y - from.y) * k;
        await raw.move(at.x, at.y);
      });
    } finally {
      gliding--;
    }
  };

  // locator の対象まで滑らせる。対象が表示されていなければ false。limit までに現れなければ投げる
  const reach = async (locator, { position, force } = {}, limit) => {
    if (!force) await locator.waitFor({ state: 'visible', timeout: limit });
    // 操作の側のスクロールは一瞬で飛ぶので、先に滑らかに寄せておく
    const sight = await locator.evaluate(async (el, offset) => {
      // 中心が window の中にあっても、スクロール領域や iframe に切られて見えていないことがある。
      // 対象が画面より大きいと全体は収まらないので、押す位置が見えているかで決める
      const entry = await new Promise((resolve) => {
        const observer = new IntersectionObserver(([first]) => {
          observer.disconnect();
          resolve(first);
        });
        observer.observe(el);
        // 描画が止まっているページでは callback が来ない
        setTimeout(resolve, 500);
      });
      const rect = el.getBoundingClientRect();
      const x = rect.left + (offset?.x ?? rect.width / 2);
      const y = rect.top + (offset?.y ?? rect.height / 2);
      const seen = entry?.intersectionRect ?? rect;
      const shown = x >= seen.left && x <= seen.right && y >= seen.top && y <= seen.bottom;
      if (shown && x >= 0 && x <= innerWidth && y >= 0 && y <= innerHeight) return 'shown';
      // scrollIntoView は要素の中の 1 点を狙えない。position の指定があるときに要素を中央へ寄せると、押す位置から離れることがある
      if (offset) return 'hidden';
      el.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' });
      return 'scrolled';
    }, position ?? null, { timeout: limit });
    // 見えていない位置へは滑らせない (画面の端で止まり、押す場所と違うところを指してしまう)
    if (sight === 'hidden') return false;
    let box = await locator.boundingBox({ timeout: limit });
    // 止まるのを待たないと、動いている途中の位置を目標にしてしまう。iframe の中の対象は親のページのスクロールで動くので、
    // その frame の中の座標ではなく、画面上の位置で確かめる
    for (let still = 0, deadline = performance.now() + 3000; sight === 'scrolled' && still < 2 && performance.now() < deadline; ) {
      await sleep(60);
      const next = await locator.boundingBox({ timeout: limit });
      still = next?.x === box?.x && next?.y === box?.y ? still + 1 : 0;
      box = next;
    }
    if (!box) return false;
    const clamp = (value, max) => Math.min(Math.max(value, 0), max - 1);
    await glide(clamp(box.x + (position?.x ?? box.width / 2), width), clamp(box.y + (position?.y ?? box.height / 2), height));
    await sleep(SETTLE_MS);
    return true;
  };
  // 後ろに元の操作が控えているので、長くは待たず、滑らせられなくても失敗にしない (待ち方と失敗の報告は元の操作に任せる)。
  // timeout の 0 は「待ち続ける」の意味
  const approach = (locator, options = {}) =>
    reach(locator, options, Math.min(options.timeout || Infinity, APPROACH_TIMEOUT_MS)).catch(() => false);

  mouse.move = async (x, y, options = {}) => {
    if (!options.steps) return glide(x, y);
    await raw.move(x, y, options);
    Object.assign(at, { x, y });
  };
  mouse.click = async (x, y, options) => {
    await glide(x, y);
    await sleep(SETTLE_MS);
    return raw.click(x, y, options);
  };

  const tell = (detail) =>
    page.evaluate(([marker, sent]) => window.dispatchEvent(new CustomEvent(marker, { detail: sent })), [OVERLAY_MARKER, detail]).catch(() => {});
  const showKey = (key) => tell({ key });
  const keyboard = page.keyboard;
  const rawPress = keyboard.press.bind(keyboard);
  keyboard.press = async (key, options) => {
    await showKey(key);
    return rawPress(key, options);
  };

  // locator の操作はサーバー側でマウスを動かし、page.mouse を通らないので、locator のメソッドの前に割り込む
  const proto = Object.getPrototypeOf(page.locator('html'));
  // setChecked → check のように、割り込んだメソッドが別の割り込んだメソッドを呼ぶ
  let nested = 0;
  // before が true を返したら、操作は before が済ませたものとして元のメソッドを呼ばない
  const wrap = (name, before) => {
    const original = proto[name];
    proto[name] = async function (...args) {
      if (this.page() !== page || nested) return original.apply(this, args);
      nested++;
      try {
        if (await before(this, args)) return;
        return await original.apply(this, args);
      } finally {
        nested--;
      }
    };
  };
  for (const [name, optionsIndex] of Object.entries(POINTER_ACTIONS)) {
    wrap(name, async (locator, args) => {
      await approach(locator, args[optionsIndex]);
    });
  }
  wrap('press', async (_locator, [key]) => {
    await showKey(key);
  });
  // 元の dragTo は掴んだ先へ一瞬で移るので、掴む・運ぶ・離すを自分で送る
  wrap('dragTo', async (source, [target, { trial, force, timeout, sourcePosition, targetPosition } = {}]) => {
    if (trial || !(await approach(source, { position: sourcePosition, force, timeout }))) return false;
    await mouse.down();
    let reached;
    try {
      // 移動先は掴んでから現れることがある。ここで待ち切らないと操作が失敗するので、元の dragTo と同じ timeout で待つ
      reached = await reach(target, { position: targetPosition, force }, timeout);
    } finally {
      await mouse.up();
    }
    if (!reached) throw new Error('dragTo の移動先が表示されていない');
    return true;
  });

  // page.click(selector) などの割り込めない操作でもマウスは動く。ページから実際の位置を受け取らないと、
  // 次に滑らせるときに古い位置へ戻ってから動き出す
  await context.exposeBinding(OVERLAY_MARKER, ({ page: source }, x, y) => {
    if (source === page && !gliding) Object.assign(at, { x, y });
  });
  await context.addInitScript(installOverlay, OVERLAY_MARKER);
  await Promise.all(page.frames().map((frame) => frame.evaluate(installOverlay, OVERLAY_MARKER).catch(() => {})));
  // 新しい document のカーソルは、マウスのイベントが来るまで描かれない。実際のマウスを動かして描かせると、
  // その位置の hover が発火し、進行中の操作のマウスの位置もずらすので、位置だけを伝える
  const redraw = () => tell({ at: [at.x, at.y] });
  page.on('framenavigated', (frame) => frame === page.mainFrame() && redraw());
  page.on('domcontentloaded', redraw);
  await redraw();
}

const scenarioPath = path.resolve(opt.scenario);
if (!existsSync(scenarioPath)) fail(`${scenarioPath} が無い`);
const scenario = await import(pathToFileURL(scenarioPath).href);
if (typeof scenario.default !== 'function') fail('scenario は録画する操作を default export の関数にする');

const chromium = loadPlaywright();
const outPath = path.resolve(opt.out);
// 親ディレクトリが無いと、ffmpeg は最初のフレームで出力を開けずに終わり、scenario を最後まで流してから EPIPE で失敗する
mkdirSync(path.dirname(outPath), { recursive: true });
const browser = await chromium
  .launch({
    ...(opt.chrome ? { executablePath: opt.chrome } : { channel: 'chrome' }),
    // ウィンドウが viewport と違う大きさだと、screencast のフレームがウィンドウ側で切られて下端が欠ける
    args: [`--window-size=${width},${height}`],
  })
  .catch((e) => fail(`ブラウザを起動できない (${e.message.split('\n')[0]})。--chrome で実行ファイルを渡す`));

let encoder;
let failed = false;
try {
  const context = await browser.newContext({ ...scenario.contextOptions, viewport: { width, height }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  if (scenario.url) await page.goto(scenario.url);
  if (scenario.setup) await scenario.setup({ page, context });

  if (!opt['no-cursor']) await installPointer(page, context);
  encoder = startEncoder(outPath);
  await page.screencast.start({
    size: { width, height },
    quality: 90,
    onFrame: ({ data, timestamp }) => encoder.push(data, timestamp),
  });

  const pause = (ms) => page.waitForTimeout(ms);
  // mouse.wheel を 1 回で大きく送ると一瞬で飛ぶので、小刻みに送る
  const scroll = async (deltaY, { duration = Math.min(Math.max(Math.abs(deltaY) * 1.2, 400), 2000) } = {}) => {
    let sent = 0;
    await tween(duration, async (k) => {
      const next = Math.round(deltaY * k);
      if (next !== sent) await page.mouse.wheel(0, next - sent);
      sent = next;
    });
    await sleep(300);
  };

  await pause(LEAD_IN_MS);
  await scenario.default({ page, context, pause, scroll });
  const endMs = Date.now();
  await page.screencast.stop();
  await encoder.finish(endMs);
} catch (e) {
  failed = true;
  // 録画を始める前に失敗したときは、前回撮った同名のファイルを消さない
  if (encoder) {
    encoder.abort();
    rmSync(outPath, { force: true });
  }
  console.error(`record-browser: ${e.stack ?? e}`);
} finally {
  // mp4 は書き終えているので、Chrome が先に落ちていて閉じられなくても録画の成否は変えない
  await browser.close().catch((e) => console.error(`record-browser: ブラウザを閉じられなかった (${e.message.split('\n')[0]})`));
}
if (failed) process.exit(1);
console.log(outPath);
