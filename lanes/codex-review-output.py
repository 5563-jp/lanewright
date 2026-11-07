#!/usr/bin/env python3
"""Codex の完了イベントと最終本文を取り出す。実行コマンド・中間出力は保存しない。"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time


def open_logdir(log, proof):
    """書き込み先の logs/ を子の起動前に開いておく。symlink は開かない。
    子が実行中に logs/ を symlink や別のフォルダに差し替えても、差し替え先へは書かない（開いたフォルダへ書く）。"""
    if log.parent != proof.parent:
        raise ValueError("log と proof は同じフォルダに置く")
    return os.open(log.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def write_at(dfd, name, data):
    """開いておいたフォルダの中で、新しい一時ファイルに書いてから名前を置き換える。
    置き換えは名前だけを付け替えるので、元の名前が symlink やハードリンクでも、その先のファイルは書き換えない。"""
    tmp = f".{name}.{os.getpid()}.{time.monotonic_ns()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=dfd)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dfd)
        except OSError:
            pass
        raise


def main():
    log, proof = map(pathlib.Path, sys.argv[1:3])
    dfd = open_logdir(log, proof)
    body = ""
    started = completed = invalid = False
    heartbeat = 0
    # stderr はランチャの非公開ログへ流す。JSONL のコマンド・環境は転記しない。
    with subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          text=True, encoding="utf-8", errors="strict") as child:
        try:
            for line in child.stdout:
                # 中間のコマンド本文は残さず、受信時刻だけで無出力の誤判定を防ぐ。
                now = time.monotonic()
                if now - heartbeat >= 1:
                    write_at(dfd, proof.name, (json.dumps({"completed": False, "received_at": time.time()}) + "\n").encode("utf-8"))
                    heartbeat = now
                try:
                    event = json.loads(line)
                    kind = event["type"]
                    if completed:
                        invalid = True
                    if kind == "turn.started":
                        if started:
                            invalid = True
                        started = True
                    elif kind == "turn.completed":
                        completed = started
                    elif kind in ("turn.failed", "error"):
                        invalid = True
                    elif kind == "item.completed":
                        item = event["item"]
                        if item["type"] == "agent_message":
                            if not started or not isinstance(item.get("text"), str):
                                invalid = True
                            else:
                                body = item["text"]
                        elif item["type"] == "error":
                            invalid = True
                except (ValueError, KeyError, TypeError):
                    invalid = True
        except UnicodeError:
            invalid = True
            # 壊れた出力も最後まで消費し、子をパイプ待ちに残さない。
            child.stdout.close()
        rc = child.wait()
    # 改行変換を挟まずバイト列で書き、同じバイト列のハッシュを証明にする（読む側も read_bytes で照合）。
    data = body.encode("utf-8")
    write_at(dfd, log.name, data)
    write_at(dfd, proof.name, (json.dumps({"completed": bool(completed and not invalid and rc == 0 and body.strip()),
                                           "sha256": hashlib.sha256(data).hexdigest()}) + "\n").encode("utf-8"))
    return rc if rc > 0 else 128 - rc if rc < 0 else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        print("ERROR: レビューの完了イベントを取得できない", file=sys.stderr)
        sys.exit(3)
