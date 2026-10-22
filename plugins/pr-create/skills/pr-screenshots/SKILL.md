---
name: pr-screenshots
description: UI の変更を含む作業で、UI を変更する前 (before の撮影)、PR を作るとき、push 後に description を更新するときに使う。PR 本文の動作確認の節に載せる before / after (VRT の baseline・撮影した画像・動画) とウォークスルーの動画の撮り方、撮り忘れた before を worktree で撮る手順、gh の `--attach` での添付と差し替えの手順を定める。
---

# UI 変更を含む PR のスクリーンショット・動画

- UI の変更を含む PR では、変更の影響を受ける画面すべての before / after を、PR 本文の動作確認の節に載せる
  - 載せる節は、PR テンプレートの動作確認・スクリーンショットの節にする (フォールバックのテンプレートでは `## 動作確認スクリーンショット`)。テンプレートにそういう節が無ければ、本文の末尾に `## 動作確認スクリーンショット` を足す。どのテンプレートを使うかは [pr-template skill](../pr-template/SKILL.md) に従う
  - 影響を受ける画面は撮影する。before は PR の分岐元 (ベースブランチとの merge-base) のコード、after は PR のブランチのコードで、同じ画面・同じ状態を撮って並べる。並べ方は PR テンプレートに形式があればその形式、無ければ [フォールバックのテンプレート](../pr-template/assets/pull_request_template.md) の `## 動作確認スクリーンショット` のコメントの形式 (before / after の表と、新しい画面の before の書き方) にする
  - プロジェクトの PR テンプレートや指示ファイルが、VRT (リポジトリに commit された baseline 画像との比較) の画像を載せる形式を定めているときは、VRT の差分で確認できる画面は撮影せず、その形式で baseline 画像の before / after を載せる (新しい画面・新機能は、下のウォークスルーの動画も撮る)
  - 撮影できなかった画面があれば、その画面名と理由を書く
- 動き・アニメーション・画面遷移、ホバーやスクロールなどの操作に伴う変化は、VRT でもスクリーンショットでも確認しにくいので、before / after の動画を撮る。以下の撮影・保存・添付の規則は動画にも同じように適用する
  - 形式は `.mp4` / `.mov` / `.webm`。H.264 の `.mp4` が最も互換性が高い
  - サイズの上限は無料プランのリポジトリで 10MB、有料プランで 100MB。超えるときは、確認したい操作の範囲に絞って撮り直すか、長辺 1280px 以下に縮めて再エンコードする (例: `ffmpeg -i in.mov -vf "scale='min(1280,iw)':'min(1280,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2" -c:v libx264 -pix_fmt yuv420p -crf 28 -an out.mp4`。`min()` は元が小さい動画を拡大しないため)。ffmpeg が無い macOS では `avconvert -s in.mov -p Preset1280x720 -o out.mp4` を使う
  - 録画時間の上限 (Android の 180 秒など) を超える操作は、先に操作のまとまりごとに分けてから撮る
  - 録画はバックグラウンドで始め、その間に画面を操作する
    - iOS シミュレータは `xcrun simctl io booted recordVideo --codec=h264 <path>.mov & echo $! > <pid ファイル>` で始め、操作を終えたら `kill -INT "$(cat <pid ファイル>)"` で止める (ほかの simctl のプロセスを巻き込まないよう、録画のプロセスだけに送る)。SIGINT 以外で止めるとファイルが書き終わらずに壊れるので、`while kill -0 "$(cat <pid ファイル>)" 2>/dev/null; do sleep 1; done` でプロセスが終わるのを待ってから使う。QuickTime 形式で書き出されるので拡張子は `.mov`
    - Android エミュレータは `adb shell screenrecord --time-limit <秒> /sdcard/<name>.mp4` に操作に要る秒数を指定し、止まるのを待つ (adb を強制終了すると mp4 が壊れることがある)。既定は 180 秒で、Android の版によってはそれが上限 (上限を超える値を渡すと録画されない)。`adb pull` で取り出し、端末側のファイルは消す
    - Web アプリや管理画面などのブラウザで動く画面は、Playwright の動画録画を使う
  - 録画できないときは、スクリーンショットを撮り、動きの違いを文章で補う
- 新しい画面・新機能 (画面を伴うもの) を実装する PR では、その機能を一通り操作するウォークスルーの動画を撮って添付する。VRT の baseline がある画面でも撮る (静止画では操作の流れが分からないため)
  - 既存の画面に新しい機能を足す PR も対象にする。その画面の before / after (VRT か撮影) に加えて撮る
  - 画面を開くところから、入力・操作、結果の表示までを 1 本にまとめる。エラー時の表示などの主な分岐も含める
  - 何をどの順に操作したかは、動画の直前の段落に書く
  - ウォークスルーの before は撮らない。録画・保存・添付の規則は、ほかの動画と同じ (サイズや録画時間の上限を超えるときは分ける)
- before は UI を変更する前に撮っておく。撮り忘れたときは、ブランチの分岐元を別の worktree に出して撮る (作業中のブランチの切り替えや `git stash` はしない)
  - `git fetch origin <ベースブランチ>` のあと `git worktree add --detach <path> "$(git merge-base HEAD origin/<ベースブランチ>)"` で出す。ベースブランチの先端で撮ると、分岐後に入った別の変更が差分に混ざる
  - `--single-branch` の clone では `git fetch origin <ベースブランチ>` で `origin/<ベースブランチ>` ができないので、`git fetch origin +refs/heads/<ベースブランチ>:refs/remotes/origin/<ベースブランチ>` で取る (以降の `git fetch origin <ベースブランチ>` や、下の `--deepen` 付きの fetch も同じ refspec で取る)
  - shallow clone で分岐元の commit が無く、`git merge-base` が何も出さないときは、`git fetch --deepen=<N> origin <ベースブランチ>` で履歴を足してから取り直す (取れるまで `<N>` を増やす)。作業ブランチも shallow に取ってきたもの (`--depth=1 --single-branch` の clone など) なら、`git fetch --deepen=<N> origin <作業ブランチ>` で作業ブランチ側の履歴も足す。merge-base が空のまま `git worktree add` に渡さない
  - `<path>` はリポジトリの外 (scratchpad など) にする。依存のインストールやビルドをし直し、gitignore されていてアプリの起動に要る設定ファイル (`.env` など) を本体の作業ツリーからコピーしてから、アプリを起動する
  - 本体の作業ツリーのアプリ (開発サーバーなど) が動いていれば止めるか、worktree のアプリを別のポートで起動する。撮る前に、開いている画面が worktree のコードのものであることを確かめる。撮り終えたら worktree のアプリを止めてから after を撮る
  - worktree から起動すると本体の作業ツリーの環境を壊すもの (compose project 名が固定されていて、本体の作業ツリーの開発用コンテナが作り直される docker compose など) は、worktree から起動しない。before は VRT の baseline で代え、代えられなければ撮影できなかった画面として扱う
  - 撮り終えたら `git worktree remove` で片付ける。撮影用に作った worktree に限り、依存のインストールで変わったファイルが残っていれば `--force` を付ける
- 撮影前にテスト用のデータに切り替えるかマスクして、個人情報・トークンなどの機密情報を写さない
- 撮影した画像・動画はリポジトリの外 (scratchpad など) に保存し、commit しない (VRT の baseline の更新とは別物)
- 撮影した画像・動画は gh の `--attach` で添付する (`gh pr create` / `gh pr edit` / `gh pr comment` で使える)
  - 本文に `![before: <画面名>](<ローカルのパス>)` のようにマークダウンの画像記法で書き、`--body-file` と一緒に渡すと、アップロードされた URL に書き換わる (例: `gh pr create --draft --body-file <本文> --attach <before.png> --attach <after.png>`)
  - 本文のパスと `--attach` のパスは同じ書き方にそろえる。違うと参照が書き換わらず、画像が本文の末尾に付く
  - 動画は参照 `![](<ローカルのパス>)` だけを 1 つの段落に単独で書く (同じ段落に文がある・表のセルに入れると、プレーヤーではなくリンクとして表示される)。動画には代替テキストを付けられないので、何の動画かは直前の段落に書く
  - 添付が一部失敗しても PR の作成・更新は行われ、終了コードだけが非ゼロになる。そのときは `gh pr create` をやり直さず、下の差し替えと同じ手順で、足りない分を添付し直す
  - `gh pr create --help` に `--attach` が無い (gh が古い) とき、gh が使えない (GitHub MCP で PR を作るなど) とき、push 権限が無いときは、画像・動画をユーザーに送り (SendUserFile が使えればそれで)、添付を依頼する
    - 本文にローカルのパスの参照は残さない
    - 添付のために commit したり外部に上げたりはしない
    - 送る手段もなければ、撮影できなかった画面と同じく PR 本文にその旨を書く
- PR 作成後の push で UI が変わったら、撮影した画面は after を撮り直して差し替える。VRT の画像を載せていれば、`git fetch origin <ベースブランチ>` で取り直したその時点の merge-base と head のものに載せ直す。新たに影響を受けた画面は before / after を足す。ウォークスルーの動画も、操作の流れや表示が変わったら撮り直して差し替える
  - 更新は今の本文を元にする。`gh pr view --json body -q .body` で取り、差し替える参照だけをローカルのパスに書き換えて、`gh pr edit --body-file <本文> --attach <after.png>` で更新する
  - `--body-file` は本文全体を置き換えるので、今の本文を元にしないと添付済みの画像が消える。push 後に description を更新するときも同じ
