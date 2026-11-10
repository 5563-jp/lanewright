# Contributing / 貢献のしかた

[English below](#english)

## 日本語

lanewright への Issue・Pull Request（PR）を歓迎します。個人の OSS なので、返事や取り込みは約束できません。気長に待ってください。

### その前に
- **セキュリティ上の問題は、公開の Issue・PR に書かないでください。** [SECURITY.md](SECURITY.md) の手順（GitHub の非公開の脆弱性報告）で送ってください。
- 大きな変更（新しいランチャ、安全策の仕組みの変更、設定キーの追加など）は、PR の前に Issue で相談してください。

### 開発の準備
- macOS と zsh、`python3`、`git` が要ります。lint（静的な検査）には `shellcheck` と `pyflakes` を使います（無いと一部が省かれます）。
- 本物の AI の CLI やネットワークは要りません。テストは偽の CLI（`lanes/tests/stubs`）と一時フォルダだけで動きます。

### テストを回す
```sh
zsh -f tests/test-lint.sh                          # 構文と lint（LANES_LINT_STRICT=1 で、道具が無いときも赤にする）
zsh -f lanes/tests/test-roles.sh                   # 1 本だけ回す
zsh -f selftest.sh --test lanes/tests/test-roles.sh # 1 本を selftest の一時 HOME で回す
zsh -f selftest.sh                                 # 全部（4 構成。15〜20 分）
```
- PR の前に `selftest.sh` を一度全部通してください。キットのリポを書き換えていないかの前後比較も入っています（回している間はキットのファイルを編集しない）。
- テストの結果は、回す場所（普段のシェル・レーンの中・`chk-run.sh` の確認コマンドの中）で変わらないはずです。レーンの中だけで回して済ませず、普段のシェルからも回してください
  （`python3` の入口が環境変数を書き換える Mac で、レーンの中だけ緑になった不具合がありました。`lanes/README.md` の 16 章）。変わったら不具合です。
- 個人の情報や固有名が混ざっていないかは `tests/test-no-private.sh` が見ます。自分用の禁止語ファイルを `LANES_PRIVATE_DENYLIST=<ファイル>` で渡すと、その語も調べます（禁止語ファイルはリポの外に置く）。

### 書き方の約束
- シェルは `#!/bin/zsh -f`（`bash` 前提のスクリプトは明記する）。`set -euo pipefail` を使い、zsh の落とし穴は `lanes/_common.sh` の先頭近くのコメントを見てください。
- コードのコメント・ドキュメント・ログの文言は日本語が基本です。英語版の README（`README.en.md`）は日本語版と内容を揃えます。
- **新しい動き・バグの修正には、テストを足してください。** 安全策（書き込み先の検査、push の遮断、symlink を辿らない書き方など）を触るときは、
  「直す前のコードで赤になり、直した後で緑になる」テストを付けてください。
- ランチャが書くファイルは、子（AI）が書ける場所に置くなら、symlink やハードリンクを辿らない書き方（`lanes_fresh_file`、`O_NOFOLLOW`、開いたフォルダの中での置き換え）にしてください。
  前からあるファイルを読む・追記するために開くときは `O_NONBLOCK` も付け、開いた後で普通のファイルかを確かめてください（FIFO（名前付きパイプ）を開こうとして待ち続けないため）。
- 固有のモデル名・個人のパス・メールアドレス・サービスの ID をコードや文書に書かないでください。
- 設定キーを足したら、`lanes/lanes.env`（既定値と値の検査）・`lanes.conf.example`・`docs/config.md` を同じ PR で直してください。

### commit と PR
- commit の件名は `種類: 内容` の形（`feat:` `fix:` `docs:` `test:` `refactor:` `chore:` など。種類は英語、内容は日本語でも英語でも可）。
- PR には、何を変えたか・なぜか・どのテストで確かめたか（`selftest.sh` の結果の表）を書いてください。

### ライセンス
PR を送ることで、その変更を [MIT License](LICENSE) で提供することに同意したものとします。

---

## English

Issues and pull requests are welcome. This is a personal open-source project, so responses and merges are best-effort.

### Before you start
- **Do not report security issues in public Issues or PRs.** Follow [SECURITY.md](SECURITY.md) (GitHub private vulnerability reporting).
- For larger changes (a new launcher, changes to a safety mechanism, new configuration keys), please open an Issue first.

### Setup
- You need macOS, zsh, `python3`, and `git`. Linting uses `shellcheck` and `pyflakes` (some checks are skipped if they are missing).
- No real AI CLIs or network access are needed. Tests run with stub CLIs (`lanes/tests/stubs`) in temporary directories.

### Running tests
```sh
zsh -f tests/test-lint.sh                          # syntax and lint (LANES_LINT_STRICT=1 fails when a tool is missing)
zsh -f lanes/tests/test-roles.sh                   # run a single test
zsh -f selftest.sh --test lanes/tests/test-roles.sh # run one test inside the self-test's temporary HOME
zsh -f selftest.sh                                 # everything (4 tool profiles, 15–20 minutes)
```
- Run the full `selftest.sh` once before opening a PR. It also verifies that the tests did not modify the kit's own repository (do not edit kit files while it runs).
- Test results must not depend on where you run them (a plain shell, inside a lane, or inside the `chk-run.sh` check command). Run them from a plain shell too, not only inside a lane
  (a bug once passed only inside lanes on Macs whose `python3` launcher rewrites environment variables; see section 16 of `lanes/README.md`). A difference is a bug.
- `tests/test-no-private.sh` checks for personal information. Pass your own deny-list with `LANES_PRIVATE_DENYLIST=<file>` (keep that file outside the repository).

### Conventions
- Shell scripts use `#!/bin/zsh -f` (mark scripts that require `bash`) and `set -euo pipefail`. See the comments near the top of `lanes/_common.sh` for zsh pitfalls.
- Code comments, documentation, and log messages are primarily in Japanese. Keep `README.en.md` in sync with `README.md`.
- **Add tests for new behavior and bug fixes.** When touching a safety mechanism (write-target checks, push blocking, not following symlinks, and so on), include a test that fails on the old code and passes on the new code.
- Files the launcher writes in places the child (the AI) can write to must be written without following symlinks or hard links (`lanes_fresh_file`, `O_NOFOLLOW`, replacing within an opened directory).
  When opening an existing file there to read or append, also pass `O_NONBLOCK` and verify after opening that it is a regular file (so that a FIFO planted at that path cannot make the open wait forever).
- Do not put specific model names, personal paths, email addresses, or service IDs in code or documentation.
- When adding a configuration key, update `lanes/lanes.env` (defaults and validation), `lanes.conf.example`, and `docs/config.md` in the same PR.

### Commits and pull requests
- Commit subjects use the form `type: summary` (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, and so on; the summary may be in Japanese or English).
- In the PR, describe what changed, why, and how you verified it (paste the `selftest.sh` results table).

### License
By submitting a pull request, you agree to license your contribution under the [MIT License](LICENSE).
