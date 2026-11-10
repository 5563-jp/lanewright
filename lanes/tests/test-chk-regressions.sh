#!/bin/zsh -f
# 省略判定と検証前後の入力照合を、模擬 npm（LANES_CHECK_CMD から呼ぶ）・使い捨て repo で検証する。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
export TEST_LANES="${0:A:h:h}"
python3 - <<'PY'
import os, pathlib, socket, subprocess, sys, tempfile, time

lanes = pathlib.Path(os.environ['TEST_LANES'])
passed = 0
def check(ok, name):
    global passed
    assert ok, name
    passed += 1
    print('ok', name, flush=True)
def wait_for(path):
    for _ in range(200):
        if path.exists(): return
        time.sleep(.05)
    raise AssertionError('模擬サーバーの待機上限')

with tempfile.TemporaryDirectory(dir=os.environ.get('LANES_SCRATCH') or os.environ['TMPDIR'], prefix='chk-regression-') as tmp:
    root = pathlib.Path(tmp)
    repo = root/'repo'; repo.mkdir()
    bindir = root/'bin'; bindir.mkdir()
    npm = bindir/'npm'
    npm.write_text('''#!/usr/bin/env python3
import os,pathlib,subprocess,sys,time
root=pathlib.Path(os.environ['CASE_ROOT'])
action=' '.join(sys.argv[1:])
if action=='run typecheck' and (root/'mutate').exists():
    mode=(root/'mutate').read_text()
    if mode=='source': pathlib.Path('src/value').write_text('GOOD')
    elif mode=='head': subprocess.run(['git','commit','--allow-empty','-qm','test: 検証中変更'],check=True)
    elif mode=='dep': pathlib.Path('node_modules/value').write_text('GOOD')
    elif mode=='dirty': pathlib.Path('src/value').write_text('GOOD changed again')
    elif mode=='ignored': pathlib.Path('local-data/config').write_text('changed')
    elif mode=='tracked-output': pathlib.Path('dist/source').write_text('changed')
if action=='run build':
    for p in (pathlib.Path('src/value'),pathlib.Path('node_modules/value'),pathlib.Path('sub/src/value'),pathlib.Path('sub/local-data/value'),*pathlib.Path('src/tests').glob('*.ts')):
        if p.exists() and 'BAD' in p.read_text(): sys.exit(9)
    runner=pathlib.Path('node_modules/.bin/runner')
    if runner.exists() and not os.access(runner,os.X_OK): sys.exit(126)
    if (root/'generate').exists():
        for name in ('dist/index.html','build/result','out/page','.next/cache','coverage/report','tsconfig.tsbuildinfo'):
            p=pathlib.Path(name); p.parent.mkdir(exist_ok=True); p.write_text(str(time.time_ns()))
if action=='run smoke:iphone' and (root/'mutate-after-build').exists():
    mode=(root/'mutate-after-build').read_text()
    if mode=='source': pathlib.Path('src/value').write_text('BAD after build')
    elif mode=='shared': pathlib.Path('node_modules/value').write_text('BAD after build')
    elif mode=='sub-ignored': pathlib.Path('sub/local-data/value').write_text('BAD after build')
if action=='run smoke:iphone' and (root/'allowed-port').exists():
    if os.environ['LANES_CHECK_PORT'] != (root/'allowed-port').read_text(): sys.exit(8)
print('SMOKE_OK')
''')
    npm.chmod(0o755)
    env={**os.environ, 'PATH':str(bindir)+os.pathsep+os.environ['PATH'], 'CASE_ROOT':str(root),
         'CHK_CACHE':str(root/'passed.tsv'),
         'LANES_CHECK_CMD':'npm run typecheck && npm run build && npm run smoke:iphone',
         'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','LANES_NOTIFY':'0'}
    for key in ('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR'): env.pop(key,None)
    def git(*args):
        return subprocess.check_output(['git','-C',str(repo),*args],env=env,stderr=subprocess.DEVNULL,text=True).strip()
    git('init','-q'); git('config','user.name','you'); git('config','user.email','you@example.com')
    assert os.path.realpath(subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(repo)), '一時リポの外の git に届いている: ' + str(repo)   # 本物のリポを書き換えない
    (repo/'.gitignore').write_text('node_modules/\nlocal-data/\ndist/\nbuild/\nout/\n.next/\ncoverage/\n*.tsbuildinfo\n')
    (repo/'src/tests').mkdir(parents=True)
    (repo/'src/value').write_text('GOOD'); (repo/'src/tests/a.ts').write_text('GOOD')
    (repo/'package.json').write_text('{"scripts":{"build":"loader src/tests/*.ts"}}')
    git('add','.'); git('commit','-qm','test: 初期化')
    def free_port():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); return sock.getsockname()[1]
    stable_port=free_port()
    def run(*args, extra=None, port=stable_port, outdir=None):
        return subprocess.run(['bash',str(lanes/'chk-run.sh'),str(repo),str(port),str(outdir or root/'out'),*args],
                              env={**env,**(extra or {})},capture_output=True,text=True,timeout=40)
    r=run(); check(r.returncode==0 and 'recorded=' in r.stdout,'初回の成功を保存')
    r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'同一入力を再利用')
    (root/'allowed-port').write_text(str(stable_port))
    other_port=free_port()
    while other_port==stable_port: other_port=free_port()
    r=run(port=other_port)
    check(r.returncode==1 and 'check=8' in r.stdout and 'skip=' not in r.stdout,'ポート変更で画面確認を再実行')
    (root/'allowed-port').unlink()
    r=run(outdir=repo); check(r.returncode==0,'作業ツリー自身も出力先に指定できる')
    (repo/'src/value').write_text('BAD')
    r=run(outdir=repo)
    check(r.returncode==1 and 'check=9' in r.stdout and 'skip=' not in r.stdout,'出力先配下の追跡済みソースを除外しない')
    (repo/'src/value').write_text('GOOD')
    (repo/'extra-input').write_text('new')
    r=run(outdir=repo)
    check(r.returncode==0 and 'recorded=' not in r.stdout and 'skip=' not in r.stdout,'出力先配下の未知の未追跡ファイルも入力に含める')
    (repo/'extra-input').unlink()
    (root/'generate').touch()
    r=run('--force',outdir=repo)
    check(r.returncode==0 and 'recorded=' in r.stdout,'正常なビルド生成物の新規作成を許可')
    r=run(outdir=repo)
    check(r.returncode==0 and 'skip=same-tree' in r.stdout,'生成済み出力が同じなら再利用')
    (repo/'dist/index.html').write_text('broken')
    r=run(outdir=repo)
    check(r.returncode==0 and 'skip=' not in r.stdout and 'recorded=' in r.stdout,'生成物が変わった場合は再利用せず再検証')
    r=run('--force',outdir=repo)
    check(r.returncode==0 and 'recorded=' in r.stdout,'正常なビルド生成物の更新を許可')
    (root/'generate').unlink()
    # 最初から未保存のファイル、無視された設定、生成先に追跡されたソースも保護する。
    for mode, rel in [('dirty','src/value'),('ignored','local-data/config'),('tracked-output','dist/source')]:
        target=repo/rel; target.parent.mkdir(exist_ok=True); target.write_text('GOOD before')
        if mode=='tracked-output': git('add','-f',rel); git('commit','-qm','test: 出力先の追跡ソース')
        (root/'mutate').write_text(mode)
        r=run('--force',outdir=repo)
        check(r.returncode==1 and 'recorded=' not in r.stdout,'検証中の入力変更を検出-'+mode)
        (root/'mutate').unlink()
        target.write_text('GOOD before' if mode=='tracked-output' else 'GOOD')
    git('add','check.log'); git('commit','-qm','test: 出力ファイルと追跡ソースの衝突')
    original=(repo/'check.log').read_bytes()
    r=run(outdir=repo)
    check(r.returncode==2 and (repo/'check.log').read_bytes()==original,'追跡済み出力ファイルを上書きしない')
    git('rm','check.log'); git('commit','-qm','test: 衝突ケースの終了')
    for name in ('fetch.log','merge.log','check-state.json'):
        (repo/name).unlink(missing_ok=True)
    git('branch','before-log-merge')
    (repo/'check.log').write_text('追跡済みのソース内容')
    git('add','check.log'); git('commit','-qm','test: 取り込む出力先のソース')
    merge_head=git('rev-parse','HEAD')
    git('checkout','-q','before-log-merge')
    r=run('--merge',merge_head,outdir=repo)
    check(r.returncode==2 and (repo/'check.log').read_text()=='追跡済みのソース内容','取り込み後も追跡済み出力先を上書きしない')
    git('rm','check.log'); git('commit','-qm','test: 取り込み衝突ケースの終了')
    (repo/'merge.log').unlink()
    (repo/'src/tests/a.ts').write_text('BAD'); git('commit','-qam','test: 一括入力の破損')
    r=run(); check(r.returncode==1 and 'check=9' in r.stdout and 'recorded=' not in r.stdout,'一括読み込みのテストも build を省略しない')
    check('record=no' not in r.stdout,'確認コマンドが失敗したときは「通ったが記録しない」の行を出さない')
    (repo/'src/tests/a.ts').write_text('GOOD'); git('commit','-qam','test: 入力復旧')
    shared=root/'shared'; shared.mkdir(); (shared/'value').write_text('GOOD')
    (repo/'node_modules').symlink_to(shared, target_is_directory=True)
    r=run(); check(r.returncode==0 and 'recorded=' not in r.stdout,'リンクした共有依存は確認結果を再利用しない')
    # （.gitignore の node_modules/ はフォルダだけに効くので、リンクの node_modules は未追跡のファイルとして数える）
    check('record=no reason=uncommitted（' in r.stdout and '未 commit の変更か未追跡のファイルがある: node_modules）' in r.stdout,
          '通ったのに記録しないときは理由を出す（リンクした共有依存）')
    (shared/'value').write_text('BAD')
    r=run(); check(r.returncode==1 and 'check=9' in r.stdout,'共有依存の内容変更で再検証する')
    (shared/'value').write_text('GOOD')
    # 共有依存リンク＋未保存変更ありで再利用不可でも、ビルド後の確認処理中のソース・共有依存変更を検出する。
    (repo/'src/value').write_text('GOOD dirty before')
    (root/'mutate-after-build').write_text('source')
    r=run()
    check(r.returncode==1 and 'recorded=' not in r.stdout and '検証中に入力が変化した' in r.stderr,
          '共有依存リンクと未保存変更があってもビルド後のソース変更を失敗にする')
    (root/'mutate-after-build').unlink()
    r=run()
    check(r.returncode==1 and 'check=9' in r.stdout,'ビルド後に壊されたソースで次回ビルド失敗')
    (repo/'src/value').write_text('GOOD dirty before')
    (root/'mutate-after-build').write_text('shared')
    r=run()
    check(r.returncode==1 and 'recorded=' not in r.stdout and '検証中に入力が変化した' in r.stderr,
          '共有依存リンク先がビルド後に変更された場合も失敗にする')
    (root/'mutate-after-build').unlink()
    (shared/'value').write_text('GOOD')
    (repo/'src/value').write_text('GOOD')
    (repo/'node_modules').unlink()
    runner=repo/'node_modules/.bin/runner'
    runner.parent.mkdir(parents=True,exist_ok=True)
    runner.write_text('#!/bin/sh\nexit 0\n')
    runner.chmod(0o755)
    r=run('--force'); check(r.returncode==0 and 'recorded=' in r.stdout,'依存実行ファイルの成功を保存')
    r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'依存実行ファイルの権限が同じなら再利用')
    runner.chmod(0o644)
    r=run(); check(r.returncode==1 and 'check=126' in r.stdout and 'skip=' not in r.stdout,'依存実行ファイルの権限剥奪で再検証し失敗する')
    runner.unlink(); (repo/'node_modules/.bin').rmdir(); (repo/'node_modules').rmdir()
    for mode in ('source','head','dep'):
        (root/'passed.tsv').write_text('')
        target=repo/('node_modules/value' if mode=='dep' else 'src/value')
        target.parent.mkdir(exist_ok=True)
        target.write_text('BAD' if mode!='head' else 'GOOD')
        git('add','src/value'); git('commit','--allow-empty','-qm','test: 検証前の入力')
        (root/'mutate').write_text(mode)
        r=run()
        check(r.returncode==1 and 'recorded=' not in r.stdout,'検証途中の変更を成功記録へ残さない-'+mode)
        (root/'mutate').unlink()
        if mode!='head':
            target.write_text('BAD')
            r=run()
            check(r.returncode==1 and 'check=9' in r.stdout and 'skip=' not in r.stdout,'元へ戻しても誤った成功記録を使わない-'+mode)
        target.write_text('GOOD')
        git('add','src/value'); git('commit','--allow-empty','-qm','test: 復旧')

    # 変更検知を省略する設定（assume-unchanged / skip-worktree）の追跡ファイルも、実際の内容で照合する。
    for flag in ('--assume-unchanged','--skip-worktree'):
        (root/'passed.tsv').write_text('')
        r=run(); check(r.returncode==0 and 'recorded=' in r.stdout,'省略設定の前に成功を保存'+flag)
        git('update-index',flag,'src/value')
        (repo/'src/value').write_text('BAD')
        r=run(); check(r.returncode==1 and 'check=9' in r.stdout and 'skip=' not in r.stdout,'省略設定の追跡ファイル書き換えで再利用しない'+flag)
        (repo/'src/value').write_text('GOOD')
        r=run(); check(r.returncode==0 and 'skip=' not in r.stdout and 'recorded=' not in r.stdout,'省略設定がある間は記録も省略もしない'+flag)
        check('record=no reason=uncommitted（' in r.stdout and '変更検知を省く設定' in r.stdout,'通ったのに記録しないときは理由を出す（変更検知を省く設定）'+flag)
        git('update-index','--no-'+flag[2:],'src/value')
        r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'解除後は同じ内容の記録を再利用'+flag)

    # サブモジュール内の追跡・未追跡・無視対象入力も再利用判定と検証前後の入力照合に含める。
    sub_origin=root/'sub-origin'; sub_origin.mkdir()
    subprocess.check_call(['git','-C',str(sub_origin),'init','-q'],env=env)
    assert os.path.realpath(subprocess.check_output(['git', '-C', str(sub_origin), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(sub_origin)), '一時リポの外の git に届いている: ' + str(sub_origin)   # 本物のリポを書き換えない
    subprocess.check_call(['git','-C',str(sub_origin),'config','user.name','you'],env=env)
    subprocess.check_call(['git','-C',str(sub_origin),'config','user.email','you@example.com'],env=env)
    (sub_origin/'.gitignore').write_text('local-data/\n')
    (sub_origin/'src').mkdir(); (sub_origin/'src/value').write_text('GOOD')
    subprocess.check_call(['git','-C',str(sub_origin),'add','.'],env=env)
    subprocess.check_call(['git','-C',str(sub_origin),'commit','-qm','test: 子リポ初期化'],env=env)
    git('-c','protocol.file.allow=always','submodule','add','-q',str(sub_origin),'sub')
    git('commit','-qam','test: サブモジュール追加')
    sub_ignored=repo/'sub/local-data/value'; sub_ignored.parent.mkdir(parents=True)
    sub_ignored.write_text('GOOD')
    (root/'passed.tsv').write_text('')
    r=run(); check(r.returncode==0 and 'recorded=' in r.stdout,'サブモジュールありの初回成功を保存')
    r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'サブモジュール内の無視対象入力が同じなら再利用')
    sub_ignored.write_text('BAD')
    r=run(); check(r.returncode==1 and 'check=9' in r.stdout and 'skip=' not in r.stdout,
                   'サブモジュール内の無視対象入力変更で再利用せず再検証')
    sub_ignored.write_text('GOOD')
    r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'サブモジュール内の無視対象入力を戻せば再利用')
    (root/'mutate-after-build').write_text('sub-ignored')
    r=run('--force')
    check(r.returncode==1 and 'recorded=' not in r.stdout and '検証中に入力が変化した' in r.stderr,
          '検証中のサブモジュール内無視対象入力変更を検出')
    (root/'mutate-after-build').unlink()
    sub_ignored.write_text('GOOD')
    subprocess.check_call(['git','-C',str(repo/'sub'),'update-index','--assume-unchanged','src/value'],env=env)
    (repo/'sub/src/value').write_text('BAD')
    r=run(); check(r.returncode==1 and 'check=9' in r.stdout and 'skip=' not in r.stdout,
                   'サブモジュール内の省略設定つき追跡ファイル変更で再利用しない')
    (repo/'sub/src/value').write_text('GOOD')
    subprocess.check_call(['git','-C',str(repo/'sub'),'update-index','--no-assume-unchanged','src/value'],env=env)
    # サブモジュールの checkout が索引の commit とずれたら再利用しない。tree が同じ別 commit の最上位は再利用する。
    (root/'passed.tsv').write_text('')
    r=run(); check(r.returncode==0 and 'recorded=' in r.stdout,'サブモジュール checkout 照合の前提を保存')
    git('commit','-q','--allow-empty','-m','test: tree が同じ別 commit')
    r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'最上位の commit だけ違う同じ tree は再利用')
    (sub_origin/'src/value').write_text('GOOD v2')
    subprocess.check_call(['git','-C',str(sub_origin),'commit','-qam','test: 子リポ更新'],env=env)
    subprocess.check_call(['git','-C',str(repo/'sub'),'-c','protocol.file.allow=always','pull','-q','origin','HEAD'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    r=run(); check(r.returncode==0 and 'skip=' not in r.stdout and 'recorded=' not in r.stdout,
                   'サブモジュールの checkout が索引とずれたら再利用も記録もしない')
    subprocess.check_call(['git','-C',str(repo/'sub'),'checkout','-q','HEAD~1'],env=env,stderr=subprocess.DEVNULL)
    r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'サブモジュールを索引の commit に戻せば再利用')
    # 読めないファイルがあっても状態取得ごと落とさず、全部回して記録だけしない。
    unreadable=repo/'local-data/secret-cache'; unreadable.parent.mkdir(exist_ok=True)
    unreadable.write_text('x'); unreadable.chmod(0)
    try:
        if os.access(unreadable, os.R_OK):
            check(True,'読めないファイルの試験は root 権限のため省略（読めてしまう）')
        else:
            r=run(); check(r.returncode==0 and 'skip=' not in r.stdout and 'recorded=' not in r.stdout and 'check=0' in r.stdout,
                           '読めないファイルがあっても全検証し、記録はしない')
    finally:
        unreadable.chmod(0o644); unreadable.unlink()
    # 未初期化のサブモジュール（中身の無いディレクトリ）だけなら再利用を止めない。
    git('submodule','deinit','-q','-f','sub')
    (root/'passed.tsv').write_text('')
    r=run(); check(r.returncode==0 and 'recorded=' in r.stdout,'未初期化サブモジュールでも成功を記録')
    r=run(); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'未初期化サブモジュールでも同じ入力を再利用')
    git('-c','protocol.file.allow=always','submodule','update','-q','--init','sub')

    # 監督役の開始時刻が起動直後に取れなくても、取り直して停止まで進める。
    psdir=root/'flaky-ps'; psdir.mkdir()
    (psdir/'ps').write_text('''#!/bin/sh
# 開始時刻の単独照会だけを指定回数失敗させる。それ以外は本物へ渡す。
case "$*" in
  "-o lstart= -p "*)
    n=$(cat "$CASE_ROOT/ps-fails" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$CASE_ROOT/ps-fails"; exit 1; fi ;;
esac
exec /bin/ps "$@"
''')
    (psdir/'ps').chmod(0o755)
    (root/'ps-fails').write_text('3')
    r=run('--force',extra={'PATH':str(psdir)+os.pathsep+str(bindir)+os.pathsep+os.environ['PATH']})
    check(r.returncode==0 and '開始時刻を確認できない' not in r.stderr and (root/'ps-fails').read_text().strip()=='0',
          '開始時刻の一時取得失敗を取り直して停止する')

    # 確認コマンドが呼ぶリポの外の実行ファイルを差し替えたら、前の成功記録を使い回さない。
    # 同じ大きさ・同じ更新時刻に戻しても、中身の指紋で見分ける
    tools=root/'tools'; tools.mkdir()
    tool=tools/'check-tool'
    tool.write_text('#!/bin/sh\nexit 00\n'); tool.chmod(0o755)
    tool_env={'PATH':str(tools)+os.pathsep+env['PATH'],'LANES_CHECK_CMD':'check-tool --all'}
    (root/'passed.tsv').write_text('')
    r=run(extra=tool_env); check(r.returncode==0 and 'recorded=' in r.stdout,'外の実行ファイルを呼ぶ確認の成功を記録')
    r=run(extra=tool_env); check(r.returncode==0 and 'skip=same-tree' in r.stdout,'外の実行ファイルが同じなら再利用')
    st=tool.stat()
    tool.write_text('#!/bin/sh\nexit 17\n'); os.utime(tool,ns=(st.st_atime_ns,st.st_mtime_ns))
    r=run(extra=tool_env)
    check(r.returncode==1 and 'skip=' not in r.stdout and 'check=17' in r.stdout,'外の実行ファイルの中身を変えたら再利用せず回し直す')
    tool.write_text('#!/bin/sh\nexit 00\n')
    # #! の解釈系（/usr/bin/env の先）も見る
    interp=tools/'my-interp'; interp.write_text('#!/bin/sh\nexit 0\n'); interp.chmod(0o755)
    tool.write_text('#!/usr/bin/env my-interp\n'); tool.chmod(0o755)
    r=run(extra=tool_env); check(r.returncode==0 and 'recorded=' in r.stdout,'#! の解釈系を通す確認の成功を記録')
    interp.write_text('#!/bin/sh\nexit 5\n')
    r=run(extra=tool_env); check('skip=' not in r.stdout and 'check=5' in r.stdout,'#! の解釈系を変えたら再利用しない')
    interp.write_text('#!/bin/sh\nexit 0\n')
    # 解釈系を確実に特定できない #!（env の -S・-i・代入付き・未知のオプション）は、回すが記録・再利用しない
    hidden=root/'hidden-interp'; hidden.mkdir()
    hinterp=hidden/'test-interp'; hinterp.write_text('#!/bin/sh\nexit 0\n'); hinterp.chmod(0o755)
    for line in (f'#!/usr/bin/env -S PATH={hidden}:/usr/bin:/bin test-interp', f'#!/usr/bin/env -i {interp}',
                 '#!/usr/bin/env FOO=1 my-interp', '#!/usr/bin/env -u FOO my-interp'):
        tool.write_text(line+'\n'); (root/'passed.tsv').write_text('')
        r=run(extra=tool_env)
        check(r.returncode==0 and 'check=0' in r.stdout and 'recorded=' not in r.stdout,'解釈系を特定できない #! は記録しない: '+line.split('env',1)[1])
    # 記録されないので、解釈系が壊れたら通常実行でも失敗する（skip=same-tree で成功にしない）
    tool.write_text(f'#!/usr/bin/env -S PATH={hidden}:/usr/bin:/bin test-interp\n')
    hinterp.write_text('#!/bin/sh\nexit 19\n')
    r=run(extra=tool_env)
    check(r.returncode==1 and 'skip=' not in r.stdout and 'check=19' in r.stdout,'env -S の先の解釈系を壊したら通常実行でも失敗する')
    tool.write_text('#!/bin/sh\nexit 00\n')
    # コマンド文字列が違えば再利用しない（同じ実行ファイルでも引数が違う）
    r=run(extra={**tool_env,'LANES_CHECK_CMD':'check-tool --other'}); check('skip=' not in r.stdout and 'recorded=' in r.stdout,'コマンド文字列が違えば再利用しない')
    # 変数で組み立てた名前・見つからない名前は同一性を確かめられないので、回すが記録しない
    r=run(extra={**tool_env,'LANES_CHECK_CMD':'"$CHK_TOOL" --all','CHK_TOOL':str(tool)})
    check(r.returncode==0 and 'check=0' in r.stdout and 'recorded=' not in r.stdout,'変数で組み立てた実行ファイル名は記録しない')
    check('record=no reason=unresolvable（' in r.stdout and '確認コマンド（LANES_CHECK_CMD）の「$CHK_TOOL」' in r.stdout
          and str(tool) not in r.stdout,'通ったのに記録しないときは理由を出す（変数で組み立てた名前。変数の値は出さない）')
    r=run(extra={**tool_env,'LANES_CHECK_CMD':'check-tool --all || no-such-tool-xyz'})
    check(r.returncode==0 and 'recorded=' not in r.stdout,'見つからない実行ファイル名があれば記録しない')
    check('record=no reason=unresolvable（' in r.stdout and '「no-such-tool-xyz」: 実行ファイルが見つからない' in r.stdout,
          '通ったのに記録しないときは理由を出す（見つからない実行ファイル）')
    # .lanes/check.sh の中から呼ぶ外の実行ファイルも見る
    (repo/'.lanes').mkdir(exist_ok=True)
    (repo/'.lanes/check.sh').write_text('set -e\nif true; then\n  FOO=1 check-tool --sh 2>&1\nfi\n')
    with open(repo/'.git/info/exclude','a') as stream: stream.write('.lanes/\n')
    r=run(extra=tool_env); check(r.returncode==0 and '.lanes/check.sh' in r.stdout and 'recorded=' in r.stdout,'.lanes/check.sh の成功を記録')
    r=run(extra=tool_env); check('skip=same-tree' in r.stdout,'.lanes/check.sh の呼ぶ実行ファイルが同じなら再利用')
    tool.write_text('#!/bin/sh\nexit 17\n')
    r=run(extra=tool_env); check('skip=' not in r.stdout and 'check=17' in r.stdout,'.lanes/check.sh の呼ぶ外の実行ファイルを変えたら再利用しない')
    # #! やコメントで始まる .lanes/check.sh でも、後ろの行のコマンドを読み飛ばさない
    tool.write_text('#!/bin/sh\nexit 00\n')
    (repo/'.lanes/check.sh').write_text('#!/bin/bash\n# 手元確認\nset -e # 途中のコメント\ncheck-tool --sh\n')
    (root/'passed.tsv').write_text('')
    r=run(extra=tool_env); check(r.returncode==0 and 'recorded=' in r.stdout,'コメントで始まる .lanes/check.sh の成功を記録')
    r=run(extra=tool_env); check('skip=same-tree' in r.stdout,'コメントで始まる .lanes/check.sh も同じなら再利用')
    tool.write_text('#!/bin/sh\nexit 17\n')
    r=run(extra=tool_env)
    check(r.returncode==1 and 'skip=' not in r.stdout and 'check=17' in r.stdout,'コメントの後ろの行の外の実行ファイルを変えたら通常実行でも失敗する')
    # 確認コマンドの中で PATH を付け替えたら、実際に呼ばれる実行ファイルを確実に決められないので記録しない
    tools2=root/'tools2'; tools2.mkdir()
    tool2=tools2/'check-tool'; tool2.write_text('#!/bin/sh\nexit 00\n'); tool2.chmod(0o755)
    tool.write_text('#!/bin/sh\nexit 00\n')
    (repo/'.lanes/check.sh').write_text(f'#!/bin/bash\nexport PATH={tools2}:$PATH\ncheck-tool --sh\n')
    r=run(extra=tool_env); check(r.returncode==0 and 'recorded=' not in r.stdout,'.lanes/check.sh で PATH を書き換えたら記録しない')
    check('record=no reason=unresolvable（' in r.stdout and '確認コマンド（.lanes/check.sh）の「PATH=' in r.stdout,
          '通ったのに記録しないときは理由を出す（.lanes/check.sh の PATH の付け替え）')
    # 報告された形: .lanes/check.sh が exec でコマンドを起動する（exec zsh -f selftest.sh など）。
    # 「引数のコマンドを起動する包み」なので仕様どおり記録しないが、黙らずに理由を出す。
    # 直す前は check=0（.lanes/check.sh）だけを出して終わり、レビューの問い合わせが no-record になる理由が分からなかった
    (repo/'.lanes/check.sh').write_text('#!/bin/bash\n# この worktree の手元確認\nexec check-tool --sh\n')
    (root/'passed.tsv').write_text('')
    r=run(extra=tool_env)
    check(r.returncode==0 and 'check=0（.lanes/check.sh）' in r.stdout and 'recorded=' not in r.stdout,'exec で起動する .lanes/check.sh は回すが記録しない')
    check('record=no reason=unresolvable（' in r.stdout and '確認コマンド（.lanes/check.sh）の「exec」' in r.stdout,
          'exec で起動する .lanes/check.sh は、記録しない理由（exec）を出す')
    q=subprocess.run(['bash',str(lanes/'chk-run.sh'),str(repo),'--query'],env={**env,**tool_env},capture_output=True,text=True,timeout=40)
    check(q.returncode==1 and q.stdout.strip()=='reuse=no reason=no-record','記録しなかった後の問い合わせは no-record（理由は chk-run.sh の record=no の行に出ている）')
    (repo/'.lanes/check.sh').write_text('#!/bin/bash\n# この worktree の手元確認\ncheck-tool --sh\n')
    r=run(extra=tool_env)
    check(r.returncode==0 and 'recorded=' in r.stdout and 'record=no' not in r.stdout,'exec を外せば記録する（記録したときは record=no を出さない）')
    (repo/'.lanes/check.sh').unlink()
    path_cmd=f'PATH={tools2}:$PATH check-tool --all'
    (root/'passed.tsv').write_text('')
    r=run(extra={**tool_env,'LANES_CHECK_CMD':path_cmd})
    check(r.returncode==0 and 'check=0' in r.stdout and 'recorded=' not in r.stdout,'PATH を前置した呼び出しは回すが記録しない')
    tool2.write_text('#!/bin/sh\nexit 17\n')
    r=run(extra={**tool_env,'LANES_CHECK_CMD':path_cmd})
    check(r.returncode==1 and 'skip=' not in r.stdout and 'check=17' in r.stdout,'PATH の付け替え先のツールを変えたら通常実行でも失敗する')
    tool2.write_text('#!/bin/sh\nexit 00\n')
    # ほかの確実に解決できない書き方も、回すが記録しない
    for cmd in ('cd . && check-tool','env check-tool','exec check-tool','command check-tool','check-tool | cat',
                '(check-tool)','f() { check-tool; }; f','source ./x.sh; check-tool','eval check-tool',
                'bash -c check-tool','echo $(check-tool)','echo `check-tool`','alias c=check-tool; check-tool',
                'xargs check-tool </dev/null','cat <<EOF\nEOF\ncheck-tool','"check-tool',"echo $'a\\'' ; check-tool"):
        r=run(extra={**tool_env,'LANES_CHECK_CMD':cmd})
        check('skip=' not in r.stdout and 'recorded=' not in r.stdout,'解決できない書き方は記録しない: '+cmd.replace('\n','⏎'))
        check(r.returncode!=0 or 'record=no reason=unresolvable（' in r.stdout,'解決できない書き方で通ったら、記録しない理由を出す: '+cmd.replace('\n','⏎'))
    # 単純な形（素の名前・前置の代入が PATH 以外・リダイレクト・改行の区切り）は今までどおり記録して再利用する
    simple='set -e\nFOO=1 check-tool --all 2>&1 >/dev/null\ncheck-tool --again && true\n'
    r=run(extra={**tool_env,'LANES_CHECK_CMD':simple}); check(r.returncode==0 and 'recorded=' in r.stdout,'単純な形は記録する')
    check('record=no' not in r.stdout,'記録したときは record=no を出さない')
    r=run(extra={**tool_env,'LANES_CHECK_CMD':simple}); check('skip=same-tree' in r.stdout,'単純な形は再利用する')
    import shutil as _sh; _sh.rmtree(repo/'.lanes')
    # 記録の日時は時間帯の表記を固定しない（%Z）
    (root/'passed.tsv').write_text('')
    r=run('--force',extra={'TZ':'UTC'})
    rows=[l for l in (root/'passed.tsv').read_text().splitlines() if l]
    check(r.returncode==0 and len(rows)==1 and rows[0].split('\t')[3].endswith(' UTC'),'記録の日時は実行環境の時間帯で書く（JST に固定しない）')

    # 確認コマンドが設定されていなければ何も回さず exit 2（記録も変えない）
    before=(root/'passed.tsv').read_text()
    r=run(extra={'LANES_CHECK_CMD':''})
    check(r.returncode==2 and 'check=' not in r.stdout and 'LANES_CHECK_CMD' in r.stderr and (root/'passed.tsv').read_text()==before,
          '確認コマンド未設定なら exit 2 で設定方法を出す')
print(f'---- {passed} passed, 0 failed')
PY
