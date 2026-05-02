---
name: resolve-pr-threads
description: PR の過去レビュースレッドのうち、指摘どおりに修正済みのものだけを resolve する。再レビュー後に古いスレッドを畳むのに使う。`mode` 引数 (all / own / none) で resolve 範囲を制御する。判定に迷う場合は resolve しない。
---

# resolve-pr-threads skill

過去のレビュースレッドのうち修正済みのものを resolve する skill。
**誤判定で未対応の指摘を畳むと見落としに直結するため、判定に迷う場合は常に「resolve しない」を選ぶこと。**

## 入力

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR
- `MODE`: resolve 範囲
  - `all` (デフォルト): すべての未 resolve スレッドを対象に、author 種別 (本レビュアー Bot / 他 Bot レビュアー / 人間レビュアー) を問わず resolve 候補にする。
  - `own`: 本アクション自身 (claude-code-action が用いる Bot) が author のスレッドのみ resolve 候補にする。判定は自身の過去コメントの `author.login` と一致するか否かで行う。判定が困難な場合は resolve しない。
  - `none`: 過去スレッドの resolve は一切行わない。本 skill 全体を skip する。
- `SELF_LOGIN` (任意): `MODE=own` 時に「自身」を判定するための `author.login`。caller が判明していれば渡す。不明なら最近の自身レビューコメントから推定する。

## 共通の resolve 判定ルール

- 既に `isResolved: true` のスレッドは触らない。
- resolve するのは **指摘内容どおりの修正が現在の差分・ファイル内容から確認できる場合のみ**。
- 以下のいずれかに該当する場合は resolve しない:
  - 指摘箇所が削除されただけで、別の場所に同じ問題が残っている可能性がある。
  - `isOutdated: true` だが、修正されたか単に行がずれただけかが判別できない。
  - 指摘が複数論点を含み、一部しか対応されていない。
  - そもそも修正されたかどうか判断に迷う。

## 手順

### Step 0. MODE のチェック

`MODE=none` の場合は何もせず終了する。

### Step 1. レビュースレッド一覧を取得する

GraphQL でスレッド一覧を取得する。`isResolved` / `isOutdated` / 各コメントの `author.login` / `path` / `line` / `body` を見て、未 resolve スレッドすべてを判定対象とする。

`reviewThreads(first: 100)` は GitHub GraphQL API の 1 ページあたりの上限値。100 件を超える可能性がある場合はページネーションすること (取得漏れに気付かないと resolve すべきスレッドの取りこぼしにつながる)。

```bash
gh api graphql \
  -F owner=<OWNER> \
  -F name=<REPO> \
  -F number=<PR_NUMBER> \
  -f query='
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              comments(first: 50) {
                nodes {
                  author { login }
                  path
                  line
                  originalLine
                  body
                }
              }
            }
          }
        }
      }
    }'
```

初回呼び出し時は `$after` を省略 (または `null`) する。`pageInfo.hasNextPage` が `true` の場合は `-F after=<endCursor>` を付けて同じクエリを再実行し、全スレッドを取得しきるまで繰り返す。

### Step 2. resolve 対象を決める

各スレッドについて以下を判定する。

1. `isResolved: true` ならスキップ。
2. `MODE=own` の場合、スレッド先頭コメントの `author.login` が `SELF_LOGIN` と一致しないならスキップ。
3. 上記「共通の resolve 判定ルール」に従って、指摘どおりに修正されたものだけを resolve 候補にする。コメントの `path` / `line` 周辺の現在のファイル内容と差分を必ず確認する。

### Step 3. `resolveReviewThread` mutation を実行する

resolve 対象のスレッドごとに以下を実行する。`<THREAD_ID>` は Step 1 で得たスレッドの `id`。

```bash
gh api graphql \
  -F threadId=<THREAD_ID> \
  -f query='
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) {
        thread { id isResolved }
      }
    }'
```

### Step 4. caller への報告

resolve したスレッドの件数と概要を caller に返す (caller がレビュー本文の総括に「既存指摘のうち N 件は対応済みのためスレッドを resolve しました」と1〜2文で記載できるように)。
