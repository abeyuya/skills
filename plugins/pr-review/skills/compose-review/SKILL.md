---
name: compose-review
description: PR 差分 or ローカルブランチ差分に対してレビュー本文 (body / event / comments[]) を生成する skill。スタイル参考ガイド (skill 配下の style-reference.md) とプロジェクト指示ファイル (REVIEW.md / AGENTS.md / .claude/CLAUDE.md / CLAUDE.md) を読み込んでレビュー方針を決め、差分を読んで `post-pr-review` のスキーマに揃った JSON を返す。出力先は `OUTPUT_DESTINATION` 入力で chat (デフォルト、人間直読用) と file (`/tmp/compose-review-output.json`、`run-pr-review` orchestrator 経由用) を切り替える。GitHub 投稿 / 過去スレッド resolve は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
---

# compose-review skill

差分 + 方針 → レビュー本文 (`body` / `event` / `comments[]`) を生成する **純粋関数に近い** skill。`post-pr-review` への受け渡しを意図した JSON をチャットに返す。GitHub への投稿や git 状態の書き換えは行わない (read-only)。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。

### モード切替

- `OWNER` / `REPO` / `PR_NUMBER` の **3 つすべてが非空の値で渡されたら** **PR モード**。
- 3 つのうち 1 つでも未指定または空文字 (`""`) なら **ローカル diff モード**。GitHub Actions 等で env 変数が未設定だと空文字で展開されるケースを「未指定」と同等に扱う (空文字で PR モードに入ると `gh pr view --repo /` 等が直ちに失敗するため)。
- `PR_NUMBER` のみが渡され `OWNER` / `REPO` が欠けている (caller の自動取得が部分失敗した) ような中途半端な状態の場合は、ローカル diff モードに静かに切り替わると caller の意図と食い違う。caller (`run-pr-review` 等) は **3 つを揃えるか、何も渡さないか** のいずれかにすること。本 skill はモード判定後にエラーを raise しない (混在を黙って local 扱いにする) ので、混在を弾く責務は caller 側にある。

### 共通

- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い。詳細は `style-reference.md` の「`MAX_INLINE_COMMENTS` の扱い」セクション参照。
- `OUTPUT_DESTINATION`: 出力先の切り替え。`chat` (デフォルト) または `file`。詳細は Step 6 参照。
  - `chat` (`run-local-review` から呼ばれる場合のデフォルト): fenced JSON ブロックをそのままチャットに出力。caller (人間) が直接読む用途。
  - `file` (`run-pr-review` から呼ばれる場合は **必須**。緩い「推奨」扱いではない): `/tmp/compose-review-output.json` に JSON 本体を `Write` し、チャットには 1 行サマリのみ出す。chat 上に「成果物っぽい大きなアウトプット」を残さず、orchestrator が JSON 解釈の終わりを「Step 完了」と誤認するのを構造的に防ぐ。PR #34 で 3 回踏み抜かれた踏み外しパターンへの構造的防止策の **要所** のため、`run-pr-review` 側で必須化されている。別 orchestrator から呼ぶ場合も同様の安全策が必要なら `file` を明示指定すること。

### ローカル diff モードのみ

- `BASE_BRANCH`: 比較対象のベースブランチ。省略時の解決順は Step 1 を参照。本 skill は `git fetch` を走らせないため、ローカルのベースが古いと古い基準で diff が出る。最新で比較したい場合は caller 側で fetch するか、`BASE_BRANCH=origin/main` のようにリモート追跡参照を明示する。

### PR モードのみ (任意)

- `EXISTING_THREADS_CONTEXT`: caller が既に GraphQL `reviewThreads` を取得済みの場合、既存スレッドの主旨サマリを自然言語で注入するためのオプション。Step 5 の重複回避判定に使う。
- `CI_FAILURE_CONTEXT`: caller が既に `gh run view --log` 等で取得済みの CI 失敗ログのサマリを自然言語で注入するためのオプション。Step 5 で `[must]` の根拠付けに使う (詳細扱いは `style-reference.md` の「CI の扱い」セクション参照)。
- `RECHECK_HEAD_SHA`: 真偽値 (`true` / `false`)。デフォルト `false`。`true` を渡すと Step 4 の `gh pr diff` 直後に head SHA を再取得し、Step 1 時点と値が変わっていれば「force-push 検知のため再実行を推奨」として停止する。force-push が頻繁な PR をドッグフーディング系 caller から扱う場合に使う (詳細は Step 1 PR モードの TOCTOU 注意)。

caller プロジェクト固有の方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (Step 3 で定義) に置く運用に固定する。個別パス指定の引数は持たない。

## 手順

### Step 1. モード判定と対象確定

#### PR モード

- `OWNER` / `REPO` / `PR_NUMBER` をそのまま採用する。
- `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json headRefOid -q .headRefOid` で head SHA を取得し、Step 6 の出力 JSON `commit_id` として控える。
- 取得失敗時は HTTP ステータス / エラー種別で扱いを分ける:
  - **致命 (即停止)**: 401 / 403 (権限不足) / 404 (PR or リポジトリ不在) / 422 など、再試行しても変わらない種類。caller に PR_NUMBER / 権限の見直しを促す。
  - **transient (再試行 → 省略)**: 5xx / network timeout / DNS 失敗 / ECONNRESET / 429 (rate limit) / 403 with `Retry-After` ヘッダ (secondary rate limit) など、時間を置けば回復が期待できる種類。判別は **`gh pr view` の exit code が非ゼロ かつ stderr に `HTTP 5xx` / `429` / `connection refused` / `i/o timeout` / `temporary failure in name resolution` / `Retry-After` などのパターンが含まれる** ことで行う (`gh pr view` には `-i` フラグが無いため HTTP ヘッダ直接取得は不可。HTTP status をどうしても見たい場合は `gh api -i repos/<OWNER>/<REPO>/pulls/<PR_NUMBER> --jq .head.sha` のように `gh api` 経由に切り替える)。**最大 2 回** まで再試行し、各再試行の間に **指数 backoff** (`sleep 2` → `sleep 4`) を入れる。2 回目も失敗したら `commit_id` を **省略** して以降の Step に進む (`post-pr-review` は `COMMIT_ID` を任意としているため、SHA 未確定でも Review 自体は投稿できる)。caller への報告で「commit_id 未確定で投稿した」旨を 1 文添える。
  - 判別が困難な場合 (生エラー文字列だけ取れる等) は **transient 扱い** に倒す (recall 重視。誤って即停止するより SHA 省略で進めた方が運用上の損失が小さい)。
- TOCTOU 注意: 本 SHA 取得から Step 4 の `gh pr diff` 実行までの間に PR が force-push されると `commit_id` と diff の line 番号が食い違う。デフォルトでは再取得しないが、caller が `RECHECK_HEAD_SHA=true` を明示的に渡してきた場合は Step 4 の `gh pr diff` 直後に `gh pr view --json headRefOid` を再取得して値が変わっていれば **中断シグナルを返して停止する** (`compose-review` の入力としては optional な真偽値。frequent force-push PR のドッグフーディング系 caller が利用する想定)。

  **中断シグナルのスキーマ** (force-push 検知時の Step 6 出力。run-pr-review Step 3.5 はこれを検知して Step 4/5 を skip し Step 6 で異常終了を caller へ報告する):

  ```json
  {
    "_intermediate": false,
    "_aborted": true,
    "_abort_reason": "head_sha_changed_during_diff",
    "_abort_message": "force-push 検知 (Step 1 取得 SHA <OLD> → Step 4 後 SHA <NEW>) のため処理を中断しました。再実行を推奨。",
    "mode": "pr"
  }
  ```

  - `_aborted: true` を最上位 boolean フィールドとして必ず含める (orchestrator の判定用フック)。
  - `_abort_reason` は machine-readable な識別子 (`head_sha_changed_during_diff` 等)。将来の中断理由追加時もここで列挙する。
  - `_abort_message` は人間向けの 1 文サマリ。`<OLD>` / `<NEW>` は実際の SHA 値で埋める。
  - 他のフィールド (`body` / `event` / `comments[]` / `commit_id` / `_summary_meta` / `next_step` 等) は **省略する** (中断時は意味を持たないため)。
  - `OUTPUT_DESTINATION=file` の場合: 通常の `/tmp/compose-review-output.json` に上記スキーマを Write し、chat には `compose-review (中断): force-push 検知。/tmp/compose-review-output.json に中断シグナルを書き出しました。run-pr-review Step 3.5 で `_aborted: true` を検知したら Step 4/5 を skip して Step 6 で異常終了を caller に報告してください。` の 1 行を出す。
  - `OUTPUT_DESTINATION=chat` の場合: 同スキーマを fenced JSON で chat に出し、前置きサマリで「中断: force-push 検知のため再実行を推奨」と明示する。

#### ローカル diff モード

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD` で取得する。`HEAD` (detached) の場合はエラーとして停止する。
- ベースブランチ: caller から `BASE_BRANCH` が渡されていればそれを使う。未指定なら以下の順で決定する:
  1. `git symbolic-ref` でリモートの既定ブランチ名を取得し、末尾セグメントだけ取り出して純粋なブランチ名にする:
     - **推奨 1 行 (最短経路)**: `git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@'` → `main` のような純粋ブランチ名を得る。
     - **互換ノート**: `--short` が無い古い `git` では `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'` を使う (出力フルパス `refs/remotes/origin/main` から接頭辞を剥がす)。
     - **NG**: フルパス (`refs/remotes/origin/main`) をそのまま `git rev-parse --verify <name>` に渡してはならない。検証は通っても以降の `git diff <base>...HEAD` 等で意図しないリモート追跡参照を比較対象にしてしまう。
     - 得られた純粋ブランチ名 (例: `main`) を `git rev-parse --verify <branch_name>` で確認し、通れば **ローカルの同名ブランチ** を base に採用する (リモート追跡 `origin/<branch_name>` ではない)。
  2. `git rev-parse --verify main` が通れば `main`
  3. `git rev-parse --verify master` が通れば `master`
  4. いずれも取れなければエラーとして停止し、caller に `BASE_BRANCH` を明示するよう促す
- `git diff <base>...HEAD` を実行し、差分モードを以下の優先順位で決定する。**本 step では差分の空 / 非空判定のみを行い、`diff_mode` を確定する**。差分本体 (各行の patch) を読むのは Step 4 で改めて行う (本 step で取得した結果を Step 4 で使い回してもよいが、Step 4 の手順自体は省略しない):
  1. **commit モード**: 差分が空でない → `diff_mode = "commit"`。Step 4 で `git diff <base>...HEAD` をレビュー対象として取得する。
  2. **staged モード**: commit モードの差分が空 → `git diff --cached` を確認し、空でなければ `diff_mode = "staged"`。Step 4 で `git diff --cached` をレビュー対象として取得する。
  3. **worktree モード**: staged モードも空 → `git diff` を確認し、空でなければ `diff_mode = "worktree"`。Step 4 で `git diff` をレビュー対象として取得する。
  4. **差分なし**: 上記すべてが空 → `diff_mode = "none"` とし、**Step 2〜5 を skip して Step 6 へ直行** する。出力 JSON は `body` を「対象差分なし (評価対象なし)」、`comments` を `[]` にする。
- 現在ブランチがベースブランチ自身の場合は commit モードの差分は必ず空になるため、上記フォールバック順に従う。
- 採用した差分モード (`commit` / `staged` / `worktree` / `none`) と解決済みの `base_branch` 名は Step 6 の出力 JSON にそのまま含める (`run-local-review` の caller 報告で使う)。

### Step 2. スタイル参考ガイドを読み込む

同じ skill 配下の `style-reference.md` を `Read` ツールで読み込む。

- `Read` ツールは **絶対パス** を要求するため、本 SKILL.md (`/path/to/.../skills/compose-review/SKILL.md`) と同じディレクトリの `style-reference.md` を絶対パスで指定する。
- **絶対パスの解決手順** (環境依存のため複数のチャネルを試す):
  1. Skill ツール起動 context (Claude Code) で SKILL.md の絶対パスが渡されていれば、その dirname を取って `<dirname>/style-reference.md` を組み立てる (最優先)。
  2. (1) で取れない場合は `Bash` で `find /home /root ~/.claude /workspace -type f -name 'style-reference.md' -path '*pr-review/skills/compose-review*' 2>/dev/null | head -1` を実行して 1 件取る。検索ルートは環境に応じて適宜追加可 (主要展開先: 開発時 `plugins/pr-review/skills/compose-review/` / `/plugin install` 後 `~/.claude/plugins/cache/.../skills/compose-review/` / `apm install` 後 `<consumer>/.claude/skills/compose-review/`)。
  3. (1)(2) いずれも取れなければ style-reference を読み込まずに `style-reference` 規約 (重要度ラベル / ノイズ抑制 / 粒度ガイド等) を skill デフォルトで進める。本 step 失敗を理由とした全体停止はしない (caller への報告で「style-reference 読み込み失敗」を 1 文添えて続行)。
- 読み込んだ内容を本セッションのレビュー方針 (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い) の参考として保持する。
- `MAX_INLINE_COMMENTS` は本 skill の入力として直接適用する (style-reference 側は引数解釈ルールを定義しているのみ)。Step 5 でレビュー本文を組み立てる際にも本キャップ値を改めて参照する。

レビュー方針は caller プロジェクトに委ねる前提。Step 3 のプロジェクト指示ファイルが style-reference に上乗せ・上書き・全置換のいずれを意図しているかは caller の指示に従う。プロジェクト指示ファイルが無ければ style-reference をそのまま採用する。

### Step 3. プロジェクト指示ファイルを読み込む (任意)

リポジトリ root の以下を上から順に存在チェックし、**最初に見つかった 1 つだけ** を読み込み、本セッションのレビュー方針として適用する。以後この skill では総称して **プロジェクト指示ファイル** と呼ぶ。

1. `REVIEW.md` — レビュー専用の最上位指示
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

いずれも存在しなければ skip する。複数存在しても下位は読まない / 連結しない。

#### 取得方法

- **ローカル diff モード**: `Read` ツールで cwd 直下を上記 4 候補の優先順で順に試す。見つかった時点でその内容を採用して終了。
- **PR モード**: まず cwd の git remote と PR の所属リポジトリが一致するかを判定する。判定アルゴリズム:
  1. `git remote get-url origin` で remote URL を取得。
  2. URL から `<owner>/<repo>` を抽出する。**`github.com` の文字列マッチに依存しない汎用ルール**: URL 末尾から `.git` を剥がしたうえで、末尾 2 セグメント (`/<owner>/<repo>`) を取り出す。例: `https://github.com/abeyuya/skills.git` → `abeyuya/skills` / `git@github.com:abeyuya/skills.git` → `abeyuya/skills` / Claude Code on the web のような proxy 形式 `http://local_proxy@127.0.0.1:44277/git/abeyuya/skills` → `abeyuya/skills` のいずれも `abeyuya/skills` に正規化される。
  3. 抽出に失敗した (`/` が無い / セグメントが取れない / 空文字) 場合は **「cwd 非一致」として扱う** (安全側に倒す。PR と無関係なリポジトリの方針を誤適用しない方向)。
  4. 抽出値が本 skill 入力の `OWNER` / `REPO` (大文字小文字区別なし) と一致するなら **cwd 一致モード**、しなければ **cwd 非一致モード**。
  5. `git remote get-url origin` 自体がエラー (remote 未設定 / git リポジトリ外) も「cwd 非一致」扱い。
  - **cwd 一致モード** (通常運用: claude-code-action 等で PR repo を checkout している場合): 4 候補について、優先順で 1 候補ずつ以下の (1)〜(3) を試す:
    1. cwd 直下を `Read`。見つかればその内容を採用して終了。
    2. (1) で見つからなければ `gh api "repos/<OWNER>/<REPO>/contents/<path>?ref=<HEAD_SHA>"` で remote fetch。見つかればその内容を採用して終了。
    3. remote fetch が 404 (またはそれ以外の取得失敗) なら **次の候補に進む**。
  - **cwd 非一致モード** (ドッグフーディング系: 別リポジトリの作業ディレクトリから別 PR をレビューする場合): cwd を **読まず** (PR と無関係なリポジトリの方針を誤適用するのを防ぐため)、4 候補について `gh api "repos/<OWNER>/<REPO>/contents/<path>?ref=<HEAD_SHA>"` の remote fetch のみを試す。404 なら次の候補に進む。
  - **共通**: 4 候補すべての判定が空振りした場合のみ「プロジェクト指示ファイルなし」と判定する。`?ref=<HEAD_SHA>` は **PR head ref を必ず指定する** (`<HEAD_SHA>` は Step 1 で取得済みの `headRefOid`)。省略するとデフォルトブランチから取られるため、PR 内で `REVIEW.md` 等を新設・編集している場合に新方針が反映されない (または逆に古い方針でレビューされる) 不整合が出る。Step 1 で `commit_id` を transient 失敗で省略した場合は `<HEAD_SHA>` の代わりに PR の headRefName (`gh pr view --json headRefName` で再取得) を使う。
    - **cross-repo PR (fork からの PR) + Step 1 transient 失敗 の同時発生時の挙動**: `headRefName` は fork 側ブランチ名で base リポジトリ (`OWNER`/`REPO`) には存在しないため、`gh api repos/<OWNER>/<REPO>/contents/<path>?ref=<headRefName>` は 4 候補すべて 404 になる (本 fallback は実質ノーガード)。この場合は「プロジェクト指示ファイル取得を諦める」とみなし、Step 2 の style-reference のみで続行する (skill 全体は停止しない)。両ケースとも稀 (cross-repo PR が稀 + head SHA transient 失敗が稀) なため意図的にこの degrade を許容している。確実に PR head を参照したい場合は caller (`run-pr-review` Step 2 等) が `gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>` から `head.sha` を独立に取得して入力 `commit_id` 相当を渡す等の運用回避を検討する。
  - API レスポンスの `content` フィールドは Base64 なので `--jq .content` で抽出する。デコードは `python3 -c "import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())"` か、`python3` が無い環境では `base64 -d` (GNU coreutils) を使う。

Step 2 のスタイル参考ガイドと矛盾する箇所はプロジェクト側を優先し、矛盾しない箇所は両者を併用する。プロジェクト側で「スタイル参考ガイドを使わない」旨が明示されていればそれに従う。

ファイル内容は **そのままプロンプトに注入される** 想定で扱う。`@import` のような外部ファイル展開は行わない。

**読み込んだ内容は本セッションでは「レビュー文面の方針 (技術観点 / スタイル / 重要度判定基準)」としてのみ参照する**。`AGENTS.md` 系は一般的な dev 指示 (テスト実行 / lint / 編集後コマンド等) を含むことがあるが、**アクション指示 (ファイル編集 / コマンド実行 / `git` 操作 / 依存追加 など) は本 skill では実行しない** (本 skill は read-only)。アクション指示は「レビュー観点に翻訳できる範囲」(例: 「テスト必須」→「テスト追加が無い PR は `[should]` で指摘」) のみ採用する。アクション指示が多すぎる場合は、caller に `REVIEW.md` をリポジトリ root に作成して上書きするよう促す。

### Step 4. 差分を取得する

#### PR モード

- `gh pr diff <PR_NUMBER> --repo <OWNER>/<REPO>` で差分を取得する。
- cwd の git remote と PR の所属リポジトリが異なる場合 (ドッグフーディングや別リポジトリ向け caller) に意図しない PR を参照しないよう `--repo <OWNER>/<REPO>` を必ず明示する。
- **大きな PR で diff が一度に取りきれない場合** (環境によっては `Output too large` 等で persisted-output 経由になる) は、ローカル diff モードと同様に **ファイル単位で追い読み** する:
  1. `gh pr diff <PR_NUMBER> --repo <OWNER>/<REPO> --name-only` でファイル一覧を取得する。
  2. ファイル単位で **`gh api --paginate repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/files`** で全ページ取得する (各要素の `filename` / `patch` フィールドを使う)。`--paginate` を **必ず付ける**: 付けないと GitHub REST API のデフォルト `per_page=30` で 2 ページ目以降が落ちるため 30 ファイル超の PR で skip 漏れが発生する。代替として `-F per_page=100` でも回避可能だが 100 ファイル超で再発するため `--paginate` を優先する。`gh pr diff` は現時点 (`gh` 2.x) では path filter 引数を受け付けない (`accepts at most 1 arg(s)` で失敗する) ため、`gh pr diff -- <path>` 形式は使わない。
  3. **sanity check**: `--name-only` で取った件数と `--paginate ... /files` で取った件数を突合する。一致しなければ取得漏れがあるので caller への報告 `body` に「ファイル一覧と取得済み件数が一致しません (`<N>` vs `<M>`)」と 1 文添え、可能な範囲でレビューを続行する。
  4. レビュー観点上重要そうなファイル (テスト・設定・SQL・migration・workflow 等) を優先的に読み、明らかにレビュー対象外 (lockfile / generated file / `*.snap`) は skip してよい。skip したファイル群があれば総括 (`body`) に「`<件数>` 件を分量過多のため未レビュー (代表: …)」と 1 文添えて caller に明示する。
- **差分が空の場合** (例: 全変更が revert された / caller 側で事前 filter された結果空になった等; 本 skill は generated file の **自動 filter は行わない** ので、`gh pr diff` 自体が空 ≠ 「ファイルは存在するが skip した」状態) は、ローカル diff モードの「差分なし」分岐と同様に **Step 5 を skip して Step 6 へ直行** する。出力 JSON は `body` を「対象差分なし (評価対象なし)」、`comments` を `[]` にする。`mode` は `"pr"` のまま。`commit_id` は Step 1 で取得済みならそのまま含め、Step 1 で transient 失敗のため省略した場合は本分岐でも引き続き省略する (`gh api .../reviews` に空文字を渡すと 422 になるため未定義値を入れない)。**`_intermediate` / `next_step` の値は通常分岐と同じく `OUTPUT_DESTINATION` の指定に従う** (`file` モード: `_intermediate: true` + `next_step: "post-pr-review"`、`chat` モード: `_intermediate: false` + `next_step` 省略)。本分岐でも Review 自体は `post-pr-review` 経由で投稿する設計のため、orchestrator は次 step に進む。

#### ローカル diff モード

リモートに無いコミットも対象にするため、`git fetch` 等は走らせない (caller 側の意思を尊重)。Step 1 で決定した差分モードに応じて以下の通り取得する:

- **commit モード**:
  - `git log <base>..HEAD --oneline` でコミット一覧を取得する。
  - `git diff <base>...HEAD` で差分本体を取得する。三点記法 (`...`) を用いて、ベースブランチ側の進行は除外し「現在ブランチで増えた変更」だけを対象にする。
  - 差分が大きく一度に取りきれない場合は、`git diff --stat <base>...HEAD` でファイル一覧をまず取り、ファイル単位で `git diff <base>...HEAD -- <path>` を必要な範囲だけ追い読みする。
- **staged モード**:
  - コミット一覧は空 (コミット未作成のため)。
  - `git diff --cached` でステージ済み差分を取得する。
  - 差分が大きい場合は `git diff --cached --stat` でファイル一覧を取り、ファイル単位で `git diff --cached -- <path>` を追い読みする。
- **worktree モード**:
  - コミット一覧は空。
  - `git diff` で作業ツリー差分を取得する。
  - 差分が大きい場合は `git diff --stat` でファイル一覧を取り、ファイル単位で `git diff -- <path>` を追い読みする。

### Step 5. レビュー本文を作成する

Step 2〜4 で得た方針・観点・差分 (および PR モードで渡されていれば `EXISTING_THREADS_CONTEXT` / `CI_FAILURE_CONTEXT`) をもとに、総括 (`body`) とインライン指摘 (`comments[]`) を作成する。

- レビュー方針は Step 3 のプロジェクト指示ファイルを最優先とし、明示的に上書きされていない論点については Step 2 の style-reference (重要度ラベル / ノイズ抑制 / 粒度ガイド等) を参考にする。プロジェクト指示ファイル側で style-reference を使わない旨が明示されていればそれに従う。
- 既存スレッドと同主旨の指摘は再掲しない (`EXISTING_THREADS_CONTEXT` が渡された場合はその主旨と突き合わせる)。位置 `path:line` が一致しても論点が別なら新規指摘してよい。caller (`run-pr-review`) は `EXISTING_THREADS_CONTEXT` に **各スレッドの `path:line` を必ず併記** した上で主旨を 1〜2 文で要約した形式で渡す前提で扱う (自由文の段落要約では path:line が落ちて dedupe 精度が下がる)。
- `CI_FAILURE_CONTEXT` が渡されている場合は style-reference の「CI の扱い」セクションに従う。
- `event` は **常に `"COMMENT"`** とする (`post-pr-review` の規約)。`[must]` の有無にかかわらず `COMMENT` で投稿し、修正の要否は本文 (`body`) と各インライン (`comments[]`) の `[must]` ラベルで伝える。
- 指摘が無い場合も Step 6 で「特に指摘なし」相当の JSON を返す (skip しない)。
- AI 自動投稿マーカーは **付けない** (`post-pr-review` が一律 prepend するため)。`body` は生本文。
- `MAX_INLINE_COMMENTS` が正の整数で渡されている場合は、style-reference の「`MAX_INLINE_COMMENTS` の扱い」セクションに従って **`comments[]` の総数を N 件以下に絞る**。優先度は `[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`。N 超過で省略した指摘がある場合は `body` に「省略した件数 + ラベル別内訳」を 1 文添える。`comments[]` を組み立てる **手順の順序** は次に固定する (順序が変わると同じ件数でも残る指摘が変わる):
  1. 差分から生指摘を抽出する。
  2. `EXISTING_THREADS_CONTEXT` が渡されていれば、既存スレッドと同主旨の指摘を **dedupe で落とす**。ただし **重要度が既存より高い場合は別主旨として残す** (例: 既存スレッドが `[nit]` 「ここは A の代わりに B を使うべき」だが新規指摘が `[must]` 「ここは A だと SQL injection が発生する」なら、論点の深刻度が違うので別指摘として残す)。`[must]` / `[should]` の指摘は dedupe で抑制されると実害が大きいため、判定に迷う場合は **残す方向に倒す**。
  3. ノイズ抑制ルール (フォーマッタレベル除外 / 同一事象は代表 1 箇所のみ等) を適用する。
  4. 重要度ラベルで優先度ソート (`[must]` > `[should]` > ...) する。
  5. `MAX_INLINE_COMMENTS` 指定があれば、上位から N 件にカットする (`unlimited` ならカットしない)。
  6. N 超過で省略があれば `body` の総括に省略件数とラベル別内訳を 1 文添える。
- 上記過程で得た集計値は **`_summary_meta` 構造化フィールド** として Step 6 の出力 JSON に必ず含める。orchestrator (`run-pr-review` Step 6 等) が `body` の Markdown をパースせずに集計値を取れるようにする。フィールド構成:
  - `inline_count`: `comments[]` の最終件数 (カット後)。
  - `inline_count_by_severity`: `{ "must": N, "should": N, "nit": N, "question": N, "pre_existing": N }`。各キーは必ず含め、該当指摘が無ければ `0`。
  - `main_concerns_count`: `body` 内の「主要懸念 top3」相当に列挙した件数 (style-reference の粒度ガイドに従い 0〜3 を想定)。
  - `praises_count`: `body` 内の「良かった点」相当に列挙した件数 (0〜2 を想定)。
  - `omitted_count`: `MAX_INLINE_COMMENTS` 超過でカットした件数 (カット無しなら `0`)。
  - これらの値は `body` Markdown の見出しに依存しない (style-reference 規約が将来揺れても集計が壊れない) 形で本 skill が責任を持って算出する。

### Step 6. JSON を出力する

`post-pr-review` のスキーマに揃った JSON を、入力 `OUTPUT_DESTINATION` に応じて出力先を切り替える。

#### `OUTPUT_DESTINATION=file` (`run-pr-review` から呼ばれる際は必須)

`Write` ツールで JSON 本体を `/tmp/compose-review-output.json` に書き出す。チャット側は **「次にやること」を含む 1 行** を出力する。

**サマリの形式 (必ずこの形に揃える)**:

```
compose-review (中間成果物): /tmp/compose-review-output.json 生成完了 (インライン指摘 N 件 / 主要懸念 M 件)。**次は run-pr-review Step 3.5: Read → Step 4: post-pr-review 呼び出し。ここでターンを終えてはいけない**。
```

- `(中間成果物)` の修飾語を付けることで「完了報告」ではなく「中継状態」であることを視覚的に示す。
- 文末を「生成完了」「投稿完了」のような完了形で締めず、**`次は ...` で続けて「次の動作」を明示**する。
- **「ここでターンを終えてはいけない」を必ず含める**。chat に出る最後の文が完了報告風だと orchestrator が処理を打ち切る慣性に負ける既知の問題への対策 (PR #34 で 3 回再発)。

その他の制約:

- **fenced JSON ブロックを chat に出さない**。chat 上に大きなアウトプットを残さないことで、orchestrator が「JSON 出力 = タスク完了」と誤認する構造的リスクを取り除く。
- `Write` ツールは中間ディレクトリの自動作成を保証しないが `/tmp/` は通常存在するので `mkdir -p` は不要。**Claude Code の Write tool は「同一セッション中に Read されていない既存ファイルへの上書き」を拒否する仕様**のため、`/tmp/compose-review-output.json` が前回呼び出しで残存している可能性に対処する。**手順**:
  1. `Bash` ツールで `test -f /tmp/compose-review-output.json` を実行 (exit code 0 = 存在 / 非ゼロ = 不在)。
  2. 存在する場合のみ `Read` ツールを 1 回挟む (Write tool の上書き許可を取るため)。
  3. 不在の場合は `Read` を呼ばずそのまま `Write` に進む (Read tool はファイル不在で例外停止する仕様のため、不在を `test -f` で事前判定して Read 自体を skip する)。
  4. `Write` ツールで JSON を書き出す。

#### `OUTPUT_DESTINATION=chat` (デフォルト、`run-local-review` から呼ばれる際 / 人間が直接 `/compose-review` を叩く際の挙動)

JSON を fenced ブロックで chat に出力する。fenced ブロックの **前** に 1〜2 行の人間向けサマリ (例: `インライン指摘 3 件 / 主要懸念 2 件`) を添える。caller (人間) が直接読めるようにする用途。

**chat モードでは orchestrator 向け meta フィールドをフィルタする** (人間が読んで紛らわしいため):

- `_intermediate` は **常に `false`** にする (chat = 最終成果物扱い)。
- `next_step` は **JSON から除外** する (PR モードでも含めない)。
- `_summary_meta` は **そのまま含める** (人間にも参照価値があり、`inline_count` 等の集計値が見えても紛らわしくないため)。
- その他のフィールド (`mode` / `body` / `event` / `comments[]` / `commit_id` / `base_branch` / `diff_mode`) は通常通り。

これにより PR モードで `/compose-review OWNER=... REPO=... PR_NUMBER=...` を人間が直接叩いた場合も `_intermediate: false` / `next_step` 無しの JSON が返り、「次に何かしないといけないのか?」という誤解を起こさない。orchestrator 経由で post-pr-review まで連鎖したい場合は `OUTPUT_DESTINATION=file` を使う前提。

#### 共通

**本 step を実行したからといって、本 skill (orchestrator から呼ばれている場合) の責務は終わりではない**。`_intermediate: true` を含む JSON を返した場合、orchestrator は **後続 skill (`post-pr-review` 等) まで実行責任がある**。本 skill から見れば本 step で出力が完了するが、本 skill を呼んだ orchestrator は出力を受け取った後で必ず次 step (run-pr-review なら Step 3.5 → 4 → 5 → 6) まで進む前提。

スキーマ (PR モード + `OUTPUT_DESTINATION=file` 例; chat モードでは `_intermediate: false` / `next_step` 削除):

```json
{
  "_intermediate": true,
  "next_step": "post-pr-review",
  "mode": "pr",
  "body": "総括コメント本文 (Markdown 可)",
  "event": "COMMENT",
  "comments": [
    {
      "path": "src/example.ts",
      "line": 42,
      "side": "RIGHT",
      "body": "[should] ここの処理は..."
    },
    {
      "path": "src/example.ts",
      "start_line": 50,
      "start_side": "RIGHT",
      "line": 55,
      "side": "RIGHT",
      "body": "[must] この複数行ブロックは..."
    }
  ],
  "commit_id": "9f8e7d6c1a2b3c4d5e6f7890abcdef1234567890",
  "_summary_meta": {
    "inline_count": 2,
    "inline_count_by_severity": { "must": 1, "should": 1, "nit": 0, "question": 0, "pre_existing": 0 },
    "main_concerns_count": 2,
    "praises_count": 1,
    "omitted_count": 0
  }
}
```

ローカル diff モード例 (常に `OUTPUT_DESTINATION=chat`):

```json
{
  "_intermediate": false,
  "mode": "local",
  "base_branch": "main",
  "diff_mode": "commit",
  "body": "総括コメント本文",
  "event": "COMMENT",
  "comments": [],
  "_summary_meta": {
    "inline_count": 0,
    "inline_count_by_severity": { "must": 0, "should": 0, "nit": 0, "question": 0, "pre_existing": 0 },
    "main_concerns_count": 0,
    "praises_count": 0,
    "omitted_count": 0
  }
}
```

- `_intermediate`: 真偽値 (必須)。**`true` なら orchestrator は本 JSON を中間成果物として扱い、`next_step` で示される後続 skill にそのまま転送する**。`false` なら本 JSON は最終成果物として caller に提示してよい (`run-local-review` 経由のローカル diff モードがこのケース)。fenced JSON ブロックを返したら処理完了、と orchestrator が誤認するのを防ぐためのメタ情報。
- `next_step`: 次に呼ぶべき skill 名 (`_intermediate: true` の場合のみ含める)。現状は PR モードで `"post-pr-review"` 固定。ローカルモードでは省略。
- `mode` は `"pr"` または `"local"`。**実行モードを正しく反映する**。caller が分岐しやすいよう常に含める。PR モード例の `"pr"` をローカルモードでもコピー貼り付けすると caller の分岐が壊れるので注意。
- 単一行コメントは `path` / `line` / `side` を指定する。
- 複数行範囲のコメントは上記に加えて `start_line` / `start_side` を併用する (`start_line` は `line` より前の行)。
- `commit_id` は **PR モードのみ** 含める。ローカルモードでは省略する。PR モードで Step 1 の head SHA 取得が transient 失敗で諦めた場合も省略する (詳細は Step 1 PR モード参照)。
- `base_branch` / `diff_mode` は **ローカル diff モードでは必須** (省略不可)、PR モードでは含めない。`base_branch` は Step 1 で解決したベースブランチ名 (`main` / `master` / caller 指定値)、`diff_mode` は `"commit"` / `"staged"` / `"worktree"` / `"none"` のいずれか (`"none"` は差分なしで Step 2〜5 を skip した場合)。orchestrator (`run-local-review`) はこの 2 フィールドが必ず存在する前提で caller への報告に使う。
- 指摘が無い場合: `body` は「特に指摘なし」相当の文言、`comments` は `[]`、`_summary_meta` は全カウント `0`。
- 差分が空で Step 2〜5 を skip した場合: `body` は「対象差分なし (評価対象なし)」相当、`comments` は `[]`、`_summary_meta` は全カウント `0`。ローカルモードでは `diff_mode: "none"`、PR モードでは PR 自体には差分が存在しないため通常運用では発生しにくいが同様に空 `comments[]` で返す。
- `_summary_meta`: 構造化された集計値 (必須、両モード共通)。`inline_count` / `inline_count_by_severity` / `main_concerns_count` / `praises_count` / `omitted_count` を含む。詳細は Step 5 末尾の定義を参照。orchestrator (`run-pr-review` Step 6 等) はこのフィールドから集計値を取る前提で、`body` Markdown をパースしてはならない。

JSON ファイルへの書き出しは `OUTPUT_DESTINATION=file` 経由の `/tmp/compose-review-output.json` を **例外** とし、それ以外 (任意パスへの書き出し / 複数ファイル分割 / debug 用ログファイル等) は行わない。markdown ファイル出力も行わない。caller が `post-pr-review` に渡す際の `/tmp/review.json` の組み立ては `post-pr-review` 側が責任を持つ (本 skill が `/tmp/review.json` を直接書くことはない)。

## 守ること

- `post-pr-review` / `resolve-pr-threads` は呼ばない (orchestrator の責務)。
- `gh pr review` / `gh pr comment` / `gh api .../reviews` を直接叩かない。レビュー投稿は本 skill の責務外。
- `git fetch` / `git pull` / `git checkout` / `git reset` / `git commit` / `git push` 等の書き換え操作は使わない。read-only の git コマンド (`git rev-parse` / `git log` / `git diff` / `git symbolic-ref` / `git remote get-url`) のみ。
- CI failure log の **収集** や reviewThreads の **取得** は本 skill では行わない (caller が `CI_FAILURE_CONTEXT` / `EXISTING_THREADS_CONTEXT` 経由で渡す前提)。
- AI 自動投稿マーカーは付けない (`post-pr-review` が prepend する)。
- markdown ファイル出力は行わない (`OUTPUT_PATH` 引数も持たない)。
- 既存資産 (`style-reference.md`) は **必ず `Read` ツール経由で利用** する。本 skill 内でラベル定義やノイズ抑制ルールを再掲しない (二重管理を避けるため)。
