---
name: post-merge-qa
description: >-
  作業枝を統合先ブランチ（develop 等）へマージした直後に、マージ後の後片付けと
  bot QA（スクリプト QA・Preview 画面 QA）を実行するときに使う。CLEAN 時の人間の QA 待ちへの引き継ぎ、
  NEEDS_FIX 時の修正・レビュー・再 QA、課題管理ツールのステータス扱いを定める。
---

# マージ後 QA レーン（post-merge-qa）

作業枝の PR（変更を統合するためのレビュー依頼）が統合先ブランチ（`LANES_BASE_BRANCH`、既定 `develop`）へマージされた直後の次工程として実行する。マージ前のコードレビュー（[review-loop](../review-loop/SKILL.md)）とは別の工程であり、観点の雑談だけでは起動しない。

## 本線（2 段の bot QA）

### 1) スクリプト bot QA（`<kit>/lanes/after-develop-merge.sh`）

```zsh
zsh <kit>/lanes/after-develop-merge.sh <feature-worktree> --apply
```

- **実行場所の注意**: 必ず本体 checkout（リポジトリの主作業フォルダ）か `$HOME` に `cd` してから呼ぶ（`<feature-worktree>`（Git で別フォルダに展開した作業ツリー）に `cd` したまま実行すると、後片付けでカレントディレクトリごと消えて以降のコマンドが `ENOENT`（ファイル・フォルダ不在エラー）になる）。
- **削除済み worktree の場合**: `gh pr merge --delete-branch` 等で `<feature-worktree>` が既に消えている場合は、`--main-checkout <path> --feature-head <40桁SHA>`（SHA：コミットを一意に識別する番号）を渡して起動する。
- **内部の動き**:
  1. 取り込み履歴（merge SHA：マージ結果を一意に識別する番号）と対応 PR を固定し、前回終了済みの QA worktree があれば先に cleanup（後片付け）へ流す。
  2. 専用 worktree（`$LANES_SCRATCH_ROOT/<repo>/<label>-checkout`）を作成し、本体 checkout の `.env*` を複製・照合して依存パッケージをロックファイルから入れ直す（`--no-deps` で省略可。準備に失敗した場合は `<feature-worktree>` を残して `EXIT:1` で止まる）。
  3. `<feature-worktree>` を cleanup し、`<kit>/lanes/run-qa.sh`（読み取り専用・MCP（AI ツールから外部サービスへ接続する仕組み）遮断）を起動する。
- **起動確認**: 起動後 60 秒以内に `<kit>/lanes/lanes-status.sh <QA-worktree> <label> --tail 20` を確認する（監視先は `after-develop-merge.sh` が出力した QA worktree と label）。`RUNNING` または `DONE` のときだけ「起動確認 OK」と報告する。
- **検証内容とビルドの省略**: QA（品質確認・動作検証）観点の洗い出し（BOT 実施分 / HUMAN 確認分）を行い、BOT が実施できる確認と typecheck（型の整合性確認）・lint（コード規約の確認）・unit（単体テスト）を実行する。**マージ後の bot QA では build（配布・実行用ファイルの生成）を回さない**（マージ前の最終 HEAD（ブランチ先端のコミット）での `<kit>/lanes/chk-run.sh` と CI（自動テスト・ビルド）で担保済み）。
- **手動での再実行**: `<kit>/lanes/run-qa.sh <QA-worktree> <case-prompt.md> <label>`
- `--skip-qa`（QA を飛ばして後片付けのみ実行）は原則禁止とし、ユーザーの明示的な指示があるときだけ使う。

### 2) 画面 QA（Preview 環境での画面確認）

第 1 段のスクリプト bot QA（`run-qa.sh`）が `VERDICT: CLEAN`（合格。VERDICT は合否判定）になった後に続けて実施する（`NEEDS_FIX`（要修正）なら先にコード修正へ戻る）。実装・レビュー用の CLI（コマンドラインで動くツール）レーン（Claude / Codex / Gemini）には代行させず、司令塔（`LANES_COMMANDER`）が実施する。

```zsh
zsh <kit>/lanes/prepare-screen-qa.sh <main-checkout> screen-qa-<label> [--url <preview-url>]
```

- 設定ファイル（`${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf`）の `LANES_SCREEN_QA_MAP`（`origin に含まれる文字列|Preview URL|観点ファイルのパス`）または `--url` から、`<main-checkout>/logs/screen-qa-<label>.prompt.md` を生成する。
- 生成されたプロンプトと観点に従い、Preview（本番公開前の確認用環境）画面上で BOT 観点の動作を確認する。
- **合否判定**:
  - 合格: `SCREEN_VERDICT: CLEAN`
  - 不合格: `SCREEN_VERDICT: NEEDS_FIX`（失敗時は bot QA 完了扱いにせず、下の「NEEDS_FIX のとき」へ進む）

## CLEAN（合格）のときと課題管理ツールの扱い

- スクリプト bot QA（および画面 QA を行う場合はその両方）が `CLEAN` になったら、**人間の QA 待ち**として確認結果と人間側で確認すべき観点（HUMAN 観点）を報告する。
- **課題管理ツール（Issues 等）の状態は、bot が勝手に「完了（Done）」にしない。**
  - 人間 QA 用のステータス（例: `QA` や `Preview`）があるプロジェクトではそこまでに留め、ステータス変更を人間側で行う運用では bot はステータスを触らない。
- 本番（`main` ブランチ）へのリリース PR や本番反映は、人間の確認とユーザーの明示的な GO（実行許可）を待つ。

## NEEDS_FIX（不合格）のとき

スクリプト bot QA または画面 QA のどちらかで `NEEDS_FIX` が出た場合は、以下の順で修正からやり直す。

1. **修正レーンの起動（`<kit>/lanes/run-impl.sh`）**:
   - 原則は Claude（`--engine claude`）で修正する。
   - [lanes](../lanes/SKILL.md) の「Claude と Gemini の振り分け」の基準を満たす軽微な修正に限り、Gemini（`--engine gemini --verify "<検証コマンド>" --allow-path <相対パス>`）を使ってもよい。
2. **レビューの実行（`<kit>/lanes/run-review.sh`）**:
   - 修正コミットに対してレビュー（初回 `full`：全体差分レビュー）を必ず通す（省略しない。詳細は [review-loop](../review-loop/SKILL.md)）。
3. **PR 作成とマージ**:
   - レビュー `CLEAN` 後、最終 HEAD で `<kit>/lanes/chk-run.sh` を 1 回通し、PR を作成して CI 緑を確認した上で `LANES_BASE_BRANCH` へマージする。
4. **bot QA の再実行**:
   - マージ後、再び 1) `after-develop-merge.sh --apply` → 2) 画面 QA の順に通す。

## QA worktree の後片付け

- 終了した QA worktree は、次回の `after-develop-merge.sh --apply`（QA あり）の開始時に自動で `<kit>/lanes/cleanup-after-merge.sh --apply` に流れて削除される（ログは退避される）。
- 最後の QA worktree は次のマージまで残るため、結果を確認してから必要に応じて `<kit>/lanes/cleanup-after-merge.sh <QA-worktree> --apply` で手動片付けしてよい。
