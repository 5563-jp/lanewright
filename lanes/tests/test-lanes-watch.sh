#!/bin/bash
# 本物のレーンは起動せず、完了通知と差し替え時計で監視の寿命・通知・排他を確認する。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "$(cd "$(dirname "$0")" && pwd -P)/_git-isolate.sh"; lanes_test_git_isolate
python3 -B - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib, io, json, os, pathlib, signal, subprocess, sys, tempfile, time
from types import SimpleNamespace
from unittest import mock

lanes = pathlib.Path(sys.argv[1])
passed = 0
children = []
fixture_processes = {}
WAIT_SECONDS = 30


def check(ok, name):
    global passed
    if not ok:
        raise AssertionError(name)
    passed += 1
    print(f"ok {passed} {name}", flush=True)


def wait_for(condition, name):
    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        value = condition()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise AssertionError(f"待機上限: {name}")
        time.sleep(.02)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def publish(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


scratch = os.environ.get("LANES_SCRATCH") or os.environ["TMPDIR"]
with tempfile.TemporaryDirectory(prefix="watch-test-", dir=scratch) as tmp:
    root = pathlib.Path(tmp)
    heartbeat, ready, reply, child = (root / name for name in ("heartbeat", "ready", "reply", "child"))
    monitor = root / "fake-monitor.sh"
    # 各回の番号を含む記録を一括置換する。存在だけ・空の途中書き込みでは先へ進まない。
    # 子は経過秒数で自然終了させず、回収対象になるまで待機する。
    fake = root / "fake-monitor.py"
    fake.write_text('''import json, os, pathlib, signal, subprocess, sys, time, uuid
root = pathlib.Path(__file__).parent
def publish(name, value):
    path = root / name
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)
token = uuid.uuid4().hex
publish('ready', {'token': token, 'pid': os.getpid()})
deadline = time.monotonic() + 30
while True:
    try:
        response = json.loads((root / 'reply').read_text())
    except (OSError, ValueError):
        response = {}
    if response.get('token') == token:
        break
    if time.monotonic() >= deadline:
        raise SystemExit('模擬 monitor の応答待機上限')
    time.sleep(.02)
action = response['action']
if action == 'quiet': print('QUIET')
elif action == 'wake': print('WAKE: テスト完了'); print('DONE 次工程を親が判断')
elif action == 'failure': print('模擬エラー', file=sys.stderr); sys.exit(7)
elif action == 'invalid': print('想定外の結果')
elif action == 'hang':
    code = "import json,os,pathlib,signal,sys; p=pathlib.Path(sys.argv[1]); t=p.with_suffix('.tmp'); t.write_text(json.dumps({'token':sys.argv[2],'pid':os.getpid()})); t.replace(p); signal.pause()"
    subprocess.Popen([sys.executable, '-B', '-c', code, str(root / 'child'), token]).wait()
else: raise SystemExit('未定義の模擬応答')
''')
    monitor.write_text('#!/bin/zsh -f\nexec "$WATCH_TEST_PYTHON" -B "${0:A:h}/fake-monitor.py"\n')
    env = {**os.environ, "LANES_RUNS_ROOT": str(root / "runs"),
           "LANES_SCRATCH_ROOT": str(root / "scratch"), "LANES_WATCH_HEARTBEAT": str(heartbeat),
           "LANES_WATCH_MONITOR": str(monitor), "WATCH_TEST_PYTHON": sys.executable}
    command = ["zsh", "-f", str(lanes / "lanes-watch.sh")]
    last_token = None
    last_monitor_pid = None

    def start(*args):
        process = subprocess.Popen(command + list(args), env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        children.append(process)
        return process

    def finish(process):
        return process.communicate(timeout=WAIT_SECONDS)

    def run(*args):
        process = start(*args)
        output, error = finish(process)
        return SimpleNamespace(returncode=process.returncode, stdout=output, stderr=error)

    def next_monitor():
        global last_token, last_monitor_pid
        def changed():
            record = read_json(ready)
            return record if record.get("token") != last_token and type(record.get("pid")) is int else None
        record = wait_for(changed, "次の monitor の準備完了")
        last_token = record["token"]
        last_monitor_pid = record["pid"]
        remember_fixture(last_monitor_pid)
        return record

    def respond(action):
        publish(reply, {"token": last_token, "action": action})

    def child_ready():
        def matching():
            record = read_json(child)
            pid = record.get("pid")
            return pid if record.get("token") == last_token and type(pid) is int and pid > 1 else None
        pid = wait_for(matching, "今回の monitor の子が番号を保存")
        remember_fixture(pid)
        return pid

    def remember_fixture(pid):
        # 番号だけを後片付けの根拠にしない。起動時刻と今回の集団を併せて保存する。
        started = watcher.identity(pid)
        try:
            if started and os.getpgid(pid) == last_monitor_pid:
                fixture_processes[pid] = (started, last_monitor_pid)
        except ProcessLookupError:
            pass

    def stop_fixtures(signum):
        # 親が先に終了していても、生存する子から集団の所有を確認して回収する。
        groups = set()
        for pid, (started, group) in fixture_processes.items():
            try:
                if watcher.identity(pid) == started and os.getpgid(pid) == group:
                    groups.add(group)
            except ProcessLookupError:
                pass
        for group in groups:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(group, signum)

    def child_alive(pid):
        result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True,
                                text=True, timeout=WAIT_SECONDS)
        return result.returncode == 0 and result.stdout.strip() and not result.stdout.strip().startswith("Z")

    # 本体は変更せず、このプロセス内だけ時計・監視結果を差し替える。
    # 取り込み時点から探索先を隔離し、本物の _runs は読まない。
    sys.path.insert(0, str(lanes))
    with mock.patch.dict(os.environ, env):
        import lanes_watch as watcher

    try:
        result = run("--check")
        check(result.returncode == 1 and result.stdout.startswith("WATCH DEAD\n"), "記録なしは DEAD")
        check("LANES RUNNING 0" in result.stdout and not heartbeat.exists() and not (root / "runs").exists(), "check は読み取りだけ")
        process = start("--until-wake", "--interval", ".1")
        next_monitor()
        respond("quiet")
        next_monitor()
        initial = read_json(heartbeat)
        check(initial["result"] == "QUIET" and initial["pid"] == process.pid and initial["lstart"]
              and len(heartbeat.read_text().splitlines()) == 1, "heartbeat に時刻・pid・結果を1行で保存")
        first_heartbeat = heartbeat.stat().st_ino
        respond("quiet")
        next_monitor()
        check(read_json(heartbeat)["result"] == "QUIET" and heartbeat.stat().st_ino != first_heartbeat,
              "QUIET 中も次周期の heartbeat を保存")
        result = run("--check")
        check(result.returncode == 0 and result.stdout.startswith("WATCH OK age="), "生きた監視は OK")
        original = read_json(heartbeat)
        duplicate = run("--until-wake", "--interval", ".1")
        check(duplicate.returncode == 2 and "既に実行中" in duplicate.stderr
              and read_json(heartbeat) == original, "二重起動を拒否し記録を保全")

        # 動いている監視の記録は書き換えず、固定時計と別ファイルで境界を確かめる。
        probe = root / "check-heartbeat"
        now = 10000
        for age, expected in ((900, "OK"), (901, "STALE"), (-2, "STALE")):
            publish(probe, {**original, "epoch": now - age})
            with mock.patch.object(watcher, "time", SimpleNamespace(time=lambda: now)), contextlib.redirect_stdout(io.StringIO()) as out:
                code = watcher.check(probe)
            check(code == (0 if expected == "OK" else 1) and out.getvalue().startswith(f"WATCH {expected} age="),
                  f"固定時計で heartbeat の古さ {age} 秒を {expected} と判定")
        publish(probe, {**original, "lstart": "別の開始時刻"})
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = watcher.check(probe)
        check(code == 1 and out.getvalue().startswith("WATCH DEAD"), "番号が同じでも開始時刻が違えば DEAD")
        probe.write_text("壊れた記録")
        with contextlib.redirect_stdout(io.StringIO()):
            check_code = watcher.check(probe)
        check(check_code == 1, "破損した記録は成功扱いしない")
        respond("wake")
        output, error = finish(process)
        check(process.returncode == 0 and output == "WAKE: テスト完了\nDONE 次工程を親が判断\n" + watcher.REARM + "\n" and not error,
              "QUIET は無出力、WAKE 本文で終了し、最後にかけ直しの案内を出す")
        check(read_json(heartbeat)["result"] == "WAKE: テスト完了", "WAKE の結果も保存")
        check(run("--check").stdout.startswith("WATCH DEAD"), "終了した監視は DEAD")
        for kind in ("wake", "failure", "invalid"):
            process = start("--until-wake")
            next_monitor()
            respond(kind)
            output, _ = finish(process)
            if kind == "wake":
                check(process.returncode == 0 and output.startswith("WAKE: テスト完了"), "終了後は同じロックで再起動可能")
            else:
                check(process.returncode == 2 and output.startswith("WAKE: lanes-monitor の実行失敗"), kind + " を親へ通知")

        class Clock:
            def __init__(self):
                self.elapsed = 0
                self.sleeps = []
            def monotonic(self):
                return self.elapsed
            def time(self):
                return now + self.elapsed
            def sleep(self, seconds):
                self.sleeps.append(seconds)
                self.elapsed += seconds

        for kind in ("quiet", "deadline", "monitor-timeout"):
            clock = Clock()
            args = SimpleNamespace(until_wake=True, interval=300, max_hours=600 / 3600)
            if kind == "deadline":
                args.max_hours = .0001
            def tick(_monitor, timeout):
                if kind != "quiet":
                    clock.elapsed += timeout
                    raise subprocess.TimeoutExpired("模擬 monitor", timeout)
                return 0, "QUIET\n"
            handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
            try:
                with mock.patch.object(watcher, "time", clock), mock.patch.object(watcher, "run_monitor", side_effect=tick) as runner, contextlib.redirect_stdout(io.StringIO()) as out:
                    code = watcher.watch(args, heartbeat, monitor)
            finally:
                for signum, handler in handlers.items():
                    signal.signal(signum, handler)
            if kind == "monitor-timeout":
                check(code == 2 and out.getvalue().startswith("WAKE: lanes-monitor の実行失敗"), "全体上限前の monitor 時間超過は失敗通知")
            else:
                check(code == 0 and out.getvalue().startswith("打ち切り:") and out.getvalue().rstrip().endswith(watcher.REARM) and read_json(heartbeat)["result"].startswith("打ち切り:"),
                      kind + " の全体上限を固定時計で検証")
            if kind == "quiet":
                check(clock.sleeps == [300, 300] and runner.call_count == 2, "QUIET の周期と全体上限を実時間待ちなしで検証")
            elif kind == "deadline":
                check(runner.call_args.args[1] == args.max_hours * 3600, "monitor の待機上限を全体の残り時間に制限")

        # 子の準備完了後に待機時間0を渡す。起動に0.36秒以上かかっても同じ回収経路を通る。
        real_popen = subprocess.Popen
        def prepared_monitor(*args, **kwargs):
            pending = real_popen(*args, **{**kwargs, "env": env})
            children.append(pending)
            next_monitor()
            respond("hang")
            child_ready()
            return pending
        # 本体の参照だけを置換し、所有確認に使う ps の起動は差し替えない。
        monitor_subprocess = SimpleNamespace(Popen=prepared_monitor, run=subprocess.run,
                                            TimeoutExpired=subprocess.TimeoutExpired,
                                            DEVNULL=subprocess.DEVNULL, PIPE=subprocess.PIPE)
        with mock.patch.object(watcher, "subprocess", monitor_subprocess):
            try:
                watcher.run_monitor(monitor, 0)
            except subprocess.TimeoutExpired:
                timed_out = True
            else:
                timed_out = False
        pid = child_ready()
        wait_for(lambda: not child_alive(pid), "時間超過した monitor の子を回収")
        check(timed_out, "時間超過時に実際の monitor と子も回収")

        real_killpg = os.killpg
        real_write_heartbeat = watcher.write_heartbeat
        second_signals = []
        def stop_monitor(*args, **kwargs):
            pending = prepared_monitor(*args, **kwargs)
            real_communicate = pending.communicate
            first_call = True
            def communicate_with_signal(*c_args, **c_kwargs):
                nonlocal first_call
                if first_call:
                    first_call = False
                    os.kill(os.getpid(), signal.SIGTERM)
                return real_communicate(*c_args, **c_kwargs)
            pending.communicate = communicate_with_signal
            return pending
        def killpg_with_second_signal(pgid, sig):
            if sig == signal.SIGTERM:
                second_signals.append(signal.SIGINT)
                os.kill(os.getpid(), signal.SIGINT)
            return real_killpg(pgid, sig)
        def write_with_second_signal(path, started, result):
            if result.startswith("停止:"):
                for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                    second_signals.append(sig)
                    os.kill(os.getpid(), sig)
                    watcher.stop(sig, None)
            return real_write_heartbeat(path, started, result)
        stop_subprocess = SimpleNamespace(Popen=stop_monitor, run=subprocess.run,
                                          TimeoutExpired=subprocess.TimeoutExpired,
                                          DEVNULL=subprocess.DEVNULL, PIPE=subprocess.PIPE)
        handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            with (mock.patch.dict(os.environ, env),
                  mock.patch.object(sys, "argv", ["lanes_watch.py", "--until-wake"]),
                  mock.patch.object(watcher, "subprocess", stop_subprocess),
                  mock.patch.object(watcher.os, "killpg", side_effect=killpg_with_second_signal),
                  mock.patch.object(watcher, "write_heartbeat", side_effect=write_with_second_signal)):
                stop_code = watcher.main()
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
        pid = child_ready()
        wait_for(lambda: not child_alive(pid), "停止中の再シグナルでも monitor の子を回収")
        check(stop_code == 143 and second_signals == [signal.SIGINT, signal.SIGTERM, signal.SIGINT, signal.SIGHUP]
              and read_json(heartbeat)["result"] == "停止: シグナルを受信",
              "停止処理中に 2 回目以降のシグナルが来ても子回収・heartbeat・排他後片付けを完了")

        kill_signals = []
        def timeout_then_signal_monitor(*args, **kwargs):
            pending = prepared_monitor(*args, **kwargs)
            real_communicate = pending.communicate
            calls = 0
            def communicate_timeout_then_stop(*c_args, **c_kwargs):
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise subprocess.TimeoutExpired(args[0], 0)
                if calls == 2:
                    os.kill(os.getpid(), signal.SIGTERM)
                return real_communicate(*c_args, **c_kwargs)
            pending.communicate = communicate_timeout_then_stop
            return pending
        def record_killpg(pgid, sig):
            kill_signals.append(sig)
            return real_killpg(pgid, sig)
        timeout_stop_subprocess = SimpleNamespace(Popen=timeout_then_signal_monitor, run=subprocess.run,
                                                  TimeoutExpired=subprocess.TimeoutExpired,
                                                  DEVNULL=subprocess.DEVNULL, PIPE=subprocess.PIPE)
        handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            with (mock.patch.dict(os.environ, env),
                  mock.patch.object(sys, "argv", ["lanes_watch.py", "--until-wake"]),
                  mock.patch.object(watcher, "subprocess", timeout_stop_subprocess),
                  mock.patch.object(watcher.os, "killpg", side_effect=record_killpg)):
                timeout_stop_code = watcher.main()
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
        pid = child_ready()
        wait_for(lambda: not child_alive(pid), "時間超過回収中のシグナルでも monitor の子を回収")
        check(timeout_stop_code == 143 and kill_signals == [signal.SIGTERM, signal.SIGKILL]
              and read_json(heartbeat)["result"] == "停止: シグナルを受信",
              "時間超過の回収中にシグナルが来ても SIGKILL まで完走して停止を記録")

        process = start("--until-wake")
        next_monitor()
        respond("hang")
        pid = child_ready()
        process.terminate()
        finish(process)
        wait_for(lambda: not child_alive(pid), "TERM を受けた monitor の子を回収")
        check(process.returncode == 143, "TERM でも子を回収して終了")

        # 被験実装が子を残す回帰を起こしても、テスト自身の後片付けで確実に回収する。
        pending = prepared_monitor(["zsh", "-f", str(monitor)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        pid = child_ready()
        pending.terminate()
        pending.wait(timeout=WAIT_SECONDS)
        check(child_alive(pid), "後片付けの検証用に親だけ終了した子を用意")
        stop_fixtures(signal.SIGTERM)
        wait_for(lambda: not child_alive(pid), "親の終了後にテスト自身が子を回収")
        finish(pending)
        check(True, "親が終了済みでも所有を確認した子を回収")
        for option, value in (("--interval", "0"), ("--interval", "nan"), ("--max-hours", "inf"), ("--max-hours", "-1")):
            check(run(option, value).returncode == 2, f"不正値 {option}={value} を拒否")
    finally:
        # 途中の検証に失敗しても起動済みの監視を終了させ、子の回収を最後まで待つ。
        for process in children:
            if process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    process.terminate()
        stop_fixtures(signal.SIGTERM)
        for process in children:
            try:
                finish(process)
            except subprocess.TimeoutExpired:
                stop_fixtures(signal.SIGKILL)
                if process.poll() is None:
                    with contextlib.suppress(ProcessLookupError):
                        process.kill()
                finish(process)
        for pid, (started, _) in fixture_processes.items():
            wait_for(lambda: watcher.identity(pid) != started, "テスト用の監視・子の終了")
# 司令塔が Claude（LANES_COMMANDER=claude）で --until-wake なしの常駐を起動したときだけ、標準エラーに案内を 1 行出す
# （不明なオプションで本体をすぐ終わらせ、入口の案内だけを見る）
with tempfile.TemporaryDirectory(prefix="watch-commander-", dir=scratch) as tmp:
    base_env = {**os.environ, "LANES_CONF": str(pathlib.Path(tmp) / "no-such.conf"),
                "LANES_RUNS_ROOT": str(pathlib.Path(tmp) / "runs"), "LANES_SCRATCH_ROOT": str(pathlib.Path(tmp) / "scratch")}
    def commander_run(commander, *args):
        return subprocess.run(["zsh", "-f", str(lanes / "lanes-watch.sh"), *args, "--bogus-option"],
                              env={**base_env, "LANES_COMMANDER": commander}, capture_output=True, text=True, timeout=WAIT_SECONDS)
    hint = "LANES_COMMANDER=claude"
    check(hint in commander_run("claude").stderr, "司令塔 claude の常駐起動で --until-wake を案内")
    check(hint not in commander_run("claude", "--until-wake").stderr, "司令塔 claude の --until-wake では案内しない")
    check(hint not in commander_run("grok").stderr, "司令塔 grok の常駐起動では案内しない")
    check(all(hint not in commander_run(c).stdout for c in ("claude", "grok")), "案内は標準出力（WAKE: / QUIET の行）に混ざらない")
print(f"PASS: {passed} 件")
PY
