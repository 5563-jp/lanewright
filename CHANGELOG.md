# Changelog / 変更履歴

このファイルには、利用者から見える変更を書きます。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿い、版の付け方は [Semantic Versioning](https://semver.org/lang/ja/) に従います（1.0.0 になるまでは、0.x の中でも動きが変わることがあります）。

This file lists user-visible changes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) (behavior may change between 0.x releases before 1.0.0).

## [Unreleased]

## [0.1.0] - 最初の公開 / Initial release

### 追加 / Added
- レーンのランチャ（`lanes/`）: Claude・Codex・Gemini（Antigravity CLI `agy`）の実装とレビューを、1 作業 = 1 worktree = 1 ランチャで並列に回す。
  入口は `run-impl.sh`（実装）と `run-review.sh`（レビュー）。構成（`LANES_TOOLS`）に合わせて振り分ける（4 構成: `full` / `claude-codex` / `claude-gemini` / `claude-only`）。
  Lane launchers for running Claude, Codex, and Gemini implementation and review in parallel (one task = one worktree = one launcher), routed by the tool profile.
- 生死の記録と見張り: `logs/<label>.{pid,done}`、`lanes-status.sh`（RUNNING / STALLED / DONE / FAILED / DEAD）、`lanes-watch.sh`（5 分ごとの見回りと `WAKE:` 通知）。
  Liveness records and monitoring.
- レビューの合否の厳格な判定（最終行の `VERDICT:`。途中で切れた出力や曖昧な文は CLEAN にしない）と、同じ確認を繰り返さない仕組み（`--mode auto` の差分レビュー、round 3 以降の P2/P3 の後回し）。
  Strict review verdicts and de-duplication of repeated reviews.
- 安全策: サブスクでのログインの点検（API キーでの起動を止める）、MCP の遮断、同じ label の排他、レビューと QA の読み取り専用（前後の比較・push の遮断）、
  git の制御ファイルの指紋比較、`logs/` や作業場所の symlink・ハードリンクを辿らない書き込み。
  Safety measures: subscription-login checks, MCP blocking, per-label locking, read-only reviews, git control-file fingerprinting, and writes that never follow symlinks or hard links.
- 同じ確認を繰り返さない仕組み: レビューは親の確認済みの記録（`chk-run.sh --query`）を使い回す（`LANES_REVIEW_REUSE_CHECKS`）。Claude レビューも差分の自動切り替え（`--mode auto`）。
  Reviews reuse the parent's recorded check results, and Claude reviews also switch to delta mode automatically.
- 司令塔の見張り: 定期の確認の間隔（`LANES_CHECK_INTERVAL_MIN`、既定 10 分）、見張りが終わるときの `RE-ARM:` 行、かけ直し忘れを止める Claude Code の Stop フック（`lanes/hooks/claude-stop-watch-guard.sh`）。
  Commander watch: configurable check interval (default 10 minutes), a `RE-ARM:` line when the watcher exits, and a Claude Code Stop hook that prevents finishing a reply without the watcher.
- 適度に締める仕組み: レビューの周回の上限（`LANES_REVIEW_MAX_ROUNDS`、既定 5。超えたら `GATE: ESCALATE` で人に返す）、受け入れ済みの限界（`.lanes/accepted-limitations.md` をレビューの指示書に必ず入れる）、締め切り前の機能の凍結（運用ルール）。
  Wrap-up controls: a review round limit (`GATE: ESCALATE`), accepted limitations fed into every review prompt, and a feature freeze rule before release.
- 起動前の点検（`lanes-doctor.sh`）、導入（`install.sh`。`--dry-run` / `--uninstall`）、自己テスト（`selftest.sh`。偽の CLI で 4 構成を回す）。
  Pre-flight checks, installer, and self-test.
- 汎用のスキル 6 本（`skills/`。開発の流れの `dev-loop` を含む）、運用ルールのひな形（`templates/`）、日本語と英語の手順書。
  Six generic skills (including the `dev-loop` development flow), operating-rule templates, and Japanese/English documentation.
