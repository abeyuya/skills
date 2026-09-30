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
  printf '   ## エスカレーション基準 (apps)\n\n- 公開 API の変更\n### 下位\n- 下位の項目\n## 次の節\n- 対象外'
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
[ "${1:-}" = api ] || { echo "stub: unsupported: $*" >&2; exit 1; }
shift
url=""; silent=false
while [ $# -gt 0 ]; do
  case $1 in
    --paginate) shift ;;
    --silent) silent=true; shift ;;
    -H) shift 2 ;;
    *) url=$1; shift ;;
  esac
done
if [ "${STUB_FAIL:-}" = 403 ]; then echo "gh: Forbidden (HTTP 403)" >&2; exit 1; fi
cd "$STUB_REPO"
case $url in
  repos/o/r/pulls/7)
    printf '{"head":{"sha":"%s"}}' "$STUB_HEAD" ;;
  repos/o/r/pulls/7/files)
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
    t=$(git cat-file -t "$ref:$path" 2>/dev/null || true)
    if [ "$t" != blob ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    $silent || git cat-file blob "$ref:$path" ;;
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

run OUT 3 env PATH="$STUB:$PATH" STUB_FAIL_CONTENTS='apps/REVIEW.md' MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh 経路: 404 以外 (500) は fatal" "$OUT" '.fatal | test("404 以外")'
run OUT 3 env PATH="$STUB:$PATH" STUB_FAIL=403 MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh 経路: 403 は fatal (0 件と読まない)" "$OUT" '.fatal != null'
run OUT 3 env PATH="$STUB:$PATH" MODE=pr HEAD_SHA="$MISSING" BASE_SHA="$BASE" OWNER=o REPO=r PR_NUMBER=7 bash "$CHANGED"
check "gh 経路: PR の現 head と HEAD_SHA が違えば fatal" "$OUT" '.fatal | test("一致しない")'

run OUT 0 env PATH="$STUB:$PATH" SOURCE=gh REF="$HEAD" OWNER=o REPO=r bash "$READ" --root -- 'a#b?c/REVIEW.md' 'no/such/REVIEW.md'
check "read gh: # ? を含むパスを取得 / 不在は absent" "$OUT" '.root_selected == "REVIEW.md" and ([.files[] | select(.path == "a#b?c/REVIEW.md") | .status] == ["present"]) and ([.files[] | select(.path == "no/such/REVIEW.md") | .status] == ["absent"])'
run OUT 3 env PATH="$STUB:$PATH" STUB_FAIL=403 SOURCE=gh REF="$HEAD" OWNER=o REPO=r bash "$READ" --root
check "read gh: 403 は fatal" "$OUT" '.fatal | test("404 以外")'
cd "$R"

# ========== read-instruction-files.sh (git / local) ==========
echo "# read-instruction-files.sh"
run CF 0 env MODE=pr HEAD_SHA="$HEAD" BASE_SHA="$BASE" SOURCE=git bash "$CHANGED"
run OUT 0 env SOURCE=git REF="$HEAD" bash "$READ" --root --ancestors "$CF"
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

# ========== read-only ==========
[ "$(git -C "$R" rev-parse HEAD)" = "$HEAD" ] && [ -z "$(git -C "$R" status --porcelain)" ] \
  && ok "テスト後もリポジトリの HEAD と作業ツリーは変わっていない" || ng "read-only"

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
