# 機械可読行の契約 (`AI-REVIEW-RESULT` / `AI-REVIEW-EXTERNAL` / `AI-REVIEW-ESCALATE`)

`post-pr-review` が Review の `body` に埋め込む機械可読行の **公開契約 (CI がパースする契約)** の正典。投稿の手順は `../SKILL.md`、実装は `../scripts/build-review-payload.sh`。投稿するだけなら本書を読む必要はない (スクリプトが規則どおりに組み立てる)。契約を変える / CI 側のパーサを書く / 出力の理由を調べるときに読む。

## 概要

本 skill は投稿する Review の `body` に **ラベル別指摘件数の機械可読サマリ行を必ず 1 行埋め込む**。CI (GitHub Actions の required status check 等) が「AI レビュー済みか / ブロッキング指摘が残っているか」を機械判定するための **公開契約 (CI がパースする契約)** として扱い、後方互換に注意して変更する (キー追加は可、既存キーの削除 / 意味変更 / 順序変更は契約変更扱い)。**この但し書きは本書が規定する 3 行すべて (`AI-REVIEW-RESULT` / `AI-REVIEW-EXTERNAL` / `AI-REVIEW-ESCALATE`) に適用される**。

**本書の規則は `../scripts/build-review-payload.sh` が機械的に実行する** (`../SKILL.md` 手順 1)。モデルが件数を数えたり行を手で組み立てたりしない — 1 回の数え間違いで must 指摘のある PR が required check を通ってしまうため。本書は契約の正典で、スクリプトはその実装 (規則を変えるときは本書・スクリプト・`../scripts/test-build-review-payload.sh` を同時に更新する)。

## フォーマット

```
<!-- AI-REVIEW-RESULT: must=0 should=1 nit=2 question=0 pre_existing=0 other=0 -->
```

- **HTML コメント**なので GitHub 上の人間向け表示 (PR の Conversation タブ) には現れず、レビュー本文の可読性を汚さない。一方 REST API (`GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`) が返す各 review の `body` にはそのまま残るため、CI から正規表現でパースできる。
- キーは **上記 6 つを固定順で必ず全て出力する**。件数 0 のキーも省略しない (「レビュー実施済みで指摘ゼロ」を CI が判別できることが本サマリ行の必須要件)。
- 値は 0 以上の整数。区切りは半角スペース 1 個。**1 つの Review body にサマリ行は 1 行だけ**。
- 挿入位置は **AI 自動投稿マーカーの直後 (区切り線 `---` より前)** に固定する (下記「body の組み立て」参照)。caller 由来の総括本文の中には入れない (本文中の任意位置に散らすと 1 行契約が崩れる)。
- **指摘 0 件 (`comments: []`) でも必ず出力する**。この場合は全キーが `0` の行になる。

## 外部レビュー行 (`AI-REVIEW-EXTERNAL`)

caller から `external_review` (prompt 経由では `EXTERNAL_REVIEW`。1 行の JSON) が渡された場合のみ、`AI-REVIEW-RESULT` の **直後の行** (空行を挟まない) に 1 行出力する。渡されなければ行ごと省略する (本 skill が値を捏造しない)。

```
<!-- AI-REVIEW-EXTERNAL: skill=scan-diff-findings mode=agent verify_degraded=false finders=5/5 findings=9 omitted=0 -->
```

- 目的: レビュー生成側 (`compose-review`) が **外部レビュースキルを併用できたか / 縮退したか** を、Review body の日本語本文を読まずに CI から判定できるようにする。
- キーと値 (この順): `skill` (未併用は `none`) / `mode` (`agent` / `partial` / `inline` / `empty` / `external` / `null`) / `verify_degraded` (`true` / `false` / `null`) / `finders` (`<finders>/<finders_expected>`。どちらかが `null` なら `finders=n/a`) / `findings` (整数) / `omitted` (整数。外部スキル側で件数上限により落とされた指摘数)。値の半角スペース等の空白は `_` に置換する。`external_review` に無いキーは出力しない。`reason` は本行には出力しない (人間向けの理由は総括本文の開示文が担う)。
- **異常系**: JSON として parse できない / 必須キー (`skill` / `mode`) を欠く / `mode` が enum 外 / 値が上記の型に合わない (`finders` / `finders_expected` / `findings` / `omitted` が非負整数でない、`verify_degraded` が boolean / null でない、`skill` が HTML コメント終端 `-->` を含む) の場合は **行ごと省略し、その旨を caller への報告に 1 行残す** (投稿自体は継続する)。壊れた値をそのまま埋め込まない。
- CI 側は係留キー `AI-REVIEW-EXTERNAL` を前置してパースする (例: `AI-REVIEW-EXTERNAL:.*?skill=(\S+).*?mode=(\S+)`)。`skill=none` / `mode=inline|partial|empty` / `verify_degraded=true` はいずれも「レビュー体制が縮退している」シグナル。
- **1 つの Review body にこの行も 1 行だけ**。caller 由来の総括本文には入れない。

## エスカレーション行 (`AI-REVIEW-ESCALATE`)

caller から `escalation` (prompt 経由では `ESCALATION`。1 行の JSON。`reasons` は自由文なので **値に改行を含めない**) が渡された場合のみ、`AI-REVIEW-EXTERNAL` の **直後の行** (空行を挟まない。`AI-REVIEW-EXTERNAL` を出力しない場合は `AI-REVIEW-RESULT` の直後) に 1 行出力する。渡されなければ行ごと省略する。

```
<!-- AI-REVIEW-ESCALATE: escalate=1 reasons=2 -->
```

- 目的: レビュー生成側が「この PR は人 (第三者) の確認が要る」と判定したかを CI から判定できるようにする。**CI 側が該当者をレビュアーに追加するためのルーティング信号** であり、**マージをブロックするゲートではない** (`escalate=1` でも `event` は `COMMENT` のまま、レビュアーの追加も行わない。それは caller / CI の責務)。
- キーと値: `escalate` (`escalation.escalate` が `true` なら `1`、`false` なら `0`) / `reasons` (`escalation.reasons` の **件数**。無い / 空配列なら `0`)。**理由の本文はこの行に載せない** (HTML コメントに自由文を入れると 1 行契約が壊れるため。人間向けの理由は総括本文の `## エスカレーション` セクションが担う)。`escalate=1` かつ `reasons=0` も有効な行。
- **異常系**: JSON として parse できない / `escalate` を欠く / `escalate` が boolean でない 場合は **行ごと省略し、その旨を caller への報告に 1 行残す** (投稿自体は継続する)。`reasons` が配列でない場合は `reasons=0` として行を出す。
- CI 側は係留キー `AI-REVIEW-ESCALATE` を前置してパースする (例: `AI-REVIEW-ESCALATE:.*?escalate=([01])`)。**行の有無だけで「判定が行われたか」を判断しない** — `run-pr-review` 経路では `escalate: true` の回だけ `ESCALATION` が転送される (詳細は `run-pr-review` Step 4) ので、行が無い状態は「エスカレーション不要」と「判定なし」の両方を含む。CI が分岐すべきは `escalate=1` の存在のみ。`escalate=0` の行を出したい caller は `escalate: false` を明示的に渡せばよい。
- **パース範囲を body 冒頭のサマリ行ブロックに限定する (本行固有の注意)**: 本行は常在しないため、行が出ていない回に総括本文中のフォーマット例 (本 plugin のドキュメント自体をレビューする PR など) が唯一のマッチになりうる。CI は本行を **マーカー行から最初の区切り線 `---` までの範囲に限って** 探し、その外側のマッチは無視すること。
- **1 つの Review body にこの行も 1 行だけ**。caller 由来の総括本文には入れない。

## 集計ルール

1. `LABEL_COUNTS` (`label_counts`) が渡されていれば **それを正典として採用する** (`MAX_INLINE_COMMENTS` の省略分を含む正確な件数を持つのは caller だけなので、再計算・上書きしない)。
   - キーは小文字化してから標準 5 ラベル (`must` / `should` / `nit` / `question` / `pre_existing`) と突合し (`MUST` も `must`。下記 2 と揃える)、それ以外のキーは `other` に合算する。渡されなかった標準ラベルは `0`。
   - JSON として parse できない / object でない / 値が非負整数でない場合は無視して下記 2 にフォールバックし、その旨を caller への報告に 1 行残す。
   - **下限チェック**: 合計が `comments[]` の件数を **下回る** 場合は caller 側の組み立て不整合 (例: `[must]` 3 件なのに `{}`) とみなし、下記 2 にフォールバックして報告に 1 行残す (省略は件数を増やす方向にしか働かないため、合計 ≧ `comments[]` 件数が不変条件)。合計が件数以上なら正典採用のまま。
2. それ以外は **`comments[]` の各 `body` の先頭**に `^\[([A-Za-z_]+)\]` をマッチさせ、**捕捉したラベルを小文字化してから**標準 5 ラベルと突合して加算する (`[MUST]` も `must`。本文中の `[must]` は数えない)。**未知ラベル (`[blocker]` 等) / ラベル無しは `other` に加算する** (落とすと合計が `comments[]` 件数と合わず「集計漏れ」と「指摘なし」を区別できなくなるため)。独自ラベル運用の caller は下記「制約」に従い `LABEL_COUNTS` でマッピングする。

## CI 側の使い方 (参考)

- **パース例** (`must` / `should` だけ見る最小形。**係留キー `AI-REVIEW-RESULT` を必ず前置する**):

  ```
  AI-REVIEW-RESULT:.*?must=(\d+)\s+should=(\d+)
  ```

  係留キーを省いた `must=(\d+) should=(\d+)` だけでは、body 中のどこかにあるプレーンな `must=0 should=0` (本改修より前の版で投稿された review や、この plugin の仕様を議論した人間のレビュー本文など) にもマッチし、**サマリ行が無い review を「レビュー済み・ブロッキングなし」と誤判定する** (後述の「サマリ行が 1 つも無ければ未実施扱い」と噛み合わなくなる。「最初のマッチを採用する」ルールもサマリ行が実在する前提でのみ安全側に働く)。

  全キーを取る場合 (空白の揺れに耐える形):

  ```
  <!--\s*AI-REVIEW-RESULT:\s*must=(\d+)\s+should=(\d+)\s+nit=(\d+)\s+question=(\d+)\s+pre_existing=(\d+)\s+other=(\d+)\s*-->
  ```

- **合格条件の例**: 「PR の現在の head SHA に対して AI レビューが投稿済み、かつ `must` / `should` が 0 件」→ サマリ行を含む review が head SHA に対して存在し、その `must=0` かつ `should=0`。
- **head SHA に対するレビューかの判定** は review の `commit_id` を PR の head SHA と比較する (本 skill は `COMMIT_ID` が渡された場合のみ `commit_id` を送るため、機械判定を前提にするなら caller は常に `COMMIT_ID` を渡す。`run-pr-review` は `COMMIT_ID` を常時転送するので、その経路なら常に付く。値の決め方は `run-pr-review` Step 2 参照)。`COMMIT_ID` を渡さないと GitHub 側が投稿時点の最新 commit を採用するため、force-push と競合したときに照合が不確実になる。
- 同一 head SHA に対してサマリ行を含む review が複数ある場合 (再レビュー等) は **最新の review** を採用する。
- 1 つの review body 内に同形の文字列が複数現れた場合は **最初のマッチを採用する**。本 skill が prepend する 1 行は常に body の冒頭側 (マーカー直後) にあり、caller 由来の総括本文はその後ろに連結されるため、最初のマッチが必ず本 skill の出力になる (本 plugin のドキュメント自体をレビューして総括にフォーマット例を引用した場合など、caller 本文側に同形の文字列が混ざるケースの取り違え防止)。
- サマリ行を含む review が 1 つも無い状態は「本 skill によるレビューが未投稿」(または本改修より前の版で投稿された review しかない) を意味する。CI は合格扱いにせず未実施 (不合格 / pending) として扱う。

## 制約 (既知の非厳密性)

- **`MAX_INLINE_COMMENTS` 省略分**: `comments[]` 集計 (上記ルール 2) では、上限超過で `comments[]` から落ちた指摘は数えられない。ただし省略は優先度順 (`[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`) に低い方から行われる契約なので、**`must` が 1 件以上あるのに `must=0` になることはない** (上限 N ≧ 1 なら must が存在すれば最低 1 件は残る)。`should` が存在するのに `should=0` になるのは must だけで上限に達したケースのみで、そのときは `must>0` なので「must=0 かつ should=0」判定は安全側に倒れる。一方で **個々の件数は実際より小さくなりうる**ため、正確な件数が必要な caller は `LABEL_COUNTS` を渡す (`compose-review` → `run-pr-review` 経路は省略分込みの `label_counts` を引き回すため常に正確)。
- **caller 独自ラベル**: caller が標準 5 ラベルを廃止し独自ラベル (`[blocker]` 等) を使う場合、`comments[]` 集計では全件が `other` に入り `must=0 should=0` になる。CI が must/should だけを見ていると誤って合格するため、独自ラベル運用の caller は **`LABEL_COUNTS` で標準 5 ラベルへマッピングして渡す** (例: `[blocker]` → `must`)。それができない場合は CI 側の合格条件に `other=0` も加える。

## body の組み立て

マーカー文言 (エージェント非依存・固定) と組み立て後の `body` の形:

```markdown
> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。

<!-- AI-REVIEW-RESULT: must=0 should=1 nit=2 question=0 pre_existing=0 other=0 -->
<!-- AI-REVIEW-EXTERNAL: skill=scan-diff-findings mode=agent verify_degraded=false finders=5/5 findings=9 omitted=0 -->
<!-- AI-REVIEW-ESCALATE: escalate=1 reasons=2 -->

---

<caller から渡された総括本文 (指摘なし時は「特に指摘なし」相当)>
```

マーカー行の後の空行は、blockquote の lazy continuation で機械可読行が取り込まれるのを防ぐためのもの。
