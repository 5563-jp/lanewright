---
name: lanes
description: >-
  Mac で Claude / Codex / Gemini の CLI をレーン（1 作業 = 1 worktree = 1 ランチャ）として
  並列に起動・監視・レビュー・マージ・後片付けするときに使う。ゴールの分解、実装エンジンの振り分け、
  全レーンでの MCP 遮断、起動確認とウォッチ、VERDICT 判定、レビューの full / delta を定める。
---

# レーン運用（lanes）

正本のスクリプトは `<kit>/lanes/` にある。タスクごとの手書き `run-*.sh` や CI（テストやビルドを自動実行する仕組み）待ち専用のレーンは作らない。

## 設定と役割の割り振り

設定ファイルは `${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf` の 1 つで管理する。主なキーは以下のとおり（固有のモデル名は手順書やプロンプトに書かず、設定ファイルと `<kit>/lanes/lanes.env` で管理する）。
- `LANES_TOOLS`: 使える CLI（コマンドラインで動くツール）を空白区切りで指定（`claude` `codex` `gemini`。`claude` は必須）
- `LANES_COMMANDER`: 司令塔の種別（`grok` などの外部 Bot、または `claude` デスクトップ）
- `LANES_BASE_BRANCH`: 作業枝の統合先ブランチ（既定 `develop`）
- `LANES_RUNS_ROOT` / `LANES_SCRATCH_ROOT`: worktree（Git で同じリポジトリから別ブランチを別フォルダに展開する仕組み）と一時領域の置き場

`<kit>/lanes/lanes-roles.sh` が `LANES_TOOLS` から構成を決め、`<kit>/lanes/run-impl.sh`（実装の入口）と `<kit>/lanes/run-review.sh`（レビューの入口）が対応するランチャ（レーンを起動・管理するスクリプト）へ振り分ける。起動前点検は `<kit>/lanes/lanes-doctor.sh` で行う。

| 構成（`LANES_PROFILE`） | `LANES_TOOLS` | 実装（`run-impl.sh`） | レビュー（`run-review.sh`） |
|---|---|---|---|
| ① `full` | `claude codex gemini` | Claude が主、軽い作業を Gemini | Codex（`run-codex-review.sh`） |
| ② `claude-codex` | `claude codex` | Claude | Codex（`run-codex-review.sh`） |
| ③ `claude-gemini` | `claude gemini` | Claude が主、軽い作業を Gemini | Claude（`run-claude-review.sh`・別セッション・読み取り専用。独立性が弱い） |
| ④ `claude-only` | `claude` | Claude | Claude（同上） |

## 最大並列とゴールの分解

品質を担保しながら、最大限並列にゴールを目指す。1 つ終わったら待たずに次へ着手する。

1. **着手時にゴールを分解する**: リリースまでに要る作業（DB（データベース）・型と契約・画面・決済・定期処理・メール・SEO（検索エンジン最適化）・規約・機能フラグ・手順書・QA（品質確認・動作検証）リスト）を洗い出し、触るファイルや責務が衝突しない単位に細かく切る。
2. **同時起動数の上限なし**: 依存のない作業はすべて同時に起動する。優先度を理由に新しい票を順番待ちにしない。DONE（完了）になったレーンは待たずに即座にレビューを起動する。
3. **effort（AI の思考の深さ設定）は下げない**: 速さは effort ではなく分割と並列で出す。
4. **自己レビューは最大 2 回で打ち切る**: 2 回目の後に残る指摘が P3（軽微）だけなら直して DONE とし、品質は後段のレビューで担保する。
5. **依存の解き方と先行起動**: 共通の型や DB は先に小さく出すか、未マージでもその作業枝の先頭から別 worktree で積み上げて先行起動する（「前の作業がまだ終わっていないから」だけで後回しにしない）。同じ worktree に後続レーンを積む場合、レビューは最後に 1 回だけ `full`（全体差分レビュー）でかける。
6. **コード以外も並走させる**: 環境変数、テスト設定、フラグ設定、手順書、QA シナリオなどは実装レーンの後ろに並べず最初から同時に動かす。
7. **節目ごとに残タスクを総点検する**: DONE・NEEDS_FIX（要修正）・CLEAN（合格）・CI 緑・マージの節目ごとに残タスク表を見直し、今すぐ起動できる作業をその場で起動する。
8. **本番系だけは別 GO**: 未公開機能は機能フラグで隠して `LANES_BASE_BRANCH` へ入れる。`main`・本番デプロイ・本番 DB・本番決済・ストア提出だけはユーザーの明示的な GO（実行許可）を待つ。
9. **クラウドエージェントの補助利用**: 別サーバーで動くクラウドエージェントも、Mac 専用作業（ローカル鍵管理、実ファイル書き出し、worktree 前提作業）以外の修正やテスト・記事追加に並列で使える。秘密値は渡さず、マージ前に必ずレビューと CI を通す。

## Claude と Gemini の振り分け

Gemini が使える構成（`full` / `claude-gemini`）では、実装レーンは Claude を主にし、仕様が固まった軽い作業（目安 6 ファイル・400 行まで）を Gemini に振る。迷ったら Claude（`run-impl.sh` の既定も Claude）。

- **Claude 固定（`--engine claude`）**:
  - 決済・課金、認証・RLS（データベースの行単位のアクセス制限）、本番 DB・DB スキーマ（構造定義）・migration（構造の変更手順）、秘密値、公開判定、`.github/`、端末作業が中心のもの、重い設計判断（新機能や型・契約の設計）
  - レビューで P0/P1（重大・高優先度の不具合）が出た修正、Gemini で 2 回続けて `NEEDS_FIX` になった票
  - 開発サーバー起動、スクリーンショット・画面確認、ブラウザ操作、モバイルシミュレータ、ネイティブビルドが要る作業（Gemini レーンでは禁止されているため送らない）
- **Gemini 優先（`--engine gemini`）**:
  - 仕様が票の中で確定していて設計判断が要らない、目安 6 ファイル・400 行程度までの作業（調査・ドキュメント、新規・既存の静的ページ、文言・メタ修正、単体テスト追加、P2/P3（中程度・軽微な指摘）のフォローアップ、小さな UI（画面の表示や操作）調整、カタログやサイトマップへの定型追加など）
- **Gemini レーンの仕組み**:
  - 専用の worktree でのみ起動でき、`--verify "<検証コマンド>"` と `--allow-path <保存可能な相対パス>`（末尾 `/` は配下全体、複数指定可）が必須。
  - Gemini 本体は端末サンドボックス（操作範囲を制限する安全環境）内で typecheck（型の整合性確認）・lint（コード規約の確認）・関連テストだけを実行し、`$LANES_SCRATCH/COMMIT_MSG.txt` を作成する。全体テストと build（配布・実行用ファイルの生成）、および commit（変更の記録）と push（リモートへの送信）はランチャがサンドボックス外で行う。
  - 終了コード: `0`=commit・検証成功（即レビューへ）／`2`=引数・前提不正／`3`=異常終了・無応答停止（条件が揃えば救済 commit されるが push なし。差分を確認して Claude へ回す）／`4`=許可範囲外の変更・`.git` 変更・監査失敗／`5`=commit メッセージ欠落・失敗／`6`=push 失敗／`7`=`--verify` 失敗（Claude へ回す）／`8`=無出力停止（`$LANES_SCRATCH/wip.patch` を確認して Claude へ回す）。

## 全レーンでの MCP 遮断

本番サービスへ届く経路を塞ぐため、全レーンで MCP（AI ツールから外部サービスへ接続する仕組み）を読み込まない・使わない。
- **Claude**: `--strict-mcp-config` でユーザー設定の MCP を読み込まない。
- **Codex**: 全 MCP サーバーを無効化し、`codex mcp list --json` で有効 0 件を確認する（確認できなければ起動拒否）。
- **Gemini**: `--sandbox` と `--settings`（`permissions.deny: ["mcp(*)"]` 等）および `ANTIGRAVITY_HEADLESS=true` を強制する。

## 起動・60 秒以内の status・ウォッチ

親シェル終了時の巻き込み停止を防ぐため、必ず `<kit>/lanes/detach-run.sh` 経由で起動する（シェルの機能でバックグラウンド維持できる環境を除く）。スクリプトは `zsh` 専用のため `bash` で呼ばない。

```zsh
# 実装（Claude）
zsh <kit>/lanes/detach-run.sh <launch.log> zsh <kit>/lanes/run-impl.sh <worktree> <prompt.md> [label] [--engine claude] [--dry-run]

# 実装（Gemini）
zsh <kit>/lanes/detach-run.sh <launch.log> zsh <kit>/lanes/run-impl.sh <worktree> <prompt.md> [label] --engine gemini --verify "<検証コマンド>" --allow-path <相対パス> [--no-push] [--dry-run]

# レビュー（構成に応じて Codex または Claude）
zsh <kit>/lanes/detach-run.sh <launch.log> zsh <kit>/lanes/run-review.sh <worktree> <prompt.md> rev-<票>-r<N> [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]
#   --round / --force と自動の full・delta 切り替えは、Codex レビュー・Claude レビューのどちらの構成でも使える（下の「VERDICT とレビュー full / delta」）
```

- **起動後 60 秒以内の確認**: `<kit>/lanes/lanes-status.sh <worktree> <label> --tail 20` を実行する。確認前に「起動した」と報告しない。`RUNNING` または `DONE` のときだけ「起動確認 OK: PID（プロセス識別番号） / ログパス」と報告する。
- **5 分ウォッチ（`<kit>/lanes/lanes-watch.sh`）**: 既定 300 秒間隔で稼働レーンと open PR（変更を統合するためのレビュー依頼）を監視し、`$LANES_RUNS_ROOT/.lanes-watch.heartbeat`（heartbeat：生存確認用の定期更新ファイル）を更新する。`LANES_COMMANDER=claude` では `--until-wake` をバックグラウンド実行し、`WAKE:` で起きて次工程をつなぐ。外の Bot は `lanes-watch.sh` を `detach-run.sh` で 1 本だけ常駐させるか、5 分ごとのルーティンで `<kit>/lanes/lanes-monitor.sh`（1 回分の巡回。heartbeat は書かない）を回す。`--until-wake` なしの `lanes-watch.sh` は終わらないので、ルーティンのたびに起動しない（2 本目は exit 2）。
- **10 分チェック（`LANES_CHECK_INTERVAL_MIN`。`<kit>/lanes/lanes-watch.sh --check`）**: heartbeat の生存（`WATCH OK` / `WATCH STALE` / `WATCH DEAD`）と稼働数・直近 N 分の DONE を確認する。STALE / DEAD ならウォッチを再起動し、次工程待ちや未起動の並列作業があれば追加起動する。
- **停止と報告**: 止める場合は `kill <ランチャPID>` を使う（`kill -9` 禁止）。開始時刻不明など同一性が確認できない PID は停止・削除・再起動を保留する。経過報告は毎回「状態 / 経過時間 / 最終出力の時刻 / 次にやること」の 4 点に揃える。

## VERDICT とレビュー full / delta・ビルドの分担

- **VERDICT（合否判定・全構成共通）**: 独立行の `VERDICT: CLEAN` / `VERDICT: NEEDS_FIX` で判定する。出力の未完了・途切れは指摘数より優先して `VERDICT: NONE`（`EXIT:3`）、P0/P1 があれば明示 `CLEAN` より `NEEDS_FIX` を優先する。レビュアーや QA が作業ツリーを書き換えた場合は `VERDICT: NEEDS_FIX`（`EXIT:4`）。label には round 番号を末尾 `-r<N>` で入れる（`rev-<票>-r<N>`）。
- **どの構成でも使える機能（Codex レビュー・Claude レビューとも。仕組みは `<kit>/lanes/review-dedup.zsh` の 1 つ）**:
  - `--mode auto`（既定）で full / delta / 省略を自動で選ぶ。`--round N` も使える。
  - `full` になる条件: 初回、P0/P1 修正後、前回 `NEEDS_FIX` 後（未解決指摘を自動引き継ぎし、独立行 `RESOLVED_PREVIOUS_FINDINGS: YES` が出るまで `CLEAN` にしない）。
  - `delta`（前回合格した HEAD（ブランチ先端のコミット）からの差分レビュー）・省略になる条件: 前回 `CLEAN` かつ未保存変更なしで条件が一致するとき。同一 HEAD は再レビューせず前回判定を返す（`skip-same-head`。やり直すときだけ `--force`）。
  - round 2 までは P2 も `NEEDS_FIX` にする。round 3 以降は P0/P1 のみ停止とし、P2/P3 は `logs/<series>.followups.md` に保存して `VERDICT: CLEAN`（`GATE: MERGE_WITH_FOLLOWUP`）で通す。残件は後回し票に起票して別レーンで直す。
  - 統合先の枝が無い repo では `--base <sha|branch>` を渡す（commit に解決できるもの）。
- **必須検証の使い回し（どの構成でも）**: 最終 HEAD で `<kit>/lanes/chk-run.sh` を通した後のレビューは、ランチャが `chk-run.sh <worktree> --query` で記録を問い合わせ、同じ中身（tree・入力の指紋・確認コマンドの指紋）で通っていれば、レビュアーに typecheck / lint / unit を回させず済んだものとして判定する（`LANES_REVIEW_REUSE_CHECKS`。既定 1、0 で問い合わせない）。`chk-run.sh` とレビューは同じシェルから呼び、その間に作業ツリーを変えない。確かめたことになるのは確認コマンドに入れた項目だけ。
- **検証とビルドの分担**: レビュー段階・修正レーン・マージ後 QA では build を回さず（`CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP`。`unit` は単体テスト。親の chk-run の記録を使い回すレビューでは成功行は要らない）、`LANES_BASE_BRANCH` へ入れる直前の最終 HEAD で `<kit>/lanes/chk-run.sh` を 1 回（同一 git tree（ファイル構成と中身の識別子）・同一 `input_fp`（環境や依存の指紋データ）なら自動省略）と CI で担保する。
  - レビューで省略してよいのは build だけ。E2E（画面を通した通しのテスト）は、full ではプロジェクトにあれば `CI=1` で自前のサーバーを立てて完走させ、delta では差分が画面・API に触れたときだけ該当の spec を回す（できなかったときは事実の理由と未実施の範囲を書く）。レビュー用テンプレート `<kit>/lanes/templates/claude-review-{full,delta}.md` と同じ。

## PR・auto-merge・cleanup・一時領域

- **永久ブランチの保護**: `main`・`master` と `LANES_BASE_BRANCH`（`develop` 等）は削除禁止（cleanup も消さない）。`--delete-branch` は作業枝から `LANES_BASE_BRANCH` への PR にだけ付ける。
- **PR の書式**: タイトルは課題管理ツールの票 ID（例: `[ISSUE-123] fix: ...`）で始め、本文先頭に `Ref ISSUE-123` と `logs/<label>.evidence.md` を貼る（`Closes` / `Fixes` は書かない）。
- **マージ（auto-merge）**: 必須 CI チェックがあるリポジトリでは `gh pr merge <PR> --auto --merge --delete-branch`（auto-merge：CI 通過後に自動でマージする設定）を使い、必須チェックが無い場合は `gh pr checks <PR> --watch --fail-fast` で緑を確認してからマージする。`main` へのリリース PR はユーザーの GO を待ち、auto-merge しない。
- **cleanup（マージ後の後片付け）と QA**: マージ後は本体 checkout か `$HOME` に移動してから `<kit>/lanes/after-develop-merge.sh <worktree> --apply`（bot QA 起動＋後片付け）または `<kit>/lanes/cleanup-after-merge.sh <worktree> --apply`（後片付けのみ）を実行する。
- **一時ファイルの置き場所**: 一時 DB・ビルド出力・ログ・diff 等は `$LANES_SCRATCH`（`$LANES_SCRATCH_ROOT/<repo>/<label>/`）だけに置き、`~/Downloads`・`$HOME` 直下・`/tmp` には書かせない。
