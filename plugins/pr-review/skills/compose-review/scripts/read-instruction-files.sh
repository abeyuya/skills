#!/usr/bin/env bash
# compose-review skill / プロジェクト指示ファイルの全文取得とエスカレーション基準の見出し検出 (deterministic)。
#
# SKILL.md Step 3「取得方法」「全文を取得する (打ち切り禁止)」と、5-4 の base / head 突き合わせで使う。
# 指示ファイルを 1 つの取得元から全文取得して一時ファイルに保存し、同じファイルに対して
#   - 行数 (grep -c '' と同じ数え方。末尾改行なしの最終行も 1 行と数える)
#   - `エスカレーション基準` を含む ATX 見出し (フェンスドコードブロックの内側は除外) とその配下のセクション本文
# を求めて JSON に書き出す。取得元と探索元が必ず一致するので、打ち切り・取得元の食い違いが起きない。
#
# 入力 (環境変数):
#   SOURCE : git | gh | local (必須)
#            git   = `git cat-file blob <REF>:<path>` (PR モード。cwd の作業ツリーは読まない)
#            gh    = `gh api -H 'Accept: application/vnd.github.raw' repos/<OWNER>/<REPO>/contents/<path>?ref=<REF>`
#            local = リポジトリ root 相対で作業ツリーのファイルを読む (ローカルモード)
#   REF    : SOURCE=git / gh のとき必須。40 桁の commit SHA (head 側なら HEAD_SHA、5-4 の base 側なら BASE_SHA)
#   OWNER / REPO : SOURCE=gh のとき必須
#   OUTPUT_PATH  : 結果 JSON の書き出し先。省略時は一意の temp ディレクトリ配下の result.json
#
# 引数 (対象パスの指定。複数併用可。同じパスは 1 回だけ取得する):
#   --root                 root の 4 候補 (REVIEW.md → AGENTS.md → .claude/CLAUDE.md → CLAUDE.md) を優先順に試し、
#                          最初に見つかった 1 つだけを取得する (以降の候補は試さない)
#   --ancestors <json>     changed-files.sh の出力の .ancestor_review_md[].path (head 側で存在する祖先)
#   --candidates <json>    changed-files.sh の出力の .ancestor_candidates[] (5-4 の base 側走査用。存在確認前の候補)
#   -- <path>...           任意のパス (root 相対)
#
# 出力: OUTPUT_PATH に JSON を書き、stdout にそのパスを 1 行出す。キー:
#   source / ref
#   fatal         : null または理由。null 以外なら files を使わない (候補不在と読まない)。
#                   git の commit object が無い / gh が 404 以外で失敗した、のいずれか
#   root_selected : --root で最初に見つかった候補のパス (見つからなければ null。--root なしなら null)
#   files[]       : {path, roles[], status: "present"|"absent", content_path, line_count,
#                    escalation_sections: [{line, end_line, level, title, text}]}
#                   content_path は全文を保存した一時ファイル。line_count はその行数 (Read の突き合わせ用)
#   has_escalation_heading : present な files のどれかに escalation_sections があるか
#
# exit: 0 = 正常 / 3 = fatal (JSON は書き出し済み) / 2 = 引数エラー (JSON なし) / 1 = 内部エラー (JSON なし)
#
# bash 互換要件: **bash 3.2 (macOS 標準の /bin/bash) で動くこと** (distill-pr-reviews/scripts/collect-signals.sh と同じ)。
#   NG: mapfile / readarray, declare -A, ${var^^} / ${var,,}, wait -n, coproc。
#   set -u 下の空配列展開は `${arr[@]+"${arr[@]}"}` の形で書く。awk は POSIX の範囲 (BWK awk で動く書き方) に留める。
# 依存: jq / awk / git (SOURCE=gh は gh)。
# read-only: 作業ツリー・ローカル ref を変えない。

set -euo pipefail

# 想定外の失敗 (jq / git の異常終了など) は exit 1 に揃え、書きかけの JSON を残さない。
# jq 自身の終了コード (2 / 3 / 5) が、このスクリプトの「引数エラー」「fatal」と取り違えられないようにするため。
EXIT_KIND=""
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$EXIT_KIND" ]; then
    [ -n "${OUTPUT_PATH:-}" ] && rm -f "$OUTPUT_PATH"
    echo "[read-instruction-files] internal error (exit $rc)" >&2
    exit 1
  fi
}
trap on_exit EXIT

log() { echo "[read-instruction-files] $*" >&2; }
die_usage() { EXIT_KIND=usage; echo "[read-instruction-files] usage error: $*" >&2; exit 2; }

SOURCE="${SOURCE:-}"
REF="${REF:-}"
OWNER="${OWNER:-}"
REPO="${REPO:-}"
OUTPUT_PATH="${OUTPUT_PATH:-}"

command -v jq >/dev/null 2>&1 || die_usage "jq が見つからない"

case $SOURCE in
  git|gh)
    printf '%s' "$REF" | grep -Eq '^[0-9a-f]{40}$' || die_usage "REF が 40 桁の SHA ではない: '$REF'"
    ;;
  local) ;;
  *) die_usage "SOURCE は git / gh / local: '$SOURCE'" ;;
esac
if [ "$SOURCE" = gh ]; then
  printf '%s' "$OWNER" | grep -Eq '^[A-Za-z0-9._-]+$' || die_usage "OWNER が不正: '$OWNER'"
  printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9._-]+$' || die_usage "REPO が不正: '$REPO'"
fi

# ---------- 対象パスの収集 ----------
# paths[i] と roles[i] を並行配列で持つ (bash 3.2 に連想配列が無いため)。

paths=()
roles=()
USE_ROOT=false

add_path() {
  # $1 = path, $2 = role。既出なら role だけ追記する
  local i=0
  while [ "$i" -lt "${#paths[@]}" ]; do
    if [ "${paths[$i]}" = "$1" ]; then
      case " ${roles[$i]} " in *" $2 "*) ;; *) roles[$i]="${roles[$i]} $2" ;; esac
      return 0
    fi
    i=$((i + 1))
  done
  paths[${#paths[@]}]=$1
  roles[${#roles[@]}]=$2
}

add_from_json() {
  # $1 = json file, $2 = jq filter (文字列を出す), $3 = role
  [ -f "$1" ] || die_usage "JSON が見つからない: $1"
  local p z
  z=$(mktemp "${TMPDIR:-/tmp}/compose-review-paths-XXXXXX")
  # プロセス置換だと jq の失敗が「0 件」に化けるので、一時ファイルに書いて終了コードを確かめる
  jq -j "$2 | . + \"\\u0000\"" "$1" >"$z" || die_usage "JSON からパスを読めない: $1"
  while IFS= read -r -d '' p; do
    add_path "$p" "$3"
  done <"$z"
  rm -f "$z"
}

while [ $# -gt 0 ]; do
  case $1 in
    --root) USE_ROOT=true; shift ;;
    # SOURCE=local は後で repo root に cd するので、JSON のパスは呼び出し時の cwd 基準の絶対パスにしておく
    --ancestors) [ $# -ge 2 ] || die_usage "--ancestors に JSON が無い"; ANC_JSON=$2; case $ANC_JSON in /*) ;; *) ANC_JSON="$PWD/$ANC_JSON" ;; esac; shift 2 ;;
    --candidates) [ $# -ge 2 ] || die_usage "--candidates に JSON が無い"; CAND_JSON=$2; case $CAND_JSON in /*) ;; *) CAND_JSON="$PWD/$CAND_JSON" ;; esac; shift 2 ;;
    --) shift; break ;;
    *) die_usage "不明な引数: $1 (任意のパスは -- の後に置く)" ;;
  esac
done

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/compose-review-instr-XXXXXX")
mkdir -p "$WORK_DIR/files"
if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="$WORK_DIR/result.json"
fi
# 後で repo root に cd するので、相対パスは呼び出し時の cwd 基準の絶対パスにしておく
case $OUTPUT_PATH in /*) ;; *) OUTPUT_PATH="$PWD/$OUTPUT_PATH" ;; esac
mkdir -p "$(dirname "$OUTPUT_PATH")"

write_fatal() {
  EXIT_KIND=fatal
  jq -n --arg source "$SOURCE" --arg ref "$REF" --arg fatal "$1" \
    '{source: $source, ref: (if $ref == "" then null else $ref end), fatal: $fatal}' >"$OUTPUT_PATH"
  log "FATAL: $1"
  echo "$OUTPUT_PATH"
  exit 3
}

if [ "$SOURCE" = local ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null) || write_fatal "git リポジトリの中で実行されていない"
  cd "$top"
fi
if [ "$SOURCE" = git ]; then
  # object 不在でも `git show` の fatal は path 不在と同じ文面になるので、先に commit object を確かめる
  git cat-file -e "$REF^{commit}" 2>/dev/null || write_fatal "commit object $REF がローカルに無い (gh 経路で取り直す)"
fi

# ---------- 取得 ----------
# fetch_one <path> <out>: 0 = present / 1 = absent。経路障害は write_fatal で止める。

# git_resolve_blob <ref> <path>: <ref> の tree 上で <path> をシンボリックリンクを辿って解決し、通常ファイルなら
# 解決後のパスを RESOLVED に入れて 0 を返す (作業ツリーの Read / contents API がリンク先を読むのと揃える)。
# 不在・ディレクトリ・リポジトリ外 (絶対パス / root より上) を指すリンク・8 段を超える連鎖は 1。
# LINK_LOG が設定されていれば、辿った先のパス (連鎖の途中と最終) を NUL 区切りでそのファイルに追記する。
RESOLVED=""
git_resolve_blob() {
  local ref=$1 p=$2 hop=0 mode type rest part norm target
  while [ "$hop" -le 8 ]; do
    if [ "$hop" -gt 0 ] && [ -n "${LINK_LOG:-}" ]; then printf '%s\0' "$p" >>"$LINK_LOG"; fi
    # --full-tree: cwd がサブディレクトリでも root 相対で引く / --literal-pathspecs: パス中の * ? [ を glob にしない
    read -r mode type rest < <(git --literal-pathspecs ls-tree --full-tree "$ref" -- "$p" 2>/dev/null) || return 1
    case $mode:$type in
      100644:blob|100755:blob) RESOLVED=$p; return 0 ;;
      120000:blob) ;;
      *) return 1 ;;
    esac
    target=$(git cat-file blob "$ref:$p"; printf x) || return 1
    target=${target%x}
    case $target in /*|'') return 1 ;; esac
    case $p in */*) rest=${p%/*}/$target ;; *) rest=$target ;; esac
    norm=""
    while [ -n "$rest" ]; do
      case $rest in */*) part=${rest%%/*}; rest=${rest#*/} ;; *) part=$rest; rest="" ;; esac
      case $part in
        ''|.) ;;
        ..) [ -n "$norm" ] || return 1; case $norm in */*) norm=${norm%/*} ;; *) norm="" ;; esac ;;
        *) norm=${norm:+$norm/}$part ;;
      esac
    done
    [ -n "$norm" ] || return 1
    p=$norm
    hop=$((hop + 1))
  done
  return 1
}

encode_path() { jq -rn --arg p "$1" '$p | split("/") | map(@uri | gsub("!"; "%21") | gsub("\\*"; "%2A") | gsub("'"'"'"; "%27") | gsub("\\("; "%28") | gsub("\\)"; "%29")) | join("/")'; }

fetch_one() {
  local p=$1 out=$2 t err enc
  case $SOURCE in
    git)
      git_resolve_blob "$REF" "$p" || return 1
      git cat-file blob "$REF:$RESOLVED" >"$out" || write_fatal "git cat-file blob $REF:$RESOLVED が失敗"
      ;;
    gh)
      enc=$(encode_path "$p")
      # contents API はディレクトリにも 200 で一覧 (JSON) を返すので、先にメタデータの type でファイルであることを確かめる
      # (確かめないと、PR 作成者が名前を決められる一覧 JSON を本文として取り込む)
      if ! gh api "repos/$OWNER/$REPO/contents/$enc?ref=$REF" >"$out.meta" 2>"$out.err"; then
        err=$(head -c 500 "$out.err")
        case $err in
          *'HTTP 404'*) return 1 ;;
          *) write_fatal "gh api contents/$p?ref=$REF が 404 以外で失敗: $err" ;;
        esac
      fi
      t=$(jq -r 'if type == "object" then .type // "" else "dir" end' <"$out.meta") \
        || write_fatal "gh api contents/$p?ref=$REF の応答を解釈できない"
      # リンク先が通常ファイルのシンボリックリンクは GitHub が解決して type=file で返す。symlink のままなら解決できないリンク
      case $t in file) ;; *) return 1 ;; esac
      if ! gh api -H 'Accept: application/vnd.github.raw' "repos/$OWNER/$REPO/contents/$enc?ref=$REF" >"$out" 2>"$out.err"; then
        err=$(head -c 500 "$out.err")
        case $err in
          *'HTTP 404'*) return 1 ;;
          *) write_fatal "gh api contents/$p?ref=$REF が 404 以外で失敗: $err" ;;
        esac
      fi
      rm -f "$out.err"
      ;;
    local)
      [ -f "$p" ] || return 1
      cp "$p" "$out"
      ;;
  esac
  return 0
}

# ---------- 見出し検出 ----------
# CommonMark の ATX 見出し (行頭 0〜3 スペース + `#` 1〜6 個 + スペース / タブまたは行末) のうち、タイトルに
# `エスカレーション基準` を含むものを拾う。フェンス (``` / ~~~ を 3 個以上、行頭 0〜3 スペース) の内側は除外する。
# 閉じフェンスは同じ文字で開きの個数以上、後ろは空白のみ。閉じられないフェンスは文書末尾まで続く。
# セクションの終わりは、次に現れる同じか浅いレベルの見出し (フェンス外) の直前、または文書末尾。
# 出力: 1 行 1 セクションで "開始行 TAB 終了行 TAB レベル TAB タイトル"。

HEADING_AWK='
function lead(s,   n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }
function run(s, ch,   m) { m = 0; while (substr(s, m + 1, 1) == ch) m++; return m }
{
  line = $0; sub(/\r$/, "", line)
  n = lead(line)
  if (n > 3) next
  rest = substr(line, n + 1); c = substr(rest, 1, 1)
  if (infence) {
    if (c == fch) { m = run(rest, fch); if (m >= flen && substr(rest, m + 1) ~ /^[ \t]*$/) infence = 0 }
    next
  }
  if (c == "`" || c == "~") {
    m = run(rest, c)
    if (m >= 3 && !(c == "`" && index(substr(rest, m + 1), "`") > 0)) { infence = 1; fch = c; flen = m; next }
  }
  if (c == "#") {
    m = run(rest, "#"); a = substr(rest, m + 1, 1)
    if (m <= 6 && (a == " " || a == "\t" || a == "")) { nh++; hl[nh] = NR; hv[nh] = m; ht[nh] = substr(rest, m + 2) }
  }
}
END {
  for (i = 1; i <= nh; i++) {
    if (index(ht[i], "エスカレーション基準") == 0) continue
    e = NR
    for (j = i + 1; j <= nh; j++) if (hv[j] <= hv[i]) { e = hl[j] - 1; break }
    print hl[i] "\t" e "\t" hv[i] "\t" ht[i]
  }
}'

ENTRIES="$WORK_DIR/entries.jsonl"
: >"$ENTRIES"
ROOT_SELECTED=""

process() {
  # $1 = index (paths / roles の添字)
  local i=$1 p out lc sec s e lv title text
  p=${paths[$i]}
  out="$WORK_DIR/files/$i.txt"
  if ! fetch_one "$p" "$out"; then
    jq -nc --arg path "$p" --arg roles "${roles[$i]}" \
      '{path: $path, roles: ($roles | split(" ")), status: "absent", content_path: null, line_count: null, escalation_sections: []}' >>"$ENTRIES" \
      || write_fatal "結果の JSON 化 (jq) が失敗: $p"
    return 1
  fi
  lc=$(grep -c '' "$out" || true)
  sec="$WORK_DIR/files/$i.sections.jsonl"
  : >"$sec"
  # awk / jq の失敗を「見出しなし」と取り違えないよう、パイプの中ではなく main shell で回し、失敗は fatal にする
  # (process は if の中で呼ばれ set -e が効かないので、失敗は明示的に拾う)
  LC_ALL=C awk "$HEADING_AWK" "$out" >"$sec.tsv" || write_fatal "見出しの検出 (awk) が失敗: $p"
  while IFS="$(printf '\t')" read -r s e lv title; do
    text=$(sed -n "${s},${e}p" "$out"; printf x) || write_fatal "セクションの抽出 (sed) が失敗: $p"
    text=${text%x}
    jq -nc --argjson line "$s" --argjson end_line "$e" --argjson level "$lv" --arg title "$title" --arg text "$text" \
      '{line: $line, end_line: $end_line, level: $level, title: $title, text: $text}' >>"$sec" \
      || write_fatal "セクションの JSON 化 (jq) が失敗: $p"
  done <"$sec.tsv"
  [ "$(grep -c '' "$sec")" = "$(grep -c '' "$sec.tsv")" ] || write_fatal "検出した見出しとセクションの件数が合わない: $p"
  jq -nc --arg path "$p" --arg roles "${roles[$i]}" --arg cp "$out" --argjson lc "$lc" --slurpfile secs "$sec" \
    '{path: $path, roles: ($roles | split(" ")), status: "present", content_path: $cp, line_count: $lc, escalation_sections: $secs}' >>"$ENTRIES" \
    || write_fatal "結果の JSON 化 (jq) が失敗: $p"
  return 0
}

if [ "$USE_ROOT" = true ]; then
  for r in REVIEW.md AGENTS.md .claude/CLAUDE.md CLAUDE.md; do
    add_path "$r" root
    idx=$((${#paths[@]} - 1))
    if process "$idx"; then ROOT_SELECTED=$r; break; fi
  done
  ROOT_DONE=${#paths[@]}
else
  ROOT_DONE=0
fi

[ -n "${ANC_JSON:-}" ] && add_from_json "$ANC_JSON" '.ancestor_review_md[].path' ancestor
[ -n "${CAND_JSON:-}" ] && add_from_json "$CAND_JSON" '.ancestor_candidates[]' candidate
for p in ${@+"$@"}; do add_path "$p" extra; done

# root で処理済みのパスに後から role が足された場合も、取得は 1 回だけにする (entries は最後に roles を上書き)
i=$ROOT_DONE
while [ "$i" -lt "${#paths[@]}" ]; do
  process "$i" || true
  i=$((i + 1))
done

# roles は add_path の最終状態を正とする (root の REVIEW.md が祖先としても列挙された場合など)
ROLES_JSON="$WORK_DIR/roles.jsonl"
: >"$ROLES_JSON"
i=0
while [ "$i" -lt "${#paths[@]}" ]; do
  jq -nc --arg path "${paths[$i]}" --arg roles "${roles[$i]}" '{path: $path, roles: ($roles | split(" "))}' >>"$ROLES_JSON"
  i=$((i + 1))
done

jq -n --arg source "$SOURCE" --arg ref "$REF" --arg root "$ROOT_SELECTED" \
  --slurpfile entries "$ENTRIES" --slurpfile roles "$ROLES_JSON" '
  ($roles | map({(.path): .roles}) | add // {}) as $r
  | ($entries | map(.roles = ($r[.path] // .roles))) as $files
  | {
      source: $source,
      ref: (if $ref == "" then null else $ref end),
      fatal: null,
      root_selected: (if $root == "" then null else $root end),
      files: $files,
      has_escalation_heading: ([$files[] | select(.status == "present") | .escalation_sections | length] | add // 0 | . > 0)
    }' >"$OUTPUT_PATH"

echo "$OUTPUT_PATH"
