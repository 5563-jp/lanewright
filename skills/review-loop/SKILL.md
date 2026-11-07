---
name: review-loop
description: >-
  実装コミットの後や指摘修正の後に、実装レーンとレビューレーンの周回を回すときに使う。
  round ごとの full / delta 切り替え、重大度（P0〜P3）ごとの再レビュー規則、
  round 3 以降の P2 / P3 後回し、検証とビルドの分担を定める。
---

# 実装・レビュー周回（review-loop）

実装 commit（変更の記録）の直後、および指摘修正 commit の直後に PR（変更を統合するためのレビュー依頼）やマージへ進む前に実行する。レーン全体の基本運用は [lanes](../lanes/SKILL.md) と `<kit>/lanes/README.md` に従う。

## 役割と起動

- **実装・修正（`<kit>/lanes/run-impl.sh`）**:
  - `LANES_TOOLS`（設定ファイル `${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf` の道具指定）に Gemini が含まれる構成では、Claude と Gemini（専用の worktree（Git で同じリポジトリから別ブランチを別フォルダに展開する仕組み）のみ）に振り分ける（Claude が主、仕様が固まった軽い作業を Gemini。迷ったら Claude）。モデルと effort（AI の思考の深さ設定）は設定ファイルと `<kit>/lanes/lanes.env` で管理する。
  - **Claude 固定（`--engine claude`）**: 決済・課金、認証・RLS（データベースの行単位のアクセス制限）、DB（データベース）・migration（構造の変更手順）、秘密値、公開判定、`.github/`、端末作業中心、重い設計判断、レビューで P0/P1（重大・高優先度の不具合）が出た修正、Gemini で 2 回続けて `NEEDS_FIX`（要修正）になった票。
  - **Gemini 優先（`--engine gemini --verify "<検証>" --allow-path <相対パス>`）**: 仕様が確定していて設計判断が要らない、目安 6 ファイル・400 行程度までの作業。開発サーバー・スクリーンショット・ブラウザ・ネイティブビルドが要る票は送らない。commit と push（リモートへの送信）はランチャ（レーンを起動・管理するスクリプト）が行う。
- **レビュー（`<kit>/lanes/run-review.sh`）**:
  - `LANES_TOOLS` に Codex が含まれる構成（`full` / `claude-codex`）では Codex レビュー（`run-codex-review.sh`）、含まれない構成（`claude-gemini` / `claude-only`）では Claude レビュー（`run-claude-review.sh`・別セッション・読み取り専用）が走る。Gemini はレビューに使わない。
  - label は全構成で `rev-<票>-r<N>` の形で round 番号を入れる。比較の起点は統合先ブランチ（`LANES_BASE_BRANCH`、既定 `develop`）か `--base`。
  - **どの構成でも（Codex レビュー・Claude レビューとも）**: 既定は `--mode auto`。round 1 は `full`（全体差分レビュー）、前回 `CLEAN`（合格）の後は前回レビューした HEAD（現在のブランチ先端のコミット）からの `delta`（増分レビュー）、同一 HEAD は省略（`skip-same-head`）を自動で選ぶ。前回 `NEEDS_FIX` なら `full` に戻して未解決指摘を引き継ぐ。`--round N`・`--force` も使える。仕組みは `<kit>/lanes/review-dedup.zsh` の 1 つ。
  - **必須検証の使い回し**: 最終 HEAD で `<kit>/lanes/chk-run.sh` を通した後にレビューを回すと、ランチャが記録を問い合わせ（`chk-run.sh <worktree> --query`）、同じ中身で通っていればレビュアーに typecheck / lint / unit を回させない（`LANES_REVIEW_REUSE_CHECKS`。既定 1）。`chk-run.sh` とレビューは同じシェルから呼び、間に作業ツリーを変えない。確かめたことになるのは確認コマンドに入れた項目だけ。
- **共通ルール**:
  - 全レーンで MCP（AI ツールから外部サービスへ接続する仕組み）は使わない（ランチャが遮断する。プロンプトでも呼ばせない）。
  - 起動は `<kit>/lanes/detach-run.sh` 経由で行う（短いシェル＋`nohup` は使わない）。
  - 起動後 60 秒以内に `<kit>/lanes/lanes-status.sh <worktree> <label> --tail 20` を確認する。確認前に「起動した」と報告しない（`RUNNING` / `DONE` のときだけ「起動確認 OK」）。以後は `<kit>/lanes/lanes-watch.sh`（5 分ウォッチ）と `<kit>/lanes/lanes-watch.sh --check`（15 分チェック）で監視する。
  - 停止は `kill <ランチャPID>`（PID：プロセス識別番号）で行う。`FAILED` / `DEAD` で子プロセスが生存しているときだけ子を停止し、`RUNNING` / `STALLED`（停滞中）の子は直接 kill しない。

## VERDICT（合否判定）の規則

- 明示判定は独立行の `VERDICT: CLEAN` / `VERDICT: NEEDS_FIX` のときだけ採用される（コードフェンス・引用・表・番号付き・見出しの中は無効）。
- 出力の未完了・途切れ・「実施できませんでした」等の未実施文言は、指摘数より優先して `VERDICT: NONE`（`EXIT:3`、失敗）になる。
- P0/P1/P2（P2 は中程度の指摘）が 1 件でもあれば、明示 `CLEAN` 行があっても `NEEDS_FIX` が優先される。Claude レビューも Codex レビューも同じ共通の判定を使う。例外は round 3 以降だけで、P2/P3 を後回し票に保存して `CLEAN` で通す（下の「round 3 以降」。Codex・Claude のレビューとも）。
- レビュアーが作業ツリーを書き換えた場合は `VERDICT: NEEDS_FIX`（`EXIT:4`）になる。

## 重大度（Severity）ごとのルール

1. **P0 / P1（重大 / 高）**:
   - Claude で修正し（Gemini には回さない）、**必ず**再レビューを回す。
   - P0/P1 が 0 件になるまで繰り返し、残っている間は PR やマージへ進まない。
   - 修正プロンプトには「指摘箇所だけでなく、同じ種類の問題を差分全体から探して横展開でまとめて直す」を必ず入れる。
2. **P2 / P3（中 / 軽微）**:
   - **round 1・2**: 指摘を横展開してまとめて修正し（Claude、または基準を満たせば Gemini の修正レーン `<label>-fix1`）、レビューを 1 回回す。前回が `NEEDS_FIX` のためランチャが自動で `full` に戻し、前回の未解決指摘を引き継ぐ（全件解消を示す独立行 `RESOLVED_PREVIOUS_FINDINGS: YES` が出るまで `CLEAN` にならない。Codex・Claude のレビューとも）。
   - **round 3 以降（どの構成でも）**: P2/P3 では止めない。ランチャが全指摘を `logs/<series>.followups.md` に保存した上で `VERDICT: CLEAN`（証跡に `GATE: MERGE_WITH_FOLLOWUP`）にする。残件は課題管理ツールの後回し票として起票し、PR・マージへ進む。round 3 以降でも P0/P1 が残る場合（`STOP_P0P1`）だけ止めて報告する。
3. **周回の上限（どの構成でも）**: round が `LANES_REVIEW_MAX_ROUNDS`（既定 5）を超えて `CLEAN` にならなければ `GATE: ESCALATE`。修正レーンを起動せず、指摘の一覧を付けて人に「直して続けるか・締めるか」を聞く。締めるなら残りを `.lanes/accepted-limitations.md`（受け入れ済みの限界。次のレビューの指示書に必ず入り、当てはまる指摘は P0〜P2 にならない）か後回し票へ。周回の途中で新しい機能を足さない。
4. **仕様確認（S-*）**:
   - コードの欠陥ではないため、要件定義や仕様の判断へ回す。

## 同じ確認を繰り返さない（full / delta とビルドの分担）

- **どの構成でも（Codex・Claude のレビューとも）**: `--mode full` を毎回指定しない（`--mode auto` が既定）。round 番号は label 末尾 `-r<N>` で必ず渡す（`--round N` でもよい。渡し忘れると round 3 以降のゲートが効かない）。`full` は初回・P0/P1 修正後・前回 `NEEDS_FIX` 後だけ。前回 `CLEAN` の後は前回 HEAD からの `delta` になる。同一 HEAD は再レビューしない（`skip-same-head`。必要なときだけ `--force` を付け、理由を 1 行残す）。
- **親の確認の使い回し**: 親が同じ中身で `chk-run.sh` を通していれば、レビュアーは typecheck / lint / unit を回さない（ランチャが判断する。証跡に `必須検証: 親の chk-run の記録を使用` が出る）。記録が無ければ今までどおりレビューの中で回す。
- **ビルドと検証の分担**:
  - build（配布・実行用ファイルの生成）は、レビュー・修正レーン・マージ後 QA（品質確認）では回さない。レビューで省略してよいのは build だけ。
  - `LANES_BASE_BRANCH` へ入れる直前の最終 HEAD で `<kit>/lanes/chk-run.sh` を 1 回（同一 git tree（ファイル構成と中身の識別子）・同一 `input_fp`（環境や依存の指紋データ）なら自動省略、差分があれば部分省略せず全検証）と CI（自動テスト・ビルド）で担保する。
  - レビューでの検証は、full では typecheck（型の整合性確認）・lint（コード規約の確認）・unit（単体テスト）全件と、プロジェクトにあれば E2E（画面から裏側まで通して動かす全体テスト。`CI=1` で自前のサーバーを立てて完走）。delta では typecheck・lint 全体と差分に関係する unit、差分が画面・API に触れたときだけ該当の E2E（認証・決済・DB・CI 設定・環境変数に触れた差分は full と同じ全件へ格上げ）。E2E を完走できなかったときは事実の理由と未実施の範囲を書く（レビュー用テンプレート `<kit>/lanes/templates/claude-review-{full,delta}.md` と同じ）。
  - レビューの表は「build: 未実施（最終検証で担保）」が正当であり、成功行は `CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP` とする（親の chk-run の記録を使い回すレビューでは成功行は要らない）。typecheck・lint・unit の未実施や build の失敗は `CLEAN` 不可。変更がドキュメントやテストだけなら、修正レーンの検証は typecheck・lint・関係するテストだけでよい。
  - リリース用の枝も中身（git tree）が確認済みの `LANES_BASE_BRANCH` と同じなら確認をやり直さない。本番反映後の確認は HTTP 200（正常応答）と主要 1 画面だけでよい。

## 周回の流れ（Loop）

1. `<kit>/lanes/run-review.sh`（label `rev-<票>-r1`）→ `CLEAN` または `NEEDS_FIX`（＋重大度）
2. **P0 / P1 あり** → Claude で横展開修正 → commit → `rev-<票>-r2` で再レビュー（Gemini には回さない）
3. **P2 / P3 のみ** → round 1・2 なら Claude 修正（または基準を満たせば Gemini 修正）→ 再レビュー 1 回（自動で `full` ＋未解決指摘の引き継ぎ）→ PR へ。round 3 以降の P2/P3 は直さず `followups.md` から後回し票を起票して PR へ進む（Codex・Claude のレビューとも）
4. **`CLEAN`** → 最終 HEAD で `<kit>/lanes/chk-run.sh` を 1 回 → push → PR 作成（`logs/<label>.evidence.md` を貼付、タイトルは `[ISSUE-123] ...`）→ CI 確認・マージ（必須チェックがあれば `gh pr merge <PR> --auto --merge --delete-branch`、無ければ `gh pr checks --watch --fail-fast` 後にマージ）。`main` へのリリース PR はユーザーの GO（実行許可）を待つ

## マージ後の次工程

- `LANES_BASE_BRANCH` へのマージが完了したら、[post-merge-qa](../post-merge-qa/SKILL.md)（`<kit>/lanes/after-develop-merge.sh <worktree> --apply`）へ進む。
