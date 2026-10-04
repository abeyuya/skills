#!/usr/bin/env bash
# compose-review skill / Step 5-3 (deterministic) の件数上限適用と label_counts 集計。
#
# 使い方:
#   bash finalize-comments.sh --init
#     一意の作業ディレクトリを作り、入力 JSON を書き出すべきパス `<dir>/input.json` を stdout に 1 行出す。
#     ファイル自体は作らない (Write ツールで新規作成でき、事前 Read が要らない)。
#   bash finalize-comments.sh <dir>/input.json
#     結果 JSON を stdout に 1 行で出す。
#
# 入力 JSON:
#   {
#     "comments": [ ... ],              必須。マージ・重複排除・範囲外除外まで済ませた全指摘
#                                       (MAX_INLINE_COMMENTS による省略は未適用)。要素はそのまま出力に渡す
#     "max_inline_comments": N|"unlimited", 任意。省略時 "unlimited"。正の整数以外も "unlimited" 扱い
#     "label_map": {"blocker": "must"}  任意。独自ラベル (小文字) → 標準ラベルの対応。モデルが決めて渡す
#   }
#
# 出力 JSON:
#   {
#     "comments": [ ... ],              上限適用後の comments[] (元の並び順を保つ)
#     "label_counts": {must, should, nit, question, pre_existing, other},
#                                       上限適用 **前** の全指摘のラベル別件数 (Step 6 の label_counts)
#     "breakdown": string,              `## 指摘内訳` に書く文字列 (上限適用後。0 件なら "指摘なし")
#     "omitted_note": string|null       省略があれば `## 指摘内訳` 末尾に添える 1 文。無ければ null
#   }
#
# ラベルは comments[].body 先頭の `^\[([A-Za-z_]+)\]` を小文字化して取る
# (post-pr-review の build-review-payload.sh と同じ規則)。
# exit: 0 = 正常 / 2 = 入力不正。
# bash 互換要件: bash 3.2 で動くこと (../../post-pr-review/scripts/build-review-payload.sh と同じ)。

set -euo pipefail

die() { echo "[finalize-comments] ERROR: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq が見つからない"
[ "$#" -eq 1 ] || die "usage: finalize-comments.sh --init | finalize-comments.sh <dir>/input.json"

if [ "$1" = "--init" ]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/compose-review-finalize.XXXXXXXX")" || die "mktemp -d に失敗"
  echo "${work_dir%/}/input.json"
  exit 0
fi

input="$1"
[ -f "$input" ] || die "入力ファイルが無い: $input"
jq -e -s 'length == 1 and (.[0] | type == "object")' "$input" >/dev/null 2>&1 \
  || die "入力が単一の JSON object として parse できない: $input"
jq -e '.comments | type == "array"' "$input" >/dev/null || die "comments が配列でない"

jq -c '
  def std: ["must", "should", "nit", "question", "pre_existing"];
  def rank($k): (std | index($k)) // 5;
  (.label_map // {}) as $map
  | (.max_inline_comments // "unlimited") as $max
  | [ .comments | to_entries[]
      | ((.value.body // "" | tostring) as $b
         | [$b | capture("^\\[(?<l>[A-Za-z_]+)\\]") | .l][0] // "" | ascii_downcase) as $raw
      | ($map[$raw] // $raw) as $mapped
      | {i: .key, c: .value, k: (if (std | index($mapped)) != null then $mapped else "other" end)} ] as $all
  | (reduce $all[] as $e ({must:0, should:0, nit:0, question:0, pre_existing:0, other:0}; .[$e.k] += 1)) as $counts
  | (if ($max | type) == "number" and $max >= 1 and ($max | floor) == $max
     then ($all | sort_by(rank(.k), .i) | .[:$max] | sort_by(.i))
     else $all end) as $kept
  | ($all - $kept) as $dropped
  | def breakdown($xs):
      [ (std + ["other"])[] as $k | ($xs | map(select(.k == $k)) | length) as $n
        | select($n > 0) | (if $k == "other" then "その他" else "[\($k)]" end) + " \($n) 件" ] | join(" / ");
  {
    comments: [$kept[].c],
    label_counts: $counts,
    breakdown: (breakdown($kept) | if . == "" then "指摘なし" else . end),
    omitted_note: (if ($dropped | length) > 0
      then "上限 \($max) 件を超えたため \($dropped | length) 件を省略 (\(breakdown($dropped)))。"
      else null end)
  }
' "$input"
