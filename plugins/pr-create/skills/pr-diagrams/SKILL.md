---
name: pr-diagrams
description: PR 本文を書くとき (PR の作成時と、push 後に本文を更新するとき) に、目的・背景や変更内容 (フォールバックの PR テンプレートでは「このPRで実現したいこと」「変更内容」) に mermaid 図や画像を載せるかどうかを決めるとき、載せるときに使う。図を載せるかどうかの判断、図の描き方、mermaid-cli での描画の確認、mermaid で表しにくい図の PNG への書き出しと添付、push 後の図の直し方を定める。
---

# PR 本文の図

PR 本文の目的・背景を書く節と、変更内容を書く節 (フォールバックの [PR テンプレート](../pr-template/assets/pull_request_template.md) では `# このPRで実現したいこと` / `## 変更内容`) に載せる図の描き方と載せ方を定める。

## 図を載せるか

PR テンプレートのコメントなどに図についての指示があれば、それに従って決める。無ければ、フォールバックの PR テンプレートのコメントと同じ次の基準で決める。

- 処理やデータの流れ、コンポーネント・テーブルの関係、状態遷移など、文章より図のほうが伝わる内容は図を載せる。1〜2 行の文章で伝わるものは図にしない
- 構成や処理の流れが変わる場合は、before / after の図を載せる

## 描き方

- 図は文章の補足にし、要点は文章でも書く。メール通知などでは図が描画されないため
- 図は mermaid で書き、本文の ```` ```mermaid ```` のコードブロックに直接置く。GitHub が描画し、テキストなので後から直しやすい
  - 種類は flowchart / sequenceDiagram / stateDiagram-v2 / erDiagram などの定番から選ぶ
  - 1 枚の図のノードは 15 個程度までにする。超えるときは図を分ける
  - flowchart のノードのラベルに記号 (`(` `)` `{` `}` `|` や先頭の `/` など) を含むときは `"..."` で囲む。囲まないと構文エラーになり、図が描画されない (sequenceDiagram のメッセージなどでは引用符がそのまま表示されるので囲まない)
- mermaid で表しにくい図 (画面上の位置に注釈を付けた図など) は画像を作る
  - SVG か HTML で描き、Chrome の headless モードで PNG に書き出す: `"<Chrome>" --headless --screenshot=<out>.png --window-size=<幅>,<高さ> "file://<in>.svg"` (`<Chrome>` は下の「Chrome」節を参照)
  - `<幅>,<高さ>` は SVG の width / height にそろえる。ずれると余白が付くか、図が切れる。HTML で描くときは `body` の `margin` を 0 にし、図の要素の幅・高さを固定してそれにそろえる (既定の `margin` の分だけ図がずれて切れるため)
  - `<in>` は絶対パスにする。相対パスだと先頭がホスト名と解釈され、図を開けない
  - 保存と添付は、[pr-screenshots skill](../pr-screenshots/SKILL.md) の撮影した画像と同じ規則に従う (リポジトリの外に保存して commit せず、gh の `--attach` で添付する)
- PR 作成後の push で処理の流れや構成が変わったら、図も直す。画像は pr-screenshots skill の差し替えと同じ手順で差し替える

## Chrome

描画の確認と PNG への書き出しは、インストール済みの Chrome を使う。手順中の `<Chrome>` はそのパス。

- macOS は `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`。他の OS では、`command -v google-chrome google-chrome-stable chromium chromium-browser` などで見つけたパスを使う
- Linux で root として動くとき (コンテナなど) は、Chrome が `--no-sandbox` なしでは起動しない。mermaid-cli には `{"args": ["--no-sandbox"]}` を書いた設定ファイルを `-p <設定ファイル>` で渡し、headless Chrome には `--no-sandbox` を付ける。設定ファイルもリポジトリの外に置く
- Chrome が無いなどで描画を確かめられなかったときは、その旨をユーザーに報告する

## 描画の確認

本文に載せる前に mermaid-cli で本文を描画し、構文エラーが無いことと見た目を確かめる。Markdown を渡すと mermaid のブロックをすべて描画し、1 つでもエラーがあれば終了コードが非ゼロになる。

```bash
mkdir -p <出力先> && PUPPETEER_EXECUTABLE_PATH="<Chrome>" npx -y @mermaid-js/mermaid-cli@12.0.0 -i <本文>.md -o <出力先>/body.md -e png
```

- Linux で root として動くとき (コンテナなど) は、`-p <設定ファイル>` も付ける (「Chrome」節)。付けないと Chrome が起動せずに失敗するので、構文エラーと取り違えない
- 出力先はリポジトリの外 (scratchpad など) にする。無いディレクトリを指定すると、描画せずにエラーで止まる
- `PUPPETEER_EXECUTABLE_PATH` は、インストール済みの Chrome を使わせるために付ける。付けないと、puppeteer が自前の Chrome (`~/.cache/puppeteer`) をダウンロードして使い、ダウンロードできない環境では Chrome が無いというエラーで止まる
- 版を固定するのは、npm の最新版を確かめないまま実行しないため
