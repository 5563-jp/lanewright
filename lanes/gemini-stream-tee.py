#!/usr/bin/env python3
"""agy の標準出力（stream-json）をパイプで直接受け取り、公開用の logs/<label>.json と親専用の写し（標準出力）の両方へそのまま書く。

使い方（gemini-agy.zsh の run_agy_once が監督役の下で起動する）:
    python3 -I gemini-stream-tee.py <logs のフォルダ> <公開用の名前> -- <agy のコマンド...>

- 公開用: logs/ を symlink を辿らずに開き、その中で前からある同じ名前を消してから O_EXCL|O_NOFOLLOW で新しく作る
  （前の実行の子が置いたリンクの先を書かない）。進行中も増えるので、ランチャの無出力の見張りはこの更新時刻を見る。
  子（agy とその子）は logs/ に書けるので、公開用は判定の正本にしない。
- 親専用の写し: 標準出力。ランチャが、子の起動前に作ってすぐ名前を消した一時ファイルを渡す。子は名前で開けないので、
  書き込みの試みの監査と最後の応答（VERDICT）の判定はこちらを読む。
- 受け取った順にバイト列のまま書く（行の区切り・文字コードは変えない。壊れた行も壊れたまま監査へ渡す）。
  公開用に書けなくなっても、親専用の写しへは最後まで書く。親専用の写しへ書けなくなったら、最後まで受け取ってから 3 で終わる。
- agy の標準入力は /dev/null、標準エラーはこの受け取り役と同じ先（ランチャの logs/<label>.stderr.log）。ほかの番号は渡さない。
- 終了コードは agy のまま（シグナルで止まったら 128+番号）。準備に失敗したら agy を起動せずに 3。
  コマンドの引数（指示書の全文を含む）は、エラーにも書き出さない。
- agy の終了は、標準出力のパイプの終端とは別に見張る。agy が起動した補助のプロセスが標準出力を受け継いだまま残ると、agy が
  終わってもパイプは閉じない（読み続けると、正常な result が届いていても無出力で止まり、外側の監督役も子孫の回収に進めない）。
  agy が終わったら、受け取り済みの出力を最大 DRAIN_SEC 秒だけ回収してから終わる（パイプの終端が先に来ればそこで終わる）。
  この受け取り役が終わると、外側の監督役（_common.sh の LANES_PROCESS_GUARD）が残った子孫を止めて回収する。
"""
import os
import selectors
import subprocess
import sys
import time

# agy の終了後に、パイプに残った出力を回収する上限（秒）。agy が終わる前に書いた分はパイプの中にあるので、すぐに読み終わる
DRAIN_SEC = 2.0


def write_all(fd, data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def open_public(logdir, name):
    dfd = os.open(logdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            os.unlink(name, dir_fd=dfd)
        except FileNotFoundError:
            pass
        return os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=dfd)
    finally:
        os.close(dfd)


def main():
    if len(sys.argv) < 5 or sys.argv[3] != "--":
        print("使い方: gemini-stream-tee.py <logs のフォルダ> <公開用の名前> -- <コマンド...>", file=sys.stderr)
        return 2
    logdir, name, cmd = sys.argv[1], sys.argv[2], sys.argv[4:]
    if not name or "/" in name or name in (".", ".."):
        print("ERROR: 公開用の名前が不正", file=sys.stderr)
        return 2
    try:
        public = open_public(logdir, name)
    except OSError:
        print("ERROR: 公開用の stream-json（logs/）を開けない", file=sys.stderr)
        return 3
    private = sys.stdout.fileno()
    try:
        child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    except Exception:
        print("ERROR: agy を起動できない", file=sys.stderr)
        return 3
    private_ok = True
    src = child.stdout.fileno()
    sel = selectors.DefaultSelector()
    sel.register(src, selectors.EVENT_READ)
    exited_at = None
    while True:
        # agy の終了をパイプの終端とは別に見る（補助のプロセスがパイプを持ち続けても、agy が終われば終わる）
        if exited_at is None and child.poll() is not None:
            exited_at = time.monotonic()
        if exited_at is None:
            wait = 0.5
        else:
            wait = DRAIN_SEC - (time.monotonic() - exited_at)
            if wait <= 0:
                break
        try:
            ready = sel.select(wait)
        except InterruptedError:
            continue
        if not ready:
            continue
        try:
            chunk = os.read(src, 1 << 16)
        except InterruptedError:
            continue
        if not chunk:
            break
        if private_ok:
            try:
                write_all(private, chunk)
            except OSError:
                private_ok = False
        if public is not None:
            try:
                write_all(public, chunk)
            except OSError:
                os.close(public)
                public = None
    sel.close()
    # 読み口を閉じる（残った補助のプロセスがこのパイプへ書いても、もう受け取らない）
    child.stdout.close()
    rc = child.wait()
    if public is not None:
        os.close(public)
    if not private_ok:
        print("ERROR: 親専用の写しへ書けなかった（監査できない）", file=sys.stderr)
        return 3
    return rc if rc > 0 else 128 - rc if rc < 0 else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # コマンドの引数（指示書の全文）や例外の本文は書き出さない
        print("ERROR: agy の出力を受け取れない", file=sys.stderr)
        sys.exit(3)
