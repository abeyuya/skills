#!/usr/bin/env bash
# distill-pr-reviews skill / Phase A+B (deterministic) collector.
#
# 入力: 環境変数 (OWNER / REPO / SINCE / UNTIL / DAYS / MAX_PRS /
#                  FILTER_AUTHOR / FILTER_LABEL / INCLUDE_AI_AUTHORED / OUTPUT_DIR)
# 出力:
#   ${OUTPUT_DIR}/_pr_list.json      (中間: gh pr list --json 生 JSON)
#   ${OUTPUT_DIR}/_pr_data.jsonl     (中間: PR ごと 1 行 JSON, GraphQL から取得した
#                                       reviewThreads + commits + files)
#   ${OUTPUT_DIR}/prs.json           (Step 3 集約 — Phase B 入力)
#   ${OUTPUT_DIR}/signals.json       (Step 4 信号付与済み — Phase C への引き渡し)
#
# stdout: signals.json の絶対パス 1 行
# stderr: 進捗ログ
# exit  : 0 = 正常 / 0 PR でも正常終了 / 非 0 = gh / jq エラー
#
# 詳細スキーマと AI 側 (Phase C) との接続は ../SKILL.md を参照。
#
# rate limit 対策:
#   - 1 PR あたり GraphQL 1 query (基本) で reviewThreads + commits + files を一括取得。
#   - reviewThreads が 50 件超の PR は after cursor で追加 query を発行。
#   - 1 thread の comments が 50 件超の場合のみ node(id) で追加 query。
#   - REST `pulls/{N}/commits` / `commits/{sha}` は全廃 (core 枠を数百 query 消費していたため)。
#   - reactions は廃止 (信号価値が低くノード上限の圧迫が大きいため)。
#   - 1 query あたりノード試算: reviewThreads(50) × comments(50) + commits(100) + files(100) + labels(0)
#     ≈ 2,700 ノード (GraphQL 500k 上限の 0.5%)。

set -euo pipefail

# ====== 入力取得 ======
OWNER="${OWNER:-}"
REPO="${REPO:-}"
SINCE="${SINCE:-}"
UNTIL="${UNTIL:-}"
DAYS="${DAYS:-7}"
MAX_PRS="${MAX_PRS:-100}"
FILTER_AUTHOR="${FILTER_AUTHOR:-}"
FILTER_LABEL="${FILTER_LABEL:-}"
INCLUDE_AI_AUTHORED="${INCLUDE_AI_AUTHORED:-true}"
OUTPUT_DIR="${OUTPUT_DIR:-}"

log() { echo "[collect-signals] $*" >&2; }

# `--argjson` が後段で受け取れる "true" / "false" の 2 値に正規化する。
# typo (`True` / `TRUE` / `1` / `yes` / 末尾空白入り 等) で jq の "invalid JSON text" を出す代わりに、
# bash 側で明示的にエラーメッセージを出して exit 2 する。
INCLUDE_AI_AUTHORED_RAW="$INCLUDE_AI_AUTHORED"
INCLUDE_AI_AUTHORED=$(echo "$INCLUDE_AI_AUTHORED_RAW" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$INCLUDE_AI_AUTHORED" in
  true|1|yes|y)  INCLUDE_AI_AUTHORED=true ;;
  false|0|no|n)  INCLUDE_AI_AUTHORED=false ;;
  *) log "ERROR: INCLUDE_AI_AUTHORED must be true or false (got: ${INCLUDE_AI_AUTHORED_RAW})"; exit 2 ;;
esac

# ====== Step 0: 入力の正規化 ======
if [[ -z "$OWNER" || -z "$REPO" ]]; then
  NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  OWNER="${NWO%/*}"
  REPO="${NWO#*/}"
  log "OWNER/REPO auto-detected: ${OWNER}/${REPO}"
fi

if [[ -z "$UNTIL" ]]; then
  UNTIL=$(date -u +%Y-%m-%d)
fi
if [[ -z "$SINCE" ]]; then
  if SINCE=$(date -u -d "${UNTIL} - ${DAYS} days" +%Y-%m-%d 2>/dev/null); then
    :
  else
    # BSD date fallback (macOS)
    SINCE=$(date -u -v "-${DAYS}d" -j -f %Y-%m-%d "${UNTIL}" +%Y-%m-%d)
  fi
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  OUTPUT_DIR="/tmp/distill-pr-reviews/${REPO}/${TS}"
fi
mkdir -p "$OUTPUT_DIR"

log "OWNER=${OWNER} REPO=${REPO} SINCE=${SINCE} UNTIL=${UNTIL} MAX_PRS=${MAX_PRS}"
log "OUTPUT_DIR=${OUTPUT_DIR}"

# ====== Step 1: gh pr list ======
# bash の variable assignment 文脈では pathname expansion されないため、
# FILTER_AUTHOR="-author:dependabot[bot]" のような角括弧入り値も glob 展開されない。
SEARCH="merged:${SINCE}..${UNTIL}"
[[ -n "$FILTER_AUTHOR" ]] && SEARCH="${SEARCH} ${FILTER_AUTHOR}"
[[ -n "$FILTER_LABEL" ]]  && SEARCH="${SEARCH} ${FILTER_LABEL}"

PR_LIMIT=$((MAX_PRS + 100))
gh pr list \
  --repo "${OWNER}/${REPO}" \
  --search "${SEARCH}" \
  --json number,title,author,mergedAt,headRefOid,mergeCommit,baseRefName,headRefName,labels,url \
  --limit "$PR_LIMIT" \
  > "${OUTPUT_DIR}/_pr_list.json"

PR_COUNT=$(jq 'length' "${OUTPUT_DIR}/_pr_list.json")
log "PR count: ${PR_COUNT}"

if [[ "$PR_COUNT" -gt "$MAX_PRS" ]]; then
  log "WARNING: PR count ${PR_COUNT} > MAX_PRS ${MAX_PRS} (信号品質低下の可能性あり)"
  MAX_PRS_EXCEEDED=true
else
  MAX_PRS_EXCEEDED=false
fi

COLLECTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 0 件は空 signals.json を出して即終了
if [[ "$PR_COUNT" -eq 0 ]]; then
  log "No PRs in period; emitting empty signals.json"
  jq -n \
    --arg owner "$OWNER" --arg repo "$REPO" \
    --arg since "$SINCE" --arg until "$UNTIL" \
    --arg collected_at "$COLLECTED_AT" \
    --argjson pr_count 0 --argjson max_prs_exceeded false \
    --argjson include_ai_authored "$INCLUDE_AI_AUTHORED" \
    '{meta: {owner:$owner, repo:$repo, since:$since, until:$until, collected_at:$collected_at, pr_count:$pr_count, max_prs_exceeded:$max_prs_exceeded, include_ai_authored:$include_ai_authored}, prs: []}' \
    > "${OUTPUT_DIR}/signals.json"
  echo "${OUTPUT_DIR}/signals.json"
  exit 0
fi

# ====== Step 2: PR ごとに GraphQL 統合クエリ ======
# 1 PR = 1 GraphQL query で reviewThreads + commits + files を一括取得する。
# reviewThreads の内側 comments は first: 50 のみ (cafter を持たせると外側全ノードに
# 同 cursor が適用されて壊れるため)。50 件超のスレッドだけ node(id) 経由で追加クエリ。
GQL_PR='query($owner: String!, $name: String!, $number: Int!, $tafter: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number
      files(first: 100) {
        pageInfo { hasNextPage }
        nodes { path }
      }
      commits(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          commit {
            oid committedDate messageHeadline
          }
        }
      }
      reviewThreads(first: 50, after: $tafter) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated
          comments(first: 50) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id author { login __typename } body createdAt
              path line originalLine diffHunk url
            }
          }
        }
      }
    }
  }
}'

# 内側追加クエリ (1 thread の comments が 50 件超の場合のみ)。
GQL_INNER='query($threadId: ID!, $cafter: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 50, after: $cafter) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id author { login __typename } body createdAt
          path line originalLine diffHunk url
        }
      }
    }
  }
}'

PR_DATA_FILE="${OUTPUT_DIR}/_pr_data.jsonl"
: > "$PR_DATA_FILE"

PR_NUMBERS=$(jq -r '.[].number' "${OUTPUT_DIR}/_pr_list.json")
PR_INDEX=0
NEED_SLEEP=$([[ "$PR_COUNT" -gt 50 ]] && echo true || echo false)

for PR_NUMBER in $PR_NUMBERS; do
  PR_INDEX=$((PR_INDEX + 1))
  if [[ "$NEED_SLEEP" == "true" && "$PR_INDEX" -gt 1 ]]; then
    sleep 1
  fi
  log "Fetching PR #${PR_NUMBER} (${PR_INDEX}/${PR_COUNT})"

  # PR ごとの中間ファイル (シェル変数経由で大きな JSON を渡すと argv 上限を超えうるため、
  # 全てファイル経由で扱う)
  THREADS_FILE_TMP="${OUTPUT_DIR}/_pr_threads_${PR_NUMBER}.tmp.json"
  FILES_FILE_TMP="${OUTPUT_DIR}/_pr_files_${PR_NUMBER}.tmp.json"
  COMMITS_FILE_TMP="${OUTPUT_DIR}/_pr_commits_${PR_NUMBER}.tmp.json"
  NODES_FILE="${OUTPUT_DIR}/_pr_nodes_${PR_NUMBER}.tmp.json"
  NEW_COMMENTS_FILE="${OUTPUT_DIR}/_pr_new_comments_${PR_NUMBER}.tmp.json"
  echo '[]' > "$THREADS_FILE_TMP"

  TAFTER=""
  FILES_TRUNCATED="false"
  COMMITS_TRUNCATED="false"
  FIRST_PAGE=true

  while :; do
    if [[ -z "$TAFTER" ]]; then
      PAGE=$(gh api graphql \
        -F owner="$OWNER" -F name="$REPO" -F number="$PR_NUMBER" \
        -f query="$GQL_PR")
    else
      PAGE=$(gh api graphql \
        -F owner="$OWNER" -F name="$REPO" -F number="$PR_NUMBER" \
        -F tafter="$TAFTER" \
        -f query="$GQL_PR")
    fi

    if [[ "$FIRST_PAGE" == "true" ]]; then
      # 初回ページのみ files / commits を保存 (2 ページ目以降は変わらないため再取得は無駄だが
      # GraphQL の API 仕様上、reviewThreads のページングと files/commits を別 query に
      # 分けるとさらに query を消費するため、1 query にまとめたまま 2 ページ目以降は捨てる)。
      echo "$PAGE" | jq '.data.repository.pullRequest.files.nodes | map(.path)' > "$FILES_FILE_TMP"
      echo "$PAGE" | jq '.data.repository.pullRequest.commits.nodes
        | map(.commit | {sha: .oid, committed_at: .committedDate, message_headline: .messageHeadline})' \
        > "$COMMITS_FILE_TMP"
      FILES_HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.files.pageInfo.hasNextPage')
      COMMITS_HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.commits.pageInfo.hasNextPage')
      if [[ "$FILES_HAS_NEXT" == "true" ]]; then
        FILES_TRUNCATED="true"
        log "WARNING: PR #${PR_NUMBER} files list truncated at 100 (file_changed_after_comment may be false-negative)"
      fi
      if [[ "$COMMITS_HAS_NEXT" == "true" ]]; then
        COMMITS_TRUNCATED="true"
        log "WARNING: PR #${PR_NUMBER} commits list truncated at 100 (late commits not reflected)"
      fi
      FIRST_PAGE=false
    fi

    # reviewThreads の nodes を累積 (argv 上限回避のためファイル経由)
    echo "$PAGE" | jq '.data.repository.pullRequest.reviewThreads.nodes' > "$NODES_FILE"
    jq -s 'add' "$THREADS_FILE_TMP" "$NODES_FILE" > "${THREADS_FILE_TMP}.new"
    mv "${THREADS_FILE_TMP}.new" "$THREADS_FILE_TMP"

    HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    TAFTER=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""')
    [[ "$HAS_NEXT" == "true" ]] || break
  done

  # 内側 (comments 50 件超) は該当スレッドだけ追加クエリで埋める
  THREAD_IDS_OVER=$(jq -r '.[] | select(.comments.pageInfo.hasNextPage == true) | .id' "$THREADS_FILE_TMP")
  for THREAD_ID in $THREAD_IDS_OVER; do
    CAFTER=$(jq -r --arg id "$THREAD_ID" '.[] | select(.id == $id) | .comments.pageInfo.endCursor' "$THREADS_FILE_TMP")
    while :; do
      INNER=$(gh api graphql \
        -F threadId="$THREAD_ID" \
        -F cafter="$CAFTER" \
        -f query="$GQL_INNER")
      echo "$INNER" | jq '.data.node.comments.nodes' > "$NEW_COMMENTS_FILE"
      jq --arg id "$THREAD_ID" --slurpfile new "$NEW_COMMENTS_FILE" \
        'map(if .id == $id then .comments.nodes += $new[0] else . end)' \
        "$THREADS_FILE_TMP" > "${THREADS_FILE_TMP}.new"
      mv "${THREADS_FILE_TMP}.new" "$THREADS_FILE_TMP"
      INNER_HAS_NEXT=$(echo "$INNER" | jq -r '.data.node.comments.pageInfo.hasNextPage')
      CAFTER=$(echo "$INNER" | jq -r '.data.node.comments.pageInfo.endCursor // ""')
      [[ "$INNER_HAS_NEXT" == "true" ]] || break
    done
  done

  # PR 単位の集約レコードを JSONL に追記
  jq -c \
    --argjson pr "$PR_NUMBER" \
    --slurpfile files "$FILES_FILE_TMP" \
    --slurpfile commits "$COMMITS_FILE_TMP" \
    --argjson files_truncated "$FILES_TRUNCATED" \
    --argjson commits_truncated "$COMMITS_TRUNCATED" \
    '{pr_number: $pr, files: $files[0], commits: $commits[0], threads: .,
      files_truncated: $files_truncated, commits_truncated: $commits_truncated}' \
    "$THREADS_FILE_TMP" >> "$PR_DATA_FILE"

  rm -f "$THREADS_FILE_TMP" "$FILES_FILE_TMP" "$COMMITS_FILE_TMP" \
        "$NODES_FILE" "$NEW_COMMENTS_FILE"
done

# ====== Step 3: prs.json 組み立て ======
PRS_FILE="${OUTPUT_DIR}/prs.json"

jq -n \
  --arg owner "$OWNER" --arg repo "$REPO" \
  --arg since "$SINCE" --arg until "$UNTIL" \
  --arg collected_at "$COLLECTED_AT" \
  --argjson pr_count "$PR_COUNT" \
  --argjson max_prs_exceeded "$MAX_PRS_EXCEEDED" \
  --argjson include_ai_authored "$INCLUDE_AI_AUTHORED" \
  --slurpfile pr_list "${OUTPUT_DIR}/_pr_list.json" \
  --slurpfile pr_data_lines <(jq -s '.' "$PR_DATA_FILE") \
  '
    ($pr_data_lines[0] | map({(.pr_number | tostring): .}) | add // {}) as $data_map |
    {
      meta: {
        owner: $owner, repo: $repo,
        since: $since, until: $until,
        collected_at: $collected_at,
        pr_count: $pr_count,
        max_prs_exceeded: $max_prs_exceeded,
        include_ai_authored: $include_ai_authored
      },
      prs: ($pr_list[0] | map(
        . as $pr |
        ($pr.number | tostring) as $key |
        ($data_map[$key] // {files: [], commits: [], threads: [], files_truncated: false, commits_truncated: false}) as $d |
        {
          number: $pr.number,
          title: $pr.title,
          author: ($pr.author.login // "ghost"),
          merged_at: $pr.mergedAt,
          head_sha: $pr.headRefOid,
          merge_commit_sha: ($pr.mergeCommit.oid // null),
          base_ref: $pr.baseRefName,
          head_ref: $pr.headRefName,
          labels: ($pr.labels | map(.name)),
          url: $pr.url,
          files: $d.files,
          files_truncated: $d.files_truncated,
          commits_truncated: $d.commits_truncated,
          commits: $d.commits,
          review_threads: ($d.threads | map({
            thread_id: .id,
            is_resolved: .isResolved,
            is_outdated: .isOutdated,
            comments: (.comments.nodes | map({
              id: .id,
              author_login: (.author.login // "ghost"),
              author_type: (.author.__typename // "Unknown"),
              body: .body,
              created_at: .createdAt,
              path: .path,
              line: .line,
              original_line: .originalLine,
              diff_hunk: .diffHunk,
              url: .url,
              is_ai_authored: (.body | test("^> \\*\\*\\[AI 自動投稿\\]\\*\\*"))
            }))
          }))
        }
      ))
    }
  ' > "$PRS_FILE"

# ====== Step 4: 信号付与 → signals.json ======
SIGNALS_FILE="${OUTPUT_DIR}/signals.json"

jq '
  def affirmative_keywords: ["fixed", "対応", "修正", "反映", "確かに", "その通り", "done", "addressed"];
  # 否定キーワード: 肯定キーワードを含んでいても、これらが同 body 内にあれば
  # affirmative=false に倒す。例:「対応しません」「現状維持」「wontfix」など。
  def negative_keywords: [
    "対応しません", "対応しない", "対応せず",
    "修正しません", "修正しない", "修正せず",
    "反映しません", "反映しない", "反映せず",
    "現状維持", "不採用", "不要です",
    "wontfix", "wont fix",
    "not addressed", "not fixed"
  ];

  .prs |= map(
    . as $pr |
    ($pr.files // []) as $pr_files |
    # PR 内の path -> 同一 PR で **別 thread** に同 path の指摘があるかの map。
    # thread 内の reply (同 path) は 1 thread = 1 指摘として扱いたいので、各 thread の冒頭コメントの path だけを拾う。
    ([$pr.review_threads[] | .comments[0].path]
      | group_by(.) | map({key: .[0], value: (length > 1)}) | from_entries) as $path_multi |

    .review_threads |= map(
      . as $thread |
      .comments |= map(
        . as $cm |
        ([$thread.comments[]
          | select(.created_at > $cm.created_at
                   and .author_login == $pr.author
                   and ((. as $x | affirmative_keywords | any(. as $kw | $x.body | contains($kw))))
                   and ((. as $x | negative_keywords | any(. as $kw | $x.body | contains($kw))) | not)
                  )
         ] | length > 0) as $author_replied |
        # file_changed_after_comment 判定:
        #   PR 全体の files に当該 path が含まれ、かつコメント作成以降に少なくとも 1 commit があるか。
        # 旧ロジック (commit 別 files の一致判定) と比較すると、コメント前 commit のみで完結した
        # 変更を false positive として拾う精度劣化があるが、commit 別 files を取るために必要だった
        # REST `commits/{sha}` (commit 数 × 1 query) を全廃できるため rate limit 観点で採用。
        # 信号値の精度低下は Phase C の AI が body + diff_hunk で最終判断することで吸収する。
        (($pr_files | any(. == $cm.path))
          and ([$pr.commits[]? | select(.committed_at > $cm.created_at)] | length > 0)
        ) as $file_changed |
        # body の引用行 (`> ` 始まり) は他コメントの引用 (post-pr-review マーカー / Reviewer の発言再掲) を含むため、
        # severity ラベルの抽出対象から除外する。残された非引用部分の最初のマッチを採用する。
        (($cm.body | split("\n") | map(select(test("^> ") | not)) | join("\n")
          | match("\\[(must|should|nit|question|pre_existing)\\]"; "")
          | .captures[0].string) // null) as $sev |
        . + {signals: {
          thread_resolved: $thread.is_resolved,
          thread_outdated: $thread.is_outdated,
          file_changed_after_comment: $file_changed,
          author_replied_affirmative: $author_replied,
          severity_label: $sev,
          is_ai_authored: $cm.is_ai_authored,
          author_type: $cm.author_type,
          reply_count: (($thread.comments | length) - 1),
          comment_length: ($cm.body | length),
          same_file_in_pr: ($path_multi[$cm.path] // false)
        }}
      )
    )
  )
' "$PRS_FILE" > "$SIGNALS_FILE"

log "Done: ${SIGNALS_FILE}"
echo "${SIGNALS_FILE}"
