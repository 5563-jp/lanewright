#!/bin/bash
# 認証情報をログへ出さず、実装レーンの MCP 接続を既定で無効にする回帰テスト。
# selftest: 構成ごと
# 本物の CLI やサービスは使わず、全作業を LANES_SCRATCH / TMPDIR 配下で完結する。
# 構成（LANES_TOOLS）に合わせて確かめる。未指定なら 3 つ全部（full）。codex の無い構成では、
# Codex のランチャが「この構成では使えない」で exit 2 になり .done を残すことを確かめる。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "$(cd "$(dirname "$0")" && pwd -P)/_git-isolate.sh"; lanes_test_git_isolate
test_dir="$(cd "$(dirname "$0")" && pwd)"
export LANES_TOOLS="${LANES_TOOLS:-claude codex gemini}"
python3 - "$test_dir/.." <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

lanes = Path(sys.argv[1]).resolve()
scratch = os.environ.get("LANES_SCRATCH") or os.environ.get("TMPDIR")
if not scratch or not Path(scratch).is_dir():
    raise SystemExit("LANES_SCRATCH または TMPDIR の既存ディレクトリが必要")

passed = 0
def check(condition, title):
    global passed
    if not condition:
        raise AssertionError(title)
    passed += 1
    print("ok  " + title, flush=True)

with tempfile.TemporaryDirectory(prefix="common-security-", dir=scratch) as temporary:
    root = Path(temporary)
    repo = root / "repo"
    repo.mkdir()
    stub = root / "cli-stub"
    events = root / "events.jsonl"
    # 模擬秘密も結果へ表示しない。スタブの出力を経由して親へ漏れないことを照合する。
    marker = "test-only-private-material-should-never-be-printed"
    stub.write_text("#!" + sys.executable + "\n" + r'''
import json, os
from pathlib import Path
import sys

args = sys.argv[1:]
marker = os.environ["STUB_MARKER"]
record = {"args": args, "cwd": os.getcwd()}
with open(os.environ["STUB_EVENTS"], "a", encoding="utf-8") as f:
    f.write(json.dumps(record) + "\n")

if args[:2] == ["login", "status"]:
    mode = os.environ.get("STUB_AUTH", "chatgpt")
    if mode in ("chatgpt", "bad-exit"):
        print("Logged in using ChatGPT", file=sys.stderr)
    elif mode == "mixed":
        print("Logged in using ChatGPT\n" + marker, file=sys.stderr)
    else:
        print("Logged in using an API key: " + marker, file=sys.stderr)
    sys.exit(9 if mode == "bad-exit" else 0)

if args[:2] == ["auth", "status"]:
    mode = os.environ.get("STUB_AUTH", "chatgpt")
    if mode == "bad-json":
        print(marker)
    elif mode == "array":
        print("[]")
    else:
        print(json.dumps({"loggedIn": "true" if mode == "wrong-type" else True,
                          "authMethod": "api_key" if mode == "api" else "claude.ai",
                          "token": marker}))
    sys.exit(9 if mode == "bad-exit" else 0)

if "mcp" in args:
    mode = os.environ.get("STUB_MCP", "good")
    changed = any(a.startswith("mcp_servers.") for a in args)
    if mode == "fail":
        print(marker, file=sys.stderr)
        sys.exit(6)
    if mode == "bad-json":
        print(marker)
        sys.exit(0)
    if mode == "wrong-shape":
        print(json.dumps({"secret": marker}))
        sys.exit(0)
    if mode == "empty":
        print("[]")
        sys.exit(0)
    name = "bad.name" if mode == "bad-name" else "private-server"
    enabled = not changed or mode == "still-enabled"
    transport_type = "unknown" if mode == "bad-transport" else "stdio"
    servers = [{"name": name, "enabled": enabled,
                "transport": {"type": transport_type, "command": marker,
                              "env": {"TOKEN": marker}}},
               {"name": "http-server", "enabled": enabled,
                "transport": {"type": "streamable_http", "url": marker}}]
    print(json.dumps(servers))
    sys.exit(0)

if args and args[0] in ("exec", "review"):
    expected = ["features.apps=false", "mcp_servers.private-server.enabled=false",
                'mcp_servers.private-server.command="/usr/bin/false"',
                "mcp_servers.http-server.enabled=false"]
    if not all(value in args for value in expected):
        sys.exit(31)
    if args[:2] == ["exec", "review"]:
        if not any(a.startswith("developer_instructions=") and "案件テスト" in a for a in args):
            sys.exit(35)
        print(json.dumps({"type": "turn.started"}))
        print(json.dumps({"type": "item.completed", "item": {"type": "command_execution", "command": marker}}))
        print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "No issues found."}}))
        print(json.dumps({"type": "turn.completed", "usage": {}}))
        sys.exit(0)
    if "案件テスト" not in sys.stdin.read():
        sys.exit(32)
    Path(args[args.index("-o") + 1]).write_text(os.environ.get("STUB_RESULT", "VERDICT: CLEAN\n"))
    sys.exit(0)

if "--strict-mcp-config" in args and "-p" in args:
    if "案件テスト" not in sys.stdin.read():
        sys.exit(33)
    print(json.dumps({"type": "result", "result": "実装を完了したよ。", "is_error": False}))
    sys.exit(0)
sys.exit(34)
''')
    stub.chmod(0o700)
    roles = subprocess.run(["zsh", "-f", str(lanes / "lanes-roles.sh"), "--env"], capture_output=True, text=True,
                           env={**os.environ, "LANES_CONF": str(root / "no-such.conf")})
    if roles.returncode != 0:
        raise SystemExit("LANES_TOOLS が不正: " + roles.stderr.strip())
    has_codex = "codex" in os.environ["LANES_TOOLS"].replace(",", " ").split()
    print("構成: " + roles.stdout.splitlines()[0], flush=True)
    env = {**os.environ, "LANES_CONF": str(root / "no-such.conf"), "CODEX_BIN": str(stub), "CLAUDE_BIN": str(stub),
           "GEMINI_BIN": str(stub), "LANES_NOTIFY": "0", "LANES_SCRATCH_ROOT": str(root / "scratch"),
           "TMPDIR": str(root) + "/", "LANES_SCRATCH": str(root),
           "HOME": str(root / "home"), "XDG_STATE_HOME": str(root / "home" / ".local" / "state"),
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "STUB_MARKER": marker, "STUB_EVENTS": str(events)}
    # 元リポジトリの参照を引き継がず、使い捨て repo 内だけを初期化する。
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
        env.pop(name, None)
    for args in (["init", "-q"], ["config", "user.name", "Test User"],
                 ["config", "user.email", "you@example.com"],
                 ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "test: 検証用の初期状態"]):
        subprocess.run(["git", "-C", str(repo), *args], env=env, check=True, capture_output=True)
        if args[0] == "init":
            assert os.path.realpath(subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(repo)), '一時リポの外の git に届いている: ' + str(repo)   # 本物のリポを書き換えない

    def shell(body, **overrides):
        return subprocess.run(["zsh", "-fc", 'set -euo pipefail; LANES_DIR="$1"; source "$LANES_DIR/_common.sh"; ' + body,
                               "test", str(lanes), str(repo)], cwd=root, env={**env, **overrides},
                              capture_output=True, text=True, timeout=25)

    def require_safe(result, code, title):
        check(result.returncode == code and marker not in result.stdout + result.stderr, title)

    require_safe(shell("lanes_check_codex_subscription"), 0, "Codex の完全一致かつ成功したサブスク認証を許可")
    for mode in ("api", "mixed", "bad-exit"):
        require_safe(shell("lanes_check_codex_subscription", STUB_AUTH=mode), 2,
                     "Codex の不正認証を本文非表示で拒否: " + mode)
    require_safe(shell("lanes_check_claude_subscription"), 0, "Claude のサブスク認証を許可")
    for mode in ("api", "wrong-type", "bad-json", "array", "bad-exit"):
        require_safe(shell("lanes_check_claude_subscription", STUB_AUTH=mode), 2,
                     "Claude の不正認証を本文非表示で拒否: " + mode)

    result = subprocess.run(["bash", "-c", 'source "$1/_common.sh"', "test", str(lanes)],
                            env=env, capture_output=True, text=True, timeout=25)
    require_safe(result, 2, "bash からの読み込みは zsh 固有構文の解析前に拒否")
    check("zsh から source" in result.stderr and "syntax error" not in result.stderr,
          "別シェルには固定の案内だけを出す")
    require_safe(shell("lanes_codex_no_mcp_args"), 2, "MCP の確認対象が無い場合は固定案内で拒否")
    events.unlink()
    result = shell('lanes_codex_no_mcp_args "$2"; print -rl -- "${LANES_CODEX_NO_MCP_ARGS[@]}"')
    require_safe(result, 0, "MCP の無効化引数に秘密を含めない")
    values = result.stdout.splitlines()
    check(values == ["-c", "features.apps=false", "-c", "mcp_servers.private-server.enabled=false",
                     "-c", 'mcp_servers.private-server.command="/usr/bin/false"',
                     "-c", "mcp_servers.http-server.enabled=false"],
          "stdio と HTTP の両接続を明示的に無効化")
    calls = [json.loads(line) for line in events.read_text().splitlines()]
    check(len(calls) == 2 and all(Path(c["cwd"]).resolve() == repo.resolve() for c in calls),
          "対象作業場所の MCP を列挙し、上書き後にも検証")
    require_safe(shell('lanes_codex_no_mcp_args "$2"', STUB_MCP="empty"), 0, "MCP が0件でも起動可能")
    for mode in ("fail", "bad-json", "wrong-shape", "bad-name", "bad-transport", "still-enabled"):
        require_safe(shell('lanes_codex_no_mcp_args "$2"', STUB_MCP=mode), 2,
                     "MCP 無効化の確認失敗で起動を拒否: " + mode)

    prompt = root / "request.md"
    prompt.write_text("案件テスト\n")
    def launcher(name, label, **overrides):
        return subprocess.run(["zsh", str(lanes / name), str(repo), str(prompt), label],
                              cwd=root, env={**env, **overrides}, capture_output=True,
                              text=True, timeout=35)

    subprocess.run(["git", "-C", str(repo), "update-ref", "refs/remotes/origin/develop", "HEAD"],
                   env=env, check=True, capture_output=True)
    if has_codex:
        result = launcher("run-codex.sh", "codex-clean")
        require_safe(result, 0, "Codex 実装へ MCP 無効化引数と標準入力を渡す")
        check("EXIT:0" in (repo / "logs/codex-clean.done").read_text(), "Codex 実装成功の終了記録を残す")
        for label, body, code in (("codex-none", "レビューを実施できませんでした。\n", 3),
                                  ("codex-fix", "[P1] 修正が必要\nVERDICT: CLEAN\n", 4)):
            result = launcher("run-codex.sh", label, STUB_RESULT=body)
            require_safe(result, code, "Codex 実装の判定不能・要修正を非正常終了へ変換: " + label)
            check("EXIT:" + str(code) in (repo / ("logs/" + label + ".done")).read_text(),
                  "Codex 実装失敗の終了記録を残す: " + label)
        result = launcher("run-codex-review.sh", "review-clean")
        require_safe(result, 0, "Codex レビューへ実装と同じ MCP 無効化契約を渡す")
        check("EXIT:0" in (repo / "logs/review-clean.done").read_text(), "Codex レビュー成功の終了記録を残す")
        result = launcher("run-codex-review.sh", "review-mcp-failure", STUB_MCP="still-enabled")
        require_safe(result, 2, "Codex レビューも MCP 無効化を検証できなければ起動禁止")
    else:
        # codex の無い構成: Codex のランチャは codex を一度も呼ばずに止まり、.done（EXIT:2）を残す
        if events.exists():
            events.unlink()
        for name, label in (("run-codex.sh", "codex-off"), ("run-codex-review.sh", "review-off")):
            result = launcher(name, label)
            require_safe(result, 2, name + " は codex の無い構成で exit 2")
            check("この構成では使えない" in result.stderr and "run-review.sh" in result.stderr,
                  name + " は代わりの入口（run-impl.sh / run-review.sh）を案内する")
            check("EXIT:2" in (repo / ("logs/" + label + ".done")).read_text(), name + " は止まっても .done を残す")
        check(not events.exists(), "codex の無い構成では Codex の CLI を呼ばない")
        # selftest.sh はこの行を見て、表で「緑(一部)」と区別する
        print("LANES_PARTIAL: codex の無い構成なので、Codex のランチャ（run-codex.sh / run-codex-review.sh）は停止の確認のみ", flush=True)
    result = launcher("run-claude.sh", "claude-clean")
    require_safe(result, 0, "Claude 実装へ --strict-mcp-config と標準入力を渡す")
    check("EXIT:0" in (repo / "logs/claude-clean.done").read_text(), "Claude 成功の終了記録を残す")
    check(all(marker not in f.read_text(errors="replace") for f in (repo / "logs").iterdir() if f.is_file()),
          "実装ランチャの全記録に認証本文・接続情報を残さない")

print(f"---- {passed} passed, 0 failed")
PY
