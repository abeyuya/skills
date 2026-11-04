#!/usr/bin/env node
// pr-screenshots skill / ブラウザで動く画面を H.264 の mp4 に録画する。
//
// Playwright の recordVideo (と screencast.start の path 指定) は、既定で 800px 以内に縮小し、
// VP8・1Mbps・速度優先の設定で webm にエンコードするため、文字が潰れてカクついた動画になる。
// ここでは screencast のフレーム (JPEG と描画時刻) を受け取り、描画時刻どおりに並べて
// ffmpeg の libx264 でエンコードする。
//
// 使い方:
//   node record-browser.mjs --scenario <scenario.mjs> --out <out.mp4> [オプション]
//
// オプション:
//   --scenario <path>    録画する操作を書いた ES module (必須。書き方は下)
//   --out <path>         書き出す .mp4 (必須)
//   --width / --height   viewport と動画の大きさ (既定 1280 x 800。偶数)
//   --fps <n>            動画のフレームレート (既定 30)
//   --crf <n>            libx264 の CRF (既定 20。小さいほど高画質で大きいファイルになる)
//   --chrome <path>      Chrome / Chromium の実行ファイル。省略時はインストール済みの Chrome (channel: 'chrome')
//   --playwright <dir>   playwright-core (または playwright) のパッケージのディレクトリ。
//                        省略時はカレントディレクトリから playwright-core → playwright の順に解決する
//   --no-cursor          カーソルと操作名の表示を付けない
//
// scenario の書き方:
//   export const url = 'http://localhost:3000/';               // 録画の前に開く URL (任意)
//   export const contextOptions = { storageState: '<path>' };   // browser.newContext に足すオプション (任意。viewport と deviceScaleFactor は上書きできない)
//   export async function setup({ page, context }) {}           // 録画しない準備。ログインなど (任意)
//   export default async function ({ page, context, pause, scroll }) {}  // 録画する操作 (必須)
//     pause(ms)               : 画面を見せるために待つ
//     scroll(deltaY)          : マウスのある位置を小刻みにスクロールする (負の値で上へ)
//   録画するのは最初のタブだけ。新しいタブやポップアップを開く操作は、同じタブで開くように書く
//
// 成功すると、書き出した mp4 の絶対パスを stdout に 1 行出す。

import { parseArgs } from 'node:util';
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// onFrame の timestamp と showActions の cursor は 1.61 で入った
const MIN_PLAYWRIGHT = [1, 61];
const LEAD_IN_MS = 800;
const LEAD_OUT_SECONDS = 1;

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
      fps: { type: 'string', default: '30' },
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

  if (!opt['no-cursor']) await page.screencast.showActions({ cursor: 'pointer' });
  encoder = startEncoder(outPath);
  await page.screencast.start({
    size: { width, height },
    quality: 90,
    onFrame: ({ data, timestamp }) => encoder.push(data, timestamp),
  });

  const pause = (ms) => page.waitForTimeout(ms);
  // mouse.wheel を 1 回で大きく送ると一瞬で飛ぶうえ、showActions が 1 回ごとに操作名を出して待つので、
  // 操作の表示を外したうえで小刻みに送る
  const scroll = async (deltaY, { step = 40 } = {}) => {
    if (!opt['no-cursor']) await page.screencast.hideActions();
    for (let moved = 0; moved < Math.abs(deltaY); moved += step) {
      await page.mouse.wheel(0, Math.sign(deltaY) * Math.min(step, Math.abs(deltaY) - moved));
      await page.waitForTimeout(16);
    }
    await page.waitForTimeout(300);
    if (!opt['no-cursor']) await page.screencast.showActions({ cursor: 'pointer' });
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
