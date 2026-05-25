#!/usr/bin/env bash
# distill-pr-reviews skill / Phase A+B (deterministic) collector.
#
# 入力: 環境変数 (OWNER / REPO / SINCE / UNTIL / DAYS / MAX_PRS /
#                  FILTER_AUTHOR / FILTER_LABEL / INCLUDE_AI_AUTHORED / OUTPUT_DIR)
# 出力:
#   ${OUTPUT_DIR}/_pr_list.json      (中間: gh pr list --json 生 JSON)
#   ${OUTPUT_DIR}/_threads.jsonl     (中間: PR ごと 1 行 JSON)
#   ${OUTPUT_DIR}/_commits.jsonl     (中間: PR ごと 1 行 JSON)
#   ${OUTPUT_DIR}/_commit_files.json (中間: sha -> [files] map)
#   ${OUTPUT_DIR}/prs.json           (Step 4 集約 — Phase B 入力)
#   ${OUTPUT_DIR}/signals.json       (Step 5 信号付与済み — Phase C への引き渡し)
#
# stdout: signals.json の絶対パス 1 行
# stderr: 進捗ログ
# exit  : 0 = 正常 / 0 PR でも正常終了 / 非 0 = gh / jq エラー
#
# 詳細スキーマと AI 側 (Phase C) との接続は ../SKILL.md を参照。

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
    '{meta: {owner:$owner, repo:$repo, since:$since, until:$until, collected_at:$collected_at, pr_count:$pr_count, max_prs_exceeded:$max_prs_exceeded}, prs: []}' \
    > "${OUTPUT_DIR}/signals.json"
  echo "${OUTPUT_DIR}/signals.json"
  exit 0
fi

# ====== Step 2: reviewThreads (GraphQL) ======
GQL_OUTER='query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id author { login } body createdAt
              path line originalLine diffHunk url
              reactions(first: 20) { nodes { content } }
            }
          }
        }
      }
    }
  }
}'

GQL_INNER='query($threadId: ID!, $cafter: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cafter) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id author { login } body createdAt
          path line originalLine diffHunk url
          reactions(first: 20) { nodes { content } }
        }
      }
    }
  }
}'

THREADS_FILE="${OUTPUT_DIR}/_threads.jsonl"
: > "$THREADS_FILE"

PR_NUMBERS=$(jq -r '.[].number' "${OUTPUT_DIR}/_pr_list.json")
PR_INDEX=0
NEED_SLEEP=$([[ "$PR_COUNT" -gt 50 ]] && echo true || echo false)

for PR_NUMBER in $PR_NUMBERS; do
  PR_INDEX=$((PR_INDEX + 1))
  if [[ "$NEED_SLEEP" == "true" && "$PR_INDEX" -gt 1 ]]; then
    sleep 1
  fi
  log "Fetching reviewThreads for PR #${PR_NUMBER} (${PR_INDEX}/${PR_COUNT})"

  ALL_THREADS='[]'
  AFTER=""
  while :; do
    if [[ -z "$AFTER" ]]; then
      PAGE=$(gh api graphql \
        -F owner="$OWNER" -F name="$REPO" -F number="$PR_NUMBER" \
        -f query="$GQL_OUTER")
    else
      PAGE=$(gh api graphql \
        -F owner="$OWNER" -F name="$REPO" -F number="$PR_NUMBER" \
        -F after="$AFTER" \
        -f query="$GQL_OUTER")
    fi

    NODES=$(echo "$PAGE" | jq '.data.repository.pullRequest.reviewThreads.nodes')
    ALL_THREADS=$(jq -n --argjson a "$ALL_THREADS" --argjson b "$NODES" '$a + $b')

    HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    AFTER=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""')
    [[ "$HAS_NEXT" == "true" ]] || break
  done

  # 内側 (comments 100 件超) は該当スレッドだけ別クエリで埋める
  THREAD_IDS_OVER=$(echo "$ALL_THREADS" | jq -r '.[] | select(.comments.pageInfo.hasNextPage == true) | .id')
  for THREAD_ID in $THREAD_IDS_OVER; do
    CAFTER=$(echo "$ALL_THREADS" | jq -r --arg id "$THREAD_ID" '.[] | select(.id == $id) | .comments.pageInfo.endCursor')
    while :; do
      INNER=$(gh api graphql \
        -F threadId="$THREAD_ID" \
        -F cafter="$CAFTER" \
        -f query="$GQL_INNER")
      NEW_COMMENTS=$(echo "$INNER" | jq '.data.node.comments.nodes')
      ALL_THREADS=$(echo "$ALL_THREADS" | jq --arg id "$THREAD_ID" --argjson new "$NEW_COMMENTS" \
        'map(if .id == $id then .comments.nodes += $new else . end)')
      INNER_HAS_NEXT=$(echo "$INNER" | jq -r '.data.node.comments.pageInfo.hasNextPage')
      CAFTER=$(echo "$INNER" | jq -r '.data.node.comments.pageInfo.endCursor // ""')
      [[ "$INNER_HAS_NEXT" == "true" ]] || break
    done
  done

  jq -nc --argjson pr "$PR_NUMBER" --argjson threads "$ALL_THREADS" \
    '{pr_number: $pr, threads: $threads}' \
    >> "$THREADS_FILE"
done

# ====== Step 3: commits + 各 commit の files ======
COMMITS_FILE="${OUTPUT_DIR}/_commits.jsonl"
: > "$COMMITS_FILE"

for PR_NUMBER in $PR_NUMBERS; do
  log "Fetching commits for PR #${PR_NUMBER}"
  COMMITS_ARRAY=$(gh pr view "$PR_NUMBER" \
    --repo "${OWNER}/${REPO}" \
    --json commits \
    --jq '[.commits[] | {sha: .oid, committed_at: .committedDate, message_headline: .messageHeadline}]')
  jq -nc --argjson pr "$PR_NUMBER" --argjson commits "$COMMITS_ARRAY" \
    '{pr_number: $pr, commits: $commits}' \
    >> "$COMMITS_FILE"
done

# 全 commit の files を取得 (Step 5 で file_changed_after_comment 判定に必要)。
# 「Phase B で必要な分のみ後埋め」とした SKILL.md 旧設計より積極取得に倒す:
# MAX_PRS=100 規模なら commit 数も最大 1000 程度で、API レート許容範囲内かつ
# 後段 (Step 5) の jq ロジックを大幅に簡素化できるため。
COMMIT_FILES_TMP="${OUTPUT_DIR}/_commit_files.jsonl"
: > "$COMMIT_FILES_TMP"

ALL_SHAS=$(jq -r '.commits[]?.sha' "$COMMITS_FILE" | sort -u)
for SHA in $ALL_SHAS; do
  [[ -z "$SHA" ]] && continue
  log "Fetching files for commit ${SHA:0:7}"
  FILES=$(gh api "repos/${OWNER}/${REPO}/commits/${SHA}" --jq '[.files[]?.filename]' 2>/dev/null || echo "[]")
  jq -nc --arg sha "$SHA" --argjson files "$FILES" '{sha: $sha, files: $files}' >> "$COMMIT_FILES_TMP"
done

# sha -> [files] map に変換
COMMIT_FILES_FILE="${OUTPUT_DIR}/_commit_files.json"
jq -s 'reduce .[] as $x ({}; .[$x.sha] = $x.files)' "$COMMIT_FILES_TMP" > "$COMMIT_FILES_FILE"

# ====== Step 4: prs.json 組み立て ======
PRS_FILE="${OUTPUT_DIR}/prs.json"

jq -n \
  --arg owner "$OWNER" --arg repo "$REPO" \
  --arg since "$SINCE" --arg until "$UNTIL" \
  --arg collected_at "$COLLECTED_AT" \
  --argjson pr_count "$PR_COUNT" \
  --argjson max_prs_exceeded "$MAX_PRS_EXCEEDED" \
  --slurpfile pr_list "${OUTPUT_DIR}/_pr_list.json" \
  --slurpfile threads_lines <(jq -s '.' "$THREADS_FILE") \
  --slurpfile commits_lines <(jq -s '.' "$COMMITS_FILE") \
  --slurpfile commit_files "$COMMIT_FILES_FILE" \
  '
    ($threads_lines[0] | map({(.pr_number | tostring): .threads}) | add // {}) as $threads_map |
    ($commits_lines[0] | map({(.pr_number | tostring): .commits}) | add // {}) as $commits_map |
    $commit_files[0] as $cf_map |
    {
      meta: {
        owner: $owner, repo: $repo,
        since: $since, until: $until,
        collected_at: $collected_at,
        pr_count: $pr_count,
        max_prs_exceeded: $max_prs_exceeded
      },
      prs: ($pr_list[0] | map(
        . as $pr |
        ($pr.number | tostring) as $key |
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
          commits: (($commits_map[$key] // []) | map(. + {files: ($cf_map[.sha] // [])})),
          review_threads: (($threads_map[$key] // []) | map({
            thread_id: .id,
            is_resolved: .isResolved,
            is_outdated: .isOutdated,
            comments: (.comments.nodes | map({
              id: .id,
              author_login: (.author.login // "ghost"),
              body: .body,
              created_at: .createdAt,
              path: .path,
              line: .line,
              original_line: .originalLine,
              diff_hunk: .diffHunk,
              url: .url,
              reactions: (.reactions.nodes | map({content: .content})),
              is_ai_authored: (.body | test("^> \\*\\*\\[AI 自動投稿\\]\\*\\*"))
            }))
          }))
        }
      ))
    }
  ' > "$PRS_FILE"

# ====== Step 5: 信号付与 → signals.json ======
SIGNALS_FILE="${OUTPUT_DIR}/signals.json"

jq '
  def positive_reactions: ["THUMBS_UP", "HEART", "HOORAY", "ROCKET"];
  def negative_reactions: ["THUMBS_DOWN", "CONFUSED"];
  def affirmative_keywords: ["fixed", "対応", "修正", "反映", "確かに", "その通り", "done", "addressed"];

  .prs |= map(
    . as $pr |
    # PR 内の path -> 同一 PR で同 path への指摘が複数あるかの map
    ([$pr.review_threads[].comments[].path]
      | group_by(.) | map({key: .[0], value: (length > 1)}) | from_entries) as $path_multi |

    .review_threads |= map(
      . as $thread |
      .comments |= map(
        . as $cm |
        ([$thread.comments[]
          | select(.created_at > $cm.created_at
                   and .author_login == $pr.author
                   and ((. as $x | affirmative_keywords | any(. as $kw | $x.body | contains($kw))))
                  )
         ] | length > 0) as $author_replied |
        ([$pr.commits[]
          | select(.committed_at > $cm.created_at)
          | .files[]?
         ] | any(. == $cm.path)) as $file_changed |
        (($cm.body | match("\\[(must|should|nit|question|pre_existing)\\]"; "")
          | .captures[0].string) // null) as $sev |
        ([$cm.reactions[].content] | map(select(. as $r | positive_reactions | any(. == $r))) | length) as $pos_re |
        ([$cm.reactions[].content] | map(select(. as $r | negative_reactions | any(. == $r))) | length) as $neg_re |
        . + {signals: {
          thread_resolved: $thread.is_resolved,
          thread_outdated: $thread.is_outdated,
          file_changed_after_comment: $file_changed,
          author_replied_affirmative: $author_replied,
          severity_label: $sev,
          is_ai_authored: $cm.is_ai_authored,
          reply_count: (($thread.comments | length) - 1),
          reactions_positive: $pos_re,
          reactions_negative: $neg_re,
          comment_length: ($cm.body | length),
          same_file_in_pr: ($path_multi[$cm.path] // false)
        }}
      )
    )
  )
' "$PRS_FILE" > "$SIGNALS_FILE"

log "Done: ${SIGNALS_FILE}"
echo "${SIGNALS_FILE}"
