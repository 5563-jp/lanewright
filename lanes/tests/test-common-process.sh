#!/bin/bash
# 実 CLI を使わず、排他・PID 同一性・孫回収・分離起動を使い捨て環境で検証する。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "$(cd "$(dirname "$0")" && pwd -P)/_git-isolate.sh"; lanes_test_git_isolate
LANES_TEST_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export LANES_TEST_DIR
python3 - <<'PY'
import os, pathlib, signal, subprocess, sys, tempfile, time

lanes = pathlib.Path(os.environ["LANES_TEST_DIR"])
scratch = os.environ.get("LANES_SCRATCH") or os.environ["TMPDIR"]
passed = 0
children = []

def check(ok, name):
    global passed
    if not ok:
        raise AssertionError(name)
    passed += 1
    print("ok", name, flush=True)

def wait_for(condition, seconds=12):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if condition():
            return True
        time.sleep(0.05)
    return False

def alive(pid):
    p = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
    return p.returncode == 0 and p.stdout.strip() and not p.stdout.strip().startswith("Z")

with tempfile.TemporaryDirectory(prefix="common-process-", dir=scratch) as tmp:
    root = pathlib.Path(tmp)
    repo = root / "repo"
    repo.mkdir()
    env = {**os.environ, "LANES_NOTIFY": "0", "LANES_SCRATCH_ROOT": str(root / "scratch"),
           "LANES_SCRATCH": str(root), "TMPDIR": str(root) + "/", "TEST_REPO": str(repo),
           "TEST_LANES": str(lanes), "TEST_ROOT": str(root)}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
        env.pop(name, None)
    subprocess.run(["git", "init", "-q", str(repo)], env=env, check=True)
    assert os.path.realpath(subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(repo)), '一時リポの外の git に届いている: ' + str(repo)   # 本物のリポを書き換えない
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test User", "-c",
                    "user.email=you@example.com", "commit", "--allow-empty", "-qm", "test: 初期化"], env=env, check=True)
    source = 'set -euo pipefail; LANES_DIR="$TEST_LANES"; source "$LANES_DIR/_common.sh"; '

    def start(code):
        p = subprocess.Popen(["zsh", "-fc", source + code], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        children.append(p)
        return p

    def run(code):
        p = start(code)
        out, err = p.communicate(timeout=20)
        return p.returncode, out, err

    try:
        # 同じ時刻にロック取得を試みる。旧 check → write の間を広げる細工は不要。
        barrier = root / "go"
        code = ('while [[ ! -f "$TEST_ROOT/go" ]]; do sleep 0.02; done; '
                'lanes_mark_start "$TEST_REPO/logs" same test "$TEST_REPO"; '
                'print accepted; sleep 1; lanes_mark_done 0 "VERDICT: CLEAN"')
        a, b = start(code), start(code)
        barrier.touch()
        results = []
        for p in (a, b):
            out, err = p.communicate(timeout=12)
            results.append((p.returncode, out))
        check(sorted(r[0] for r in results) == [0, 2] and
              sum("accepted" in r[1] for r in results) == 1, "同一 label の同時起動は1本だけ")
        check((repo / "logs/same.done").read_text().startswith("EXIT:0"), "拒否側は所有者の終了記録を上書きしない")
        rc, _, _ = run('lanes_mark_start "$TEST_REPO/logs" same test "$TEST_REPO"; lanes_mark_done 0 "VERDICT: CLEAN"')
        check(rc == 0, "終了後は同じロックファイルで再起動できる")

        hold = start('lanes_mark_start "$TEST_REPO/logs" held test "$TEST_REPO"; '
                     'lanes_mark_done 0 "VERDICT: CLEAN"; sleep 1')
        check(wait_for(lambda: (repo / "logs/held.done").exists()), "終了記録の先行作成を待てる")
        rc, _, _ = run('lanes_mark_start "$TEST_REPO/logs" held test "$TEST_REPO"')
        check(rc == 2, "終了記録があってもランチャ終了までは排他を維持")
        hold.communicate(timeout=5)

        rc, _, _ = run('lanes_mark_start "$TEST_REPO/logs" rejected test "$TEST_REPO"; lanes_die "模擬前提エラー"')
        check(rc == 2 and "EXIT:2" in (repo / "logs/rejected.done").read_text(), "前提エラーも終了記録を残す")
        rc, _, _ = run('lanes_mark_start "$TEST_REPO/logs" rejected test "$TEST_REPO"; lanes_mark_done 0 "VERDICT: CLEAN"')
        check(rc == 0, "前提エラー後のロックは自動解放")

        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(40)"])
        children.append(unrelated)
        rc, _, _ = run(f'LANES_CHILD={unrelated.pid}; LANES_CHILD_LSTART="異なる開始時刻"; lanes_kill_child')
        check(rc == 0 and unrelated.poll() is None, "開始時刻が不一致なら TERM・KILL を送らない")
        for label, fields in [('legacy', f'pid={unrelated.pid}\n'),
                              ('legacychild', f'pid=0\nchild_pid={unrelated.pid}\n')]:
            (repo / f'logs/{label}.pid').write_text(fields)
            (repo / f'logs/{label}.done').write_text('EXIT:0\n')
            rc, _, _ = run(f'lanes_mark_start "$TEST_REPO/logs" {label} test "$TEST_REPO"')
            check(rc == 2, label + ' 開始時刻なしでも再起動を拒否')
        (repo / 'logs/legacy.done').unlink()
        status = subprocess.run(['zsh', str(lanes/'lanes-status.sh'), str(repo), 'legacy'],
                                env=env, capture_output=True, text=True)
        check(status.returncode == 13 and '同一性不明' in status.stdout and 'kill ' not in status.stdout,
              '開始時刻なしの状態表示は停止を案内しない')
        unrelated.terminate()
        unrelated.wait(timeout=5)

        # 親が終わっても孫を残す模擬 CLI。TERM を無視する孫は最後の KILL も必要になる。
        grand = root / "grand.py"
        grand.write_text('import os,signal,time,pathlib,sys\n'
                         'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                         'pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n'
                         'time.sleep(40)\n')
        fake = root / "fake.py"
        fake.write_text('import pathlib,subprocess,sys,time\n'
                        'subprocess.Popen([sys.executable,sys.argv[1],sys.argv[2]])\n'
                        'while not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)\n'
                        'if sys.argv[3] == "wait": time.sleep(40)\n')
        for signum in (None, signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            label = "normal" if signum is None else "signal" + str(int(signum))
            marker = root / (label + ".grand")
            code = ('lanes_mark_start "$TEST_REPO/logs" ' + label + ' test "$TEST_REPO"; '
                    'lanes_start_child python3 "$TEST_ROOT/fake.py" "$TEST_ROOT/grand.py" '
                    f'"$TEST_ROOT/{label}.grand" ' + ('exit' if signum is None else 'wait') + '; '
                    'rc=0; wait "$LANES_CHILD" || rc=$?; LANES_CHILD=""; '
                    'lanes_mark_done "$rc" "VERDICT: CLEAN"; exit "$rc"')
            p = start(code)
            check(wait_for(marker.exists), label + " 孫の起動を確認")
            grand_pid = int(marker.read_text())
            if signum is not None:
                state = subprocess.run(["zsh", str(lanes / "lanes-status.sh"), str(repo), label],
                                       env=env, capture_output=True, text=True, timeout=5)
                check(state.returncode == 10 and state.stdout.startswith("RUNNING"), label + " 稼働状態を確認")
                p.send_signal(signum)
            out, err = p.communicate(timeout=20)
            expected = 0 if signum is None else 128 + int(signum)
            check(p.returncode == expected, label + " 終了コードを維持")
            check(not alive(grand_pid), label + " TERM を無視する孫も回収")
            check("EXIT:" + str(expected) in (repo / ("logs/" + label + ".done")).read_text(),
                  label + " 回収後に終了記録を作る")

        # 別集団へ独立した後、中間親が消えた孫。通常終了と停止競合の両経路を固定する。
        middle = root / "middle.py"
        middle.write_text('import subprocess,sys,time\n'
                          'subprocess.Popen([sys.executable,sys.argv[1],sys.argv[2]], start_new_session=True, '
                          'stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n'
                          'time.sleep(0.7)\n')
        for scenario in ("known", "fast"):
            marker = root / (scenario + ".grand")
            detached = root / "detached.py"
            if scenario == "known":
                detached.write_text('import pathlib,subprocess,sys,time\n'
                                    'subprocess.Popen([sys.executable,*sys.argv[1:]]).wait()\n'
                                    'pathlib.Path(sys.argv[3]+".ready").touch()\n'
                                    'time.sleep(40)\n')
                args = '"$TEST_ROOT/middle.py" "$TEST_ROOT/grand.py" "$TEST_ROOT/known.grand"'
            else:
                detached.write_text('import subprocess,sys,time\n'
                                    'time.sleep(0.045)\n'
                                    'subprocess.Popen([sys.executable,sys.argv[1],sys.argv[2]], start_new_session=True, '
                                    'stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n')
                args = '"$TEST_ROOT/grand.py" "$TEST_ROOT/fast.grand"'
            # 同じ時刻に作った別レーン相当の処理は回収対象にしない。
            other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(40)"])
            children.append(other)
            p = start('lanes_mark_start "$TEST_REPO/logs" ' + scenario + ' test "$TEST_REPO"; '
                      'lanes_start_child python3 "$TEST_ROOT/detached.py" ' + args + '; '
                      'rc=0; wait "$LANES_CHILD" || rc=$?; LANES_CHILD=""; '
                      'lanes_mark_done "$rc" "VERDICT: CLEAN"; exit "$rc"')
            ready = pathlib.Path(str(marker) + ".ready") if scenario == "known" else marker
            check(wait_for(ready.exists), scenario + " 独立した孫を起動")
            grand_pid = int(marker.read_text())
            if scenario == "known":
                p.terminate()
            p.communicate(timeout=20)
            check(p.returncode == (143 if scenario == "known" else 0), scenario + " 独立孫回収の終了コード")
            check(not alive(grand_pid), scenario + " 親消滅後の独立孫も回収")
            check(other.poll() is None, scenario + " 別レーン相当の処理を巻き込まない")
            other.terminate()
            other.wait(timeout=5)

        # 実子の起動後に ps 全体が失敗しても、監督役を消して孤児にしない。
        mockbin = root / 'fault-bin'; mockbin.mkdir()
        fault = root / 'ps-fault'
        ps = mockbin / 'ps'
        ps.write_text('#!/bin/sh\nif [ -f "$TEST_ROOT/ps-fault" ]; then exit 1; fi\nexec /bin/ps "$@"\n')
        ps.chmod(0o755)
        worker = root / 'fault-worker.py'
        marker = root / 'fault-child.pid'
        worker.write_text('import os,pathlib,time,sys\n'
                          'pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n'
                          'pathlib.Path(sys.argv[2]).touch()\n'
                          'time.sleep(40)\n')
        p = start('PATH="$TEST_ROOT/fault-bin:$PATH"; '
                  'lanes_mark_start "$TEST_REPO/logs" fault test "$TEST_REPO"; '
                  'lanes_start_child python3 "$TEST_ROOT/fault-worker.py" "$TEST_ROOT/fault-child.pid" "$TEST_ROOT/ps-fault"; '
                  'rc=0; wait "$LANES_CHILD" || rc=$?; LANES_CHILD=""; '
                  'lanes_mark_done "$rc" "VERDICT: NONE"; exit "$rc"')
        try:
            check(wait_for(marker.exists), 'ps 障害を起こす実子を起動')
            time.sleep(0.7)
            check(p.poll() is None and alive(int(marker.read_text())), 'ps 障害中も実子と監督を保持')
            rc, _, _ = run('lanes_mark_start "$TEST_REPO/logs" fault test "$TEST_REPO"')
            check(rc == 2, 'ps 障害中は再起動を拒否')
            fault.unlink()
            # 一時的な ps 障害では健全な実子を止めない（監督ループは再試行する）。
            time.sleep(0.7)
            check(p.poll() is None and alive(int(marker.read_text())), 'ps 復旧後も健全な実子を止めない')
            os.kill(int(marker.read_text()), signal.SIGTERM)
            p.communicate(timeout=20)
            check(p.returncode == 143 and not alive(int(marker.read_text())), 'ps 復旧後は実子の終了コードをそのまま記録')
        finally:
            fault.unlink(missing_ok=True)

        # 独立直後の孫への個別 ps だけが一度失敗しても、所属確認を諦めない。
        marker = root / 'individual-child.pid'
        fault = root / 'individual-fault'
        ps.write_text('#!' + sys.executable + '\n'
                      'import os,pathlib,sys\n'
                      'root=pathlib.Path(os.environ["TEST_ROOT"]); a=sys.argv[1:]\n'
                      'marker=root/"individual-child.pid"; fault=root/"individual-fault"\n'
                      'if a and a[0]=="eww" and marker.exists() and a[a.index("-p")+1]==marker.read_text() and not fault.exists():\n'
                      ' fault.touch(); sys.exit(1)\n'
                      'os.execv("/bin/ps",["ps",*a])\n')
        worker.write_text('import os,pathlib,sys,time\n'
                          'time.sleep(.045)\n'
                          'if os.fork(): os._exit(0)\n'
                          'os.setsid()\n'
                          'null=os.open("/dev/null",os.O_RDWR)\n'
                          'for n in (0,1,2): os.dup2(null,n)\n'
                          'pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n'
                          'time.sleep(40)\n')
        p = start('PATH="$TEST_ROOT/fault-bin:$PATH"; '
                  'lanes_mark_start "$TEST_REPO/logs" individual test "$TEST_REPO"; '
                  'lanes_start_child python3 "$TEST_ROOT/fault-worker.py" "$TEST_ROOT/individual-child.pid"; '
                  'rc=0; wait "$LANES_CHILD" || rc=$?; LANES_CHILD=""; '
                  'lanes_mark_done "$rc" "VERDICT: NONE"; exit "$rc"')
        try:
            check(wait_for(marker.exists), '個別 ps 障害用の独立孫を起動')
            p.communicate(timeout=20)
            check(fault.exists(), '独立孫への個別 ps 障害を再現')
            # 障害が監督ループ中なら再試行で 0、停止処理中なら回収を確認したうえで 3（失敗を記録）になる。
            check(p.returncode in (0, 3) and not alive(int(marker.read_text())), '所属未確認の孫を再確認して回収')
        finally:
            if marker.exists() and alive(int(marker.read_text())):
                os.kill(int(marker.read_text()), signal.SIGTERM)

        # コマンド引数の記録は禁止。分離した子自身は何も表示せずすぐ終了する。
        log = root / "detached.log"
        marker = root / "detached.finished"
        sentinel = "模擬の非公開引数"
        p = subprocess.run(["zsh", str(lanes / "detach-run.sh"), str(log), sys.executable,
                            "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()", str(marker), sentinel],
                           env=env, capture_output=True, text=True, timeout=5)
        check(p.returncode == 0 and wait_for(marker.exists), "分離起動が正常に完了")
        check(sentinel not in log.read_text() and sentinel not in p.stdout + p.stderr,
              "分離起動ログにコマンド引数を転記しない")
        p = subprocess.run(["zsh", str(lanes / "detach-run.sh"), str(log), str(root / sentinel)],
                           env=env, capture_output=True, text=True, timeout=5)
        check(p.returncode == 2 and sentinel not in log.read_text() + p.stdout + p.stderr,
              "分離起動失敗時も引数・例外本文を転記しない")
    finally:
        for p in children:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
print(f"---- {passed} passed, 0 failed")
PY
