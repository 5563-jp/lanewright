#!/bin/zsh -f
# Gemini レビュー（run-gemini-review.sh）と、レビューの入口の --engine（run-review.sh）のテスト。
# 偽の agy（このテストが一時領域に置く。本物の agy・ネットワークには触らない）と、tests/stubs の偽の claude・codex だけを使う。
# 構成（LANES_TOOLS）はこのテストの中で固定・切り替える（呼び出し元の構成に左右されない）。全データを一時領域に置く。
# 確かめること:
#   1. 引数の誤りは今回の失敗（EXIT:2）として .done に残す
#   2. 入口の振り分け: --engine ＞ LANES_REVIEW_ENGINE ＞ 構成のレビュー役。知らない値・構成に無い道具は EXIT:2。
#      起動前点検は振り分けたレビュー役で回す（設定が gemini でも --engine codex なら agy を点検しない）
#   3. 親の chk-run の記録が無いとき（LANES_REVIEW_REQUIRE_CHECKS=1）は子を起動せずに EXIT:2。LANES_REVIEW_ENGINE を渡しても記録を使い回せる
#   4. 読み取り専用の強制（--mode plan・--sandbox・--settings の拒否・子の環境）。agy --help に足りないもの・本体 checkout では起動しない
#   5. 子が作業ツリー・git の管理フォルダ・制御ファイルを変えたら NEEDS_FIX（EXIT:4）
#   6. 書き込み系のツールの step_update が 1 件でもあれば不合格（EXIT:4）。実機の形の stream-json でも同じ
#   7. JSON の不備・agy の失敗・見張り（無出力 EXIT:8・idle EXIT:3）。補助のプロセスが出力を持ち続けても終わる
#   8. VERDICT・P0〜P3・GATE・後回し票・ESCALATE が、同じ本文の Claude レビューと同じ
#   9. モデル・effort の記録と証跡
#  10. 同じ道具でレビューしない（--allow-same-engine で通して証跡に残す）
#  11. 同じ head の結果の再利用（skip-same-head）・delta・前回 NEEDS_FIX の引き継ぎ・dry-run
#  12. 確認中の印（IN_PROGRESS）: 子の起動前に書く。失敗・中断・書き込み違反・記録の書き込みの失敗では確定しない。
#      その後の起動は古い CLEAN（記録・過去の証跡）を使わない。前回 NEEDS_FIX の未解決指摘は引き継ぐ。成功したときだけ確定する
#  13. 本文の途中の独立した行の VERDICT（共通の判定の規則は維持。Claude レビューは今までどおり）
#  14. 生死の見張り（lanes-status / lanes-monitor）・起動前点検（lanes-doctor.sh）・役割の表示（lanes-roles.sh --print）
#  15. 記録の確定と安全の直し（round 1 の指摘）: 今回の NEEDS_FIX を前回分の後回しで上書きしない・確定に失敗したら合格の証跡を残さない・
#      dry-run の書き込み先・前回の本文を読み切ってから IN_PROGRESS・親の python を worktree から切り離す・失格の回の後回し票・
#      壊れた行の前の書き込みの記録・HEAD を読めない・.done を書けない・点検の codex・GNU の stat
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-gemrev.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
PYTHONDONTWRITEBYTECODE=1 python3 -I - "$LANES_DIR" "$T" <<'PY'
import json, os, pathlib, re, shutil, signal, subprocess, sys, time
lanes, T = map(pathlib.Path, sys.argv[1:3])
stubs = lanes / 'tests' / 'stubs'
fixtures = lanes / 'tests' / 'fixtures' / 'gemini-review'
passed = 0
def check(name, cond, detail=''):
    global passed
    if not cond:
        raise AssertionError(name + (('\n' + detail) if detail else ''))
    passed += 1
    print(f'ok {passed} {name}', flush=True)

home = T / 'home'; (home / '.gemini' / 'antigravity-cli').mkdir(parents=True)
bindir = T / 'bin'; bindir.mkdir()
# 偽の gh（監視が呼んでも外へ通信しない。未ログインと同じ終了コード）
(bindir / 'gh').write_text('#!/bin/sh\nexit 4\n'); (bindir / 'gh').chmod(0o755)
# 偽の agy。--help の中身・子の動き（作業ツリーの書き換えなど）・出す stream-json を GT_* で切り替える。
# 呼ばれた引数・作業場所・一部の環境変数・stdin が /dev/null か・起動時の再利用の記録（logs/.*.review-state）を GT_CAPTURE に書く
agy = bindir / 'agy'
agy.write_text(r'''#!/usr/bin/env python3
import glob, json, os, pathlib, subprocess, sys, time
args = sys.argv[1:]
if '--help' in args:
    h = os.environ.get('GT_HELP', 'full')
    opts = ['--add-dir', '--effort', '--model', '--output-format', '--print', '--print-timeout', '--settings', '--sandbox']
    if h == 'no-sandbox': opts.remove('--sandbox')
    if h not in ('no-mode', 'model-plan'): opts.append('--mode  Set the agent execution mode (accept-edits, auto' + ('' if h == 'no-plan' else ', plan') + ')')
    # --mode が無く、--model の説明にだけ plan の語がある（部分一致の *--mode* では通ってしまう形）
    if h == 'model-plan': opts.append('--model  Model to use with your subscription plan')
    print('\n'.join(opts)); sys.exit(0)
st0, dn = os.fstat(0), os.stat('/dev/null')
keys = ('ANTIGRAVITY_HEADLESS', 'TMPDIR', 'LANES_SCRATCH', 'GIT_OPTIONAL_LOCKS', 'GIT_PAGER', 'GIT_CONFIG_GLOBAL', 'GIT_ALLOW_PROTOCOL',
        'GIT_DIR', 'GIT_WORK_TREE')
present = ('GEMINI_API_KEY', 'GOOGLE_API_KEY', 'AGY_ADC_AUTH', 'GOOGLE_APPLICATION_CREDENTIALS', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY')
states = {os.path.basename(p): pathlib.Path(p).read_text() for p in glob.glob('logs/.*.review-state')}
info = {'args': args, 'cwd': os.getcwd(), 'stdin_devnull': st0.st_rdev == dn.st_rdev and st0.st_ino == dn.st_ino,
        'env': {k: os.environ.get(k) for k in keys}, 'keys_present': [k for k in present if k in os.environ], 'states': states}
if os.environ.get('GT_CAPTURE'):
    pathlib.Path(os.environ['GT_CAPTURE']).write_text(json.dumps(info, ensure_ascii=False))
def git(*a):
    subprocess.run(['git', *a], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
mut = os.environ.get('GT_MUTATION', '')
if mut == 'overwrite': pathlib.Path('a.txt').write_text('レビュー中の上書き')
if mut == 'untracked': pathlib.Path('new.txt').write_text('追加')
if mut == 'commit':
    pathlib.Path('a.txt').write_text('変更'); git('add', 'a.txt'); git('commit', '-qm', 'test: 模擬変更')
if mut == 'git-config': git('config', 'core.hooksPath', 'x')
if mut == 'git-tag': git('tag', 'tag-by-review')
if mut == 'gitlink': pathlib.Path('.git').write_text('gitdir: /nonexistent/elsewhere\n')
lbl = os.environ.get('GT_LABEL', '')
if mut == 'lose-head':
    # 今の枝の参照を消す（レビューの後に HEAD を読めなくなる形）
    git('update-ref', '-d', subprocess.check_output(['git', 'symbolic-ref', 'HEAD'], text=True).strip())
if mut == 'plant-done-dir' and lbl: os.mkdir(f'logs/{lbl}.done')
# 公開ログを読めなくする（書けるが読めない）。ランチャの再利用の記録の確定（本文の読み込み）だけを失敗させる
if mut == 'log-unreadable' and lbl: os.chmod(f'logs/{lbl}.log', 0o200)
if mut == 'hold':
    # 補助のプロセスが標準出力を受け継いだまま残る（agy が終わってもパイプが閉じない形）
    subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
def ev(d): print(json.dumps(d, ensure_ascii=False), flush=True)
body = os.environ.get('GT_BODY', '問題なし\nVERDICT: CLEAN')
rc = int(os.environ.get('GT_RC', '0'))
events = os.environ.get('GT_EVENTS', '')
if os.environ.get('GT_REPLAY'):
    for line in open(os.environ['GT_REPLAY'], encoding='utf-8'):
        d = json.loads(line)
        if d.get('event') == 'result': d['result']['response'] = body
        ev(d)
    sys.exit(rc)
if events == 'empty': sys.exit(rc)
if events == 'late_init': ev({'event': 'step_update', 'step_update': {'step_index': 0, 'state': 'DONE', 'step_type': 'user_input'}})
if events != 'no_init': ev({'event': 'init'})
if events == 'dup_init': ev({'event': 'init'})
def tool(idx, name, state, params):
    ev({'event': 'step_update', 'step_update': {'step_index': idx, 'state': state, 'step_type': 'tool', 'tool_name': name,
        'tool_info': {'name': name, 'parameters': params}}})
if mut == 'read-tool':
    tool(2, 'read_file', 'ACTIVE', {'Path': 'a.txt'}); tool(2, 'read_file', 'DONE', {'Path': 'a.txt'})
    tool(3, 'run_command', 'DONE', {'CommandLine': 'git log --oneline -1'})
if mut in ('write-tool', 'write-tools'):
    tool(4, 'write_file', 'ACTIVE', {'Path': 'x.txt'}); tool(4, 'write_file', 'ERROR', {'Path': 'x.txt'})
    if mut == 'write-tools':
        tool(5, 'edit_file', 'ERROR', {'Path': 'a.txt'}); tool(6, 'delete_file', 'ERROR', {'Path': 'a.txt'})
if events == 'write_badutf8': tool(4, 'write_file', 'ERROR', {'Path': 'x.txt'})
if events == 'drip':
    # 出力を 1 秒ごとに少しずつ出し続ける（無出力の見張りが止めてはいけない形）
    for i in range(int(os.environ.get('GT_SLEEP', '6'))):
        ev({'event': 'step_update', 'step_update': {'step_index': 100 + i, 'state': 'DONE', 'step_type': 'system_message'}}); time.sleep(1)
if events == 'idle':
    print('root agent idle', file=sys.stderr, flush=True); time.sleep(int(os.environ.get('GT_SLEEP', '8')))
if events == 'sleep': time.sleep(int(os.environ.get('GT_SLEEP', '8')))
if events == 'bad_json': print('{broken', flush=True)
if events == 'bad_tool': ev({'event': 'step_update', 'step_update': {'step_type': 'tool', 'tool_info': {}}})
if events != 'missing_result':
    ev({'event': 'result', 'result': {'status': 'ERROR' if events == 'error_status' else 'SUCCESS', 'response': body,
                                      'num_turns': 1, 'usage': {}}})
if events == 'write_badutf8':
    # 最後の行の文字が途中で切れた（UTF-8 の不完全なバイト列で終わる）
    sys.stdout.buffer.write(b'{"event":"step_update","note":"\xe3\x81'); sys.stdout.flush()
if events == 'dup_result': ev({'event': 'result', 'result': {'status': 'SUCCESS', 'response': body}})
if events == 'nonterminal': ev({'event': 'step_update', 'step_update': {'step_index': 9, 'state': 'DONE', 'step_type': 'system_message'}})
sys.exit(rc)
''')
agy.chmod(0o755)

drop = re.compile(r'^(LANES_|CLAUDE_|CODEX_|GEMINI_|CHK_|STUB_|GT_)')
secret_like = {'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY',
               'GOOGLE_APPLICATION_CREDENTIALS', 'AGY_ADC_AUTH', 'XAI_API_KEY', 'GROK_API_KEY', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME'}
BASE = {k: v for k, v in os.environ.items() if not drop.match(k) and k not in secret_like}
BASE.update(HOME=str(home), PATH=f'{bindir}{os.pathsep}{stubs}{os.pathsep}{os.environ["PATH"]}', LANES_CONF=str(T / 'no-such.conf'),
            LANES_NOTIFY='0', LANES_SCRATCH_ROOT=str(T / 'scratch'), LANES_RUNS_ROOT=str(T / 'runs'), XDG_STATE_HOME=str(T / 'state'),
            TMPDIR=str(T) + '/', LANES_SCRATCH=str(T), LANES_TOOLS='claude codex gemini',
            CLAUDE_BIN=str(stubs / 'claude'), CODEX_BIN=str(stubs / 'codex'), GEMINI_BIN=str(agy),
            CHK_CACHE=str(T / 'chk-cache' / 'passed.tsv'), GEMINI_POLL_SEC='1', GEMINI_IDLE_GRACE='1', GEMINI_IDLE_RESUME_GRACE='1',
            PYTHONDONTWRITEBYTECODE='1')
prompt = T / 'case.md'; prompt.write_text('案件固有の検証指示（テスト）')
capture = T / 'capture.json'

def git(wt, *a):
    return subprocess.check_output(['git', '-C', str(wt), *a], env=BASE, stderr=subprocess.DEVNULL, text=True).strip()
def repo(name, gitignore='logs/\n'):
    """一時リポ（本体）と、その linked worktree（ランチャが受け付ける形）を作る。origin/develop は初期の commit"""
    base = T / (name + '-base'); wt = T / name
    base.mkdir()
    git(base, 'init', '-q', '-b', 'main')
    top = os.path.realpath(subprocess.check_output(['git', '-C', str(base), 'rev-parse', '--show-toplevel'], env=BASE, text=True).strip())
    assert top == os.path.realpath(base), '一時リポの外の git に届いている: ' + str(base)   # 本物のリポを書き換えない
    for k, v in (('user.name', 'Test User'), ('user.email', 'you@example.com'), ('commit.gpgSign', 'false')):
        git(base, 'config', k, v)
    (base / 'a.txt').write_text('初期'); (base / '.gitignore').write_text(gitignore)
    git(base, 'add', '.'); git(base, 'commit', '-qm', 'test: 初期')
    git(base, 'worktree', 'add', '-q', '-b', 'feat/' + name, str(wt))
    first = git(wt, 'rev-parse', 'HEAD'); git(wt, 'update-ref', 'refs/remotes/origin/develop', first)
    (wt / 'b.txt').write_text('足した'); git(wt, 'add', 'b.txt'); git(wt, 'commit', '-qm', 'feat: b を足す')
    return wt, first

def make_env(body='問題なし\nVERDICT: CLEAN', mutation='', events='', rc=0, replay=None, help='full', env=None):
    e = dict(BASE, GT_CAPTURE=str(capture), GT_BODY=body, GT_MUTATION=mutation, GT_EVENTS=events, GT_RC=str(rc), GT_HELP=help,
             STUB_CLAUDE_RESULT=body)
    if replay: e['GT_REPLAY'] = str(replay)
    e.update(env or {})
    return e
def run(script, wt, label, *args, timeout=120, cwd=None, **kw):
    capture.unlink(missing_ok=True)
    e = make_env(**kw)
    r = subprocess.run(['zsh', '-f', str(lanes / script), str(wt), str(prompt), *([label] if label else []), *args],
                       env=e, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    cap = json.loads(capture.read_text()) if capture.exists() else None
    donef = pathlib.Path(wt) / 'logs' / (label + '.done') if label else None
    done = donef.read_text() if donef and donef.is_file() and not donef.is_symlink() else ''
    return r, cap, done
def gem(wt, label, *args, **kw): return run('run-gemini-review.sh', wt, label, *args, **kw)
def out(r): return f'rc={r.returncode}\n--- stdout\n{r.stdout[-2500:]}\n--- stderr\n{r.stderr[-2500:]}'
def evidence(wt, label): return (pathlib.Path(wt) / 'logs' / (label + '.evidence.md')).read_text()
def state(wt, series):
    f = pathlib.Path(wt) / 'logs' / f'.{series}.review-state'
    return json.loads(f.read_text()) if f.exists() else None
def note_gate(done):
    m = re.search(r'gate=(\S+)', done); return m[1] if m else ''

# ---- 1. 引数 ----
wt, first = repo('args')
(wt / 'logs').mkdir()
r, cap, done = gem(wt, 'a1', '--bogus', 'value')
check('不明なオプションは EXIT:2 で今回の .done に残る', r.returncode == 2 and 'EXIT:2' in done and '不明なオプション' in done and cap is None, out(r))
r, cap, done = gem(wt, 'a2', '--mode', 'sideways')
check('--mode の値の誤りも EXIT:2', r.returncode == 2 and 'auto|full|delta' in done and cap is None, out(r))
r, cap, done = gem(wt, 'a3', 'extra-label')
check('label の二重指定は EXIT:2', r.returncode == 2 and cap is None, out(r))
r, cap, done = gem(wt, 'a4', '--round', 'x')
check('--round の値の誤りも EXIT:2', r.returncode == 2 and '--round' in done and cap is None, out(r))

# ---- 2. 入口の振り分け ----
wt, first = repo('route')
r, cap, done = run('run-review.sh', wt, 'e1', '--engine', 'gemini')
check('--engine gemini は Gemini レビューへ振り分ける', r.returncode == 0 and cap is not None and 'lane=gemini-review' in (wt / 'logs/e1.pid').read_text(), out(r))
r, cap, done = run('run-review.sh', wt, 'e2', env={'LANES_REVIEW_ENGINE': 'gemini'})
check('LANES_REVIEW_ENGINE=gemini でも Gemini レビューへ', r.returncode == 0 and cap is not None and 'lane=gemini-review' in (wt / 'logs/e2.pid').read_text(), out(r))
r, cap, done = run('run-review.sh', wt, 'e3', '--engine', 'claude', env={'LANES_REVIEW_ENGINE': 'gemini'})
check('--engine は LANES_REVIEW_ENGINE に勝つ', r.returncode == 0 and cap is None and 'lane=claude-review' in (wt / 'logs/e3.pid').read_text(), out(r))
r, cap, done = run('run-review.sh', wt, 'e4')
check('省略時は今までどおり構成のレビュー役（full なら Codex）', r.returncode == 0 and cap is None and 'lane=codex-review' in (wt / 'logs/e4.pid').read_text(), out(r))
r, cap, done = run('run-review.sh', wt, 'e5', env={'LANES_TOOLS': 'claude gemini'})
check('省略時は今までどおり構成のレビュー役（claude-gemini なら Claude）', r.returncode == 0 and cap is None and 'lane=claude-review' in (wt / 'logs/e5.pid').read_text(), out(r))
r, cap, done = run('run-review.sh', wt, 'e6', '--engine', 'bogus')
check('知らない --engine の値は今回の失敗として .done に残す', r.returncode == 2 and cap is None and 'EXIT:2' in done and '--engine は codex か claude か gemini' in done, out(r))
r, cap, done = run('run-review.sh', wt, 'e7', env={'LANES_REVIEW_ENGINE': 'bogus'})
check('知らない LANES_REVIEW_ENGINE は設定の誤りとして .done に残す', r.returncode == 2 and cap is None and 'LANES_REVIEW_ENGINE' in done, out(r))
for tools in ('claude codex', 'claude'):
    r, cap, done = run('run-review.sh', wt, 'e8', '--engine', 'gemini', env={'LANES_TOOLS': tools})
    check(f'構成 [{tools}] に gemini が無ければ入口で exit 2・agy を起動しない', r.returncode == 2 and cap is None and 'gemini が無い' in done, out(r))
    r, cap, done = gem(wt, 'e9', env={'LANES_TOOLS': tools})
    check(f'構成 [{tools}] に gemini が無ければ直接の起動も exit 2', r.returncode == 2 and cap is None and 'この構成では使えない' in r.stderr and 'EXIT:2' in done, out(r))
r, cap, done = run('run-review.sh', wt, 'e10', '--engine', 'codex', env={'LANES_TOOLS': 'claude gemini'})
check('--engine codex も構成に codex が無ければ exit 2', r.returncode == 2 and 'codex が無い' in done, out(r))
r, cap, done = run('run-review.sh', wt, 'e11', '--engine', 'claude', '--allow-same-engine')
check('--allow-same-engine は gemini 以外では誤り', r.returncode == 2 and 'Gemini レビュー（--engine gemini）用' in done, out(r))
# 起動前点検は振り分けたレビュー役で回す。設定ファイルが LANES_REVIEW_ENGINE=gemini に固定していても、--engine codex なら agy を点検しない
fixed = T / 'fixed-gemini.conf'; fixed.write_text('LANES_REVIEW_ENGINE=gemini\n')
r, cap, done = run('run-review.sh', wt, 'e12', '--engine', 'codex', help='no-mode', env={'LANES_CONF': str(fixed)})
check('設定が gemini に固定でも --engine codex の起動は Gemini の点検で止めない', r.returncode == 0 and 'lane=codex-review' in (wt / 'logs/e12.pid').read_text(), out(r))
r, cap, done = run('run-review.sh', wt, 'e13', help='no-mode', env={'LANES_CONF': str(fixed)})
check('設定が gemini で agy が plan に対応していなければ、起動前点検で止める（EXIT:2・agy を起動しない）',
      r.returncode == 2 and cap is None and 'EXIT:2' in done and 'lanes-doctor' in r.stdout + r.stderr, out(r))

# ---- 3. 親の chk-run の記録 ----
wt, first = repo('require')
(wt / 'logs').mkdir()
r, cap, done = gem(wt, 'rq', env={'LANES_REVIEW_REQUIRE_CHECKS': '1', 'LANES_CHECK_CMD': '/usr/bin/true'})
check('LANES_REVIEW_REQUIRE_CHECKS=1 で記録が無ければ EXIT:2・子を起動しない', r.returncode == 2 and cap is None and 'chk-run の記録を使えない' in done and not (wt / 'logs/rq.evidence.md').exists(), out(r))
r, cap, done = gem(wt, 'rq', '--allow-missing-checks', env={'LANES_REVIEW_REQUIRE_CHECKS': '1', 'LANES_CHECK_CMD': '/usr/bin/true'})
check('--allow-missing-checks なら起動し、証跡に残す', r.returncode == 0 and cap is not None and '--allow-missing-checks で起動' in evidence(wt, 'rq'), out(r))
wt, first = repo('reuse')
# chk-run.sh は、レビューを起動するのと同じ環境（LANES_REVIEW_ENGINE だけは渡さない）で通す
chk = subprocess.run(['bash', str(lanes / 'chk-run.sh'), str(wt), '49997', str(T / 'chk-out')], env=make_env(env={'LANES_CHECK_CMD': '/usr/bin/true'}),
                     capture_output=True, text=True, timeout=120)
check('用意: chk-run.sh が記録を残す', chk.returncode == 0 and 'recorded=' in chk.stdout + chk.stderr, chk.stdout[-800:] + chk.stderr[-800:])
r, cap, done = run('run-review.sh', wt, 'ru', '--engine', 'gemini', env={'LANES_CHECK_CMD': '/usr/bin/true', 'LANES_REVIEW_ENGINE': 'gemini'})
check('起動のときだけ LANES_REVIEW_ENGINE を渡しても、親の chk-run の記録を使い回せる', r.returncode == 0 and '親の chk-run の記録を使用' in evidence(wt, 'ru'), out(r))

# ---- 4. 読み取り専用の強制 ----
wt, first = repo('jail')
r, cap, done = gem(wt, 'j1')
check('素直な本文は CLEAN・EXIT:0', r.returncode == 0 and 'VERDICT: CLEAN' in done and 'EXIT:0' in done, out(r))
a = cap['args']
settings = json.loads(a[a.index('--settings') + 1])
deny = settings['permissions']['deny']
check('--mode plan と --sandbox が渡る', a[a.index('--mode') + 1] == 'plan' and '--sandbox' in a)
check('--dangerously-skip-permissions・accept-edits・auto は渡らない', '--dangerously-skip-permissions' not in a and 'accept-edits' not in a and 'auto' not in a)
check('settings: MCP・書き込み・URL を拒否する', {'mcp(*)', 'write_file(*)', 'write_file(/)', 'read_url(*)', 'execute_url(*)'} <= set(deny), json.dumps(deny))
check('settings: commit・push・stash・tag・PR のマージ・別のエージェントの起動などのコマンドを拒否する',
      {'command(git commit)', 'command(git push)', 'command(git stash)', 'command(git tag)', 'command(gh pr merge)', 'command(agy)'} <= set(deny), json.dumps(deny))
check('settings: 作業場所の外を触らせない・サンドボックス有効・既定の提供元・クレジットなし',
      settings['allowNonWorkspaceAccess'] is False and settings['enableTerminalSandbox'] is True and settings['modelProvider'] == '' and settings['useG1Credits'] is False)
scratch = cap['env']['LANES_SCRATCH']
check('--add-dir は scratch だけ', [a[i + 1] for i, x in enumerate(a) if x == '--add-dir'] == [scratch] and scratch.startswith(str(T / 'scratch')))
check('出力は stream-json・--print-timeout は既定 45m・-p で全文を渡す', a[a.index('--output-format') + 1] == 'stream-json' and a[a.index('--print-timeout') + 1] == '45m' and a[a.index('-p') + 1].startswith('# レビュー本線（Gemini）'))
check('--model / --effort は既定では付けない（CLI の既定）', '--model' not in a and '--effort' not in a)
envs = cap['env']
check('子の環境: headless・TMPDIR と LANES_SCRATCH は scratch・GIT_OPTIONAL_LOCKS=0・GIT_PAGER=cat・通信止め',
      envs['ANTIGRAVITY_HEADLESS'] == 'true' and envs['TMPDIR'] == scratch + '/' and envs['GIT_OPTIONAL_LOCKS'] == '0' and envs['GIT_PAGER'] == 'cat'
      and envs['GIT_ALLOW_PROTOCOL'] == 'lanes-no-transport', json.dumps(envs))
gitconfig = pathlib.Path(envs['GIT_CONFIG_GLOBAL'])
check('子の環境: GIT_CONFIG_GLOBAL は scratch の最小 gitconfig', str(gitconfig).startswith(scratch) and 'pager = cat' in gitconfig.read_text())
check('子の環境: stdin は /dev/null・作業場所は worktree・API キーの変数なし', cap['stdin_devnull'] is True and os.path.realpath(cap['cwd']) == os.path.realpath(wt) and cap['keys_present'] == [])
r, cap, done = gem(wt, 'j2', env={'GEMINI_API_KEY': 'dummy-not-a-key', 'GOOGLE_API_KEY': 'dummy-not-a-key', 'AGY_ADC_AUTH': '1'})
check('呼び出し元に API キーの変数があっても子には渡さない', cap is not None and cap['keys_present'] == [], out(r))
merged = (wt / 'logs/j1.prompt.md').read_text()
check('指示書: テンプレの役名を Gemini に読み替え、案件の指示・閉じ込め・出し方・最終行の規則を付ける',
      merged.startswith('# レビュー本線（Gemini）') and '案件固有の検証指示（テスト）' in merged and 'このレビューの閉じ込め' in merged
      and '**全部** 列挙する' in merged and merged.rstrip().endswith('VERDICT: CLEAN\nVERDICT: NEEDS_FIX')
      and 'Claude' not in merged.split('# 案件固有の指示')[0])
for help_kind, why in (('no-mode', '--mode'), ('no-plan', 'plan'), ('no-sandbox', '--sandbox'), ('model-plan', '--mode（--model の説明の plan だけ）')):
    r, cap, done = gem(wt, 'j3', help=help_kind)
    check(f'agy --help に {why} が無ければ起動しない', r.returncode == 2 and cap is None and 'EXIT:2' in done, out(r))
main = T / 'main-checkout'; main.mkdir(); git(main, 'init', '-q', '-b', 'main')
for k, v in (('user.name', 'Test User'), ('user.email', 'you@example.com'), ('commit.gpgSign', 'false')): git(main, 'config', k, v)
(main / '.gitignore').write_text('logs/\n'); git(main, 'add', '.'); git(main, 'commit', '-qm', 'test: 初期')
r, cap, done = gem(main, 'j4', '--base', 'HEAD')
check('本体 checkout（.git がディレクトリ）では起動しない', r.returncode == 2 and cap is None and '本体 checkout' in r.stderr, out(r))

# ---- 5. 子が作業ツリー・git の管理フォルダ・制御ファイルを変えたら NEEDS_FIX（EXIT:4）----
for mutation in ('overwrite', 'untracked', 'commit', 'git-config', 'git-tag', 'gitlink'):
    wt, first = repo('mut-' + mutation)
    if mutation == 'gitlink': before_link = (wt / '.git').read_text()
    r, cap, done = gem(wt, 'rv', mutation=mutation)
    check(f'子の変更（{mutation}）は NEEDS_FIX・EXIT:4', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and 'EXIT:4' in done, out(r) + '\n' + done)
    check(f'子の変更（{mutation}）の後は再利用の記録を確定しない（IN_PROGRESS のまま）', state(wt, 'rv')['last_verdict'] == 'IN_PROGRESS', json.dumps(state(wt, 'rv')))
    if mutation in ('gitlink', 'git-config'):
        check(f'git の制御ファイルの変更（{mutation}）は git を呼ぶ前に止め、証跡を作らない', 'git の制御ファイル' in done and not (wt / 'logs/rv.evidence.md').exists(), done)
    if mutation == 'gitlink': (wt / '.git').write_text(before_link)

# ---- 6. 書き込み系のツールの呼び出し ----
wt, first = repo('writes')
r, cap, done = gem(wt, 'w1', mutation='write-tool')
ev_text = evidence(wt, 'w1')
check('書き込み系のツールを 1 回呼んだら不合格（EXIT:4・NEEDS_FIX）', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done, out(r))
check('同じ呼び出しの経過の記録は 1 件に数え、証跡に件数を書く', '書き込みの試み 1 件（write_file）' in ev_text, ev_text)
r, cap, done = gem(wt, 'w2', mutation='write-tools')
check('作成・編集・削除の呼び出しを全部数える', r.returncode == 4 and '書き込みの試み 3 件' in evidence(wt, 'w2'), evidence(wt, 'w2'))
r, cap, done = gem(wt, 'w3', mutation='read-tool')
check('読むだけのツール（read_file・run_command）は数えない', r.returncode == 0 and 'VERDICT: CLEAN' in done and '書き込みの試み 0 件' in evidence(wt, 'w3'), out(r))
r, cap, done = gem(wt, 'w4', replay=fixtures / 'denied-writes.jsonl')
check('実機の形: 拒否された write_file・edit_file も書き込みの試み 2 件として不合格', r.returncode == 4 and '書き込みの試み 2 件' in evidence(wt, 'w4'), out(r) + evidence(wt, 'w4'))
r, cap, done = gem(wt, 'w5', replay=fixtures / 'read-only-commands.jsonl')
check('実機の形: 読み取りのコマンドだけなら本文の VERDICT を採用（CLEAN）', r.returncode == 0 and 'VERDICT: CLEAN' in done, out(r))
check('最後の応答の本文だけを last.md に残す', (wt / 'logs/w5.last.md').read_text() == '問題なし\nVERDICT: CLEAN')
r, cap, done = gem(wt, 'w6', body='問題なし\u2028続きの文\nVERDICT: CLEAN')
check('本文の中の行区切りの文字（U+2028）で stream-json の 1 行を割らない（CLEAN）', r.returncode == 0 and 'VERDICT: CLEAN' in done, out(r) + done)

# ---- 7. JSON の不備・失敗・見張り ----
wt, first = repo('broken')
for events in ('bad_json', 'missing_result', 'dup_result', 'nonterminal', 'error_status', 'empty', 'bad_tool', 'no_init', 'dup_init', 'late_init'):
    r, cap, done = gem(wt, 'b-' + events, events=events)
    check(f'stream-json の不備（{events}）は VERDICT: NONE・EXIT:3', r.returncode == 3 and 'VERDICT: NONE' in done and (wt / f'logs/b-{events}.last.md').read_text() == '', out(r) + done)
r, cap, done = gem(wt, 'b-rc', rc=7)
check('agy が非 0 で終わったら NONE・その終了コード', r.returncode == 7 and 'VERDICT: NONE' in done and 'EXIT:7' in done, out(r))
r, cap, done = gem(wt, 'b-noout', events='sleep', env={'GEMINI_REVIEW_NOOUTPUT_SEC': '2', 'GT_SLEEP': '8'})
check('出力が止まったら EXIT:8・NONE（見張りは実装と同じ）', r.returncode == 8 and 'VERDICT: NONE' in done and '更新なし' in (wt / 'logs/b-noout.log').read_text(), out(r))
r, cap, done = gem(wt, 'b-idle', events='idle', env={'GT_SLEEP': '8'})
check('idle のまま子が無ければ EXIT:3・NONE', r.returncode == 3 and 'VERDICT: NONE' in done and 'idle' in evidence(wt, 'b-idle'), out(r))
r, cap, done = gem(wt, 'b-badcfg', env={'GEMINI_REVIEW_NOOUTPUT_SEC': 'abc'})
check('見張りの設定の誤りは起動前に EXIT:2', r.returncode == 2 and cap is None and 'EXIT:2' in done and 'GEMINI_REVIEW_NOOUTPUT_SEC' in r.stderr, out(r))
r, cap, done = gem(wt, 'b-timeout', env={'GEMINI_REVIEW_PRINT_TIMEOUT': '10m'})
check('GEMINI_REVIEW_PRINT_TIMEOUT を --print-timeout に渡す', cap is not None and cap['args'][cap['args'].index('--print-timeout') + 1] == '10m', out(r))
t0 = time.monotonic()
r, cap, done = gem(wt, 'b-hold', mutation='hold', timeout=60)
check('補助のプロセスが出力を持ち続けても、agy が終われば短い時間で終わる（受け取り役の DRAIN_SEC）',
      r.returncode == 0 and 'VERDICT: CLEAN' in done and time.monotonic() - t0 < 25, out(r) + f'\n経過 {time.monotonic() - t0:.1f} 秒')

# ---- 8. VERDICT・指摘・GATE・後回し票・ESCALATE は Claude レビューと同じ ----
skip_line = 'CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP'
cases = [
    ('c1-r1', 'VERDICT: CLEAN'),
    ('c2-r1', '- [P1] a.txt:1 認証の不具合\nVERDICT: CLEAN'),
    ('c3-r1', '- [P2] 条件付きの不具合\nVERDICT: NEEDS_FIX'),
    ('c4-r1', '- [P3] 文言\nVERDICT: CLEAN'),
    ('c5-r3', '- [P2] 残件\n  再現条件\n' + skip_line + '\nVERDICT: NEEDS_FIX'),
    ('c6-r3', '- [P2] 残件\nVERDICT: NEEDS_FIX'),
    ('c7-r6', '- [P1] 残る重大な指摘\nVERDICT: NEEDS_FIX'),
    ('c8-r1', 'レビューを完了できませんでした\nVERDICT: CLEAN'),
    ('c9-r1', 'typecheck / lint / unit / build 未実施\nVERDICT: CLEAN'),
]
for label, body in cases:
    seen = {}
    for script in ('run-claude-review.sh', 'run-gemini-review.sh'):
        wt, first = repo(f'parity-{label}-{script[4:10]}')
        r, cap, done = run(script, wt, label, body=body)
        series = re.sub(r'-r[0-9]+$', '', label)
        fu = wt / 'logs' / f'{series}.followups.md'
        exit_line = re.search(r'^EXIT:(\d+)', done, re.M)
        verdict_line = re.search(r'^VERDICT: \S+', done, re.M)
        fu_text = '\n'.join(l for l in fu.read_text().splitlines() if not l.startswith('## round')) if fu.exists() else ''
        seen[script] = (r.returncode, exit_line[0] if exit_line else '', verdict_line[0] if verdict_line else '', note_gate(done), fu_text)
    c, g = seen['run-claude-review.sh'], seen['run-gemini-review.sh']
    check(f'Claude と同じ判定 {label}: rc・EXIT・VERDICT・GATE・後回し票', c == g, f'claude={c}\ngemini={g}')

# ---- 9. モデル・effort の記録と証跡 ----
wt, first = repo('model')
r, cap, done = gem(wt, 'm1', env={'GEMINI_REVIEW_MODEL': 'review-model-x', 'GEMINI_REVIEW_EFFORT': 'low', 'GEMINI_MODEL': 'impl-model-y', 'GEMINI_EFFORT': 'max'})
pid = (wt / 'logs/m1.pid').read_text()
a = cap['args']
check('.pid の model= / effort= は GEMINI_REVIEW_MODEL / GEMINI_REVIEW_EFFORT', 'model=review-model-x' in pid.splitlines() and 'effort=low' in pid.splitlines(), pid)
check('子へは --model / --effort でその値を渡し、実装用の GEMINI_MODEL / GEMINI_EFFORT は使わない',
      a[a.index('--model') + 1] == 'review-model-x' and a[a.index('--effort') + 1] == 'low' and 'impl-model-y' not in a and 'max' not in a)
ev_text = evidence(wt, 'm1')
check('証跡にモデル・effort とレビューエンジンの行', '- モデル: review-model-x / effort low' in ev_text and '- レビューエンジン: gemini' in ev_text and ev_text.startswith('## Gemini レビュー証跡（m1）'), ev_text)
r, cap, done = gem(wt, 'm2', env={'GEMINI_REVIEW_EFFORT': 'medium'})
check('環境変数の GEMINI_REVIEW_EFFORT が設定と違えば注意を 1 行出す', '注意: GEMINI_REVIEW_EFFORT は環境変数の値「medium」で動く' in r.stderr, r.stderr[-800:])

# ---- 10. 同じ道具でレビューしない ----
wt, first = repo('same')
(wt / 'logs').mkdir()
(wt / 'logs/impl.prev-20260101-000000.pid').write_text('pid=1\nlane=gemini\nworktree=x\n')
r, cap, done = gem(wt, 's1')
check('Gemini 実装の記録（回転した .pid の lane=gemini）があれば起動しない（EXIT:2・agy 未起動）',
      r.returncode == 2 and cap is None and 'Gemini 実装の記録がある' in done and 'Codex か Claude のレビュー' in done, out(r))
r, cap, done = run('run-review.sh', wt, 's2', '--engine', 'gemini')
check('入口（--engine gemini）からも同じく拒否', r.returncode == 2 and cap is None and 'Gemini 実装の記録がある' in done, out(r))
r, cap, done = gem(wt, 's3', '--allow-same-engine')
check('--allow-same-engine なら回し、証跡にその旨を 1 行残す', r.returncode == 0 and cap is not None and '- 同じ道具のレビュー: ' in evidence(wt, 's3') and '--allow-same-engine で起動' in evidence(wt, 's3'), out(r))
r, cap, done = run('run-review.sh', wt, 's4', '--engine', 'gemini', '--allow-same-engine')
check('入口も --allow-same-engine を渡す', r.returncode == 0 and cap is not None, out(r))
r, cap, done = run('run-review.sh', wt, 's5', '--engine', 'claude')
check('Codex・Claude のレビューは今までどおり回る（Gemini 実装の記録があっても）', r.returncode == 0 and 'VERDICT: CLEAN' in done, out(r))
wt, first = repo('same-evidence')
(wt / 'logs').mkdir(); (wt / 'logs/impl.evidence.prev-20260101-000000.md').write_text('## Gemini 実装証跡（impl）\n- 結果: EXIT:0\n')
r, cap, done = gem(wt, 's6')
check('Gemini 実装の証跡の見出しでも拒否', r.returncode == 2 and cap is None, out(r))
wt, first = repo('same-other')
(wt / 'logs').mkdir(); (wt / 'logs/rev.pid').write_text('pid=1\nlane=gemini-review\n'); (wt / 'logs/q.pid').write_text('pid=1\nlane=qa\n')
r, cap, done = gem(wt, 's7')
check('Gemini レビュー・QA の記録は Gemini 実装に数えない', r.returncode == 0 and cap is not None, out(r))
wt, first = repo('same-unreadable')
(wt / 'logs').mkdir(); bad = wt / 'logs' / 'old.pid'; bad.write_text('pid=1\nlane=claude\n'); bad.chmod(0)
r, cap, done = gem(wt, 's8')
check('候補の .pid を読めなければ「記録あり（読めない）」として起動しない（EXIT:2）', r.returncode == 2 and cap is None and '読めない' in done, out(r) + done)
bad.chmod(0o644)

# ---- 11. 同じ head の結果の再利用と delta・前回 NEEDS_FIX・dry-run ----
wt, first = repo('dedup')
r, cap, done = gem(wt, 'd-r1')
first_head = git(wt, 'rev-parse', 'HEAD')
r, cap, done = gem(wt, 'd-r1')
check('同じ head は前回の結果を使い、agy を起動しない（skip-same-head）', r.returncode == 0 and cap is None and 'VERDICT: CLEAN' in done
      and 'skip-same-head' in evidence(wt, 'd-r1') and '- レビューエンジン: gemini' in evidence(wt, 'd-r1'), out(r))
r, cap, done = gem(wt, 'd-r1', '--force')
check('--force なら同じ head でも回す', cap is not None and r.returncode == 0, out(r))
(wt / 'c.txt').write_text('軽い修正'); git(wt, 'add', 'c.txt'); git(wt, 'commit', '-qm', 'fix: 軽い修正')
r, cap, done = gem(wt, 'd-r2')
merged = (wt / 'logs/d-r2.prompt.md').read_text()
check('前回 CLEAN の後の新しい commit は delta（前回の head から）', cap is not None and 'delta 再レビュー' in merged and f'git diff {first_head}...HEAD' in merged
      and 'モード: delta' in evidence(wt, 'd-r2'), out(r))
r, cap, done = gem(wt, 'd-r2', '--force', body='- [P1] a.txt:1 直っていない\nVERDICT: NEEDS_FIX')
check('用意: 同じ round を --force で回し直して NEEDS_FIX（記録も NEEDS_FIX で確定）', 'VERDICT: NEEDS_FIX' in done and state(wt, 'd')['last_verdict'] == 'VERDICT: NEEDS_FIX', done)
(wt / 'd.txt').write_text('直し'); git(wt, 'add', 'd.txt'); git(wt, 'commit', '-qm', 'fix: 直し')
r, cap, done = gem(wt, 'd-r2', '--mode', 'delta')
merged = (wt / 'logs/d-r2.prompt.md').read_text()
check('前回 NEEDS_FIX なら明示 delta でも full に戻して未解決指摘を引き継ぐ', 'full レビュー' in merged and '直っていない' in merged and 'VERDICT: NEEDS_FIX' in done
      and f'git diff {first}...HEAD' in merged, done)
r, cap, done = gem(wt, 'd-r2', body='a.txt:1 の指摘は解消済み\nRESOLVED_PREVIOUS_FINDINGS: YES\nVERDICT: CLEAN')
check('前回 NEEDS_FIX の後は、全件の解消の宣言があるときだけ CLEAN（Claude と同じ）', 'VERDICT: CLEAN' in done, done)
wt, first = repo('dry')
r, cap, done = gem(wt, 'dr', '--dry-run')
check('--dry-run は agy を起動せず .pid / .done / ログ・再利用の記録を作らない', r.returncode == 0 and cap is None and not (wt / 'logs/dr.pid').exists()
      and not (wt / 'logs/dr.done').exists() and not (wt / 'logs/dr.log').exists() and (wt / 'logs/dr.dry-run.prompt.md').exists()
      and state(wt, 'dr') is None and '--mode plan --sandbox --settings' in r.stdout, out(r))

# ---- 12. 確認中の印（IN_PROGRESS）----
wt, first = repo('inprog')
r, cap, done = gem(wt, 'ip-r1')
check('用意: 1 回目は CLEAN で確定', r.returncode == 0 and state(wt, 'ip')['last_verdict'] == 'VERDICT: CLEAN' and state(wt, 'ip')['last_exit'] == 0, out(r))
r, cap, done = gem(wt, 'ip-r2', '--force', rc=7)
seen_state = json.loads(cap['states']['.ip.review-state'])
check('子の起動の前に、系列の記録を IN_PROGRESS（last_exit=-1・last_round は前の値）に書き換えている',
      seen_state['last_verdict'] == 'IN_PROGRESS' and seen_state['last_exit'] == -1 and seen_state['last_round'] == '1' and seen_state['last_head'] == '',
      json.dumps(seen_state, ensure_ascii=False))
check('agy が失敗したら確定しない（IN_PROGRESS のまま・EXIT:7）', r.returncode == 7 and state(wt, 'ip')['last_verdict'] == 'IN_PROGRESS', out(r))
# 過去の証跡（ip-r1.evidence.md は CLEAN・EXIT:0）にも戻らない
probe = subprocess.run(['zsh', '-fc', 'source "$1/review-dedup.zsh"; print -r -- "[$(rvd_prev_record "$2" ip 3)]"', '_', str(lanes), str(wt / 'logs')],
                       env=BASE, capture_output=True, text=True)
check('IN_PROGRESS のときは rvd_prev_record が空（過去の CLEAN の証跡に戻らない）', probe.stdout.strip() == '[]' and 'VERDICT: CLEAN' in (wt / 'logs/ip-r1.evidence.md').read_text(), probe.stdout + probe.stderr)
r, cap, done = gem(wt, 'ip-r3')
check('途中で終わった後の起動は、古い CLEAN を使わず full で回す（同じ HEAD でも agy を起動する）',
      r.returncode == 0 and cap is not None and 'skip-same-head' not in evidence(wt, 'ip-r3') and 'モード: full' in evidence(wt, 'ip-r3'), out(r))
check('成功したら CLEAN で確定する', state(wt, 'ip')['last_verdict'] == 'VERDICT: CLEAN' and state(wt, 'ip')['last_label'] == 'ip-r3')
# 見張りの停止・書き込みの試みでも確定しない
for kind, kw, want in (('noout', dict(events='sleep', env={'GEMINI_REVIEW_NOOUTPUT_SEC': '2', 'GT_SLEEP': '8'}), 8),
                       ('write', dict(mutation='write-tool'), 4), ('json', dict(events='bad_json'), 3)):
    wt, first = repo('inprog-' + kind)
    gem(wt, 'q-r1')
    r, cap, done = gem(wt, 'q-r1', '--force', **kw)
    check(f'{kind} で止まったら確定しない（IN_PROGRESS・EXIT:{want}）', r.returncode == want and state(wt, 'q')['last_verdict'] == 'IN_PROGRESS', out(r))
    r, cap, done = gem(wt, 'q-r1')
    check(f'{kind} の後の通常の起動は、古い CLEAN の同じ HEAD の省略をしない', cap is not None and 'skip-same-head' not in evidence(wt, 'q-r1'), out(r))
# 中断（SIGTERM）でも確定しない
wt, first = repo('inprog-term')
gem(wt, 'k-r1')
capture.unlink(missing_ok=True)
p = subprocess.Popen(['zsh', '-f', str(lanes / 'run-gemini-review.sh'), str(wt), str(prompt), 'k-r1', '--force'],
                     env=make_env(events='sleep', env={'GT_SLEEP': '30'}), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
for _ in range(300):
    if capture.exists(): break
    time.sleep(0.1)
check('用意: 中断の前に agy が起動した', capture.exists())
time.sleep(1); p.send_signal(signal.SIGTERM)
so, se = p.communicate(timeout=60)
done = (wt / 'logs/k-r1.done').read_text()
check('中断（SIGTERM）したら確定しない（IN_PROGRESS・.done は NONE）', p.returncode == 143 and 'VERDICT: NONE' in done and state(wt, 'k')['last_verdict'] == 'IN_PROGRESS', f'{p.returncode}\n{se[-1500:]}\n{done}')
r, cap, done = gem(wt, 'k-r1')
check('中断の後の通常の起動は、古い CLEAN の同じ HEAD の省略をしない', cap is not None and 'skip-same-head' not in evidence(wt, 'k-r1'), out(r))
# 記録の書き込みの失敗（公開ログ・証跡・後回し票）では確定しない
for what in ('last.md', 'evidence.md'):
    wt, first = repo('inprog-wf-' + what.split('.')[0])
    gem(wt, 'f-r1')
    (wt / 'logs' / f'f-r1.{what}').unlink(missing_ok=True); (wt / 'logs' / f'f-r1.{what}').mkdir()
    r, cap, done = gem(wt, 'f-r1', '--force')
    check(f'{what} を書けなければ確定しない（IN_PROGRESS・EXIT:3・.done は NONE）', r.returncode == 3 and 'VERDICT: NONE' in done and '記録を書けない' in done
          and state(wt, 'f')['last_verdict'] == 'IN_PROGRESS', out(r) + done)
wt, first = repo('inprog-wf-followups')
(wt / 'logs').mkdir(); (wt / 'logs/g.followups.md').mkdir()
r, cap, done = gem(wt, 'g-r3', body='- [P2] 残件\n' + skip_line + '\nVERDICT: NEEDS_FIX')
check('後回し票を書けなければ確定しない（IN_PROGRESS・EXIT:3）', r.returncode == 3 and 'VERDICT: NONE' in done and state(wt, 'g')['last_verdict'] == 'IN_PROGRESS', out(r) + done)
# 前回 NEEDS_FIX の未解決指摘は、途中で終わっても次へ引き継ぐ（CLEAN は引き継がない）
wt, first = repo('inprog-carry')
r, cap, done = gem(wt, 'n-r1', body='- [P1] a.txt:1 未解決の重大な指摘\nVERDICT: NEEDS_FIX')
check('用意: 1 回目は NEEDS_FIX で確定', state(wt, 'n')['last_verdict'] == 'VERDICT: NEEDS_FIX', done)
r, cap, done = gem(wt, 'n-r2', rc=7)
st = state(wt, 'n')
check('NEEDS_FIX の後に途中で終わったら、IN_PROGRESS の記録に未解決指摘を持ち越す',
      st['last_verdict'] == 'IN_PROGRESS' and st['last_carried_verdict'] == 'VERDICT: NEEDS_FIX' and '未解決の重大な指摘' in st['last_report'], json.dumps(st, ensure_ascii=False))
r, cap, done = gem(wt, 'n-r2', '--mode', 'delta', body='問題なし\nVERDICT: CLEAN')
merged = (wt / 'logs/n-r2.prompt.md').read_text()
check('次の起動は full に戻して未解決指摘を引き継ぎ、解消の宣言が無ければ NEEDS_FIX', 'full レビュー' in merged and '未解決の重大な指摘' in merged
      and 'VERDICT: NEEDS_FIX' in done and '途中で終わったレビュー（IN_PROGRESS）' in evidence(wt, 'n-r2'), out(r) + done)
# round の数え: label に -r<N> が無くても、途中で終わった round をもう一度回す
wt, first = repo('inprog-round')
gem(wt, 'plain'); gem(wt, 'plain', '--force', rc=7)
check('途中で終わっても round の数え（last_round）は前の値のまま', state(wt, 'plain')['last_round'] == '1', json.dumps(state(wt, 'plain')))
r, cap, done = gem(wt, 'plain')
check('次の起動は同じ round（2）を回し直す', 'round=2' in evidence(wt, 'plain'), evidence(wt, 'plain'))
wt, first = repo('inprog-first')
r, cap, done = gem(wt, 'z-r4', rc=7)
check('記録が無い系列の初回で失敗したら、last_round は round - 1', state(wt, 'z')['last_round'] == '3' and state(wt, 'z')['last_verdict'] == 'IN_PROGRESS', json.dumps(state(wt, 'z')))

# ---- 13. 本文の途中の独立した行の VERDICT ----
inline_cases = [
    ('i1', '指摘なし\nVERDICT: CLEAN\n以上です。', 'VERDICT: CLEAN', 0, True),
    ('i2', '- **VERDICT: CLEAN**\n補足の説明', 'VERDICT: CLEAN', 0, True),
    ('i3', 'VERDICT: NEEDS_FIX\n考え直した\nVERDICT: CLEAN\n補足', 'VERDICT: NEEDS_FIX', 0, True),
    ('i4', 'VERDICT: PASS\n補足', 'VERDICT: CLEAN', 0, True),
    ('i5', '```\nVERDICT: CLEAN\n```\n補足', 'VERDICT: NONE', 3, False),
    ('i6', '> VERDICT: CLEAN\n補足', 'VERDICT: NONE', 3, False),
    ('i7', '1. VERDICT: CLEAN\n補足', 'VERDICT: NONE', 3, False),
    ('i8', '| VERDICT: CLEAN |\n補足', 'VERDICT: NONE', 3, False),
    ('i9', '    VERDICT: CLEAN\n補足', 'VERDICT: NONE', 3, False),
    ('i10', 'レビューを完了できませんでした\nVERDICT: CLEAN\n補足', 'VERDICT: NONE', 3, False),
    ('i11', 'VERDICT: CLEAN\n補足\n```\n閉じていないコード', 'VERDICT: NONE', 3, False),
    ('i12', '- [P1] a.txt:1 重大\nVERDICT: CLEAN\n補足', 'VERDICT: NEEDS_FIX', 0, False),
    ('i13', 'typecheck: 未実施\nVERDICT: CLEAN\n補足', 'VERDICT: NEEDS_FIX', 0, False),
    ('i14', '判定の文字列は本文のどこにも無い\n補足', 'VERDICT: NONE', 3, False),
    ('i15', '本文の中の VERDICT: CLEAN は独立した行ではない\n補足', 'VERDICT: NONE', 3, False),
]
wt, first = repo('inline')
for label, body, want, want_rc, noted in inline_cases:
    r, cap, done = gem(wt, label, body=body)
    ev_text = evidence(wt, label)
    check(f'本文の途中の VERDICT（{label}）は {want}・EXIT:{want_rc}', r.returncode == want_rc and re.search(r'^' + re.escape(want) + r'$', done, re.M) is not None
          and (('VERDICT の読み取り: 本文の途中の独立した行' in ev_text) == noted), out(r) + done + ev_text)
check('本文の途中の判定で CLEAN にしたときも記録を確定する', state(wt, 'i1')['last_verdict'] == 'VERDICT: CLEAN')
wt, first = repo('inline-claude')
r, cap, done = run('run-claude-review.sh', wt, 'ic', body='指摘なし\nVERDICT: CLEAN\n以上です。')
check('Claude レビューの読み取りは今までどおり（最後の行でなければ NONE）', r.returncode == 3 and 'VERDICT: NONE' in done, out(r))

# ---- 14. 生死の見張り・点検・役割の表示 ----
wt, first = repo('status')
gem(wt, 'st')
st_out = subprocess.run(['zsh', '-f', str(lanes / 'lanes-status.sh'), str(wt), 'st'], env=BASE, capture_output=True, text=True)
check('lanes-status.sh は Gemini レビューの終了を DONE で読む', st_out.stdout.startswith('DONE'), st_out.stdout + st_out.stderr)
runs = T / 'runs'; runs.mkdir(exist_ok=True)
mon_wt, _ = repo('runs/monitor')
gem(mon_wt, 'mon')
mon = subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh'), '--no-append'], env=dict(BASE, LANES_MONITOR_STATE=str(T / 'mon-state.json')),
                     capture_output=True, text=True, timeout=60)
check('lanes-monitor.sh の新規終了に [gemini-review] の印', '[gemini-review]' in mon.stdout, mon.stdout[-1500:] + mon.stderr[-800:])
def doctor(*args, env=None, help='full'):
    return subprocess.run(['zsh', '-f', str(lanes / 'lanes-doctor.sh'), *args], env=make_env(help=help, env=env), capture_output=True, text=True)
d = doctor()
check('点検: 既定の設定では Gemini レビューの点検を足さない', d.returncode == 0 and 'gemini レビュー' not in d.stdout, d.stdout)
d = doctor('--review-engine', 'gemini')
check('点検: --review-engine gemini なら agy の --sandbox・--settings・--mode plan を見る', d.returncode == 0 and 'gemini レビュー: agy が --sandbox・--settings・--mode plan に対応' in d.stdout, d.stdout)
d = doctor('--review-engine', 'gemini', help='model-plan')
check('点検: --mode が無く --model の説明に plan があるだけなら NG（単語として照合）', d.returncode == 2 and '--mode' in d.stdout and 'NG' in d.stdout, d.stdout)
d = doctor(env={'LANES_REVIEW_ENGINE': 'gemini'}, help='no-plan')
check('点検: LANES_REVIEW_ENGINE=gemini でも同じく見る（plan が無ければ NG）', d.returncode == 2 and '--mode plan' in d.stdout, d.stdout)
d = doctor('--review-engine', 'codex', env={'LANES_REVIEW_ENGINE': 'gemini'}, help='no-plan')
check('点検: --review-engine は設定に勝つ（codex なら Gemini レビューの点検をしない）', d.returncode == 0 and 'gemini レビュー' not in d.stdout, d.stdout)
d = doctor('--review-engine', 'gemini', env={'LANES_TOOLS': 'claude codex'})
check('点検: 構成に gemini が無いのに Gemini レビューを指定したら NG', d.returncode == 2 and 'gemini が無い' in d.stdout, d.stdout)
d = doctor('--review-engine', 'bogus')
check('点検: --review-engine の知らない値は exit 2', d.returncode == 2, d.stdout + d.stderr)
roles = lambda env: subprocess.run(['zsh', '-f', str(lanes / 'lanes-roles.sh'), '--print'], env=dict(BASE, **env), capture_output=True, text=True).stdout
pr = roles({'LANES_TOOLS': 'claude gemini'})
check('役割の表示: gemini がある構成では Gemini レビューの案内を出す', 'Gemini レビュー: 明示したときだけ' in pr and 'run-gemini-review.sh' in pr, pr)
pr = roles({'LANES_TOOLS': 'claude gemini', 'LANES_REVIEW_ENGINE': 'gemini'})
check('役割の表示: LANES_REVIEW_ENGINE=gemini の振り分け先と独立性を出す', 'run-gemini-review.sh へ振り分ける' in pr and '指定のレビュー役（LANES_REVIEW_ENGINE=gemini）の独立性: あり' in pr, pr)
pr = roles({'LANES_TOOLS': 'claude codex'})
check('役割の表示: gemini の無い構成では Gemini レビューの案内を出さない', 'Gemini レビュー' not in pr, pr)

# ---- 15. 記録の確定と安全の直し ----
# 15-1. round 3 以降、前回が P2 だけでも、今回の本文が重大度を読み取れない NEEDS_FIX なら、前回分の後回しで CLEAN にしない
wt, first = repo('defer-new')
r, cap, done = gem(wt, 'x-r2', body='- [P2] a.txt:1 前回の軽微な指摘\nVERDICT: NEEDS_FIX')
check('用意: round 2 は P2 だけの NEEDS_FIX で確定', state(wt, 'x')['last_verdict'] == 'VERDICT: NEEDS_FIX', done)
r, cap, done = gem(wt, 'x-r3', body='a.txt:5 に今回見つけた新しい問題がある（重大度の印なし）\n' + skip_line + '\nVERDICT: NEEDS_FIX')
check('round 3: 前回が P2 だけでも、今回の本文が重大度を読み取れない NEEDS_FIX なら NEEDS_FIX のまま（後回し票も作らない）',
      r.returncode == 0 and 'VERDICT: NEEDS_FIX' in done and note_gate(done) == 'FIX' and not (wt / 'logs/x.followups.md').exists(), out(r) + done)
wt, first = repo('defer-ok')
gem(wt, 'y-r2', body='- [P2] a.txt:1 前回の軽微な指摘\nVERDICT: NEEDS_FIX')
r, cap, done = gem(wt, 'y-r3', body='新しい指摘なし\n' + skip_line + '\nVERDICT: CLEAN')
fu = wt / 'logs/y.followups.md'
check('round 3: 今回が CLEAN なら、前回の P2 を後回し票へ移して通す（今までどおり）',
      r.returncode == 0 and 'VERDICT: CLEAN' in done and note_gate(done) == 'MERGE_WITH_FOLLOWUP' and fu.exists() and '前回の軽微な指摘' in fu.read_text(), out(r) + done)

# 15-2. 再利用の記録を確定できなければ、証跡・ログの末尾・標準出力に合格を残さない（.done と同じ NONE / EXIT:3）
wt, first = repo('fin-fail')
r, cap, done = gem(wt, 'ff', mutation='log-unreadable', env={'GT_LABEL': 'ff'})
logf = wt / 'logs/ff.log'; logf.chmod(0o644)
ev_text, log_text = evidence(wt, 'ff'), logf.read_text()
check('確定に失敗したら、.done・証跡・ログの末尾はどれも VERDICT: NONE / EXIT:3（合格の証跡を残さない）',
      r.returncode == 3 and 'EXIT:3' in done and 'VERDICT: NONE' in done
      and '- VERDICT: NONE' in ev_text and '- VERDICT: CLEAN' not in ev_text and 'EXIT:3' in ev_text and '記録の確定: できなかった' in ev_text
      and log_text.rstrip().endswith('EXIT:3\nVERDICT: NONE') and '上の判定は採用しない' in log_text and '- VERDICT: CLEAN' not in r.stdout,
      out(r) + done + ev_text + log_text[-600:])
check('確定に失敗したら、再利用の記録は IN_PROGRESS のまま', state(wt, 'ff')['last_verdict'] == 'IN_PROGRESS', json.dumps(state(wt, 'ff'), ensure_ascii=False))
r, cap, done = gem(wt, 'ff')
check('次の通常の起動は回して CLEAN で確定する', r.returncode == 0 and cap is not None and state(wt, 'ff')['last_verdict'] == 'VERDICT: CLEAN'
      and evidence(wt, 'ff').count('- VERDICT: CLEAN') == 1 and '- VERDICT: CLEAN' in r.stdout, out(r))
# 同じ head の結果を使うときも、証跡を書けなければ合格にしない
(wt / 'logs/ff.evidence.md').unlink(); (wt / 'logs/ff.evidence.md').mkdir()
r, cap, done = gem(wt, 'ff')
check('skip-same-head でも証跡を書けなければ EXIT:3・VERDICT: NONE（前回の結果を使ったことにしない）',
      r.returncode == 3 and cap is None and 'VERDICT: NONE' in done and '記録を書けない' in done and '- VERDICT: CLEAN' not in r.stdout, out(r) + done)
(wt / 'logs/ff.evidence.md').rmdir()

# 15-3. dry-run でも書き込み先を確かめ、リンクを辿らない（Gemini レビュー・Gemini 実装）
wt, first = repo('dry-link')
elsewhere = T / 'dry-elsewhere'; elsewhere.mkdir()
(wt / 'logs').symlink_to(elsewhere)
r, cap, done = gem(wt, 'dl', '--dry-run')
check('dry-run: logs/ が symlink なら書かない（EXIT:2・リンク先に何も作らない）', r.returncode == 2 and cap is None and list(elsewhere.iterdir()) == [], out(r))
(wt / 'logs').unlink(); (wt / 'logs').mkdir()
victim = T / 'dry-victim.txt'; victim.write_text('元の中身')
(wt / 'logs/dp.dry-run.prompt.md').symlink_to(victim)
r, cap, done = gem(wt, 'dp', '--dry-run')
dp = wt / 'logs/dp.dry-run.prompt.md'
check('dry-run: 既存の <label>.dry-run.prompt.md が symlink でもリンク先を上書きせず、普通のファイルとして新しく書く',
      r.returncode == 0 and victim.read_text() == '元の中身' and not dp.is_symlink() and dp.read_text().startswith('# レビュー本線（Gemini）'), out(r))
(wt / 'logs/gi.dry-run.prompt.md').symlink_to(victim)
gi = subprocess.run(['zsh', '-f', str(lanes / 'run-gemini.sh'), str(wt), str(prompt), 'gi', '--verify', 'true', '--allow-path', 'owned.txt', '--dry-run'],
                    env=make_env(), capture_output=True, text=True, timeout=120)
check('Gemini 実装の dry-run も同じく、symlink の書き先を辿らずに普通のファイルとして書く',
      gi.returncode == 0 and victim.read_text() == '元の中身' and not (wt / 'logs/gi.dry-run.prompt.md').is_symlink()
      and '案件固有の検証指示（テスト）' in (wt / 'logs/gi.dry-run.prompt.md').read_text(), out(gi))
shutil.rmtree(wt / 'logs'); (wt / 'logs').symlink_to(elsewhere)
gi = subprocess.run(['zsh', '-f', str(lanes / 'run-gemini.sh'), str(wt), str(prompt), 'gi', '--verify', 'true', '--allow-path', 'owned.txt', '--dry-run'],
                    env=make_env(), capture_output=True, text=True, timeout=120)
check('Gemini 実装の dry-run も logs/ が symlink なら書かない（EXIT:2）', gi.returncode == 2 and list(elsewhere.iterdir()) == [], out(gi))
(wt / 'logs').unlink()

# 15-4. 前回の指摘本文を読み切ってから IN_PROGRESS に置き換える（読めなければ元の記録を残して 1）
ld = T / 'mark-logs'; ld.mkdir()
orig = json.dumps({'last_round': '1', 'last_verdict': 'VERDICT: NEEDS_FIX', 'last_exit': 0, 'last_report': '- [P1] a.txt:1 未解決の重大な指摘\n',
                   'last_blocking_previous': '0', 'last_label': 's-r1'}, ensure_ascii=False) + '\n'
for kind, override in (('読み出しの失敗', 'rvd_record_get() { [[ "$2" == report ]] && { print -n -- "途中まで"; return 1; }; rvd_state_get "$1" "last_$2"; }'),
                       ('空の本文', 'rvd_record_get() { [[ "$2" == report ]] && { print -- "  "; return 0; }; rvd_state_get "$1" "last_$2"; }')):
    (ld / '.s.review-state').write_text(orig)
    probe = subprocess.run(['zsh', '-fc', 'source "$1/review-dedup.zsh"; eval "$3"; rvd_mark_in_progress "$2" s 2 s-r2 "$2/.s.review-state" "VERDICT: NEEDS_FIX"; print -r -- "rc=$?"',
                            '_', str(lanes), str(ld), override], env=BASE, capture_output=True, text=True)
    check(f'rvd_mark_in_progress: 前回の本文が{kind}なら 1 を返し、元の NEEDS_FIX の記録を壊さない',
          probe.stdout.strip().endswith('rc=1') and (ld / '.s.review-state').read_text() == orig, probe.stdout + probe.stderr + (ld / '.s.review-state').read_text())
(ld / '.s.review-state').write_text(orig)
probe = subprocess.run(['zsh', '-fc', 'source "$1/review-dedup.zsh"; rvd_mark_in_progress "$2" s 2 s-r2 "$2/.s.review-state" "VERDICT: NEEDS_FIX"; print -r -- "rc=$?"',
                        '_', str(lanes), str(ld)], env=BASE, capture_output=True, text=True)
st = json.loads((ld / '.s.review-state').read_text())
check('rvd_mark_in_progress: 読めたときは今までどおり IN_PROGRESS に本文を持ち越す',
      probe.stdout.strip().endswith('rc=0') and st['last_verdict'] == 'IN_PROGRESS' and st['last_report'] == '- [P1] a.txt:1 未解決の重大な指摘\n', probe.stdout + probe.stderr)

# 15-5. 親の python はレビュー対象の worktree の中のモジュールを読まない（worktree の中から起動しても）
wt, first = repo('isolate')
marker = T / 'planted-import-marker'
(wt / 'json.py').write_text(f'open({str(marker)!r}, "w").write("imported")\n')
for how, script, extra in (('直接', 'run-gemini-review.sh', ()), ('入口（--engine gemini）', 'run-review.sh', ('--engine', 'gemini'))):
    r, cap, done = run(script, wt, 'iso-' + script[4:8], *extra, cwd=wt, env={'LANES_REVIEW_REUSE_CHECKS': '0'})
    check(f'{how}: worktree の中から起動しても、親の python が worktree の json.py を読まない',
          r.returncode == 0 and cap is not None and 'VERDICT: CLEAN' in done and not marker.exists(), out(r) + done)
marker.unlink(missing_ok=True)

# 15-6. 監査で失格（EXIT:4）の回の指摘は、後回し票に書かない（次の回で重ならない）
wt, first = repo('fu-audit')
body3 = '- [P2] 今回の残件\n' + skip_line + '\nVERDICT: NEEDS_FIX'
fu = wt / 'logs/h.followups.md'
r, cap, done = gem(wt, 'h-r3', mutation='write-tool', body=body3)
check('round 3 の P2 でも、書き込みの試みで失格（EXIT:4）なら後回し票に書かない（証跡にも保存していないと書く）',
      r.returncode == 4 and not fu.exists() and '（確定しなかったので保存していない）' in evidence(wt, 'h-r3'), out(r) + done)
r, cap, done = gem(wt, 'h-r3', body=body3)
check('監査を通った回だけ後回し票に公開し、失格の回の分は重ならない',
      r.returncode == 0 and fu.read_text().count('## round 3') == 1 and fu.read_text().count('今回の残件') == 1
      and '確定しなかったので' not in evidence(wt, 'h-r3'), out(r) + (fu.read_text() if fu.exists() else ''))
wt, first = repo('fu-prev')
gem(wt, 'p-r2', body='- [P2] a.txt:1 前回の軽微な指摘\nVERDICT: NEEDS_FIX')
fu = wt / 'logs/p.followups.md'
r, cap, done = gem(wt, 'p-r3', mutation='write-tool', body='新しい指摘なし\n' + skip_line + '\nVERDICT: CLEAN')
check('前回分の後回しも、失格（EXIT:4）の回は後回し票に書かない', r.returncode == 4 and not fu.exists(), out(r) + done)
r, cap, done = gem(wt, 'p-r3', body='新しい指摘なし\n' + skip_line + '\nVERDICT: CLEAN')
check('次の通常の起動で、前回分を 1 回だけ後回し票へ公開して通す',
      r.returncode == 0 and note_gate(done) == 'MERGE_WITH_FOLLOWUP' and fu.read_text().count('前回の軽微な指摘') == 1, out(r) + done)

# 15-7. 最後の行の文字が途中で切れても、その前の書き込みの試みを捨てない（EXIT:4 を優先）
wt, first = repo('badutf8')
r, cap, done = gem(wt, 'u8', events='write_badutf8')
ev_text = evidence(wt, 'u8')
check('末尾が不完全な UTF-8 でも、先の write_file を数えて不合格（EXIT:4・書き込みの試み 1 件・文字コードの不正行）',
      r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and '書き込みの試み 1 件' in ev_text and '文字コードの不正行' in ev_text, out(r) + ev_text)

# 15-8. レビューの後に HEAD を読めなくても、git のエラーで落ちずに変更として不合格（EXIT:4）
wt, first = repo('lose-head')
r, cap, done = gem(wt, 'lh', mutation='lose-head')
check('レビューの後に HEAD を読めなければ NEEDS_FIX・EXIT:4（証跡に「読めない」）',
      r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and 'EXIT:4' in done and 'HEAD を読めない' in r.stderr and '（読めない）' in evidence(wt, 'lh')
      and state(wt, 'lh')['last_verdict'] == 'IN_PROGRESS', out(r) + done)

# 15-9. 終了記録（.done）を書けないときは確定しない（起動前に分かれば止める・実行中に置かれたら確定しない）
wt, first = repo('done-dir')
r, cap, done = gem(wt, 'dd', mutation='plant-done-dir', env={'GT_LABEL': 'dd'})
check('実行中に .done の名前にフォルダを置かれたら確定しない（EXIT:3・IN_PROGRESS・証跡は NONE）',
      r.returncode == 3 and state(wt, 'dd')['last_verdict'] == 'IN_PROGRESS' and '- VERDICT: NONE' in evidence(wt, 'dd')
      and '- VERDICT: CLEAN' not in r.stdout, out(r))
(wt / 'logs/dd.done').rmdir()
r, cap, done = gem(wt, 'dd')
check('用意: 次の通常の起動は CLEAN で確定', r.returncode == 0 and state(wt, 'dd')['last_verdict'] == 'VERDICT: CLEAN', out(r))
(wt / 'logs/dd.done').unlink(); (wt / 'logs/dd.done').mkdir()
r, cap, done = gem(wt, 'dd', '--force')
check('起動の前から .done の名前がフォルダなら、記録に触らずに止める（EXIT:2・agy 未起動・前の CLEAN の記録はそのまま）',
      r.returncode == 2 and cap is None and state(wt, 'dd')['last_verdict'] == 'VERDICT: CLEAN' and '終了記録の書き込み先' in r.stderr, out(r))
(wt / 'logs/dd.done').rmdir()

# 15-10. 起動前点検: Codex の構成の不一致も NG（run-review.sh と同じ判定）
d = doctor('--review-engine', 'codex', env={'LANES_TOOLS': 'claude'})
check('点検: claude だけの構成で --review-engine codex は NG（exit 2・指定の出どころを出す）', d.returncode == 2 and 'codex が無い' in d.stdout and '--review-engine' in d.stdout, d.stdout)
d = doctor('--quiet', env={'LANES_TOOLS': 'claude', 'LANES_REVIEW_ENGINE': 'codex'})
check('点検: LANES_REVIEW_ENGINE=codex でも同じく NG（--quiet でも exit 2）', d.returncode == 2 and 'LANES_REVIEW_ENGINE' in d.stdout, d.stdout)
d = doctor('--review-engine', 'claude', env={'LANES_TOOLS': 'claude'})
check('点検: claude はどの構成でも通る', d.returncode == 0, d.stdout)

# 15-11. PATH の先に GNU 風の stat があっても、出力が続いている agy を無出力として止めない（zsh 組み込みの zstat）
gnu = T / 'gnu-stat-bin'; gnu.mkdir()
(gnu / 'stat').write_text('#!/bin/sh\necho "stat: GNU 風の偽物（-f %m を受け付けない）" >&2\nexit 1\n'); (gnu / 'stat').chmod(0o755)
wt, first = repo('gnu-stat')
r, cap, done = gem(wt, 'gs', events='drip', env={'PATH': f'{gnu}{os.pathsep}{BASE["PATH"]}', 'GEMINI_REVIEW_NOOUTPUT_SEC': '3', 'GT_SLEEP': '7'})
check('GNU 風の stat が先にあっても、出力が続く間は止めない（CLEAN・EXIT:0）', r.returncode == 0 and 'VERDICT: CLEAN' in done and '更新なし' not in (wt / 'logs/gs.log').read_text(), out(r) + done)

print(f'PASS: {passed} 件 / EXIT:0')
PY
