#!/usr/bin/env bash
# compose-review skill / Step 5-5 (deterministic) の `## レビュー観点` に載せるパスの表示文字列を作る。
# パスはレビュー対象の作成者が付けられる値なので、表示とリンクの安全化を規則どおり機械的に行う。
#
# 使い方:
#   bash render-paths.sh --init
#     入力 JSON を書き出すべきパス `<dir>/input.json` を stdout に 1 行出す (ファイルは作らない)。
#   bash render-paths.sh <dir>/input.json
#     表示文字列の配列 (入力と同じ順) を stdout に 1 行の JSON で出す。
#
# 入力 JSON:
#   {"mode": "pr"|"local", "owner": string, "repo": string, "head_sha": string, "paths": [string, ...]}
#   owner / repo / head_sha は mode=pr のときだけ使う。
#
# 規則 (SKILL.md 5-5 の正典をここで実装する):
#   - 改行・制御文字・双方向制御文字・ゼロ幅文字を含むパスは "(表示できないパス)"
#   - 200 文字を超えるパスは "(長すぎるパス)"
#   - それ以外はコードスパンにする (パス中の最長のバッククォート列より 1 つ長い列で囲み、
#     先頭か末尾がバッククォートなら内側の前後にスペースを 1 つずつ入れる)
#   - mode=pr はレビューした head へのパーマリンクにする。URL はセグメントごとに @uri でエンコードし
#     (英数字・`-`・`.`・`_`・`~` 以外をパーセントエンコード)、区切りの `/` を残す
# exit: 0 = 正常 / 2 = 入力不正。
# bash 互換要件: bash 3.2 で動くこと (../../post-pr-review/scripts/build-review-payload.sh と同じ)。

set -euo pipefail

die() { echo "[render-paths] ERROR: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq が見つからない"
[ "$#" -eq 1 ] || die "usage: render-paths.sh --init | render-paths.sh <dir>/input.json"

if [ "$1" = "--init" ]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/compose-review-paths.XXXXXXXX")" || die "mktemp -d に失敗"
  echo "${work_dir%/}/input.json"
  exit 0
fi

input="$1"
[ -f "$input" ] || die "入力ファイルが無い: $input"
jq -e -s 'length == 1 and (.[0] | type == "object")' "$input" >/dev/null 2>&1 \
  || die "入力が単一の JSON object として parse できない: $input"
jq -e '(.mode == "pr" or .mode == "local") and (.paths | type == "array")' "$input" >/dev/null \
  || die "mode が pr / local でない、または paths が配列でない"
jq -e '.mode == "local" or ([.owner, .repo, .head_sha] | all(type == "string" and length > 0))' "$input" >/dev/null \
  || die "mode=pr で owner / repo / head_sha のいずれかが欠けている"

jq -c '
  def unsafe: test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}\\x{061c}\\x{200b}-\\x{200f}\\x{202a}-\\x{202e}\\x{2060}-\\x{2064}\\x{2066}-\\x{2069}\\x{feff}]");
  def codespan:
    . as $p
    | ([$p | scan("`+") | length] | max // 0) as $n
    | ("`" * ($n + 1)) as $f
    | (if ($p | startswith("`")) or ($p | endswith("`")) then " " + $p + " " else $p end) as $in
    | $f + $in + $f;
  . as $cfg
  | [ .paths[] | tostring
      | if unsafe then "(表示できないパス)"
        elif length > 200 then "(長すぎるパス)"
        elif $cfg.mode == "pr" then
          "[" + codespan + "](https://github.com/\($cfg.owner)/\($cfg.repo)/blob/\($cfg.head_sha)/"
            + (split("/") | map(@uri) | join("/")) + ")"
        else codespan end ]
' "$input"
