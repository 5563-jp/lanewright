"""lanes-watch.sh の本体。監視だけを実行し、次の作業は親が判断する。"""
import argparse
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from lanes_monitor import RUNS, watch_summary

# 監視の心拍がこれより古ければ止まったとみなす（5 分の見回りの 3 回分。定期の確認の間隔とは別）
STALE_SECONDS = 15 * 60
# --until-wake が終わるときの最後の行。1 行目（WAKE: / 打ち切り）の読み取りには混ざらない。
# 終わった時点で見張りは止まっているので、司令塔は次工程を判断する前にかけ直す
REARM = "RE-ARM: 監視は止まった。次工程を判断する前に lanes-watch.sh --until-wake をバックグラウンドでかけ直す"


def positive(value):
    try:
        number = float(value)
        if not math.isfinite(number) or number <= 0:
            raise ValueError()
        return number
    except ValueError:
        raise argparse.ArgumentTypeError("正の有限数を指定する") from None


def identity(pid):
    # 引数・環境は取得しない。番号再利用や終了済みのプロセスを生存扱いしない。
    try:
        result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart=", "-o", "stat="],
                                env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
                                capture_output=True, text=True, timeout=5)
        fields = result.stdout.split()
        if result.returncode == 0 and len(fields) == 6 and not fields[-1].startswith("Z"):
            return " ".join(fields[:5])
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def write_heartbeat(path, started, result):
    data = {"epoch": time.time(), "time": datetime.datetime.now().astimezone().isoformat(),
            "pid": os.getpid(), "lstart": started, "result": result.splitlines()[0][:500]}
    temporary = None
    try:
        # 読み手が途中までの JSON を拾わないように、同じ場所で置き換える。
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(data, stream, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def check(path):
    result, code = "WATCH DEAD", 1
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        pid, epoch = data["pid"], data["epoch"]
        if (type(pid) is not int or pid <= 1 or type(epoch) not in (int, float)
                or not math.isfinite(epoch) or not isinstance(data.get("lstart"), str)):
            raise ValueError()
        age = int(time.time() - epoch)
        if data["lstart"] and identity(pid) == data["lstart"]:
            if 0 <= age <= STALE_SECONDS:
                result, code = f"WATCH OK age={age} pid={pid}", 0
            else:
                result = f"WATCH STALE age={age} pid={pid}"
    except (OSError, ValueError, KeyError, TypeError):
        pass
    print(result, flush=True)
    watch_summary()
    return code


STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


class Stopped(Exception):
    def __init__(self, signum):
        self.signum = signum


def ignore_stop_signals():
    for signum in STOP_SIGNALS:
        signal.signal(signum, signal.SIG_IGN)


def stop(signum, _frame):
    # 停止処理の途中に届く 2 回目以降のシグナルで後片付けを中断させない。
    if signal.getsignal(signum) == signal.SIG_IGN:
        return
    ignore_stop_signals()
    raise Stopped(signum)


def run_monitor(monitor, timeout):
    # monitor が途中で止まっても、今回作った集団だけを回収する。
    process = subprocess.Popen(["zsh", "-f", str(monitor), "--no-append"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, _ = process.communicate(timeout=timeout)
        return process.returncode, stdout
    except BaseException:
        try:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            process.communicate(timeout=1)
        except BaseException as exc:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                process.communicate()
            except BaseException:
                process.communicate()
                raise
            if not isinstance(exc, subprocess.TimeoutExpired):
                raise
        raise


def watch(args, heartbeat, monitor):
    started = identity(os.getpid())
    if not started:
        print("ERROR: watch の開始時刻を確認できない", file=sys.stderr)
        return 2
    deadline = time.monotonic() + args.max_hours * 3600
    try:
        for signum in STOP_SIGNALS:
            signal.signal(signum, stop)
        write_heartbeat(heartbeat, started, "RUNNING 初回監視中")
        while time.monotonic() < deadline:
            tick = time.monotonic()
            remaining = deadline - tick
            try:
                rc, output = run_monitor(monitor, min(240, remaining))
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    break
                rc, output = 2, ""
            except OSError:
                rc, output = 2, ""
            first = output.splitlines()[0] if output else ""
            if rc or not (first == "QUIET" or first.startswith("WAKE:")):
                first = "WAKE: lanes-monitor の実行失敗（親が確認）"
                write_heartbeat(heartbeat, started, first)
                print(first, flush=True)
                if args.until_wake:
                    print(REARM, flush=True)
                return 2
            write_heartbeat(heartbeat, started, first)
            if not args.until_wake or first.startswith("WAKE:"):
                print(output.rstrip(), flush=True)
            if args.until_wake and first.startswith("WAKE:"):
                print(REARM, flush=True)
                return 0
            time.sleep(max(0, min(deadline, tick + args.interval) - time.monotonic()))
        result = "打ち切り: --max-hours の監視時間を超えたため終了（親が次工程を判断）"
        write_heartbeat(heartbeat, started, result)
        print(result, flush=True)
        if args.until_wake:
            print(REARM, flush=True)
        return 0
    except Stopped as stopped:
        ignore_stop_signals()
        write_heartbeat(heartbeat, started, "停止: シグナルを受信")
        return 128 + stopped.signum
    finally:
        ignore_stop_signals()


def main():
    parser = argparse.ArgumentParser(description="5 分監視 / 定期の生存確認（既定 10 分ごと。LANES_CHECK_INTERVAL_MIN）。作業レーンは自動起動しない。")
    parser.add_argument("--until-wake", action="store_true")
    parser.add_argument("--interval", type=positive, default=300)
    parser.add_argument("--max-hours", type=positive, default=12)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    heartbeat = Path(os.environ.get("LANES_WATCH_HEARTBEAT", str(Path(RUNS) / ".lanes-watch.heartbeat"))).expanduser().absolute()
    if args.check:
        return check(heartbeat)
    monitor = Path(os.environ.get("LANES_WATCH_MONITOR", str(Path(__file__).with_name("lanes-monitor.sh")))).expanduser().absolute()
    heartbeat.parent.mkdir(parents=True, exist_ok=True)
    # core と同じ fcntl 排他。ファイルを消すと別の実体にロックできるため残す。
    # 子へ継承しない。異常終了でも OS が解放し、残ったファイルは再起動を妨げない。
    with heartbeat.with_name(heartbeat.name + ".lock").open("a") as lock:
        try:
            fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("ERROR: lanes-watch は既に実行中（排他ロック取得不可）", file=sys.stderr)
            return 2
        try:
            return watch(args, heartbeat, monitor)
        finally:
            fcntl.lockf(lock, fcntl.LOCK_UN)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError:
        print("ERROR: watch の記録・実行に失敗", file=sys.stderr)
        sys.exit(2)
