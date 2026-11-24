#!/bin/zsh -f
# Bot Shell のプロセスグループから完全分離してコマンドを起動する。
# 起動ログを worktree の logs/ の直下（<worktree>/logs/<名前>）に置くときは、書く前にその名前をランチャの記録の台帳
# （logs/.lanes-records。_common.sh の lanes_records_claim と同じ形の file:<名前>）へ載せる。chk-run.sh は台帳に載っている記録だけを
# 入力の指紋から外すので、載せないと「chk-run.sh の直後にレビューを起動する」だけで確認済みの記録と合わなくなる。
# worktree の logs/ の直下でない場所（ほかのフォルダ・logs/ の下のフォルダ）に置くときは、台帳を作らない。
# 起動ログに使えるのは、普通のファイル（無ければ作る。ハードリンクでないもの）と /dev/null のような文字デバイスだけ。
# symlink・ハードリンク・FIFO（名前付きパイプ）などは、その先へ書かず・待たずに exit 2 で止め、コマンドを起動しない。
# 起動するコマンドには、呼び出し元の環境変数をそのまま渡す（このスクリプトを挟んでも、挟まずに起動したときと同じ環境で動く）。
# 切り離しに使う python3（以下「補助」）へ乗り換える前のこのシェルの環境変数を fd 3 のパイプで渡し、子にはそれだけを渡す
# （補助や、その入口が足す環境変数は渡さない。渡すと chk-run.sh の入力の指紋が親と合わなくなる）。値はファイルにも引数にも書かない。
#
# 守る線:
#   このスクリプトの 1 行目から子を起動するまでの間に、ランチャの立場（呼び出し元の環境変数を読める立場）で動くのは、zsh の組み込みと、
#   下に書いた 2 つの絶対パスのどちらかの python3（とその標準ライブラリ）だけ。それが何になるか・起動時に何を読むかは、呼び出し元の
#   PATH・環境変数・作業場所・設定ファイル・起動ログの場所で変わらない（起動する対象のリポジトリの仮想環境を有効にしたシェルから
#   呼んでも、その python3・mkdir や、作業場所・PYTHONPATH にある同じ名前のファイルは動かない）。
#   - 補助は名前で探さない（PATH・環境変数・引数・設定からは決めない）。
#   - 補助は環境変数を 1 つも持たずに動く（exec -c）。-I で作業場所と PYTHON* を見ず、-S で site（起動時に自動で読む仕組み）を読まない。
#   - 補助が動き出すまで、このシェルは組み込みと決め打ちの値だけを使う。対象のリポジトリの場所は知らない（場所で動きを変えない）。
# 守らない:
#   - スクリプトの 1 行目より前（zsh <このファイル> と -f なしで呼んだときの利用者の .zshenv・zsh 自体の選び方）。
#   - 利用者の権限で OS 側の置き場や一時フォルダを細工された場合（Command Line Tools の無い Mac の /usr/bin/python3 は入口で、
#     行き先を利用者ごとの一時フォルダの控えから引く）。入口そのものが失敗したときの終了コードは、入口のもの。
#   - 起動するコマンド（子）自身の選び方（名前だけで書けば、今までどおり呼び出し元の PATH から探す）。
#   - ランチャ（run-*.sh・chk-run.sh）の中の python3 の選び方。
# 書き方の決まり（補助へ乗り換える exec の行まで）:
#   - 候補を足さない。補助の場所を、環境変数・設定キー・引数で受け取らない。3 つ目が欲しくなったら、設計を見直す合図とする。
#   - 補助の前に外部コマンドを呼ばない（mkdir・env・sh も）。ファイルを source しない。cd しない。パスを解決しない。
#   - ( … ) や $( … ) で包まない（包むと、呼び出し元が無視していたシグナルが子で既定に戻る）。
#   - ここ文書（<<）を使わない（一時ファイルを通り、その置き場 TMPPREFIX は環境から受け継ぐ）。
#   - 補助の本文を -c の引数にしない（標準入力で渡す）。コマンドを書かないリダイレクトを書かない（zsh が PATH の cat を起動する）。
#   - 名前の付いた変数を使わない（位置引数と関数 2 つだけ）。呼び出し元に同じ名前の環境変数があると、代入でその値を書き換えたり、
#     local で隠して下の一覧から落としたりして、子へそのまま渡せなくなるため。
#   - 補助の本文に一重引用符を書かない（一重引用符の中に置くため）。読み込むのは標準ライブラリだけ。
#   - -I と -S を外さない（-I を外すと作業場所の同じ名前のファイルを読み、Apple の python3 はホームの下のバイトコードの控えも使い始める）。
#   - 将来、補助が外部の道具（tmux など）を呼ぶなら、実行ファイルは絶対パス、渡す環境変数は名前を挙げたものだけにする。
set -euo pipefail
: "${1:?launch.log}"
(( $# >= 2 )) || { print -u2 -- "usage: detach-run.sh <launch.log> <cmd> [args...]"; exit 2; }
# 補助の python3 を位置引数の先頭に置く（この先は $1 = 補助、$2 = 起動ログ、$3 以降 = コマンド）。
# 候補はこの 2 つだけで、前から順に、最初にある「普通のファイルで実行できる」ものを使う（Mac の Command Line Tools の実体 → OS の入口）
set -- /Library/Developer/CommandLineTools/usr/bin/python3 "$@"
[[ -f "$1" && -x "$1" ]] || set -- /usr/bin/python3 "${@:2}"
[[ -f "$1" && -x "$1" ]] || { print -u2 -- "ERROR: 切り離しに使う python3 が決まった場所（/Library/Developer/CommandLineTools/usr/bin/python3・/usr/bin/python3）に無いので起動しない。PATH の python3 は使わない（Mac は xcode-select --install、Linux は OS の python3 を入れる）"; exit 2; }
# このシェルが export している変数（= ここから直に起動したコマンドへ渡る環境変数）を「名前=値」の NUL 区切りで出す。
# 最後に空の 1 件（NUL だけ）を置く。受け取る側は、終わりが NUL 2 つなら最後まで読めたと分かる
detach_env_dump() {
  set -- "${(@k)parameters[(R)*export*]}"
  while (( $# )); do print -rn -- "$1=${(P)1}"$'\0'; shift; done
  print -n -- $'\0'
}
# 補助の本文（Python）。標準入力のパイプで渡す
detach_py_source() { print -r -- '
import fcntl, os, stat, sys, subprocess
from pathlib import Path
log, cmd = Path(sys.argv[1]), sys.argv[2:]

def say(text):
    """文言を標準エラーへ出す。この python3 は空の環境で動き、ロケールが C になるので、UTF-8 のバイト列で直に書く。"""
    os.write(2, (text + "\n").encode("utf-8"))

# 起動ログのフォルダは、ここで作る（シェルの側では作らない。補助の前に外部コマンドを呼ばないため）。パスと例外の本文は出さない
try:
    log.parent.mkdir(parents=True, exist_ok=True)
except OSError:
    say("ERROR: 起動ログのフォルダを作れないので起動しない。書けるフォルダの下のパスを指定する")
    sys.exit(1)

def caller_environ():
    """呼び出し元のシェルの環境変数（detach-run.sh が fd 3 のパイプで渡す「名前=値」の NUL 区切り）を読む。
    読めない・途中で切れている・形が違うときは None（呼び出し側は起動しない）。
    子に渡すのは、この一覧だけ（この python3 自身の環境変数は、空から python3 と入口が足したものなので渡さない）。"""
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
        # この python3 の環境は空なので、受け取れないまま進むと子が空の環境で動く。起動しない
        say("ERROR: 呼び出し元の環境変数を受け取れないので起動しない")
        sys.exit(2)
    claim_launch_log(log)
    try:
        fd = open_launch_log(log)
    except OSError:
        # パスと例外の本文は出さない（下の「引数・例外本文は非表示」と同じ）
        say("ERROR: 起動ログを開けない、または起動ログに使えない種類（symlink・ハードリンク・FIFO など）なので起動しない。"
            "普通のファイルのパスを指定する")
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
    say("ERROR: 分離起動に失敗（引数・例外本文は非表示）")
    sys.exit(2)
print(p.pid)
' }
# 環境の写しは fd 3 へ、補助の本文は標準入力へ、どちらもプロセス置換（コマンドの出力をパイプでつなぐ書き方）で渡す。
# exec -c は、環境変数を全部外して補助へ乗り換える（このシェルは残らない。終了コードと出力は補助のもの）
exec -c "$1" -I -S - "${@:2}" 3< <(detach_env_dump) < <(detach_py_source)
