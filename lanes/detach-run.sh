#!/bin/zsh -f
# Bot Shell のプロセスグループから完全分離してコマンドを起動する。
# 起動ログを worktree の logs/ の直下（<worktree>/logs/<名前>）に置くときは、書く前にその名前をランチャの記録の台帳
# （logs/.lanes-records。_common.sh の lanes_records_claim と同じ形の file:<名前>）へ載せる。chk-run.sh は台帳に載っている記録だけを
# 入力の指紋から外すので、載せないと「chk-run.sh の直後にレビューを起動する」だけで確認済みの記録と合わなくなる。
# worktree の logs/ の直下でない場所（ほかのフォルダ・logs/ の下のフォルダ）に置くときは、台帳を作らない。
set -euo pipefail
log="${1:?launch.log}"; shift
(( $# >= 1 )) || { print -u2 -- "usage: detach-run.sh <launch.log> <cmd> [args...]"; exit 2; }
mkdir -p "${log:h}"
python3 - "$log" "$@" <<'PY'
import os, stat, sys, subprocess
from pathlib import Path
log, cmd = Path(sys.argv[1]), sys.argv[2:]
log.parent.mkdir(parents=True, exist_ok=True)

def claim_launch_log(log):
    """起動ログの名前をランチャの記録の台帳へ載せる。載せられなくても起動は止めない（確認済みの記録を使い回せなくなるだけ）。"""
    logdir = log.parent
    name = log.name
    if not name or name in (".", "..") or any(c in name for c in "\n\r\0"):
        return
    try:
        # worktree の logs/ の直下だけ（親に .git がある logs/。symlink の logs/ は辿らない）
        if logdir.name != "logs" or logdir.is_symlink() or not (logdir.parent / ".git").exists():
            return
        dfd = os.open(logdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            # 台帳が symlink・ハードリンク・普通のファイルでないときは書かない（辿って外へ書かない）
            fd = os.open(".lanes-records", os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o666, dir_fd=dfd)
            with os.fdopen(fd, "r+b") as f:
                st = os.fstat(f.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                    return
                data = f.read()
                line = os.fsencode("file:" + name)
                if line in data.split(b"\n"):
                    return
                head = b"" if data else "# ランチャの記録の台帳。ランチャが logs/ に書く名前の持ち主を載せる（chk-run.sh が入力の指紋から外す）。手で書き換えない\n".encode("utf-8")
                f.write((b"" if not data or data.endswith(b"\n") else b"\n") + head + line + b"\n")
        finally:
            os.close(dfd)
    except OSError:
        pass

try:
    claim_launch_log(log)
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
