# Security Policy / セキュリティポリシー

## 脆弱性の報告（日本語）

このリポジトリ（`lanewright`）に関するセキュリティ上の問題（秘密情報の露出、制限やガードの回避、意図しないコマンド実行など）を見つけた場合は、**公開の Issue・Pull Request・Discussion には書き込まないでください**。

報告は **GitHub の Private vulnerability reporting**（このリポジトリの **Security** タブ → **Report a vulnerability**）から送ってください。連絡用のメールアドレスは設けていません。

### 対象範囲

- **対象**: このキットに含まれるスクリプト・ランチャ・補助ツール自体の脆弱性。
- **対象外**: 各 AI コーディング CLI 自体（Anthropic Claude Code、OpenAI Codex CLI、Google Antigravity CLI `agy`）や GitHub CLI（`gh`）の脆弱性・不具合は、それぞれの提供元へ直接報告してください。

### 利用上の注意

このキットは AI エージェントに書き込み権限とコマンド実行権限を持たせて自動で動かす道具です。レビュー側の禁止リストは完全なサンドボックスではなく、事後検知を含みます。検証の手順（`--verify`・`chk-run.sh`・依存の導入）は、AI が書いたコードをサンドボックスの外で実行します。本番の鍵・本番 DB・本番デプロイに届く環境では使わないでください。

---

## Reporting a Vulnerability (English)

If you find a security vulnerability in `lanewright` (such as secret exposure, restriction or guard bypass, or unintended command execution), **please do not report it in public GitHub Issues, Pull Requests, or Discussions**.

Instead, please report it via **GitHub Private vulnerability reporting** (go to this repository's **Security** tab and click **Report a vulnerability**). No contact email address is provided.

### Scope

- **In scope**: Vulnerabilities in the scripts, launchers, and helper tools included in this kit.
- **Out of scope**: Vulnerabilities or bugs in the AI coding CLIs themselves (Anthropic Claude Code, OpenAI Codex CLI, Google Antigravity CLI `agy`) or GitHub CLI (`gh`). Please report those directly to their respective vendors.

### Safety Notice

This toolkit runs AI agents automatically with write and shell execution permissions. The review-lane restrictions and deny-lists are not a complete sandbox and rely in part on post-execution detection. Verification steps (`--verify`, `chk-run.sh`, dependency installs) execute AI-written code outside the sandbox. Do not use this toolkit in environments that have access to production keys, production databases, or production deployment targets.
