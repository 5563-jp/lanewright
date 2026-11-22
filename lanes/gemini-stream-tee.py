#!/usr/bin/env python3
"""agy の標準出力（stream-json）をパイプで受け取り、そのまま自分の標準出力（ランチャが logs/<label>.json へ向ける）へ書く受け取り役。

使い方（gemini-agy.zsh の run_agy_once が監督役の下で起動する。run-gemini.sh と run-gemini-review.sh で共通）:
    python3 gemini-stream-tee.py -- <agy のコマンド...>

- 受け取った順にバイト列のまま書く（行の区切り・文字コードは変えない。壊れた行も壊れたまま監査へ渡す）。
  書くたびに出力先の更新時刻が進むので、ランチャの無出力の見張りはこの更新時刻を見る。
- agy の標準入力は /dev/null、標準エラーはこの受け取り役と同じ先（ランチャの logs/<label>.stderr.log）。
- agy の終了は、標準出力のパイプの終端とは別に見張る。agy が起動した補助のプロセスが標準出力を受け継いだまま残ると、agy が
  終わってもパイプは閉じない（読み続けると、正常な result が届いていても終われず、外側の監督役も子孫の回収に進めない）。
  agy が終わったら、パイプに残った出力を最大 DRAIN_SEC 秒だけ受け取ってから終わる（パイプの終端が先に来ればそこで終わる）。
  この受け取り役が終わると、外側の監督役（_common.sh の LANES_PROCESS_GUARD）が残った子孫を止めて回収する。
- 終了コードは agy のまま（シグナルで止まったら 128+番号）。agy を起動できない・出力先へ書けないときは 3。
  コマンドの引数（指示書の全文を含む）は、エラーにも書き出さない。
"""
import os
import selectors
import subprocess
import sys
import time

# agy の終了後に、パイプに残った出力を受け取る上限（秒）。agy が終わる前に書いた分はパイプの中にあるので、すぐに読み終わる
DRAIN_SEC = 2.0


def write_all(fd, data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        print("使い方: gemini-stream-tee.py -- <コマンド...>", file=sys.stderr)
        return 2
    try:
        child = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    except Exception:
        print("ERROR: agy を起動できない", file=sys.stderr)
        return 3
    out = sys.stdout.fileno()
    out_ok = True
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
        if out_ok:
            try:
                write_all(out, chunk)
            except OSError:
                # 書けなくなっても agy の出力は最後まで受け取る（パイプが詰まって agy が止まらないように）
                out_ok = False
    sel.close()
    # 読み口を閉じる（残った補助のプロセスがこのパイプへ書いても、もう受け取らない）
    child.stdout.close()
    rc = child.wait()
    if not out_ok:
        print("ERROR: agy の出力を logs/ へ書けなかった", file=sys.stderr)
        return 3
    return rc if rc > 0 else 128 - rc if rc < 0 else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # コマンドの引数（指示書の全文）や例外の本文は書き出さない
        print("ERROR: agy の出力を受け取れない", file=sys.stderr)
        sys.exit(3)
