# Changelog / 変更履歴

このファイルには、利用者から見える変更を書きます。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿い、版の付け方は [Semantic Versioning](https://semver.org/lang/ja/) に従います（1.0.0 になるまでは、0.x の中でも動きが変わることがあります）。

This file lists user-visible changes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) (behavior may change between 0.x releases before 1.0.0).

## [Unreleased]

### 直したこと / Fixed
- `chk-run.sh` が成功を記録した直後に `detach-run.sh` 経由でレビューを起動すると、証跡が毎回「親の chk-run の記録は使わない: input-changed」になり、
  必須検証の使い回しが効かなかった。`detach-run.sh` が起動ログ（`<worktree>/logs/launch.log`）をランチャの問い合わせより先に書き、
  その無視対象のファイルが入力の指紋に入っていたため（dry-run や手での問い合わせでは再現しない）。
  ランチャの記録を入力の指紋に入れないようにした。名前が記録に似ているだけでは外さない: ランチャと `detach-run.sh` が、`logs/` に書く前に
  書く名前の持ち主を台帳（`logs/.lanes-records`。`label:<label>` か `file:<名前>` の行）へ載せ、`chk-run.sh` は台帳に載っている持ち主の
  決まった名前のファイル（`<label>.pid`・`.done`・`.log`・`.json`・`.prompt.md`・`.evidence.md`・起動ログなど。git が無視している普通のファイル）だけを外す。
  台帳に無い名前のファイル（確認コマンドが読む `logs/input.json` など）、`logs/` の中のフォルダ、リンク、追跡しているファイルは今までどおり入力として
  照合する（中身を変えれば、古い成功の記録を使い回さずに回し直す）。レビューの後に `chk-run.sh` を呼び直しても、同じ確認を省く（`skip=same-tree`）。
  この版より前のランチャが書いた記録は台帳に無いので入力として数える（同じ label を起動し直すと台帳に載る）。
  台帳が symlink・ハードリンク・FIFO（名前付きパイプ）など、普通のファイルでないときは、ランチャは書かず、`chk-run.sh` も使わない
  （どちらも待たずに開いてから種別を確かめるので、台帳が FIFO でも `chk-run.sh`・レビューの起動は止まらない）。
  Reviews launched through `detach-run.sh` right after a successful `chk-run.sh` never reused the parent's check record
  (`input-changed`), because `detach-run.sh` wrote the launch log (`<worktree>/logs/launch.log`) before the launcher queried the record,
  and that git-ignored file was part of the input fingerprint. Launcher records are no longer part of the fingerprint. A record-like name is not enough:
  launchers and `detach-run.sh` register the owner of what they write in a ledger (`logs/.lanes-records`, lines of `label:<label>` or `file:<name>`)
  before writing, and `chk-run.sh` only skips the well-known file names of registered owners (`<label>.pid`, `.done`, `.log`, `.json`, `.prompt.md`,
  `.evidence.md`, launch logs, and so on; git-ignored regular files). Unregistered names (for example a `logs/input.json` read by the check command),
  subdirectories, links, and tracked files under `logs/` are still fingerprinted, so changing them re-runs the check instead of reusing an old success.
  Records written by launchers older than this version are not in the ledger and count as input until the same label is launched again.
  If the ledger is a symlink, a hard link, or not a regular file (for example a FIFO), launchers do not write to it and `chk-run.sh` ignores it;
  both open it without blocking and check the file type afterwards, so a FIFO ledger cannot make `chk-run.sh` or a review launch hang.
- `detach-run.sh` が、起動ログのパスに FIFO（名前付きパイプ）があると、読み手が現れるまで待ち続けた（読み手がいれば、起動したコマンドの出力が
  その先へ流れた）。ハードリンクのときは、追記が別の名前のファイルにも届いた。起動ログは待たずに開いてから種別を確かめ、普通のファイル
  （ハードリンクでないもの）か `/dev/null` のような文字デバイスでなければ、書かずに exit 2 で止め、コマンドを起動しないようにした
  （symlink を辿らないのは今までどおり）。
  `detach-run.sh` waited forever when the launch log path was a FIFO with no reader (with a reader, the launched command's output went into it),
  and appended through a hard link into the file's other name. The launch log is now opened without blocking and its type is checked afterwards:
  unless it is a regular file with a single link or a character device such as `/dev/null`, nothing is written, the command is not started,
  and the script exits with status 2 (symlinks are still not followed).
- `chk-run.sh` が、確認コマンドは通ったのに結果を記録しないとき（未 commit の変更がある・確認コマンドや依存を確実に照合できない）、何も出さずに終わっていた。
  そのためレビューの証跡が `no-record` になる理由が分からなかった（`.lanes/check.sh` に `exec zsh -f …` と書いただけで起きる。`exec` は
  「引数のコマンドを起動する包み」なので、仕様どおり記録しない）。`record=no reason=<uncommitted|unresolvable>（理由）` の行を出すようにした。
  説明には原因になったファイルや書き方が出る（例: `確認コマンド（.lanes/check.sh）の「exec」`）。記録する・しないの条件は変えていない。
  `chk-run.sh` printed nothing when the check command passed but the result was not recorded (uncommitted changes, or a check command or dependency
  that cannot be fingerprinted reliably), so it was unclear why review evidence said `no-record` (writing `exec zsh -f …` in `.lanes/check.sh` is enough:
  `exec` is a wrapper that launches its argument, so by design the result is not recorded). It now prints
  `record=no reason=<uncommitted|unresolvable>` with an explanation naming the file or construct. The conditions for recording are unchanged.
- `cleanup-after-merge.sh` が、`chk-run.sh` のビルドが残した無視対象の `dist/` で止まった（`EXIT:4`）。git が無視している生成物
  （作業ツリー直下の `dist/` `build/` `out/` の中など）は、残骸と同じく退避してから後片付けを続けるようにした（本体 checkout の生成物は退避も削除もしない）。
  生成物の定義は `chk-run.sh` と共通の 1 か所（`lanes/_common.sh` の `LANES_GENERATED_DIRS` / `LANES_GENERATED_SUFFIXES`）にまとめた。
  git が無視していない未追跡ファイルや、知らない除外ファイルで止まる動きは変えていない。
  `cleanup-after-merge.sh` stopped (`EXIT:4`) on a git-ignored `dist/` left by the `chk-run.sh` build. Git-ignored build outputs
  (files under the worktree's top-level `dist/`, `build/`, `out/`, and so on) are now archived like other leftovers and the cleanup continues
  (in the main checkout they are left in place). The definition of build outputs is shared with `chk-run.sh` in one place
  (`LANES_GENERATED_DIRS` / `LANES_GENERATED_SUFFIXES` in `lanes/_common.sh`). Untracked files that are not ignored, and unknown ignored files, still stop the cleanup.
- 必須検証を使い回さなかったレビューの証跡が、回せていなくても「レビューの中で実施」と書いていた。「レビューの中で回すよう指示」に直し、
  使わなかった理由に一言の説明を足した（回せたかどうかは「必須検証の成功確認」の行が示す）。
  Review evidence no longer claims the required checks were "performed in the review" when they were only requested;
  it now says they were requested and adds a short explanation of why the parent's record was not reused.

### 変えたこと / Changed
- 起動元のシェルが `CLAUDE_EFFORT`・`CODEX_EFFORT`・`GEMINI_EFFORT` を環境変数として持っていて、設定ファイル（無ければ既定）と違う値で勝っているとき、
  ランチャが起動時に注意を 1 行出すようにした（`lanes-doctor.sh` でも出る）。勝つ順番（環境変数 > 設定ファイル > 既定）と、CLI に渡す値は変えていない。
  設定ファイルの値に固定する書き方（`CLAUDE_EFFORT="xhigh"` と値をそのまま書く）を `lanes.conf.example` と `docs/config.md` に書いた。
  When the launching shell has `CLAUDE_EFFORT`, `CODEX_EFFORT`, or `GEMINI_EFFORT` set as an environment variable and it overrides a different value
  from the config file (or the default), the launcher now prints a one-line notice at startup (`lanes-doctor.sh` shows it too).
  Precedence (environment variable > config file > default) and the value passed to the CLI are unchanged.
  `lanes.conf.example` and `docs/config.md` describe how to pin the config value (write the value literally, e.g. `CLAUDE_EFFORT="xhigh"`).
- Codex レビューの `--dry-run` の表示に、必須検証を使い回すかどうか（`必須検証の使い回し: yes / no / off`）を出すようにした（Claude レビューと同じ）。
  The Codex review `--dry-run` output now shows whether the parent's check record will be reused, like the Claude review.

## [0.1.1] - chk-run の記録の直し / chk-run record fix

### 直したこと / Fixed
- `chk-run.sh` が npm の作業ツリーで成功を一度も記録しなかった。`node_modules/.bin/*` のシンボリックリンクを見て、毎回「使い回し不可」と判断していたため。
  リンクの実体が作業ツリーの中にあれば、リンク先の中身をハッシュしたうえで記録・使い回しを続けるようにした。作業ツリーの外を指すリンクや行き先の無いリンクは、今までどおり記録しない。
  `chk-run.sh` never recorded a successful run in npm worktrees, because the symlinks in `node_modules/.bin/*` disabled reuse. Symlinks that resolve inside the worktree no longer disable reuse (their targets are still hashed). Symlinks pointing outside the worktree, and dangling ones, still disable it.

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
