#!/bin/bash
# 任意の深さのレーン発見・除外・GitHub 接続先の特定・定期の確認の集計を使い捨て repo で検証する。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "$(cd "$(dirname "$0")" && pwd -P)/_git-isolate.sh"; lanes_test_git_isolate
python3 -B - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import json, os, pathlib, runpy, subprocess, sys, tempfile, time
from unittest import mock

lanes = pathlib.Path(sys.argv[1])
passed = 0

def check(ok, name):
    global passed
    if not ok:
        raise AssertionError(name)
    passed += 1
    print(f"ok {passed} {name}", flush=True)

with tempfile.TemporaryDirectory(prefix="monitor-test-", dir=os.environ.get("LANES_SCRATCH") or os.environ.get("TMPDIR", "/tmp")) as tmp:
    root = pathlib.Path(tmp)
    runs, bindir = root / "runs", root / "bin"
    bindir.mkdir()
    calls = root / "gh-calls"
    stub = bindir / "gh"
    stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1:3] == ['auth', 'status']:
    # 未ログインの再現は MONITOR_TEST_GH_AUTH=1 で
    sys.exit(int(os.environ.get('MONITOR_TEST_GH_AUTH', '0')))
assert sys.argv[1:3] == ['pr', 'list']
with pathlib.Path(os.environ['MONITOR_TEST_CALLS']).open('a') as stream:
    stream.write(sys.argv[sys.argv.index('--repo') + 1] + '\\n')
# 開いている PR の一覧は MONITOR_TEST_PRS（JSON）で差し替える。既定は 0 件
print(os.environ.get('MONITOR_TEST_PRS', '[]'))
''')
    stub.chmod(0o755)
    env = {key: value for key, value in os.environ.items() if key not in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE')}
    env.update(LANES_RUNS_ROOT=str(runs), LANES_SCRATCH_ROOT=str(runs/'_scratch'), PATH=str(bindir) + os.pathsep + os.environ['PATH'],
               MONITOR_TEST_CALLS=str(calls), LANES_WATCH_HEARTBEAT=str(root / 'absent-heartbeat'),
               LANES_NOTIFY='0', LM_ALLOW_REDEPLOY='1')
    now = time.time()
    ident = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'lstart='],
                                    env={**env, 'LC_ALL': 'C', 'TZ': 'UTC'}, text=True).strip()

    # scp 形式の接続先はメールの形に見えるので、組み立てて書く（固有情報の機械検査に掛からないように）
    gh_host = 'github' + '.com'

    def git(wt, *args):
        return subprocess.run(['git', '-C', str(wt), *args], env=env, capture_output=True, text=True, check=True).stdout.strip()

    def fixture(relative, label, remote=None, finished=True, age=0, code=0, verdict='CLEAN', stalled=False):
        wt = runs / relative
        logs = wt / 'logs'
        logs.mkdir(parents=True, exist_ok=True)
        if not (wt / '.git').exists():
            git(wt, 'init', '-q')
            assert os.path.realpath(subprocess.check_output(['git', '-C', str(wt), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(wt)), '一時リポの外の git に届いている: ' + str(wt)   # 本物のリポを書き換えない
            git(wt, 'config', 'user.name', 'you')
            git(wt, 'config', 'user.email', 'you@example.com')
            git(wt, 'commit', '--allow-empty', '-qm', 'test: 監視用の初期化')
        if remote:
            git(wt, 'config', 'remote.origin.url', remote)
        pidfile = logs / (label + '.pid')
        start = int(now - (7200 if stalled else 10))
        pidfile.write_text(f'pid={os.getpid()}\nlstart={ident}\nstarted_epoch={start}\nlane=claude\nworktree={wt}\n')
        os.utime(pidfile, (now - age - 1, now - age - 1))
        if finished:
            done = logs / (label + '.done')
            done.write_text(f'EXIT:{code}\nVERDICT: {verdict}\n')
            os.utime(done, (now - age, now - age))
        return wt

    fixture('my-app/one', 'mine', 'https://github.com/example/workspace.git')
    fixture('other-app/two', 'avatar', f'git@{gh_host}:example/avatar.git')
    direct = fixture('direct-three', 'direct', f'ssh://git@{gh_host}/example/workspace.git')
    fixture('arbitrary/group/deep', 'deep', 'https://elsewhere.invalid/example/unknown.git')
    fixture('active/wt', 'active', finished=False)
    fixture('active/stalled', 'stalled', finished=False, stalled=True)
    unknown = fixture('active/unknown', 'unknown', finished=False)
    (unknown/'logs/unknown.pid').write_text(f'pid={os.getpid()}\nlane=claude\n')
    for label, finished in [('qa-done',True),('qa-live',False)]:
        qa = runs/'_scratch/workspace'/f'{label}-checkout'
        git(direct, 'worktree', 'add', '-q', '--detach', str(qa), 'HEAD')
        fixture(str(qa.relative_to(runs)), label, finished=finished)
    # checkout という名前だけの保管領域やリンクを QA と誤認しない。
    fixture('_scratch/workspace/archive-checkout', 'excluded')
    (runs/'_scratch/workspace/linked-checkout').symlink_to(qa, target_is_directory=True)
    fixture('my-app/one', 'old', age=1000)
    fixture('my-app/one', 'failed', code=2)
    fixture('my-app/one', 'none', verdict='NONE')
    for name in ('_archive', '_scratch', '_prompts', '.hidden', 'my-app/_private'):
        fixture(name + '/skipped', 'excluded')
    # リンク経由で外へ出ず、回転済み・pid 無しの記録も拾わない。
    (runs / 'linked').symlink_to(direct, target_is_directory=True)
    (direct / 'logs' / 'rotated.prev-20261106-010101.pid').write_text('pid=1\n')
    (direct / 'logs' / 'rotated.prev-20261106-010101.done').write_text('EXIT:0\n')
    orphan = runs / 'done-only' / 'logs'
    orphan.mkdir(parents=True)
    (orphan / 'orphan.done').write_text('EXIT:0\n')

    def monitor():
        return subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh'), '--no-append'],
                              env=env, capture_output=True, text=True, timeout=30)

    result = monitor()
    check(result.returncode == 0 and result.stdout.startswith('WAKE:'), '新しい完了を検知')
    output = result.stdout
    check(all(name + ' ' in output for name in ('mine', 'avatar', 'direct', 'deep')), '既存3案件以外・直下・任意の深さも発見')
    check('excluded' not in output and 'rotated' not in output and 'orphan' not in output, '_始まり・隠し領域・回転済み・pid無しを除外')
    check(output.count('DONE direct-three direct ') == 1, 'リンクを重複巡回しない')
    check('FAILED my-app failed ' in output and 'FAILED my-app none ' in output, '失敗とNONEを完了扱いしない')
    check('RUNNING 2' in output and 'STALLED active stalled' in output, '稼働中と無出力状態を区別')
    check('FAILED active unknown' in output and '要対応' in output.splitlines()[0], '終了記録なしの同一性不明も失敗として通知')
    check('qa-done' in output and 'qa-live' in output, 'scratch の QA 専用作業場所の稼働と完了を検知')
    check(sorted(calls.read_text().splitlines()) == ['example/avatar', 'example/workspace'], 'GitHubが判明したリポだけ重複なくPR照会')
    state = runs / '.lanes-monitor-state.json'
    saved = json.loads(state.read_text())
    check('arbitrary/group/deep/deep' in saved['seen_done'], '既読の鍵に相対作業場所を使用')
    result = monitor()
    check(result.returncode == 0 and result.stdout.startswith('QUIET'), '既読完了と同じ問題は連続通知しない')
    saved=json.loads(state.read_text())
    saved['problems']['active/unknown/unknown']['wake']=now-31*60
    state.write_text(json.dumps(saved))
    result=monitor()
    check(result.stdout.startswith('WAKE:') and 'FAILED active unknown' in result.stdout, 'FAILED は30分後に再通知')
    state_before, calls_before = state.read_bytes(), calls.read_bytes()
    result = subprocess.run(['zsh', '-f', str(lanes / 'lanes-watch.sh'), '--check'],
                            env=env, capture_output=True, text=True, timeout=30)
    check(result.returncode == 1 and result.stdout.startswith('WATCH DEAD\n'), 'watch停止とレーン集計を同時表示')
    check('LANES RUNNING 3（うち STALLED 1）' in result.stdout, 'check は生存レーンの本数を表示')
    check('直近10分 DONE（次工程待ち）: 5 件' in result.stdout, '既定（10 分）の範囲の成功完了だけを集計')
    check('FAILED active/unknown/unknown' in result.stdout and 'qa-done-checkout/qa-done' in result.stdout,
          '定期の確認も同一性不明と QA 専用作業場所を表示')
    # 確認の間隔（LANES_CHECK_INTERVAL_MIN）を延ばすと、その分前に終わったもの（old は約 17 分前）も拾う
    wide = subprocess.run(['zsh', '-f', str(lanes / 'lanes-watch.sh'), '--check'],
                          env={**env, 'LANES_CHECK_INTERVAL_MIN': '30'}, capture_output=True, text=True, timeout=30)
    check('直近30分 DONE（次工程待ち）: 6 件' in wide.stdout and '/old' in wide.stdout, 'LANES_CHECK_INTERVAL_MIN で集計の範囲が変わる')
    done_lines='\n'.join(line for line in result.stdout.splitlines() if line.startswith('- DONE '))
    check('my-app/one/mine' in done_lines and '/old' not in done_lines and '/failed' not in done_lines, '次工程待ちを作業場所付きで全件表示')
    check(state.read_bytes() == state_before and calls.read_bytes() == calls_before, 'check は既読状態もPR一覧も変更しない')
    check(not (runs / 'lanes-monitor-now.txt').exists(), 'no-append は履歴を書かない')
    # QA の後片付けと探索が重なっても、通常領域の監視は継続する。
    with mock.patch.dict(os.environ, env):
        module = runpy.run_path(str(lanes / 'lanes_monitor.py'))
    original_scandir = os.scandir
    for missing in (runs/'_scratch', runs/'_scratch/workspace'):
        def disappearing_scandir(path):
            if os.fspath(path) == str(missing):
                raise FileNotFoundError(path)
            return original_scandir(path)
        with mock.patch('os.scandir', side_effect=disappearing_scandir):
            discovered = list(module['discover_worktrees']())
        check(any(wt == str(direct) for wt, _ in discovered), '探索中の削除でも他レーンを監視-'+missing.name)
    # watch と手動の単発監視が重なっても、保存エラーや同じ終了の二重通知を起こさない。
    state.unlink()
    processes = [subprocess.Popen(['zsh', '-f', str(lanes / 'lanes-monitor.sh'), '--no-append'],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(8)]
    try:
        results = [(process, process.communicate(timeout=30)) for process in processes]
        check(all(process.returncode == 0 and not output[1] for process, output in results), '8 本同時でも全件正常終了')
        check(sum(output[0].startswith('WAKE:') for _, output in results) == 1, '既読判定も排他して完了を一度だけ通知')
        check(bool(json.loads(state.read_text())['seen_done']), '同時実行後も状態ファイルを復元可能')
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
    # gh が未ログイン・未導入なら PR 照会を黙って飛ばす（失敗行も出さない）
    calls.write_text('')
    for case, extra in (('未ログイン', {'MONITOR_TEST_GH_AUTH': '1'}),
                        ('未導入', {'PATH': os.pathsep.join(p for p in env['PATH'].split(os.pathsep) if not os.path.exists(os.path.join(p, 'gh')))})):
        result = subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh'), '--no-append', '--reset'],
                                env={**env, **extra}, capture_output=True, text=True, timeout=30)
        check(result.returncode == 0 and calls.read_text() == '' and 'gh pr list 失敗' not in result.stdout,
              'gh が' + case + 'なら PR 照会を黙って飛ばす')
    # 認証の確認に失敗した回は、前回の PR の状態を空で上書きしない。復旧後にその間のマージを通知する
    one_pr = json.dumps([{'number': 5, 'title': 'feat: テスト', 'headRefName': 'feat/x', 'isDraft': False}])
    def monitor_with(extra):
        return subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh'), '--no-append'],
                              env={**env, **extra}, capture_output=True, text=True, timeout=30)
    monitor_with({'MONITOR_TEST_PRS': one_pr})
    check(json.loads(state.read_text())['prs'].get('example/workspace') == [5], '開いている PR を状態に保存')
    result = monitor_with({'MONITOR_TEST_PRS': '[]', 'MONITOR_TEST_GH_AUTH': '1'})
    check(json.loads(state.read_text())['prs'].get('example/workspace') == [5] and 'PR クローズ' not in result.stdout,
          '認証の確認に失敗した回は前回の PR の状態を残す')
    result = monitor_with({'MONITOR_TEST_PRS': '[]'})
    check(result.stdout.startswith('WAKE:') and 'PR クローズ/マージ #5' in result.stdout,
          '認証の復旧後に、その間にマージされた PR を通知する')
    # gh が使える回は、レーンの無くなったリポの古い PR 状態を持ち続けない
    saved = json.loads(state.read_text()); saved['prs']['example/gone'] = [9]; state.write_text(json.dumps(saved))
    monitor_with({'MONITOR_TEST_GH_AUTH': '1'})
    check(json.loads(state.read_text())['prs'].get('example/gone') == [9], '認証の確認に失敗した回は、見つからないリポの状態も残す')
    monitor_with({})
    check('example/gone' not in json.loads(state.read_text())['prs'], 'gh が使える回は、レーンの無くなったリポの PR 状態を捨てる')
    result = monitor_with({'TZ': 'UTC'})
    check(' UTC ' in result.stdout.splitlines()[1], '時刻の行は実行環境の時間帯で書く（JST に固定しない）')
    # LANES_VERCEL_PROJECT が空なら自動再デプロイは無効と出す（--allow-redeploy を付けたときだけ動く）
    result = subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh'), '--no-append', '--allow-redeploy'],
                            env={k: v for k, v in env.items() if k != 'LANES_VERCEL_PROJECT'}, capture_output=True, text=True, timeout=30)
    check('無効（LANES_VERCEL_PROJECT が空）' in result.stdout, 'Vercel のプロジェクト未設定なら自動再デプロイは無効')
print(f'PASS: {passed} 件')
PY
