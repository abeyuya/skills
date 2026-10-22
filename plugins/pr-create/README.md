# pr-create plugin

PR を作成するときに使う skill 群。PR 本文をどの構成で書くかの決め方と、プロジェクトに PR テンプレートも本文の指示も無いときに使う **フォールバックの PR テンプレート**、UI 変更の **before / after のスクリーンショット・動画** の撮り方と添付の仕方、PR 本文に載せる **mermaid 図・画像** の描き方と描画の確認の仕方を提供する。

## 提供 skill

- `skills/pr-template`: PR 本文の構成を「ユーザー・プロジェクトの指示ファイルの指示 → プロジェクトの PR テンプレート (`.github/pull_request_template.md` 等) → フォールバックのテンプレート」の順で決める skill。どちらも無いときに使うフォールバックのテンプレートを [`assets/pull_request_template.md`](skills/pr-template/assets/pull_request_template.md) に同梱する (節は「このPRで実現したいこと」「関連リンク」「変更内容」「動作確認スクリーンショット」「特に人間にレビューしてほしい箇所」)。
- `skills/pr-screenshots`: UI の変更を含む PR で、影響を受ける画面の before / after (VRT の baseline・撮影した画像・動画) と、新しい画面・機能のウォークスルーの動画を PR 本文に載せる手順を定める skill。撮り忘れた before を分岐元の worktree で撮る手順、gh の `--attach` での添付と push 後の差し替えの手順を含む。
- `skills/pr-diagrams`: PR 本文に図を載せるかどうかの判断、mermaid 図の描き方、mermaid-cli での描画の確認、mermaid で表しにくい図の PNG への書き出しと添付の手順を定める skill。

いずれもモデルが自動で選んで読む想定の skill で、PR の作成・本文の更新・UI の変更の前に、description の条件に合えば読まれる。

グローバルの `~/.claude/CLAUDE.md` やプロジェクトの指示ファイルに、PR のスクリーンショットや本文の書き方について別の手順を書いている場合は、その節を「pr-create の skill に従う」旨の参照に置き換える。指示ファイルは skill より優先して読まれるので、手順が食い違うと、どちらに従うかがセッションごとにぶれる。

## 必要なもの

使う手順に応じて、次のものが要る。無い場合の扱いは各 skill に書いてある。

- **gh (`--attach` に対応した版)**: 撮影した画像・動画と、PNG に書き出した図の添付に使う (`pr-screenshots` / `pr-diagrams`)。使えない (gh が古い・GitHub MCP で PR を作る等) ときは、ファイルをユーザーに送って添付を依頼する。
- **Chrome (または Chromium) と Node.js 22.13 以上 (`npx`)**: mermaid-cli での描画の確認と、SVG / HTML の図の PNG への書き出しに使う (`pr-diagrams`)。
- **録画の手段**: iOS シミュレータは `xcrun simctl`、Android エミュレータは `adb`、ブラウザで動く画面は Playwright (`pr-screenshots`)。
- **ffmpeg (任意)**: 動画がサイズの上限を超えるときの再エンコードに使う (`pr-screenshots`)。macOS では代わりに標準の `avconvert` も使える。

## 利用方法 (ローカル Claude Code)

```bash
/plugin marketplace add abeyuya/skills
/plugin install pr-create@abeyuya-skills
```

## 利用方法 (apm 経由)

[apm (Agent Package Manager)](https://github.com/microsoft/apm) は Claude Code 形式の `marketplace.json` / `plugin.json` をネイティブに解釈するため、本リポジトリの配布物 (`.claude-plugin/marketplace.json` と `plugins/pr-create/`) を **そのまま** 依存として扱える。

```bash
# marketplace 経由 (recommended)
apm marketplace add abeyuya/skills
apm install pr-create@abeyuya-skills

# または subdirectory を直接指定する primitive form
apm install abeyuya/skills/plugins/pr-create
```

skill 同士は相対パス (`../pr-template/...` 等) で互いを参照しているので、3 つの skill はまとめて install する (plugin として install すれば常にそうなる)。

## 開発時 (このリポジトリ自身で plugin を編集しながら使う)

```bash
claude --plugin-dir plugins/pr-create
```

セッション中に `SKILL.md` を編集したら `/reload-plugins` で再読込できる。

フォールバックのテンプレート (`skills/pr-template/assets/pull_request_template.md`) のコメントには、図を載せる基準と動作確認スクリーンショットの規則の要約を、テンプレート単体でも使えるように書いている。`pr-diagrams` / `pr-screenshots` の規則を変えたら、テンプレートのコメントも合わせて直す。
