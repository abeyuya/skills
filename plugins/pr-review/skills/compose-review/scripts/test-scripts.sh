#!/usr/bin/env bash
# compose-review/scripts/*.sh のテスト。一時 git リポジトリに扱いにくいパスを作って各スクリプトを実行し、JSON を検証する。
#
# 使い方: bash plugins/pr-review/skills/compose-review/scripts/test-scripts.sh
# 依存: bash / git / jq (gh は不要。gh 経路は PATH 先頭に置くスタブで検証する)
# 作業ディレクトリは mktemp -d で作り、終了時に消す。リポジトリの作業ツリーには何も書かない。
#
# bash 互換要件: bash 3.2 で動くこと (本体スクリプトと同じ)。

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHANGED="$HERE/changed-files.sh"
READ="$HERE/read-instruction-files.sh"
RENDER="$HERE/render-instruction-links.sh"
FINAL="$HERE/finalize-comments.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/compose-review-test-XXXXXX")
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"
mkdir -p "$TMPDIR"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
ng() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; }

# check <説明> <JSON ファイル> <jq 式 (真偽値)>
check() {
  local r
  r=$(jq -e "$3" "$2" 2>&1) && ok "$1" || ng "$1" "jq: $3 => $r"
}

# run <出力を入れる変数名> <期待 exit> <コマンド...>
run() {
  local __var=$1 want=$2 got=0 out
  shift 2
  out=$("$@" 2>"$T/last.err") || got=$?
  if [ "$got" != "$want" ]; then
    ng "exit code $want: $*" "got $got / stderr: $(head -c 400 "$T/last.err")"
  fi
  eval "$__var=\$out"
}

NL=$'\n'

# ---------- fixture ----------
R="$T/repo"
mkdir -p "$R"
cd "$R"
git init -q -b main
git config user.email test@example.com
git config user.name test
git config commit.gpgsign false

mkdir -p 'apps/web/src' 'apps/api' 'old' "日本語 dir" 'a#b?c' '`tick`' "nl${NL}dir" 'node_modules/pkg' 'docs'

# root REVIEW.md: `## エスカレーション基準` はコードフェンスの内側にだけある (見出しではない)
cat > REVIEW.md <<'EOF'
# Review

本文中の言及: エスカレーション基準はまだ定めていない。

```markdown
## エスカレーション基準
- テンプレート例
```

~~~~
## エスカレーション基準
~~~
まだフェンスの中 (閉じは 4 個以上の ~)
~~~~
EOF

# apps/REVIEW.md: 本物の見出しがファイル末尾にあり、末尾改行なし
{
  printf '# apps\n\n'
  i=1; while [ $i -le 70 ]; do printf 'line %d\n' "$i"; i=$((i + 1)); done
  printf '   ## エスカレーション基準 (apps)\n\n- 公開 API の変更\n### 下位\n- 下位の項目\n##\n- 対象外 (空の見出しでもセクションは終わる)'
} > apps/REVIEW.md

printf '# web\n' > apps/web/REVIEW.md
printf '# old\n\n## エスカレーション基準\n- old の基準\n' > old/REVIEW.md
printf '# ja\n' > "日本語 dir/REVIEW.md"
printf '# hash\n' > 'a#b?c/REVIEW.md'
printf '# tick\n' > '`tick`/REVIEW.md'
printf '# nl\n' > "nl${NL}dir/REVIEW.md"
printf '# vendored\n' > node_modules/pkg/REVIEW.md
printf 'x\n' > apps/web/src/a.ts
printf 'x\n' > apps/api/b.ts
printf 'x\n' > "日本語 dir/ファイル 1.txt"
printf 'x\n' > 'a#b?c/x.txt'
printf 'x\n' > '`tick`/y.txt'
printf 'x\n' > "nl${NL}dir/z.txt"
printf 'x\n' > node_modules/pkg/index.js
printf 'x\n' > docs/readme.txt
mkdir -p 'dir/REVIEW.md'
printf 'x\n' > 'dir/REVIEW.md/inner.txt'  # REVIEW.md という名前のディレクトリ (blob ではない)
git add -A
git commit -qm base
BASE=$(git rev-parse HEAD)

git checkout -q -b feature
printf 'y\n' >> apps/web/src/a.ts
printf 'y\n' >> apps/api/b.ts
printf 'y\n' >> "日本語 dir/ファイル 1.txt"
printf 'y\n' >> 'a#b?c/x.txt'
printf 'y\n' >> '`tick`/y.txt'
printf 'y\n' >> "nl${NL}dir/z.txt"
printf 'y\n' >> node_modules/pkg/index.js
printf 'y\n' >> 'dir/REVIEW.md/inner.txt'
mkdir -p new
git mv old/REVIEW.md new/REVIEW.md                 # rename: 移動元と移動先の両方が一覧に出るべき
git add -A
git commit -qm feature
HEAD=$(git rev-parse HEAD)

# ========== changed-files.sh (PR モード / git 経路) ==========
echo "# changed-files.sh: PR モード git 経路"
run OUT 0 env MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" SOURCE=git bash "$CHANGED"
check "source=git" "$OUT" '.source == "git" and .fatal == null'
check "rename の移動元と移動先が changed_files に両方ある" "$OUT" '(.changed_files | index(["old/REVIEW.md"])) and (.changed_files | index(["new/REVIEW.md"]))'
check "range_files は移動先のみ" "$OUT" '(.range_files | index(["new/REVIEW.md"])) and ((.range_files | index(["old/REVIEW.md"])) | not)'
check "changed_count は --no-renames の件数 (10)" "$OUT" '.changed_count == 10 and .range_count == 9'
check "非 ASCII + 空白のパスが quote されずに出る" "$OUT" '.changed_files | index(["日本語 dir/ファイル 1.txt"])'
check "改行を含むパスが 1 件のまま出る" "$OUT" '.changed_files | index(["nl\ndir/z.txt"])'
check "祖先 REVIEW.md が root → 親 → 子 の順" "$OUT" '[.ancestor_review_md[].path] == ["REVIEW.md", "`tick`/REVIEW.md", "a#b?c/REVIEW.md", "apps/REVIEW.md", "new/REVIEW.md", "日本語 dir/REVIEW.md", "apps/web/REVIEW.md"]'
check "削除された old/REVIEW.md は head に無いので祖先に出ない (候補には出る)" "$OUT" '([.ancestor_review_md[].path] | index(["old/REVIEW.md"]) | not) and (.ancestor_candidates | index(["old/REVIEW.md"]))'
check "node_modules/ 配下は候補から除外" "$OUT" '[.ancestor_candidates[] | select(test("node_modules"))] == []'
check "REVIEW.md という名前のディレクトリは存在扱いしない" "$OUT" '[.ancestor_review_md[].path] | index(["dir/REVIEW.md"]) | not'
check "改行を含むパスの REVIEW.md は除外して件数を返す" "$OUT" '.excluded_review_md == 1'
check "changed_files_under (apps/ は 2 件、root は全件)" "$OUT" '(.ancestor_review_md[] | select(.path == "apps/REVIEW.md") | .changed_files_under) == 2 and (.ancestor_review_md[] | select(.path == "REVIEW.md") | .changed_files_under) == 10'
check "rename した REVIEW.md で 5-4 が発火" "$OUT" '.instruction_files_touched == true and .instruction_files_touched_paths == ["new/REVIEW.md", "old/REVIEW.md"]'

# 指示ファイルに触れない差分では発火しない
run OUT 0 env MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$(git rev-parse HEAD)" SOURCE=git bash "$CHANGED"
check "空差分: 0 件で fatal なし・発火なし" "$OUT" '.changed_count == 0 and .fatal == null and .instruction_files_touched == false and .ancestor_review_md == []'

# object が無い SHA: git 固定なら fatal、auto で gh も無ければ fatal
MISSING=0123456789abcdef0123456789abcdef01234567
run OUT 3 env MODE=pr HEAD_SHA="$MISSING" BASE_SHA="$BASE" SOURCE=git bash "$CHANGED"
check "head object が無いと fatal (空リストと読まない)" "$OUT" '.fatal != null and (.changed_files | not)'
run OUT 2 env MODE=pr HEAD_SHA=FETCH_HEAD BASE_SHA="$BASE" bash "$CHANGED"
[ -z "$OUT" ] && ok "SHA でない HEAD_SHA は引数エラー" || ng "SHA でない HEAD_SHA は引数エラー"

# ========== changed-files.sh (ローカルモード) ==========
echo "# changed-files.sh: ローカルモード"
run OUT 0 env MODE=local DIFF_MODE=commit BASE_BRANCH=main bash "$CHANGED"
check "commit モードは PR モードと同じ一覧" "$OUT" '.source == "local" and .changed_count == 10 and .excluded_review_md == 1 and .instruction_files_touched'
check "commit モードの祖先は作業ツリーで確認" "$OUT" '[.ancestor_review_md[].path] | index(["apps/web/REVIEW.md"])'

printf 'z\n' >> docs/readme.txt
git add docs/readme.txt
run OUT 0 env MODE=local DIFF_MODE=staged bash "$CHANGED"
check "staged モード" "$OUT" '.changed_files == ["docs/readme.txt"] and [.ancestor_review_md[].path] == ["REVIEW.md"] and (.instruction_files_touched | not)'
run OUT 0 env MODE=local DIFF_MODE=worktree bash "$CHANGED"
check "worktree モード (staged 済みは出ない)" "$OUT" '.changed_count == 0'
printf 'w\n' >> CLAUDE.md
git add -N CLAUDE.md
run OUT 0 env MODE=local DIFF_MODE=worktree bash "$CHANGED"
check "worktree モードで CLAUDE.md に触れると発火" "$OUT" '.instruction_files_touched_paths == ["CLAUDE.md"]'
git rm -q --cached CLAUDE.md; rm -f CLAUDE.md
git reset -q docs/readme.txt; git checkout -q -- docs/readme.txt

# 一覧を取れないとき (存在しないベース) は fatal
run OUT 3 env MODE=local DIFF_MODE=commit BASE_BRANCH=no-such-branch bash "$CHANGED"
check "ベースが無ければ fatal" "$OUT" '.fatal | test("git diff")'

# ========== gh 経路 (スタブ) ==========
echo "# changed-files.sh / read-instruction-files.sh: gh 経路 (スタブ)"
STUB="$T/bin"
mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
# テスト用の gh スタブ。STUB_REPO の git object から GitHub API の応答を組み立てる。
# STUB_FAIL=403 で全 API を 403 にし、STUB_FAIL_CONTENTS=<path> でその contents だけ 500 にする。
set -euo pipefail
if [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  # gh pr diff --name-only: パッチ見出しの b/ 側だけ (rename の移動元は出ない)
  cd "$STUB_REPO"; git diff --name-only "$STUB_BASE...$STUB_HEAD"; exit 0
fi
[ "${1:-}" = api ] || { echo "stub: unsupported: $*" >&2; exit 1; }
shift
url=""; silent=false; raw=false
while [ $# -gt 0 ]; do
  case $1 in
    --paginate) shift ;;
    --silent) silent=true; shift ;;
    -H) case $2 in *raw*) raw=true ;; esac; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
if [ "${STUB_FAIL:-}" = 403 ]; then echo "gh: Forbidden (HTTP 403)" >&2; exit 1; fi
cd "$STUB_REPO"
case $url in
  repos/o/r/pulls/7)
    n=${STUB_CHANGED_FILES:-$(git diff --name-only -z "$STUB_BASE...$STUB_HEAD" | tr -cd '\0' | wc -c | tr -d ' ')}
    printf '{"head":{"sha":"%s"},"changed_files":%s}' "$STUB_HEAD" "$n" ;;
  repos/o/r/pulls/7/files)
    if [ -n "${STUB_FAIL_FILES:-}" ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
    # 2 ページに分けて返す (--paginate の連結を再現)。rename は previous_filename 付き
    git diff --name-status -z "$STUB_BASE...$STUB_HEAD" | jq -Rs '
      split("\u0000") | map(select(length > 0)) as $a
      | [range(0; $a | length) as $i | $a[$i]] as $t
      | reduce range(0; $t | length) as $i ({out: [], skip: 0};
          if .skip > 0 then .skip -= 1
          elif ($t[$i] | test("^R")) then .out += [{status: "renamed", previous_filename: $t[$i+1], filename: $t[$i+2]}] | .skip = 2
          else .out += [{status: "modified", filename: $t[$i+1]}] | .skip = 1 end)
      | .out' | jq -c '.[0:3], .[3:]' ;;
  repos/o/r/contents/*)
    enc=${url#repos/o/r/contents/}; ref=${enc##*\?ref=}; enc=${enc%\?ref=*}
    path=$(printf '%b' "$(printf '%s' "$enc" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; printf x); path=${path%x}
    if [ -n "${STUB_FAIL_CONTENTS:-}" ] && [ "$path" = "$STUB_FAIL_CONTENTS" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    # GitHub と同じく、ディレクトリにも 200 で一覧 (JSON 配列) を返す。raw 指定でもディレクトリは一覧になる
    t=$(git cat-file -t "$ref:$path" 2>/dev/null || true)
    case $t in
      blob)
        # GitHub と同じく、リポジトリ内の通常ファイルを指すシンボリックリンクは解決して返す (path はリンク先。1 段・同階層基準のみ)
        mode=$(git ls-tree --full-tree "$ref" -- "$path" | cut -d' ' -f1)
        if [ "$mode" = 120000 ]; then
          tgt=$(git cat-file blob "$ref:$path")
          case $path in */*) path=${path%/*}/$tgt ;; *) path=$tgt ;; esac
        fi
        if $raw; then $silent || git cat-file blob "$ref:$path"; else $silent || jq -nc --arg p "$path" '{type: "file", path: $p}'; fi ;;
      tree) $silent || printf '[{"type":"file","name":"x"}]' ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  *) echo "stub: unknown url $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB/gh"
export STUB_REPO="$R" STUB_HEAD="$HEAD" STUB_BASE="$BASE"

# auto: head object が無い clone で git 経路が使えない状況を、存在しない BASE ではなく別リポジトリで再現する
EMPTY="$T/empty"
git init -q "$EMPTY"
cd "$EMPTY"
run OUT 0 env PATH="$STUB:$PATH" MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "object が無ければ auto で gh 経路に degrade" "$OUT" '.source == "gh" and .git_error != null and .head_object == false'
check "gh 経路: rename の移動元と移動先 / 改行を含む filename も 1 件" "$OUT" '.changed_count == 10 and .range_count == 9 and (.changed_files | index(["nl\ndir/z.txt"]))'
check "gh 経路: 祖先 REVIEW.md が git 経路と同じ (# ? バッククォート 非 ASCII を URL エンコードして確認)" "$OUT" '[.ancestor_review_md[].path] == ["REVIEW.md", "`tick`/REVIEW.md", "a#b?c/REVIEW.md", "apps/REVIEW.md", "new/REVIEW.md", "日本語 dir/REVIEW.md", "apps/web/REVIEW.md"] and .excluded_review_md == 1'
check "gh 経路: 5-4 発火" "$OUT" '.instruction_files_touched'
# gh 経路: root の CLAUDE.md がリンクで、リンク先だけを編集した PR でも発火する (変更ファイルの祖先に無くても)
R4="$T/r4"; mkdir -p "$R4/docs"; cd "$R4"; git init -q
git config user.email test@example.com; git config user.name test; git config commit.gpgsign false
printf '## エスカレーション基準\n- 基準\n' > docs/rules.md
ln -s docs/rules.md CLAUDE.md
git add -A; git commit -qm b; B4=$(git rev-parse HEAD)
printf -- '- 追記\n' >> docs/rules.md
git add -A; git commit -qm h; H4=$(git rev-parse HEAD)
cd "$EMPTY"
run OUT 0 env PATH="$STUB:$PATH" STUB_REPO="$R4" STUB_HEAD="$H4" STUB_BASE="$B4" bash "$CHANGED" MODE=pr HEAD_SHA="$H4" BASE_SHA="$B4" OWNER=o REPO=r PR_NUMBER=7
check "gh 経路: root の CLAUDE.md のリンク先だけの編集でも 5-4 が発火 (引数で渡す形)" "$OUT" '.source == "gh" and .instruction_files_touched_paths == ["docs/rules.md"]'

run OUT 3 env PATH="$STUB:$PATH" STUB_FAIL_CONTENTS='apps/REVIEW.md' MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh 経路: 404 以外 (500) は fatal" "$OUT" '.fatal | test("404 以外")'
run OUT 0 env PATH="$STUB:$PATH" STUB_FAIL_FILES=1 MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh pr diff 代替: list_degraded で 5-4 は安全側に発火" "$OUT" '.source == "gh-pr-diff" and .list_degraded and .instruction_files_touched'
run OUT 3 env PATH="$STUB:$PATH" STUB_CHANGED_FILES=3500 MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh 経路: files が PR の変更ファイル数に足りなければ fatal (3000 件の打ち切り)" "$OUT" '.fatal | test("打ち切られた")'
run OUT 3 env PATH="$STUB:$PATH" STUB_FAIL=403 MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh 経路: 403 は fatal (0 件と読まない)" "$OUT" '.fatal != null'
run OUT 3 env PATH="$STUB:$PATH" MODE=pr HEAD_SHA="$MISSING" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh 経路: PR の現 head と HEAD_SHA が違えば fatal" "$OUT" '.fatal | test("一致しない")'

run OUT 0 env PATH="$STUB:$PATH" SOURCE=gh REF="$HEAD" OWNER=o REPO=r bash "$READ" --root -- 'a#b?c/REVIEW.md' 'no/such/REVIEW.md' 'dir/REVIEW.md'
check "read gh: # ? を含むパスを取得 / 不在は absent" "$OUT" '.root_selected == "REVIEW.md" and ([.files[] | select(.path == "a#b?c/REVIEW.md") | .status] == ["present"]) and ([.files[] | select(.path == "no/such/REVIEW.md") | .status] == ["absent"])'
check "read gh: REVIEW.md という名前のディレクトリは absent (一覧 JSON を本文にしない)" "$OUT" '[.files[] | select(.path == "dir/REVIEW.md") | .status] == ["absent"]'
GP=$(jq -r '.files[] | select(.path == "a#b?c/REVIEW.md") | .content_path' "$OUT")
[ "$(cat "$GP")" = "# hash" ] && ok "read gh: raw の本文を保存" || ng "read gh: raw の本文を保存" "$(cat "$GP")"
run OUT 3 env PATH="$STUB:$PATH" STUB_FAIL=403 SOURCE=gh REF="$HEAD" OWNER=o REPO=r bash "$READ" --root
check "read gh: 403 は fatal" "$OUT" '.fatal | test("404 以外")'
cd "$R"

# ========== read-instruction-files.sh (git / local) ==========
echo "# read-instruction-files.sh"
run CF 0 bash "$CHANGED" MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" SOURCE=git
check "KEY=VALUE の引数でも渡せる" "$CF" '.source == "git" and .changed_count == 10'
run OUT 2 bash "$CHANGED" MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" BOGUS=1
[ -z "$OUT" ] && ok "不明な引数は引数エラー" || ng "不明な引数は引数エラー"
run OUT 0 bash "$READ" SOURCE=git REF="$HEAD" --root --ancestors "$CF"
check "root_selected=REVIEW.md で roles に root と ancestor" "$OUT" '.root_selected == "REVIEW.md" and (.files[0].roles == ["root", "ancestor"])'
check "コードフェンス内の見出しは拾わない" "$OUT" '(.files[] | select(.path == "REVIEW.md") | .escalation_sections) == []'
check "末尾の本物の見出しを拾う (インデント 3 スペース)" "$OUT" '(.files[] | select(.path == "apps/REVIEW.md") | .escalation_sections | map(.line)) == [73]'
check "セクションは同じか浅い見出しの手前まで (下位見出しは含む)" "$OUT" '(.files[] | select(.path == "apps/REVIEW.md") | .escalation_sections[0] | (.end_line == 77 and (.text | test("下位の項目")) and (.text | test("対象外") | not)))'
check "末尾改行なしでも行数は grep -c と同じ (79)" "$OUT" '(.files[] | select(.path == "apps/REVIEW.md") | .line_count) == 79'
AP=$(jq -r '.files[] | select(.path == "apps/REVIEW.md") | .content_path' "$OUT")
cmp -s "$AP" <(git cat-file blob "$HEAD:apps/REVIEW.md") && ok "content_path は head の全文 (打ち切りなし)" || ng "content_path は head の全文"
check "has_escalation_heading (head)" "$OUT" '.has_escalation_heading == true'
check "非 ASCII / バッククォートのパスも取得" "$OUT" '[.files[] | select(.path == "日本語 dir/REVIEW.md" or .path == "`tick`/REVIEW.md") | .status] == ["present", "present"]'

# 5-4 の base 側: 候補一覧で base を走査すると、rename 前の old/REVIEW.md の基準が見える
run OUT 0 env SOURCE=git REF="$BASE" bash "$READ" --root --candidates "$CF"
check "base 側: old/REVIEW.md の基準を検出、new/REVIEW.md は absent" "$OUT" '([.files[] | select(.path == "old/REVIEW.md") | .escalation_sections | length] == [1]) and ([.files[] | select(.path == "new/REVIEW.md") | .status] == ["absent"])'
check "base 側: 改行を含むパスの候補も走査できる" "$OUT" '[.files[] | select(.path == "nl\ndir/REVIEW.md") | .status] == ["present"]'

# cwd の作業ツリーを読まない: 作業ツリーだけにある変更は git 経路の結果に出ない
printf '## エスカレーション基準\n- 作業ツリーだけ\n' >> REVIEW.md
run OUT 0 env SOURCE=git REF="$HEAD" bash "$READ" --root
check "git 経路は作業ツリーの変更を読まない" "$OUT" '(.files[0].escalation_sections) == []'
cp "$CF" "$T/cf.json"
cd apps
run OUT 0 env SOURCE=local bash "$READ" --ancestors ../../cf.json
cd "$R"
check "local 経路: サブディレクトリから相対パスの JSON を渡しても読める" "$OUT" '[.files[] | select(.status == "present") | .path] | index(["apps/web/REVIEW.md"])'
run OUT 0 env SOURCE=local bash "$READ" --root
check "local 経路は作業ツリーを読む" "$OUT" '(.files[0].escalation_sections | length) == 1'
git checkout -q -- REVIEW.md

run OUT 3 env SOURCE=git REF="$MISSING" bash "$READ" --root
check "read git: commit object が無ければ fatal (候補不在と読まない)" "$OUT" '.fatal | test("ローカルに無い")'

# root の優先順: REVIEW.md が無ければ AGENTS.md
cd "$T"; mkdir r2; cd r2; git init -q; printf '# agents\n' > AGENTS.md; printf '# claude\n' > CLAUDE.md
run OUT 0 env SOURCE=local bash "$READ" --root
check "root は最初に見つかった 1 つだけ (AGENTS.md)" "$OUT" '.root_selected == "AGENTS.md" and ([.files[] | select(.status == "present") | .path] == ["AGENTS.md"])'
cd "$R"

# シンボリックリンクの指示ファイルは、git 経路でもリンク先の中身を読む (作業ツリー / contents API と揃える)
cd "$T"; mkdir r3; cd r3; git init -q
git config user.email test@example.com; git config user.name test; git config commit.gpgsign false
printf '# claude\n\n## エスカレーション基準\n- 共有の基準\n' > CLAUDE.md
ln -s CLAUDE.md AGENTS.md
mkdir -p shared sub esc loop
printf '# shared\n\n## エスカレーション基準\n- sub の基準\n' > shared/REVIEW-body.md
ln -s ../shared/REVIEW-body.md sub/REVIEW.md
ln -s ../../outside.md esc/REVIEW.md
ln -s REVIEW.md loop/REVIEW.md
printf 'x\n' > sub/a.txt; printf 'x\n' > esc/a.txt; printf 'x\n' > loop/a.txt
git add -A; git commit -qm s
S3=$(git rev-parse HEAD)
run OUT 0 env SOURCE=git REF="$S3" bash "$READ" --root -- sub/REVIEW.md esc/REVIEW.md loop/REVIEW.md
check "git 経路: シンボリックリンクの AGENTS.md はリンク先 (CLAUDE.md) の基準を読む" "$OUT" '.root_selected == "AGENTS.md" and ((.files[] | select(.path == "AGENTS.md") | .escalation_sections | length) == 1)'
check "git 経路: 相対リンク (../) を解決する" "$OUT" '(.files[] | select(.path == "sub/REVIEW.md") | .escalation_sections[0].text) | test("sub の基準")'
check "git 経路: リポジトリ外を指すリンク・循環リンクは absent" "$OUT" '[.files[] | select(.path == "esc/REVIEW.md" or .path == "loop/REVIEW.md") | .status] == ["absent", "absent"]'
run OUT 0 env SOURCE=local bash "$READ" --root -- sub/REVIEW.md
check "local 経路と git 経路で結果が揃う" "$OUT" '.root_selected == "AGENTS.md" and ([.files[] | select(.status == "present") | .escalation_sections | length] == [1, 1])'
printf 'y\n' >> sub/a.txt; printf 'y\n' >> esc/a.txt; printf 'y\n' >> loop/a.txt
git add -A; git commit -qm s2
S4=$(git rev-parse HEAD)
cd sub   # cwd がサブディレクトリでも root 相対で解決する
run OUT 0 env MODE=pr HEAD_SHA="$S4" BASE_SHA="$S3" SOURCE=git bash "$CHANGED"
cd "$R"
check "changed-files: シンボリックリンクの祖先 REVIEW.md はリンク先がファイルなら存在扱い (リポジトリ外・循環は除外)" "$OUT" '[.ancestor_review_md[].path] == ["sub/REVIEW.md"]'
check "changed-files: 指示ファイルに触れない差分では発火しない" "$OUT" '.instruction_files_touched == false'
cd "$T/r3"
printf -- '- 追記\n' >> shared/REVIEW-body.md
git add -A; git commit -qm s3
S5=$(git rev-parse HEAD)
run OUT 0 env MODE=pr HEAD_SHA="$S5" BASE_SHA="$S4" SOURCE=git bash "$CHANGED"
check "changed-files: シンボリックリンク先 (祖先 REVIEW.md) だけの編集でも 5-4 が発火" "$OUT" '.instruction_files_touched and .instruction_files_touched_paths == ["shared/REVIEW-body.md"]'
check "changed-files: 発火の根拠になったリンク (sub/REVIEW.md) を比較候補に足す" "$OUT" '.ancestor_candidates | index(["sub/REVIEW.md"])'
# SKILL.md 5-4 の突き合わせコマンドで、リンク先の基準の変更が changed=true になることを確かめる
cp "$OUT" "$T/cf-link.json"
run HJ 0 env SOURCE=git REF="$S5" bash "$READ" --root --candidates "$T/cf-link.json"
run BJ 0 env SOURCE=git REF="$S4" bash "$READ" --root --candidates "$T/cf-link.json"
CMP=$(jq -n --slurpfile h "$HJ" --slurpfile b "$BJ" '
  def crit: [.files[] | select(.status == "present" and (.escalation_sections | length > 0))
             | {key: .path, value: [.escalation_sections[].text]}] | from_entries;
  {changed: (($h[0] | crit) != ($b[0] | crit)), head: ($h[0] | crit), base: ($b[0] | crit),
   root_head: $h[0].root_selected, root_base: $b[0].root_selected}')
printf '%s' "$CMP" > "$T/cmp.json"
check "5-4 の突き合わせ: リンク先の基準の変更を changed=true と判定" "$T/cmp.json" '.changed and (.head | has("sub/REVIEW.md"))'
printf -- '- 追記\n' >> CLAUDE.md
git add -A; git commit -qm s4
run OUT 0 env MODE=pr HEAD_SHA="$(git rev-parse HEAD)" BASE_SHA="$S5" SOURCE=git bash "$CHANGED"
check "changed-files: CLAUDE.md の編集は名前で発火" "$OUT" '.instruction_files_touched_paths == ["CLAUDE.md"]'
# 連鎖リンク (chain/REVIEW.md -> a.md -> b.md) の途中の a.md だけを付け替える PR でも発火する
mkdir -p chain
printf '## エスカレーション基準\n- chain の基準\n' > chain/b.md
printf '# 基準なし\n' > chain/c.md
ln -s a.md chain/REVIEW.md; ln -s b.md chain/a.md
git add -A; git commit -qm chain
S6=$(git rev-parse HEAD)
rm chain/a.md; ln -s c.md chain/a.md
git add -A; git commit -qm repoint
run OUT 0 env MODE=pr HEAD_SHA="$(git rev-parse HEAD)" BASE_SHA="$S6" SOURCE=git bash "$CHANGED"
check "changed-files: 連鎖リンクの途中だけを付け替えても 5-4 が発火" "$OUT" '.instruction_files_touched_paths == ["chain/a.md"]'
cd "$R"

# ========== jq の途中失敗を「見出しなし」「0 件」と取り違えない ==========
echo "# 内部の失敗"
FJ="$T/fakejq"
mkdir -p "$FJ"
REAL_JQ=$(command -v jq)
cat > "$FJ/jq" <<FAKEJQ
#!/usr/bin/env bash
# 引数に JQ_FAIL_ON の文字列を含む呼び出しだけ jq のコンパイルエラー相当 (exit 3) で落とす
for a in "\$@"; do case \$a in *"\$JQ_FAIL_ON"*) echo "fake jq: fail" >&2; exit 3 ;; esac; done
exec "$REAL_JQ" "\$@"
FAKEJQ
chmod +x "$FJ/jq"
run OUT 3 env PATH="$FJ:$PATH" JQ_FAIL_ON='end_line: $end_line' SOURCE=git REF="$HEAD" bash "$READ" --ancestors "$CF"
check "セクションの JSON 化が落ちたら fatal (見出しなしにしない)" "$OUT" '.fatal | test("JSON 化")'
run OUT 1 env PATH="$FJ:$PATH" JQ_FAIL_ON='instruction_files_touched_paths:' MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" SOURCE=git bash "$CHANGED"
[ -z "$OUT" ] && ok "最後の JSON 化が落ちたら exit 1 で JSON を返さない (fatal の 3 と区別)" || ng "内部エラーは exit 1" "$OUT"
run OUT 3 env PATH="$FJ:$PATH" JQ_FAIL_ON='split("\u0000")' MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" SOURCE=git bash "$CHANGED"
check "一覧の JSON 化が落ちたら fatal (0 件にしない)" "$OUT" '.fatal | test("JSON 化")'

# ========== render-instruction-links.sh ==========
echo "# render-instruction-links.sh"
SHA=0123456789abcdef0123456789abcdef01234567
LONG=$(printf 'd%.0s' $(seq 1 195))/REVIEW.md
jq -n --arg sha "$SHA" --arg long "$LONG" '{
  mode: "pr", owner: "octo", repo: "hello", head_sha: $sha,
  adopted: ["apps/web/REVIEW.md", "REVIEW.md", "a#b?c/REVIEW.md", "日本語 dir/REVIEW.md", "`tick`/REVIEW.md",
            "x`y``z/REVIEW.md", "bidi\u202e/REVIEW.md", "zw\u200b/REVIEW.md", "ctl\u0007/REVIEW.md", $long,
            "REVIEW.md", "p(1)!/REVIEW.md"],
  rejected: ["r1/REVIEW.md", "REVIEW.md"],
  scopes: ["packages/@acme/ui/", "`x/", " sp "]
}' > "$T/in.json"
run OUT 0 bash "$RENDER" "$T/in.json"
check "root → 子の順・重複は 1 行" "$OUT" '.lines[0] == "[`REVIEW.md`](https://github.com/octo/hello/blob/'"$SHA"'/REVIEW.md)" and ([.lines[] | select(test("\\(https://github.com/octo/hello/blob/[0-9a-f]+/REVIEW.md\\)$"))] | length) == 1'
check "# ? はパーセントエンコード" "$OUT" '.lines | index(["[`a#b?c/REVIEW.md`](https://github.com/octo/hello/blob/'"$SHA"'/a%23b%3Fc/REVIEW.md)"])'
check "非 ASCII と空白は UTF-8 でエンコード" "$OUT" '.lines | index(["[`日本語 dir/REVIEW.md`](https://github.com/octo/hello/blob/'"$SHA"'/%E6%97%A5%E6%9C%AC%E8%AA%9E%20dir/REVIEW.md)"])'
check "先頭バッククォートはスペースで離す" "$OUT" '.lines | index(["[`` `tick`/REVIEW.md ``](https://github.com/octo/hello/blob/'"$SHA"'/%60tick%60/REVIEW.md)"])'
check "最長のバッククォート列より長い列で囲む" "$OUT" '.lines | map(select(startswith("[```x`y``z/REVIEW.md```]"))) | length == 1'
check "!()' もエンコード" "$OUT" '.lines | map(select(endswith("/p%281%29%21/REVIEW.md)"))) | length == 1'
check "双方向制御・ゼロ幅・制御文字は (表示できないパス)" "$OUT" '[.lines[] | select(. == "(表示できないパス)")] | length == 3'
check "200 文字超は (長すぎるパス)" "$OUT" '[.lines[] | select(. == "(長すぎるパス)")] | length == 1'
check "不採用は採用と重複しないものだけ・注記付き" "$OUT" '[.lines[] | select(endswith("(件数上限で方針として不採用)"))] == ["[`r1/REVIEW.md`](https://github.com/octo/hello/blob/'"$SHA"'/r1/REVIEW.md) (件数上限で方針として不採用)"]'
check "markdown は 2 スペース + - の箇条書き" "$OUT" '.markdown | startswith("  - [`REVIEW.md`]")'
check "scopes もコードスパン (リンクなし。先頭と末尾が両方スペースなら 1 つずつ足す)" "$OUT" '.scopes == [{path: "packages/@acme/ui/", rendered: "`packages/@acme/ui/`"}, {path: "`x/", rendered: "`` `x/ ``"}, {path: " sp ", rendered: "`  sp  `"}]'

jq -n '{mode: "local", adopted: [range(0; 25) | "d\(.)/REVIEW.md"], rejected: [range(0; 7) | "r\(.)/REVIEW.md"]}' > "$T/in2.json"
run OUT 0 bash "$RENDER" "$T/in2.json"
check "local はリンクなし・採用 20 件 + ほか 5 件" "$OUT" '.lines[0] == "`d0/REVIEW.md`" and (.lines | index(["ほか 5 件"])) == 20'
check "不採用 5 件 + ほか 2 件も件数上限で不採用" "$OUT" '([.lines[] | select(endswith("(件数上限で方針として不採用)"))] | length) == 5 and .lines[-1] == "ほか 2 件も件数上限で不採用"'
run OUT 0 bash "$RENDER" <(echo '{"mode":"local","adopted":[]}')
check "1 つも無ければ なし" "$OUT" '.lines == ["なし"]'
run OUT 2 bash "$RENDER" <(echo '{"mode":"pr","owner":"o","repo":"r","head_sha":"main","adopted":[]}')
[ -z "$OUT" ] && ok "head_sha が SHA でなければ入力エラー" || ng "head_sha が SHA でなければ入力エラー"

# ========== finalize-comments.sh ==========
cat > "$T/fc.json" <<'EOF'
{"comments": [
  {"path": "a", "line": 1, "body": "[nit] a"},
  {"path": "b", "line": 2, "body": "[MUST] b"},
  {"path": "c", "line": 3, "body": "[blocker] c"},
  {"path": "d", "line": 4, "body": "[should] d"},
  {"path": "e", "line": 5, "body": "ラベルなし"},
  {"path": "f", "line": 6, "body": "[weird] f"},
  {"path": "g", "line": 7, "body": "[pre_existing] g"}],
 "label_map": {"[Blocker]": "MUST"}}
EOF
run OUT 0 bash "$FINAL" MAX_INLINE_COMMENTS=3 "$T/fc.json"
check "label_counts は上限適用前の全件 (label_map は大文字小文字と [] を無視・未知ラベルは other)" "$OUT" '.label_counts == {must: 2, should: 1, nit: 1, question: 0, pre_existing: 1, other: 2}'
check "上限は優先度順に残し、入力順で返す" "$OUT" '.kept_indices == [1, 2, 3] and ([.comments[].path] == ["b", "c", "d"])'
check "breakdown は残した指摘の内訳" "$OUT" '.breakdown == "[must] 2 件 / [should] 1 件"'
check "omitted_note に省略件数と内訳 (other も数える)" "$OUT" '.omitted_count == 4 and .omitted_note == "上限 3 件を超えたため 4 件を省略 ([nit] 1 件 / [pre_existing] 1 件 / その他 2 件)。"'
run OUT 0 bash "$FINAL" MAX_INLINE_COMMENTS='"3"' "$T/fc.json"
check "数値でない上限は上限なし + warnings" "$OUT" '.max_inline_comments == "unlimited" and (.comments | length) == 7 and (.warnings | length) == 1'
run OUT 0 bash "$FINAL" "$T/fc.json"
check "MAX_INLINE_COMMENTS 省略は上限なし" "$OUT" '.max_inline_comments == "unlimited" and .omitted_note == null and .warnings == []'
run OUT 0 bash "$FINAL" MAX_INLINE_COMMENTS=unlimited - < <(echo '{"comments": []}')
check "指摘なしは全キー 0 と 指摘なし" "$OUT" '.label_counts == {must: 0, should: 0, nit: 0, question: 0, pre_existing: 0, other: 0} and .breakdown == "指摘なし"'
run OUT 2 bash "$FINAL" - < <(echo '{"comments": ["x"]}')
[ -z "$OUT" ] && ok "comments の要素が object でなければ入力エラー" || ng "comments の要素が object でなければ入力エラー"
run OUT 2 bash "$FINAL" - < <(echo '{"comments": [], "label_map": {"blocker": "critical"}}')
[ -z "$OUT" ] && ok "label_map の値が標準ラベルでなければ入力エラー" || ng "label_map の値が標準ラベルでなければ入力エラー"

cat > "$T/fc2.json" <<'EOF'
{"comments": [
  {"path": "a", "line": 1, "body": "[要修正] a"},
  {"path": "b", "line": 2, "body": "[must-fix] b"},
  {"path": "c", "line": 3, "body": "ラベルなし"}],
 "label_map": {"要修正": "must", "[Must-Fix]": "should"}}
EOF
run OUT 0 env MAX_INLINE_COMMENTS=1 bash "$FINAL" "$T/fc2.json"
check "非 ASCII・ハイフン入りの独自ラベルも label_map で寄せる / 環境変数の MAX_INLINE_COMMENTS は読まない" "$OUT" '.label_counts == {must: 1, should: 1, nit: 0, question: 0, pre_existing: 0, other: 1} and .max_inline_comments == "unlimited"'
run OUT 2 bash "$FINAL" - < <(echo '{"comments": [], "label_map": {"blocker": "must", "[BLOCKER]": "nit"}}')
[ -z "$OUT" ] && ok "label_map のキーが正規化後に重複すれば入力エラー" || ng "label_map のキーが正規化後に重複すれば入力エラー"
run OUT 2 bash "$FINAL" - < <(echo '{"comments": [], "label_map": {"[]": "must"}}')
[ -z "$OUT" ] && ok "label_map の空キーは入力エラー" || ng "label_map の空キーは入力エラー"
for lm in '{"MUST": "nit"}' '{" must": "nit"}' '{"[should]": "pre_existing"}' '{"mu​st": "question"}' '{"ＭＵＳＴ": "nit"}' '{"nit": "must"}' '{"nit": "question"}'; do
  run OUT 2 bash "$FINAL" - < <(echo '{"comments": [{"path": "a", "line": 1, "body": "[must] a"}], "label_map": '"$lm"'}')
  [ -z "$OUT" ] && grep -q '付け替える' "$T/last.err" \
    && ok "標準ラベルの付け替えは入力エラー: $lm" || ng "標準ラベルの付け替えは入力エラー: $lm" "$(cat "$T/last.err")"
done
cat > "$T/fc3.json" <<'EOF'
{"comments": [
  {"path": "a", "line": 1, "body": "[ must] a"},
  {"path": "b", "line": 2, "body": "[[MUST]] b"},
  {"path": "c", "line": 3, "body": "[mu​st] c"},
  {"path": "d", "line": 4, "body": "[ＭＵＳＴ] d"},
  {"path": "e", "line": 5, "body": " ​[should] e"},
  {"path": "f", "line": 6, "body": "[nit] f"},
  {"path": "g", "line": 7, "body": "[blocker] g"}],
 "label_map": {"must": "must", "blocker": "must"}}
EOF
run OUT 0 bash "$FINAL" "$T/fc3.json"
check "空白・二重括弧・書式文字・全角・前置きの空白があっても標準ラベルとして数え、恒等の対応は受け付ける" "$OUT" '.label_counts == {must: 5, should: 1, nit: 1, question: 0, pre_existing: 0, other: 0}'
mkdir -p "$T/fcdir"
run OUT 2 bash "$FINAL" "$T/fcdir"
[ -z "$OUT" ] && ok "入力がディレクトリなら入力エラー" || ng "入力がディレクトリなら入力エラー"
cp "$T/fc2.json" "$T/a=b.json"
run OUT 0 bash "$FINAL" -- "$T/a=b.json"
check "= を含むパスは -- の後に置ける" "$OUT" '.label_counts.must == 1'
before=$(ls "$TMPDIR" | grep -c '^compose-review-finalize-' || true)
run OUT 0 bash -c 'cd "$1" && bash "$2" OUTPUT_PATH=out/rel.json "$3"' _ "$T" "$FINAL" "$T/fc2.json"
[ "$OUT" = "$T/out/rel.json" ] && [ -f "$T/out/rel.json" ] && ok "相対の OUTPUT_PATH は絶対パスにして出す" || ng "相対の OUTPUT_PATH は絶対パスにして出す" "$OUT"
after=$(ls "$TMPDIR" | grep -c '^compose-review-finalize-' || true)
[ "$before" = "$after" ] && ok "OUTPUT_PATH を指定した回は作業ディレクトリを残さない" || ng "OUTPUT_PATH を指定した回は作業ディレクトリを残さない" "$before -> $after"

# ========== read-only ==========
[ "$(git -C "$R" rev-parse HEAD)" = "$HEAD" ] && [ -z "$(git -C "$R" status --porcelain)" ] \
  && ok "テスト後もリポジトリの HEAD と作業ツリーは変わっていない" || ng "read-only"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
