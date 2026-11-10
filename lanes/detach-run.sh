#!/bin/zsh -f
# Bot Shell のプロセスグループから完全分離してコマンドを起動する。
# 起動ログを worktree の logs/ の直下（<worktree>/logs/<名前>）に置くときは、書く前にその名前をランチャの記録の台帳
# （logs/.lanes-records。_common.sh の lanes_records_claim と同じ形の file:<名前>）へ載せる。chk-run.sh は台帳に載っている記録だけを
# 入力の指紋から外すので、載せないと「chk-run.sh の直後にレビューを起動する」だけで確認済みの記録と合わなくなる。
# worktree の logs/ の直下でない場所（ほかのフォルダ・logs/ の下のフォルダ）に置くときは、台帳を作らない。
# 起動ログに使えるのは、普通のファイル（無ければ作る。ハードリンクでないもの）と /dev/null のような文字デバイスだけ。
# symlink・ハードリンク・FIFO（名前付きパイプ）などは、その先へ書かず・待たずに exit 2 で止め、コマンドを起動しない。
# 起動するコマンドには、呼び出し元の環境変数をそのまま渡す（このスクリプトを挟んでも、挟まずに起動したときと同じ環境で動く）。
# 切り離しに使う python3 は、Mac では本物の前に入口を通ることが多く（Xcode の /usr/bin/python3・pyenv の shims など）、
# その入口が環境変数を書き換える（MANPATH の先頭へ通るたびに足す・SDKROOT・PYENV_DIR に通った場所を入れる・PATH に足す など）。
# python3 から見えた環境変数をそのまま子へ渡すと、起動したランチャだけが呼び出し元と違う環境で動き、chk-run.sh の入力の指紋
# （環境変数が入る）が、親が chk-run.sh を回したときと合わなくなる（レビューが確認済みの記録を使い回せない）。
# そこで、python3 を呼ぶ前のこのシェルの環境変数を fd 3 のパイプで渡し、子にはそれを渡す。値はファイルにも引数にも書かない。
set -euo pipefail
log="${1:?launch.log}"; shift
(( $# >= 1 )) || { print -u2 -- "usage: detach-run.sh <launch.log> <cmd> [args...]"; exit 2; }
mkdir -p "${log:h}"
# このシェルが export している変数（= ここから直に起動したコマンドへ渡る環境変数）を「名前=値」の NUL 区切りで出す。
# 最後に空の 1 件（NUL だけ）を置く。受け取る側は、終わりが NUL 2 つなら最後まで読めたと分かる
detach_env_dump() {
  local k
  for k in "${(@k)parameters[(R)*export*]}"; do print -rn -- "$k=${(P)k}"$'\0'; done
  print -n -- $'\0'
}
python3 - "$log" "$@" 3< <(detach_env_dump) <<'PY'
import fcntl, os, re, stat, sys, subprocess
from pathlib import Path
log, cmd = Path(sys.argv[1]), sys.argv[2:]
log.parent.mkdir(parents=True, exist_ok=True)

def caller_environ():
    """呼び出し元のシェルの環境変数（detach-run.sh が fd 3 のパイプで渡す「名前=値」の NUL 区切り）を読む。
    読めない・途中で切れている・形が違うときは None（呼び出し側は今の環境変数で起動する）。
    渡された一覧に無い変数（python3 の入口や python3 自身が足したもの）は、子に渡さない。ただし、シェルが変数として持てない名前
    （英数字と _ 以外を含む名前）は一覧に出ないことがあるので、今の環境変数から引き継ぐ。"""
    try:
        with os.fdopen(3, "rb") as stream:
            data = stream.read()
    except OSError:
        return None
    if not data.endswith(b"\0\0"):
        return None
    env = {}
    for record in data[:-2].split(b"\0"):
        name, sep, value = record.partition(b"=")
        if not sep or not name:
            return None
        env[name] = value
    plain_name = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")
    for name, value in os.environb.items():
        if name not in env and not plain_name.fullmatch(name):
            env[name] = value
    return env

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
            # 台帳が symlink・ハードリンク・普通のファイルでない（FIFO など）ときは書かない（辿って外へ書かない）。
            # 種別は開いた後で確かめるので、O_NONBLOCK で開くところでは待たない（FIFO を開こうとして待ち続けない）
            fd = os.open(".lanes-records", os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o666, dir_fd=dfd)
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                os.close(fd)
                return
            with os.fdopen(fd, "r+b") as f:
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

def open_launch_log(log):
    """起動ログを、辿らず・待たずに開く。使えるのは普通のファイル（ハードリンクでないもの）と、/dev/null のような文字デバイスだけ。
    symlink は、その先へ追記してしまうので O_NOFOLLOW で辿らない。FIFO（名前付きパイプ）は、O_NONBLOCK を付けずに開くと読み手が
    現れるまで open が返らず、読み手がいれば子の出力がその先へ流れる。ハードリンクは、追記が別の名前のファイルにも届く。
    種別は開いた後で確かめる。使えないものは OSError にする。"""
    fd = os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o666)
    try:
        st = os.fstat(fd)
        if not ((stat.S_ISREG(st.st_mode) and st.st_nlink == 1) or stat.S_ISCHR(st.st_mode)):
            raise OSError("起動ログに使えない種類のファイル")
        # 子へ渡す出力先は、待つ書き込みに戻す（O_NONBLOCK は、開くところで待たないためだけに使う）
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd

try:
    # fd 3 は最初に読んで閉じる（下で開くファイルの番号と取り違えない）
    child_env = caller_environ()
    if child_env is None:
        print("NOTE: 呼び出し元の環境変数を受け取れなかったので、python3 から見える環境変数のまま起動する"
              "（python3 の入口が環境変数を書き換える Mac では、chk-run.sh の確認済みの記録を使い回せないことがある）", file=sys.stderr)
        child_env = os.environ.copy()
    claim_launch_log(log)
    try:
        fd = open_launch_log(log)
    except OSError:
        # パスと例外の本文は出さない（下の「引数・例外本文は非表示」と同じ）
        print("ERROR: 起動ログを開けない、または起動ログに使えない種類（symlink・ハードリンク・FIFO など）なので起動しない。"
              "普通のファイルのパスを指定する", file=sys.stderr)
        sys.exit(2)
    with os.fdopen(fd, "ab", buffering=0) as f:
        # 引数にはプロンプトや認証情報が入りうるため、起動した事実だけを残す。
        f.write(b"\n=== detach-run ===\n")
        p = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=child_env,
        )
except Exception:
    print("ERROR: 分離起動に失敗（引数・例外本文は非表示）", file=sys.stderr)
    sys.exit(2)
print(p.pid)
PY
