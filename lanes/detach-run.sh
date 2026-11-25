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
# 使い方: detach-run.sh <launch.log> <cmd> [args...]
#         detach-run.sh --tmux <セッション名> [--linger <秒>] <launch.log> <cmd> [args...]
# --tmux を付けると、tmux（端末を裏で保持して、あとからつなぎ直せる道具）のセッションを 1 つ作り、その画面の中に居続ける親
# （以下「画面の中の親」）からコマンドを起動する。起動したレーンが tmux のセッションとして見え、画面には、起動した pid・起動ログの続き・
# 終わったときの終了コードが出る。
#   - 起動するコマンドから見えるもの（環境変数・作業場所・umask・標準入力は /dev/null・出力は起動ログ・ほかの fd は無い・新しいセッション・
#     無視にしていたシグナル）と、呼び出し元から見えるもの（標準出力は pid の 1 行・起動ログの見出し・台帳・終了コード）は、
#     付けないときと同じ。違うのは、起動したコマンドの親が tmux の画面の中に居ること。tmux が足す環境変数（TMUX・TERM など）は渡らない。
#   - セッションを閉じても、画面で Ctrl-C を押しても、起動したコマンドは止まらない（別のセッションで動いている。止めるのは、
#     今までどおり標準出力に出した pid への kill）。コマンドが終わると、画面に終了コードを出し、--linger 秒（0〜86400 の整数。既定 600）
#     待ってからセッションが閉じる。
#   - セッション名は英数と _ -（先頭は英数・100 字まで）。同じ名前のセッションがあれば <名前>-2 … <名前>-9 を順に試す。
#   - tmux は、下の本文に書いた 3 つの場所だけから選ぶ（PATH からは探さない）。tmux へ渡す環境変数は、名前を挙げた 6 つだけ
#     （呼び出し元からは TMUX_TMPDIR と LANG。HOME・USER・LOGNAME は OS のユーザー情報から。PATH は決め打ち）。tmux のサーバーが
#     まだ無ければ、この起動が立ち上げる。その環境は、利用者が後で開くウィンドウにも受け継がれるので、呼び出し元の環境まるごとは渡さず、
#     設定ファイルの場所・既定のシェル・PATH を、呼び出し元の値（起動する対象のリポジトリを指しうる）で決めさせない。
#   - 画面の中の親は、この入口を /bin/zsh -f で呼び直したもの（--tmux-pane。手では呼ばない）。tmux のサーバーの環境は、下の exec -c で
#     捨てる。呼び出し元とは、自分だけが読める一時フォルダ（TMPDIR があればその下。無ければ /tmp）のソケットでつなぎ、環境変数・コマンドと、
#     呼び出し元が開いた起動ログ・作業場所の fd を受け取る（値をファイル・引数・tmux の環境には書かない。画面の側はパスを開かない）。
#   - 門つきの起動: 画面の中の親が作った子は、付けないときと同じ形に整えてから、コマンドを始める前の「門」で待つ。門を開けるのは
#     呼び出し元だけ（子の pid を受け取ったら、合図を書く）。合図の前に呼び出し元が止められた・失敗した・期限（20 秒）が来たときは、
#     コマンドは一度も始まらない（失敗を返したのに動き続けない。始まったコマンドを後から止める処理も無い）。
#   - 失敗は、決まった文言で exit 2（起動ログのフォルダを作れないときは、付けないときと同じ exit 1）。作ったセッションは、
#     画面の中の親が自分で終わるので残らない。呼び出し元は、tmux のセッションを作るだけで、閉じる・探す操作をしない。
#   - 1 つ目の引数が --tmux・--linger・--tmux-pane そのもののときだけ、この経路に入る（その名前の起動ログは ./--tmux と書く）。
#
# 守る線:
#   このスクリプトの 1 行目から子を起動するまでの間に、ランチャの立場（呼び出し元の環境変数を読める立場）で動くのは、zsh の組み込みと、
#   下に書いた 2 つの絶対パスのどちらかの python3（とその標準ライブラリ）だけ。それが何になるか・起動時に何を読むかは、呼び出し元の
#   PATH・環境変数・作業場所・設定ファイル・起動ログの場所で変わらない（起動する対象のリポジトリの仮想環境を有効にしたシェルから
#   呼んでも、その python3・mkdir や、作業場所・PYTHONPATH にある同じ名前のファイルは動かない）。
#   --tmux のときに加わるのは、決め打ちの場所の tmux と /bin/zsh だけ。tmux へ渡す環境変数は名前を挙げた 6 つ（呼び出し元の値は
#   TMUX_TMPDIR と LANG だけ）で、/bin/zsh（画面の中の親）は、tmux のサーバーの環境を捨ててから、同じ補助になる。
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
#   - 補助が外部の道具（いまは tmux と、tmux に起動させる /bin/zsh）を呼ぶときは、実行ファイルは決め打ちの絶対パス、渡す環境変数は
#     名前を挙げたものだけにする（PATH と、呼び出し元の環境まるごとからは決めない）。
#   - 補助へ渡す引数は、この入口の場所（書かれたままの $0。--tmux の画面の中の親が、同じ入口を呼び直すのに使う）と、受け取った引数だけ。
#     --tmux の引数の読み取りは、補助の側で行う（シェルの側に分岐を足さない）。
set -euo pipefail
: "${1:?launch.log}"
(( $# >= 2 )) || { print -u2 -- "usage: detach-run.sh <launch.log> <cmd> [args...]"; exit 2; }
# 補助の python3 を位置引数の先頭に置く（この先は $1 = 補助、$2 = 起動ログ、$3 以降 = コマンド）。
# 候補はこの 2 つだけで、前から順に、最初にある「普通のファイルで実行できる」ものを使う（Mac の Command Line Tools の実体 → OS の入口）
set -- /Library/Developer/CommandLineTools/usr/bin/python3 "$@"
[[ -f "$1" && -x "$1" ]] || set -- /usr/bin/python3 "${@:2}"
[[ -f "$1" && -x "$1" ]] || { print -u2 -- "ERROR: 切り離しに使う python3 が決まった場所（/Library/Developer/CommandLineTools/usr/bin/python3・/usr/bin/python3）に無いので起動しない。PATH の python3 は使わない（Mac は xcode-select --install、Linux は OS の python3 を入れる）" || :; exit 2; }
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

def say(text):
    """文言を標準エラーへ出す。この python3 は空の環境で動き、ロケールが C になるので、UTF-8 のバイト列で直に書く。
    標準エラーが閉じているなどで書けなくても、止めない（呼び出し側が決めた終了コードを、そのまま返す）。"""
    try:
        os.write(2, (text + "\n").encode("utf-8"))
    except OSError:
        pass

# ---- ここから --tmux（tmux の画面の中に居続ける親から起動する）。付けない起動は、この区切りの中を通らない ----
# tmux の場所。前から順に、最初にある実行できるファイルを使う（PATH からは探さない。環境変数・設定・引数では受け取らない）
TMUX_BINS = ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux")
# 画面の中の親とのやり取りを終えるまでの上限（秒）。tmux がセッションを作って親が動き出すまでの時間で、コマンドの実行時間ではない
HANDSHAKE_SECONDS = 20
# 画面の側の上限は、呼び出し元より長くする（呼び出し元が上限まで待っている途中で、画面の側が先に諦めない）
PANE_SECONDS = HANDSHAKE_SECONDS + 5
# 門を開けた後、コマンドへ切り替わった結果を待つ上限（秒）。過ぎたら、起動したものとして扱う（門はもう開いている）
RESULT_SECONDS = 10
# 1 つ目の引数がこのどれかのときだけ、--tmux の経路に入る（--tmux-pane は、画面の中の親としての起動。このスクリプトが自分で呼ぶ）
TMUX_WORDS = ("--tmux", "--linger", "--tmux-pane")
TMUX_USAGE = ("usage: detach-run.sh --tmux <セッション名> [--linger <秒>] <launch.log> <cmd> [args...]\n"
              "  セッション名は英数と _ -（先頭は英数・100 字まで）。--linger は 0〜86400 の整数の秒（既定 600）")

class Refused(Exception):
    """--tmux の起動をやめる理由。決まった文言だけを持つ（引数・環境変数・パス・例外の本文は持たない）"""

class Launched:
    """--tmux で起動したコマンド（subprocess.Popen の結果の代わりに返す。使うのは pid だけ）"""
    def __init__(self, pid):
        self.pid = pid

def recv_exact(conn, size):
    """ソケットから、ちょうど size バイト読む。その前に相手が居なくなったら EOFError"""
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data

def tmux_options():
    """--tmux <セッション名> [--linger <秒>] を読んで引数から外し、コマンドを起動する関数（subprocess.Popen の代わり）を返す。
    使い方の誤り・tmux が無いときは、決まった文言を出して exit 2（ここまでに、フォルダもファイルも作っていない）"""
    session = sys.argv[2] if sys.argv[1] == "--tmux" else ""
    rest, linger = sys.argv[3:], "600"
    if rest[:1] == ["--linger"]:
        linger, rest = "".join(rest[1:2]), rest[2:]
    alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    if not (0 < len(session) <= 100 and session[0] in alnum and all(c in alnum + "_-" for c in session)
            and 0 < len(linger) <= 5 and all(c in "0123456789" for c in linger) and int(linger) <= 86400
            and len(rest) >= 2 and rest[0] not in TMUX_WORDS):
        say(TMUX_USAGE)
        sys.exit(2)
    tmux = next((path for path in TMUX_BINS if os.path.isfile(path) and os.access(path, os.X_OK)), None)
    if tmux is None:
        say("ERROR: tmux が決まった場所（" + "・".join(TMUX_BINS) + "）に無いので起動しない。PATH の tmux は使わない（--tmux を外すか、tmux を入れる）")
        sys.exit(2)
    sys.argv[1:] = rest
    return lambda *args, **plain: tmux_launch(tmux, session, int(linger), *args, **plain)

def tmux_launch(tmux, session, linger, cmd, stdout, env, **plain):
    """--tmux のときに subprocess.Popen の代わりに呼ぶ（引数の形は同じ。stdout は開いた起動ログ、env は呼び出し元の環境変数）。
    tmux のセッションを作り、その画面の中の親（この入口の --tmux-pane）に子を門の前で待たせてから、門を開けて、起動した pid を返す。
    門を開ける（合図を書く）のはここだけ。開ける前に止められた・失敗したときは、合図を書かずに口を閉じる（子はコマンドを始めずに終わる）。
    作ったセッションを閉じる操作はしない（口が閉じたのを見て、画面の中の親が自分で終わる。ほかのセッションを指す操作が無い）。"""
    # 止める合図（呼び出し元が無視にしていないもの）は、待っている所（waiting）でだけ受け付ける。フォルダを作る・片付ける・
    # 門を開ける間は受け付けない（pthread_sigmask は、届いていた合図のハンドラを自分の中で動かすので、例外はそこから出る）。
    # 待っている所では、入ったときの集合に戻す（呼び出し元がもともと止めていたシグナルを、ここで外さない）
    stops = [s for s in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM) if signal.getsignal(s) != signal.SIG_IGN]
    # 呼び出し元が無視にしていたシグナル（子に引き継ぐ。PIPE と XFSZ は python3 が自分で無視にするもので、Popen は子で既定に戻す）
    ignored = [s for s in range(1, signal.NSIG)
               if signal.getsignal(s) == signal.SIG_IGN and s not in (signal.SIGPIPE, signal.SIGXFSZ)]
    before = signal.pthread_sigmask(signal.SIG_BLOCK, stops)
    stopped = []
    def stop(signum, frame):
        if not stopped:
            stopped.append(signum)
            raise Refused("止める合図（シグナル）を受けたので起動しない")
    for signum in stops:
        signal.signal(signum, stop)
    def waiting(call, *args):
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, before)
            return call(*args)
        finally:
            signal.pthread_sigmask(signal.SIG_BLOCK, stops)
    deadline = time.monotonic() + HANDSHAKE_SECONDS
    left = lambda: max(deadline - time.monotonic(), 0.05)
    work = wfd = srv = conn = here = log_r = None
    def tidy():
        """受け渡しのフォルダとソケットを消す（自分が作ったものだけ。ソケットは、開いたフォルダを基準に消す）"""
        nonlocal work, wfd
        if wfd is not None:
            try:
                os.unlink("s", dir_fd=wfd)
            except OSError:
                pass
            os.close(wfd)
        if work is not None:
            try:
                os.rmdir(work)
            except OSError:
                pass
        work = wfd = None
    reason = answer = None
    try:
        # 作業場所は、開いた fd のまま子へ渡す（画面の側はパスで開かない。消したフォルダでも、開ければ今までどおり起動できる）。
        # 入口と受け渡しのフォルダは、相対のときだけ今の場所につないで絶対にする（文字列の上で .. は畳まない）
        try:
            here = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
            entry = script if os.path.isabs(script) else os.path.join(os.getcwd(), script)
            base = env.get(b"TMPDIR") or b"/tmp"
            base = base if os.path.isabs(base) else os.path.join(os.getcwdb(), base)
        except OSError:
            raise Refused("作業場所を開けないので起動しない（--tmux は、読めないフォルダからは起動できない）") from None
        mask = os.umask(0o077)
        os.umask(mask)
        # 受け渡しのフォルダ（自分だけが読める）とソケット。TMPDIR があればその下、無ければ /tmp（ほかの場所へは逃がさない）。
        # ソケットのパスには長さの上限（約 100 バイト）があるので、開いたフォルダへ移ってから相対の名前で作る
        try:
            path = os.path.join(base, b"lanes-detach-" + os.urandom(8).hex().encode())
            os.mkdir(path, 0o700)
            work = path
            wfd = os.open(work, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            os.fchdir(wfd)
            try:
                srv.bind("s")
            finally:
                os.fchdir(here)
            srv.listen(1)
        except OSError:
            raise Refused("受け渡しの一時フォルダ（TMPDIR があればその下。無ければ /tmp）を作れないので起動しない") from None
        # tmux へ渡す環境変数は、名前を挙げたこれだけ（呼び出し元の環境まるごとは渡さない）。サーバーがまだ無いと、tmux はこの環境を
        # サーバーの既定にして、利用者が後で開くウィンドウへも渡す。設定ファイルの場所（HOME）・既定のシェル・PATH を呼び出し元の値で
        # 決めさせない（HOME と USER は OS のユーザー情報から、PATH は決め打ち。SHELL は渡さない = OS のユーザー情報のシェルになる）。
        # 呼び出し元から受け取るのは、サーバーの場所（TMUX_TMPDIR）と文字コード（LANG）だけ
        tmux_env = {b"PATH": os.fsencode(os.path.dirname(tmux)) + b":/usr/bin:/bin:/usr/sbin:/sbin"}
        try:
            me = pwd.getpwuid(os.getuid())
            tmux_env.update({b"HOME": os.fsencode(me.pw_dir), b"USER": os.fsencode(me.pw_name), b"LOGNAME": os.fsencode(me.pw_name)})
        except KeyError:
            pass
        tmux_env.update({name: env[name] for name in (b"TMUX_TMPDIR", b"LANG") if name in env})
        def tmux_run(*args):
            # 作業場所は /（サーバーを立ち上げたとき、サーバーが呼び出し元の作業場所を掴み続けない）。出力は読まない
            return subprocess.run([tmux, *args], env=tmux_env, cwd="/", stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=left()).returncode
        # 画面の中の親は、同じ入口を呼び直す（tmux のサーバーの環境は、入口が exec -c で捨てる）。コマンドを複数の引数で渡すので、
        # tmux は既定のシェルを通さずに直に実行する。利用者の設定が「終わった画面を残す」でも、このセッションは終わったら閉じる
        pane = ["/bin/zsh", "-f", entry, "--tmux-pane", os.fsdecode(work)]
        for number in range(1, 10):
            name = session if number == 1 else "%s-%d" % (session, number)
            if waiting(tmux_run, "new-session", "-d", "-s", name, "--", *pane, ";", "set-option", "-w", "remain-on-exit", "off") == 0:
                break
            if waiting(tmux_run, "has-session", "-t", "=" + name) != 0:
                raise Refused("tmux のセッションを作れないので起動しない")
        else:
            raise Refused("同じ名前の tmux のセッションが多すぎるので起動しない（終わったセッションを閉じるか、別の名前にする）")
        srv.settimeout(left())
        conn = waiting(srv.accept)[0]
        tidy()   # つながったので、受け渡しのフォルダはもう要らない
        # 画面へ流す読み口は、渡す直前に開いて、子へ渡す書き口と同じものか確かめる（別のファイルの中身を画面へ流さない）。
        # 画面の側は、起動ログも作業場所もパスでは開かない（ここで開いた fd をそのまま使う）
        try:
            log_r = os.open(log, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            os.lseek(log_r, 0, os.SEEK_END)   # 見出しの後ろ（今回の分）から流す
            same = os.path.samestat(os.fstat(log_r), os.fstat(stdout.fileno()))
        except OSError:
            same = False
        if not same:
            raise Refused("起動ログを読めない、または開いた後で別のものに置き換わったので起動しない（--tmux は、起動ログの続きを画面に流す）")
        body = b"\0".join([b"%d" % linger, b"%d" % mask, b",".join(b"%d" % s for s in ignored), b"%d" % len(cmd)]
                          + [os.fsencode(part) for part in cmd] + [key + b"=" + value for key, value in env.items()])
        def exchange():
            conn.settimeout(left())
            conn.sendmsg([b"F"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                   b"".join(fd.to_bytes(4, sys.byteorder) for fd in (stdout.fileno(), log_r, here)))])
            conn.sendall(b"%020d" % len(body) + body)
            return int(recv_exact(conn, 20))
        pid = waiting(exchange)
        # ここで門を開ける。止める合図はもう受け付けていない（waiting の外）。期限を過ぎていたら開けない。開けた後は取り消さない
        if time.monotonic() >= deadline:
            raise TimeoutError
        conn.sendall(b"A")
        # 子は、門を通ったら G を書いてからコマンドへ切り替わる（切り替わると口が閉じる）。切り替われなかったら F を書く。
        # 期限まで何も分からないときは、起動したものとして扱う（門はもう開いているので、失敗を返すと「動いているのに失敗」になる）
        conn.settimeout(RESULT_SECONDS)
        answer = b""
        try:
            while b"F" not in answer:
                chunk = conn.recv(8)
                if not chunk:
                    break
                answer += chunk
        except socket.timeout:
            answer = answer or b"G"
        except OSError:
            pass
        if not answer:
            raise EOFError   # 通った印が無いまま口が閉じた（子が居なくなった。コマンドは始まっていない）
    except Refused as refused:
        reason = refused.args[0]
    except (OSError, EOFError, ValueError, subprocess.SubprocessError):
        reason = "tmux の画面の側（画面の中の親と、その子）とやり取りできないので起動しない（コマンドは始まっていない）"
    finally:
        # 口を閉じる（合図を受け取っていない子は、これを見てコマンドを始めずに終わる）
        for sock in (conn, srv):
            if sock is not None:
                sock.close()
        for fd in (log_r, here):
            if fd is not None:
                os.close(fd)
        tidy()
    if reason is not None:
        say("ERROR: " + reason)
        sys.exit(2)
    if answer != b"G":
        # コマンドへ切り替われなかった。付けない起動と同じ文言・終了コードにする（呼び出し側の except が出す）
        raise OSError("コマンドを起動できない")
    if number > 1:
        say("NOTE: 同じ名前の tmux のセッションがあるので、名前の後ろに -%d を付けたセッションを作った" % number)
    return Launched(pid)

def gated_child(conn, status, log_w, here, mask, ignored, cmd, env):
    """画面の中の親が fork した子。付けない起動（subprocess.Popen）と同じ形（新しいセッション・同じ作業場所と umask・標準入力は
    /dev/null・出力は起動ログ・ほかの fd は閉じる）に整えてから、自分の pid を呼び出し元へ知らせて、門で待つ。
    合図（A）が来たら、通った印（G）を書き、シグナルの扱いを呼び出し元と同じにして、コマンドへ切り替わる（切り替わると口は閉じる）。
    合図が来ないまま口が閉じたら、コマンドを始めずに終わる。期限が来た・切り替われなかったら、失敗の印（F）を書いて終わる。
    この関数からは戻らない。"""
    try:
        os.setsid()
        os.fchdir(here)
        os.umask(mask)
        os.dup2(os.open(os.devnull, os.O_RDWR), 0)
        os.dup2(log_w, 1)
        os.dup2(log_w, 2)
        # 0・1・2 のほかの fd は、ここで全部閉じる（受け取った fd も、画面の中の親が受け継いでいたものも。Popen の close_fds と同じ）
        for name in os.listdir("/dev/fd"):
            if int(name) > 2 and int(name) not in (conn.fileno(), status):
                try:
                    os.close(int(name))
                except OSError:
                    pass
        conn.sendall(b"%020d" % os.getpid())
        if conn.recv(1) != b"A":
            os._exit(0)
        for fd in (status, conn.fileno()):
            try:
                os.write(fd, b"G")
            except OSError:
                pass
        # シグナルの扱いは、切り替わる直前に整える（PIPE を既定に戻すと、相手の居ない口へ書いただけで終わってしまう）
        for signum in range(1, signal.NSIG):
            try:
                signal.signal(signum, signal.SIG_IGN if signum in ignored else signal.SIG_DFL)
            except (OSError, ValueError, RuntimeError):
                pass
        os.execvpe(cmd[0], cmd, env)
    except BaseException:
        pass
    for fd in (status, conn.fileno()):
        try:
            signal.signal(signal.SIGPIPE, signal.SIG_IGN)
            os.write(fd, b"F")
        except BaseException:
            pass
    os._exit(127)

def tmux_pane(work):
    """--tmux で作った画面の中の親（このスクリプトが tmux 経由で自分を呼ぶ。手では呼ばない）。呼び出し元のソケットへつなぎ、
    起動ログ（書き口・読み口）と作業場所の fd、コマンド、環境変数を受け取り、子を門の前で待たせる。子がコマンドへ切り替わったら、
    画面に pid と起動ログの続きを流し、コマンドが終わったら終了コードを出して、少し待ってから終わる（終わるとセッションが閉じる）。
    門を開けるのは呼び出し元だけで、この親は子を止めない。受け渡しのフォルダには触らない（消すのは作った側）。"""
    try:
        # この起動の環境変数の写し（tmux のサーバーのもの）は使わない。子には呼び出し元のものを渡す。読まずに閉じる
        # （開けたままだと、写しが大きいとき、入口のシェルが残した書き手が、画面の下で待ち続ける）
        os.close(3)
    except OSError:
        pass
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(PANE_SECONDS)
        os.chdir(work)
        conn.connect("s")
        os.chdir("/")
        mark, extra = conn.recvmsg(1, socket.CMSG_SPACE(3 * 4))[:2]
        raw = extra[0][2] if mark == b"F" and len(extra) == 1 and extra[0][:2] == (socket.SOL_SOCKET, socket.SCM_RIGHTS) else b""
        log_w, log_r, here = [int.from_bytes(raw[i:i + 4], sys.byteorder) for i in range(0, len(raw), 4)]
        parts = recv_exact(conn, int(recv_exact(conn, 20))).split(b"\0")
        linger, mask, count = int(parts[0]), int(parts[1]), int(parts[3])
        ignored = {int(s) for s in parts[2].split(b",") if s}
        cmd, env = parts[4:4 + count], dict(pair.partition(b"=")[::2] for pair in parts[4 + count:])
        status, status_w = os.pipe()
        pid = os.fork()
    except (OSError, EOFError, ValueError, IndexError):
        say("ERROR: 画面の中の親を始められない（--tmux-pane は、このスクリプトが自分で呼ぶもの。引数・例外本文は非表示）")
        return 2
    if pid == 0:
        gated_child(conn, status_w, log_w, here, mask, ignored, cmd, env)   # 戻らない
    conn.close()   # 呼び出し元とやり取りするのは子だけ（この親が居なくなっても、門が開くかどうかは変わらない）
    for fd in (status_w, log_w, here):
        os.close(fd)
    # 子が門を通ったか（G）・切り替われなかったか（F）を、子が口を閉じるまで読む（コマンドへ切り替わると、口は閉じる）
    outcome = b""
    while True:
        chunk = os.read(status, 16)
        if not chunk:
            break
        outcome += chunk
    os.close(status)
    if outcome != b"G":
        os.waitpid(pid, 0)   # コマンドを始めずに終わった子を回収する
        return 2
    # 画面のキー（Ctrl-C・Ctrl-\・Ctrl-Z）で、この親は止まらない（子はもう別のセッションで動いていて、この設定を引き継がない）
    for signum in (signal.SIGINT, signal.SIGQUIT, signal.SIGTSTP):
        signal.signal(signum, signal.SIG_IGN)
    def show(data):
        try:
            while data:
                data = data[os.write(1, data):]
        except OSError:
            sys.exit(0)   # 画面が無くなった。起動したコマンドはそのまま動く
    def drain():
        while True:
            try:
                chunk = os.read(log_r, 65536)
            except OSError:
                return
            if not chunk:
                return
            show(chunk)
    show(("lanes: 起動した pid %d。この画面を閉じても、Ctrl-C を押しても、起動したコマンドは止まらない（止めるのは kill %d）。"
          "以下は起動ログの続き\n" % (pid, pid)).encode("utf-8"))
    code = None
    while code is None:
        drain()
        # 終わった子を 1 つずつ回収する（入口のシェルが残した、環境の写しと本文を流し終えた子も。終わったまま画面の下に残さない）
        done, ended = os.waitpid(-1, os.WNOHANG)
        if done == pid:
            code = ended
        elif not done:
            time.sleep(0.2)
    drain()
    code = os.WEXITSTATUS(code) if os.WIFEXITED(code) else 128 + os.WTERMSIG(code)
    show(("\n=== 終了: 終了コード %d。この画面は %d 秒後に閉じる ===\n" % (code, linger)).encode("utf-8"))
    time.sleep(linger)
    return 0

# この入口（detach-run.sh）の場所。シェルが 1 つ目の引数で渡す（--tmux のとき、画面の中の親が同じ入口を呼び直すのに使う）
script = sys.argv.pop(1)
# コマンドを起動する関数。--tmux を付けない起動は、今までどおり subprocess.Popen
start = subprocess.Popen
if sys.argv[1] in TMUX_WORDS:
    import pwd, signal, socket, time
    if sys.argv[1] == "--tmux-pane":
        try:
            sys.exit(tmux_pane(sys.argv[2]))
        except Exception:
            sys.exit(2)   # 例外の本文を画面に出さない
    start = tmux_options()
# ---- ここまで --tmux ----
log, cmd = Path(sys.argv[1]), sys.argv[2:]

# 起動ログのフォルダは、ここで作る（シェルの側では作らない。補助の前に外部コマンドを呼ばないため）。パスと例外の本文は出さない。
# 作るフォルダは、書かれたままの引数から求める（末尾の / を除いた、最後の / より前。/ が無ければ今の場所）。Path は末尾の /. を
# 落とすので、log.parent から求めると、<ファイル>/. や /dev/null/. が「そのファイルを起動ログにする」指定として通ってしまう
# 切り出した親は Path で整えてから作る（main の mkdir -p と同じく、親の中の余分な . を落とす。行き先の無いリンクの下の <リンク>/./x.log を
# 「作れた」ことにして先へ進まない）
try:
    Path(os.path.dirname(sys.argv[1].rstrip("/") or "/") or ".").mkdir(parents=True, exist_ok=True)
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
        p = start(
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
exec -c "$1" -I -S - "$0" "${@:2}" 3< <(detach_env_dump) < <(detach_py_source)
