#!/usr/bin/env bash
# compose-review skill / 5-5「参照した指示ファイル」の描画 (deterministic)。
#
# 指示ファイルのパスはレビュー対象の作成者が付けられる値なので、公開される Review body に載せる前に
#   - URL 部分: 英数字・`-`・`.`・`_`・`~`・区切りの `/` 以外のバイトを UTF-8 でパーセントエンコード
#   - リンクテキスト: コードスパン (パス中の最長のバッククォート列より 1 つ長い列で囲む。先頭か末尾が
#     バッククォートのとき、または先頭と末尾の両方がスペースのときは、内側の前後にスペースを 1 つずつ入れる)
#   - 制御文字・書式文字 (双方向制御 / ゼロ幅など Unicode の Cc / Cf)、行区切り (Zl / Zp)、不正な UTF-8 を含むパス
#     → `(表示できないパス)`、200 文字を超えるパス → `(長すぎるパス)`
#   - 件数上限: 採用 20 件 (超過は `ほか <N> 件`)、不採用 5 件 (超過は `ほか <N> 件も件数上限で不採用`)
# を機械的に適用する。
#
# 入力: 第 1 引数に JSON ファイル (`-` または省略で stdin)。
#   {
#     "mode": "pr" | "local",
#     "owner": "...", "repo": "...", "head_sha": "<40 桁>",   // mode=pr のとき必須
#     "adopted":  ["REVIEW.md", "apps/web/REVIEW.md", ...],   // 方針として読み込んだファイル (root 相対)
#     "rejected": ["apps/x/REVIEW.md", ...],                  // Step 3 の間引きで不採用にした祖先 (任意)
#     "scopes":   ["apps/web/", ...]                          // `自前レビュー` 行の適用範囲 (任意)
#   }
#   順序は root → 子 (`/` の少ない順。同じ深さは入力順) に並べ直す。同じパスは 1 行にまとめる。
#   OUTPUT_PATH (環境変数) : 結果 JSON の書き出し先。省略時は一意の temp ディレクトリ配下の result.json
#
# 出力: OUTPUT_PATH に JSON を書き、stdout にそのパスを 1 行出す。
#   {
#     "markdown": "  - [`REVIEW.md`](https://...)\n  - ...\n",   // `- 参照した指示ファイル` の下にそのまま置く行
#     "lines": ["[`REVIEW.md`](https://...)", ...],               // 箇条書き記号なしの各行
#     "scopes": [{"path": "apps/web/", "rendered": "`apps/web/`"}]  // 適用範囲のコードスパン (同じ規則。リンクなし)
#   }
#
# exit: 0 = 正常 / 2 = 入力エラー
#
# bash 互換要件: **bash 3.2 (macOS 標準の /bin/bash) で動くこと** (distill-pr-reviews/scripts/collect-signals.sh と同じ)。
#   描画はすべて jq で行う (文字数は jq の length = コードポイント数)。

set -euo pipefail

die_usage() { echo "[render-instruction-links] usage error: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die_usage "jq が見つからない"

IN="${1:--}"
OUTPUT_PATH="${OUTPUT_PATH:-}"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/compose-review-links-XXXXXX")
if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="$WORK_DIR/result.json"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"

if [ "$IN" = - ]; then
  cat >"$WORK_DIR/input.json"
else
  [ -r "$IN" ] || die_usage "入力 JSON が見つからない: $IN"
  cat "$IN" >"$WORK_DIR/input.json"
fi

err=$(jq -r '
  if (.mode != "pr" and .mode != "local") then "mode は pr / local"
  elif .mode == "pr" and ((.owner // "") | test("^[A-Za-z0-9._-]+$") | not) then "owner が不正"
  elif .mode == "pr" and ((.repo // "") | test("^[A-Za-z0-9._-]+$") | not) then "repo が不正"
  elif .mode == "pr" and ((.head_sha // "") | test("^[0-9a-f]{40}$") | not) then "head_sha が 40 桁の SHA ではない"
  elif ((.adopted // []) | type) != "array" or ((.rejected // []) | type) != "array" or ((.scopes // []) | type) != "array" then "adopted / rejected / scopes は配列"
  elif ([(.adopted // [])[], (.rejected // [])[], (.scopes // [])[]] | all(type == "string") | not) then "パスは文字列"
  else "" end' "$WORK_DIR/input.json" 2>&1) || die_usage "入力 JSON を解釈できない: $err"
[ -z "$err" ] || die_usage "$err"

jq '
  def depth: [scan("/")] | length;
  def uniq_keep_order: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
  def order: uniq_keep_order | to_entries | sort_by((.value | depth), .key) | map(.value);
  def unsafe: test("[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}\\x{FFFD}]");
  def codespan:
    (([match("`+"; "g") | .length] | max) // 0) as $m
    | ("`" * ($m + 1)) as $f
    | (if startswith("`") or endswith("`") or (startswith(" ") and endswith(" ")) then " " + . + " " else . end) as $in
    | $f + $in + $f;
  def enc: split("/") | map(@uri | gsub("!"; "%21") | gsub("\\*"; "%2A") | gsub("'"'"'"; "%27") | gsub("\\("; "%28") | gsub("\\)"; "%29")) | join("/");
  def entry($link):
    if unsafe then "(表示できないパス)"
    elif length > 200 then "(長すぎるパス)"
    elif $link then "[" + codespan + "](" + $link + ")"
    else codespan end;

  . as $in
  | (if $in.mode == "pr" then "https://github.com/\($in.owner)/\($in.repo)/blob/\($in.head_sha)/" else null end) as $base
  | def render: . as $p | entry(if $base == null or ($p | unsafe) or ($p | length > 200) then null else $base + ($p | enc) end);
    (($in.adopted // []) | order) as $a
  | (($in.rejected // []) | order | map(select(. as $x | $a | index([$x]) | not))) as $r
  | ([$a[:20][] | render]
     + (if ($a | length) > 20 then ["ほか \(($a | length) - 20) 件"] else [] end)
     + [$r[:5][] | render + " (件数上限で方針として不採用)"]
     + (if ($r | length) > 5 then ["ほか \(($r | length) - 5) 件も件数上限で不採用"] else [] end)
    ) as $lines
  | ($lines | if length == 0 then ["なし"] else . end) as $lines
  | {
      markdown: ($lines | map("  - " + . + "\n") | add),
      lines: $lines,
      scopes: [($in.scopes // [])[] | {path: ., rendered: entry(null)}]
    }
' "$WORK_DIR/input.json" >"$OUTPUT_PATH"

echo "$OUTPUT_PATH"
