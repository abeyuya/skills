#!/usr/bin/env bash
# compose-review skill / 変更ファイル一覧・祖先 REVIEW.md の列挙・5-4 の発火判定 (deterministic)。
#
# SKILL.md「共通規約: 変更ファイル一覧の取得」の処理をまとめて行い、結果を JSON 1 つに書き出す。
# モデルが NUL 区切り・quote・改行・404 と FATAL の区別を文章で再現しなくて済むようにするためのスクリプト。
#
# 入力 (環境変数):
#   MODE          : pr | local (必須)
#   --- PR モード ---
#   HEAD_SHA / BASE_SHA : Step 1 で確定した 40 桁の commit SHA (必須)
#   OWNER / REPO / PR_NUMBER : gh 経路で使う (SOURCE=git のときは不要)
#   SOURCE        : auto (既定) | git | gh
#                   auto = git 経路を試し、head / base の object が無い・git diff が fatal なら gh 経路に degrade する
#   --- ローカルモード ---
#   DIFF_MODE     : commit | staged | worktree (必須)
#   BASE_BRANCH   : DIFF_MODE=commit のとき必須 (Step 1 で解決したベースブランチ名)
#   --- 共通 ---
#   OUTPUT_PATH   : 結果 JSON の書き出し先。省略時は一意の temp ディレクトリ配下の result.json
#
# 出力: OUTPUT_PATH に JSON を書き、stdout にそのパスを 1 行出す。キー:
#   mode / source ("git" | "gh" | "gh-pr-diff" | "local") / range
#   fatal            : null または理由の文字列。null 以外なら他のキーを使わない (空リストと読まない)
#   git_error        : SOURCE=auto で git 経路を諦めた理由 (degrade した回のみ。それ以外は null)
#   head_object / base_object : PR モードで各 commit object がローカルにあるか (真偽値)
#   changed_files    : `--no-renames` 相当の一覧 (rename は移動元と移動先の両方)。祖先探索と 5-4 の判定に使った一覧
#   range_files      : rename を既定のまま数えた一覧 (移動先のみ)。5-3 の範囲外除外と 5-2 リカバリの件数突合用
#   changed_count / range_count : 上記の件数 (JSON に載せられないパスも含めた実件数)
#   lossy_paths      : changed_files のうち不正な UTF-8 を含み JSON で正確に表せなかったパスの件数 (配列中は U+FFFD に化ける)
#   ancestor_candidates : 祖先 REVIEW.md の候補 (存在確認前・node_modules/ vendor/ 除外済み)。5-4 の base 側走査用
#   ancestor_review_md  : 存在する祖先 REVIEW.md。root → 親 → 子 (`/` の少ない順) で
#                         [{path, depth, changed_files_under}]。changed_files_under は Step 3 の間引きの優先度用
#   excluded_review_md  : 改行を含む / JSON で正確に表せないため読まずに除外した REVIEW.md の件数 (body で開示)
#   instruction_files_touched       : 5-4「判定基準の自己回避を防ぐ」の発火有無
#   instruction_files_touched_paths : 発火の根拠になったパス
#   list_degraded    : gh pr diff --name-only で代替した回は true (パッチ見出し由来で quote が崩れうる)
#
# exit: 0 = 正常 / 3 = fatal (JSON は書き出し済み。.fatal に理由) / 2 = 引数エラー (JSON なし) / 1 = 内部エラー (JSON なし)
#
# bash 互換要件: **bash 3.2 (macOS 標準の /bin/bash) で動くこと** (distill-pr-reviews/scripts/collect-signals.sh と同じ)。
#   NG: mapfile / readarray, declare -A, ${var^^} / ${var,,}, wait -n, coproc。
#   set -u 下の空配列展開は `${arr[@]+"${arr[@]}"}` の形で書く。
# 依存: git / jq (gh 経路のみ gh)。
# read-only: 作業ツリー・ローカル ref・index を一切変えない (git diff / git cat-file / gh api の GET のみ)。
#   PR モードは cwd の作業ツリーを読まない (存在確認は head の tree に対して行う)。

set -euo pipefail

# 想定外の失敗 (jq / git の異常終了など) は exit 1 に揃え、書きかけの JSON を残さない。
# jq 自身の終了コード (2 / 3 / 5) が、このスクリプトの「引数エラー」「fatal」と取り違えられないようにするため。
EXIT_KIND=""
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$EXIT_KIND" ]; then
    [ -n "${OUTPUT_PATH:-}" ] && rm -f "$OUTPUT_PATH"
    echo "[changed-files] internal error (exit $rc)" >&2
    exit 1
  fi
}
trap on_exit EXIT

log() { echo "[changed-files] $*" >&2; }
die_usage() { EXIT_KIND=usage; echo "[changed-files] usage error: $*" >&2; exit 2; }

MODE="${MODE:-}"
SOURCE="${SOURCE:-auto}"
HEAD_SHA="${HEAD_SHA:-}"
BASE_SHA="${BASE_SHA:-}"
OWNER="${OWNER:-}"
REPO="${REPO:-}"
PR_NUMBER="${PR_NUMBER:-}"
DIFF_MODE="${DIFF_MODE:-}"
BASE_BRANCH="${BASE_BRANCH:-}"
OUTPUT_PATH="${OUTPUT_PATH:-}"

command -v jq >/dev/null 2>&1 || die_usage "jq が見つからない"

is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

case $MODE in
  pr)
    is_sha "$HEAD_SHA" || die_usage "HEAD_SHA が 40 桁の SHA ではない: '$HEAD_SHA'"
    is_sha "$BASE_SHA" || die_usage "BASE_SHA が 40 桁の SHA ではない: '$BASE_SHA'"
    case $SOURCE in auto|git|gh) ;; *) die_usage "SOURCE は auto / git / gh: '$SOURCE'" ;; esac
    # 空は許す (auto で git 経路が通れば不要)。値があるなら URL に埋め込める形であること
    [ -z "$OWNER" ] || printf '%s' "$OWNER" | grep -Eq '^[A-Za-z0-9._-]+$' || die_usage "OWNER が不正: '$OWNER'"
    [ -z "$REPO" ] || printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9._-]+$' || die_usage "REPO が不正: '$REPO'"
    [ -z "$PR_NUMBER" ] || printf '%s' "$PR_NUMBER" | grep -Eq '^[0-9]+$' || die_usage "PR_NUMBER が不正: '$PR_NUMBER'"
    if [ "$SOURCE" = gh ] && { [ -z "$OWNER" ] || [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; }; then
      die_usage "SOURCE=gh には OWNER / REPO / PR_NUMBER が必要"
    fi
    ;;
  local)
    case $DIFF_MODE in
      commit) [ -n "$BASE_BRANCH" ] || die_usage "DIFF_MODE=commit には BASE_BRANCH が必要" ;;
      staged|worktree) ;;
      *) die_usage "DIFF_MODE は commit / staged / worktree: '$DIFF_MODE'" ;;
    esac
    ;;
  *) die_usage "MODE は pr / local: '$MODE'" ;;
esac

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/compose-review-files-XXXXXX")
if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="$WORK_DIR/result.json"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"

NAMES="$WORK_DIR/names.z"   # --no-renames の一覧 (NUL 区切り)
RANGE="$WORK_DIR/range.z"   # rename 既定の一覧 (NUL 区切り)
: > "$NAMES"; : > "$RANGE"

FATAL=""
GIT_ERROR=""
USED_SOURCE=""
RANGE_DESC=""
LIST_DEGRADED=false
HEAD_OBJ=false
BASE_OBJ=false

write_fatal() {
  EXIT_KIND=fatal
  jq -n --arg mode "$MODE" --arg fatal "$1" --arg source "$USED_SOURCE" \
    '{mode: $mode, source: (if $source == "" then null else $source end), fatal: $fatal}' > "$OUTPUT_PATH"
  log "FATAL: $1"
  echo "$OUTPUT_PATH"
  exit 3
}

# ---------- 一覧の取得 ----------

git_lists() {
  # $1 以降: git diff に渡す範囲引数。成功時 0。
  local err
  if ! err=$(git diff --name-only -z --no-renames "$@" 2>&1 >"$NAMES"); then
    GIT_ERROR="git diff --no-renames が失敗: $err"; return 1
  fi
  if ! err=$(git diff --name-only -z "$@" 2>&1 >"$RANGE"); then
    GIT_ERROR="git diff が失敗: $err"; return 1
  fi
  return 0
}

gh_lists() {
  local raw="$WORK_DIR/files.json" err cur total got
  # force-push 検知: gh の一覧は常に PR の現 head のものなので、HEAD_SHA と一致しなければ使わない
  if ! gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER" >"$WORK_DIR/pull.json" 2>"$WORK_DIR/gh.err" \
     || ! cur=$(jq -r '.head.sha // empty' <"$WORK_DIR/pull.json") \
     || ! total=$(jq -r '.changed_files // empty' <"$WORK_DIR/pull.json"); then
    FATAL="gh api pulls/$PR_NUMBER が失敗: $(head -c 500 "$WORK_DIR/gh.err")"; return 1
  fi
  if [ "$cur" != "$HEAD_SHA" ]; then
    FATAL="PR の現 head ($cur) が HEAD_SHA ($HEAD_SHA) と一致しない (force-push の可能性。再実行が必要)"; return 1
  fi
  if gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/files" >"$raw" 2>"$WORK_DIR/gh.err"; then
    # --paginate はページごとの配列を連結して出すので、jq は複数の値として順に読む。
    # JSON 文字列から直接 NUL 区切りで書くので、改行を含む filename も 1 件のまま扱える。
    if ! jq -j '.[] | .filename, (.previous_filename // empty) | . + "\u0000"' <"$raw" >"$NAMES" \
       || ! jq -j '.[] | .filename | . + "\u0000"' <"$raw" >"$RANGE"; then
      FATAL="gh api pulls/$PR_NUMBER/files の応答を解釈できない"; return 1
    fi
    # pulls/<N>/files は 3000 件で打ち切られる。欠けた一覧を完全なものとして扱うと、
    # 切り捨て側の REVIEW.md で 5-4 が発火せず、祖先 REVIEW.md も黙って抜けるので fatal にする
    got=$(jq -s 'map(length) | add // 0' <"$raw") || { FATAL="gh api pulls/$PR_NUMBER/files の応答を解釈できない"; return 1; }
    if [ -n "$total" ] && [ "$got" != "$total" ]; then
      FATAL="gh api pulls/$PR_NUMBER/files が $got 件しか返さない (PR の変更ファイルは $total 件。API の上限で打ち切られた可能性)"; return 1
    fi
    USED_SOURCE=gh
    return 0
  fi
  err=$(head -c 500 "$WORK_DIR/gh.err")
  log "gh api pulls/$PR_NUMBER/files が失敗 ($err)。gh pr diff --name-only で代替する"
  if gh pr diff --name-only "$PR_NUMBER" --repo "$OWNER/$REPO" >"$WORK_DIR/names.txt" 2>"$WORK_DIR/gh.err"; then
    # パッチ見出し由来なので改行を含むパスは表せない (行 = 1 件)
    tr '\n' '\0' <"$WORK_DIR/names.txt" >"$NAMES"
    cp "$NAMES" "$RANGE"
    USED_SOURCE=gh-pr-diff
    LIST_DEGRADED=true
    return 0
  fi
  FATAL="gh 経路でも一覧を取得できない: gh api: $err / gh pr diff: $(head -c 500 "$WORK_DIR/gh.err")"
  return 1
}

if [ "$MODE" = pr ]; then
  RANGE_DESC="$BASE_SHA...$HEAD_SHA"
  git cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null && HEAD_OBJ=true
  git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null && BASE_OBJ=true
  git_ok=false
  if [ "$SOURCE" != gh ]; then
    if [ "$HEAD_OBJ" != true ] || [ "$BASE_OBJ" != true ]; then
      GIT_ERROR="commit object がローカルに無い (head=$HEAD_OBJ base=$BASE_OBJ)"
    elif git_lists "$RANGE_DESC"; then
      git_ok=true
      USED_SOURCE=git
    fi
  fi
  if [ "$git_ok" != true ]; then
    if [ "$SOURCE" = git ]; then
      write_fatal "git 経路で一覧を取得できない: $GIT_ERROR"
    fi
    if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
      write_fatal "git 経路で一覧を取得できず (${GIT_ERROR}), gh 経路に必要な OWNER / REPO / PR_NUMBER も無い"
    fi
    command -v gh >/dev/null 2>&1 || write_fatal "git 経路で一覧を取得できず (${GIT_ERROR}), gh も無い"
    [ -n "$GIT_ERROR" ] && log "git 経路を諦めて gh 経路に degrade: $GIT_ERROR"
    gh_lists || write_fatal "$FATAL"
  fi
else
  USED_SOURCE=local
  top=$(git rev-parse --show-toplevel 2>/dev/null) || write_fatal "git リポジトリの中で実行されていない"
  cd "$top"
  case $DIFF_MODE in
    commit)   RANGE_DESC="$BASE_BRANCH...HEAD"; git_lists "$RANGE_DESC" || write_fatal "$GIT_ERROR" ;;
    staged)   RANGE_DESC="--cached";            git_lists --cached     || write_fatal "$GIT_ERROR" ;;
    worktree) RANGE_DESC="worktree";            git_lists              || write_fatal "$GIT_ERROR" ;;
  esac
  GIT_ERROR=""
fi

# ---------- 祖先 REVIEW.md の候補 ----------
# 親ディレクトリは ${d%/*} で求める ($(dirname) は末尾の改行を削るので、改行で終わるディレクトリ名が化ける)。

CAND="$WORK_DIR/candidates.z"
while IFS= read -r -d '' p; do
  d=$p
  while :; do
    case $d in */*) d=${d%/*} ;; *) d=. ;; esac
    if [ "$d" = . ]; then c=REVIEW.md; else c=$d/REVIEW.md; fi
    case /$c in */node_modules/*|*/vendor/*) ;; *) printf '%s\0' "$c" ;; esac
    [ "$d" = . ] && break
  done
done <"$NAMES" | LC_ALL=C sort -zu >"$CAND"

# ---------- 存在確認 ----------

EXIST="$WORK_DIR/existing.z"
: >"$EXIST"
exist_fatal=""
encode_path() { jq -rn --arg p "$1" '$p | split("/") | map(@uri | gsub("!"; "%21") | gsub("\\*"; "%2A") | gsub("'"'"'"; "%27") | gsub("\\("; "%28") | gsub("\\)"; "%29")) | join("/")'; }

while IFS= read -r -d '' c; do
  case $USED_SOURCE in
    git)
      # tree ではなく blob であることまで確かめる (REVIEW.md という名前のディレクトリを拾わない)
      t=$(git cat-file -t "$HEAD_SHA:$c" 2>/dev/null) || continue
      [ "$t" = blob ] || continue
      ;;
    gh|gh-pr-diff)
      enc=$(encode_path "$c")
      if ! err=$(gh api --silent -H 'Accept: application/vnd.github.raw' "repos/$OWNER/$REPO/contents/$enc?ref=$HEAD_SHA" 2>&1); then
        case $err in
          *'HTTP 404'*) continue ;;
          *) exist_fatal="$exist_fatal$c: $(printf '%s' "$err" | head -c 300)"$'\n'; continue ;;
        esac
      fi
      ;;
    local)
      [ -f "$c" ] || continue
      ;;
  esac
  printf '%s\0' "$c" >>"$EXIST"
done <"$CAND"

if [ -n "$exist_fatal" ]; then
  # 404 以外の失敗を候補不在と同じに扱うと、祖先の REVIEW.md とそこにしかない基準が黙って落ちる
  write_fatal "祖先 REVIEW.md の存在確認が 404 以外で失敗した: $exist_fatal"
fi

# ---------- 5-4 の発火判定 ----------
# 改行を含むパスも NUL 区切りのまま 1 件として判定する。`*` は `/` と改行にも一致する。

TOUCHED="$WORK_DIR/touched.z"
: >"$TOUCHED"
while IFS= read -r -d '' p; do
  case $p in
    REVIEW.md|*/REVIEW.md|AGENTS.md|.claude/CLAUDE.md|CLAUDE.md) printf '%s\0' "$p" >>"$TOUCHED" ;;
  esac
done <"$NAMES"

# ---------- JSON 組み立て ----------
# NUL 区切りのファイルを jq -Rs で読み、NUL で split する (不正な UTF-8 は U+FFFD に置き換わる)。

zlist='split("\u0000") | map(select(length > 0))'
# プロセス置換の中の失敗は検知できないので、先に一時ファイルへ変換して終了コードを確かめる
for z in NAMES RANGE CAND EXIST TOUCHED; do
  eval "zf=\$$z"
  jq -Rs "$zlist" <"$zf" >"$zf.json" || write_fatal "一覧の JSON 化 (jq) が失敗: $z"
done

jq -n \
  --arg mode "$MODE" \
  --arg source "$USED_SOURCE" \
  --arg range "$RANGE_DESC" \
  --arg git_error "$GIT_ERROR" \
  --argjson head_object "$HEAD_OBJ" \
  --argjson base_object "$BASE_OBJ" \
  --argjson list_degraded "$LIST_DEGRADED" \
  --slurpfile names "$NAMES.json" \
  --slurpfile rng "$RANGE.json" \
  --slurpfile cand "$CAND.json" \
  --slurpfile exist "$EXIST.json" \
  --slurpfile touched "$TOUCHED.json" \
  '
  def lossy: test("�");
  def depth: [scan("/")] | length;
  ($names[0]) as $n
  | ($exist[0]) as $e
  | ($e | map(select((test("\n") or lossy) | not))) as $ok
  | {
      mode: $mode,
      source: $source,
      range: $range,
      fatal: null,
      git_error: (if $git_error == "" then null else $git_error end),
      head_object: (if $mode == "pr" then $head_object else null end),
      base_object: (if $mode == "pr" then $base_object else null end),
      list_degraded: $list_degraded,
      changed_count: ($n | length),
      range_count: ($rng[0] | length),
      lossy_paths: ($n | map(select(lossy)) | length),
      changed_files: $n,
      range_files: $rng[0],
      ancestor_candidates: $cand[0],
      ancestor_review_md: (
        $ok
        | map(. as $c
              | ($c | sub("REVIEW\\.md$"; "")) as $dir
              | {path: $c, depth: ($c | depth),
                 changed_files_under: ([$n[] | select(startswith($dir))] | length)})
        | sort_by(.depth)
      ),
      excluded_review_md: (($e | length) - ($ok | length)),
      instruction_files_touched: (($touched[0] | length) > 0),
      instruction_files_touched_paths: $touched[0]
    }
  ' >"$OUTPUT_PATH"

echo "$OUTPUT_PATH"
