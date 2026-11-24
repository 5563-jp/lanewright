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

from lanes_monitor import RUNS, discover_worktrees, mtime, watch_summary

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


def non_negative(value):
    try:
        number = float(value)
        if not math.isfinite(number) or number < 0:
            raise ValueError()
        return number
    except ValueError:
        raise argparse.ArgumentTypeError("0 以上の有限数を指定する") from None


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


def run_mark(path):
    """その実行の .pid を見分ける印（更新時刻とファイルの番号）。読めない・symlink なら None。
    ランチャは回し直すたびに前の .pid を退避して新しく作るので、更新時刻が同じ（秒までしか残らない保存先）でも、ファイルの番号で別の実行と分かる。"""
    try:
        if os.path.islink(path):
            return None
        status = os.stat(path, follow_symlinks=False)
        return status.st_mtime, status.st_ino
    except OSError:
        return None


def finished_lanes():
    """終わったレーン（.done が .pid 以降に書かれたもの）と、その実行の印（run_mark）。読むだけで、何も書かない。
    見るのはフォルダの一覧と更新時刻だけ（作業ツリー 200・レーン 700 ほどで 1 回 0.1 秒ほど）。
    印に .done の時刻は使わない。同じ実行の .done が書き換わっただけでは「新しく終わった」とみなさず、
    同じ label を回し直した実行は、.done の時刻の前後に関係なく別の実行として見分けるため。
    .pid を読めなかった label（一覧を取った後に退避された、など）は、その回は数えない（前の実行の .done が残っていても、
    読めなかった印で「別の実行が終わった」とみなさない）。"""
    finished = {}
    for worktree, labels in discover_worktrees():
        for label in labels:
            mark = run_mark(os.path.join(worktree, "logs", label + ".pid"))
            if mark is None:
                continue
            done = mtime(os.path.join(worktree, "logs", label + ".done"))
            if done and done >= mark[0]:
                finished[worktree, label] = mark
    return finished


def finished_baseline(quick):
    # 見回りの直前に取る。取った後に終わったレーンは、見回りが拾っていても次の軽い確認でもう一度見回る
    # （見回りが 1 回増えるだけで、既読の判定は lanes-monitor がするので二重には知らせない。逆の順だと取りこぼす）
    if not quick:
        return None
    try:
        return finished_lanes()
    except OSError:
        return None


def wait_next(until, baseline, quick):
    """次の見回りの時刻まで待つ。quick が正なら、その間隔で「baseline の後に終わったレーンがあるか」だけを軽く見て、
    あれば待ちを切り上げる（判定はしない。すぐ次の見回りを回して lanes-monitor に任せる）。
    「baseline の後に終わった」は、baseline に無いレーンが終わっている（初めて終わった）か、同じ label の別の実行が終わっている、のどちらか。
    軽い確認が読めないときは、その回はいつもの間隔の見回りだけに戻す。"""
    while True:
        remaining = until - time.monotonic()
        if remaining <= 0:
            return
        if not quick or baseline is None:
            time.sleep(remaining)
            return
        time.sleep(min(quick, remaining))
        if until - time.monotonic() <= 0:
            return   # 次の見回り（か打ち切り）の時刻になった。最後の軽い確認は要らない
        try:
            if any(baseline.get(lane) != run for lane, run in finished_lanes().items()):
                return
        except OSError:
            baseline = None


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
            baseline = finished_baseline(args.quick_interval)
            # 残り時間は、基準を取った後で求める（基準を取っている間に全体の上限を越えたら、見回りを起動せずに打ち切る）
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
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
            wait_next(min(deadline, tick + args.interval), baseline, args.quick_interval)
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
    parser = argparse.ArgumentParser(description="5 分監視（その間も、終わったレーンの有無だけは --quick-interval 秒ごとに軽く見て、あればすぐ見回る）/ "
                                                 "定期の生存確認（既定 10 分ごと。LANES_CHECK_INTERVAL_MIN）。作業レーンは自動起動しない。")
    parser.add_argument("--until-wake", action="store_true")
    parser.add_argument("--interval", type=positive, default=300)
    parser.add_argument("--quick-interval", type=non_negative, default=5,
                        help="見回りの合間に、終わったレーン（新しい .done）の有無だけを見る間隔（秒）。0 で無効（--interval ごとの見回りだけ）")
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
