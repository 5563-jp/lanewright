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
"""
import os
import subprocess
import sys


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
    while True:
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
