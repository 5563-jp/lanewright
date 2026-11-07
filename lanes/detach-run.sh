#!/bin/zsh -f
# Bot Shell のプロセスグループから完全分離してコマンドを起動する。
set -euo pipefail
log="${1:?launch.log}"; shift
(( $# >= 1 )) || { print -u2 -- "usage: detach-run.sh <launch.log> <cmd> [args...]"; exit 2; }
mkdir -p "${log:h}"
python3 - "$log" "$@" <<'PY'
import os, sys, subprocess
from pathlib import Path
log, cmd = Path(sys.argv[1]), sys.argv[2:]
log.parent.mkdir(parents=True, exist_ok=True)
try:
    # 起動ログが symlink だと、その先へ追記してしまう。辿らずに開く
    fd = os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o666)
    with os.fdopen(fd, "ab", buffering=0) as f:
        # 引数にはプロンプトや認証情報が入りうるため、起動した事実だけを残す。
        f.write(b"\n=== detach-run ===\n")
        p = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=os.environ.copy(),
        )
except Exception:
    print("ERROR: 分離起動に失敗（引数・例外本文は非表示）", file=sys.stderr)
    sys.exit(2)
print(p.pid)
PY
