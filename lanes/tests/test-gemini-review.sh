#!/bin/zsh -f
# Gemini レビュー（run-gemini-review.sh）と、レビューの入口の --engine（run-review.sh）のテスト。
# 偽の agy（このテストが一時領域に置く。本物の agy・ネットワークには触らない）と、tests/stubs の偽の claude・codex だけを使う。
# 構成（LANES_TOOLS）はこのテストの中で固定・切り替える（呼び出し元の構成に左右されない）。全データを一時領域に置く。
# 確かめること:
#   1. 引数（不明なオプション・label の二重・--mode の値）は今回の失敗（EXIT:2）として .done に残す
#   2. 入口の振り分け: --engine gemini / LANES_REVIEW_ENGINE=gemini は Gemini レビューへ。--engine は設定に勝つ。省略時は今までどおり構成のレビュー役。
#      知らない値は今回の失敗として .done に残す。構成に gemini が無ければ（入口・直接とも）exit 2 で agy を起動しない
#   3. 親の chk-run の記録が無いとき（LANES_REVIEW_REQUIRE_CHECKS=1）は子を起動せずに EXIT:2
#   4. 読み取り専用の強制: --mode plan・--sandbox・--settings（mcp(*)・write_file(*)・commit や push の command の拒否）が渡り、
#      --dangerously-skip-permissions・accept-edits・auto は渡らない。--add-dir は scratch だけ。子の環境（headless・stdin・git の設定・通信止め・
#      API キーなし）。agy --help に --mode / plan / --sandbox が無い・本体 checkout では起動しない
#   5. 子が作業ツリー・git の管理フォルダ（設定・hooks・タグ）・git の制御ファイル（.git）・再利用の記録・使い回し禁止の印を変えたら NEEDS_FIX（EXIT:4）
#   6. 書き込み系のツールの step_update が 1 件でもあれば不合格（EXIT:4。証跡に件数）。実機（agy 1.5.14）の形の stream-json でも同じに数える
#   7. JSON の欠損・不正・result の重複・終端でない・status=ERROR・agy の非 0 は VERDICT: NONE。見張り（無出力 EXIT:8・idle EXIT:3）
#   8. VERDICT・P0〜P3・GATE・後回し票・ESCALATE が、同じ本文の Claude レビューと同じになる（round 3 の後回しを含む）。証跡の行の並びも同じ
#   9. .pid の model= / effort= は GEMINI_REVIEW_MODEL / GEMINI_REVIEW_EFFORT（実装用の GEMINI_MODEL とは別）。証跡のレビューエンジンの行
#  10. 同じ道具でレビューしない: Gemini 実装の記録（.pid の lane=gemini・証跡の見出し）があれば拒否、--allow-same-engine で通して証跡に残す
#  11. 同じ head の結果の再利用（skip-same-head）と delta。--dry-run は .pid / .done / ログを作らない
#  12. lanes-status.sh・lanes-watch.sh --check・lanes-monitor.sh が gemini-review を他のレビューと同じに読む（一覧には [gemini-review] の印）
#  13. 起動のときだけ LANES_REVIEW_ENGINE を渡しても、親の chk-run の記録を使い回せる（chk-run.sh の指紋に入らない）
#  14. 起動前点検（lanes-doctor.sh）・役割の表示（lanes-roles.sh --print）
#  15. dry-run も書き出し先（logs/・指示書・台帳）のリンクを辿らない（Claude・Codex レビューの dry-run も）
#  16. 呼び出し元の GIT_DIR などに引きずられない・worktree が git の最上位であること
#  17. 親の Python が worktree の同名のモジュール（json.py など）を読まない
#  18. 監査は親が直接受け取った中身で行う（子が logs/<label>.json を書き換えても。書き換えは改ざんとして不合格）
#  19. 書き込み違反・改ざん（EXIT:4）で系列の前回の CLEAN を失効させる（前回 NEEDS_FIX は残す）
#  20. 書き込み違反の EXIT:4 は agy の失敗の終了コードより優先（agy の終了コードは証跡に別記）
#  21. 「使い回し禁止」の印は置き場所ごとに比べる（新設・片方だけの削除）。logs/ の差し替えは EXIT:5 で外に印
#  22. run-review.sh は解決後のレビュー役で起動前点検を回す
#  23. scratch の相対指定を絶対パスに直す
#  24. 専用の linked worktree だけ（管理領域を外に置いた本体・submodule は不可。run-gemini.sh も）
#  25. 役名の読み替えでパス・枝名を変えない（Gemini・Codex）
#  26. --mode の単語照合（doctor）・独立性の表示は選んだレビュー役で
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-gemrev.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
# Python のテストが子へ渡す環境は、ここで外した後のものを使う
PYTHONDONTWRITEBYTECODE=1 python3 -I - "$LANES_DIR" "$T" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys, time
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
# 呼ばれた引数・作業場所・一部の環境変数（値は秘密でないものと、有無だけを見るもの）・stdin が /dev/null かを GT_CAPTURE に書く
agy = bindir / 'agy'
agy.write_text(r'''#!/usr/bin/env python3
import glob, json, os, pathlib, subprocess, sys, time
args = sys.argv[1:]
if '--help' in args:
    h = os.environ.get('GT_HELP', 'full')
    opts = ['--add-dir', '--effort', '--model', '--output-format', '--print', '--print-timeout', '--settings', '--sandbox']
    if h == 'no-sandbox': opts.remove('--sandbox')
    if h not in ('no-mode', 'model-plan'): opts.append('--mode  Set the agent execution mode (accept-edits, auto' + ('' if h in ('no-plan', 'plan-elsewhere') else ', plan') + ')')
    if h == 'plan-elsewhere': opts.append('--remote-agent  research and write a plan for your review')
    # --mode が無く、--model の説明にだけ plan の語がある（部分一致の *--mode* では通ってしまう形）
    if h == 'model-plan': opts.append('--model  Model to use with your subscription plan')
    print('\n'.join(opts)); sys.exit(0)
st0, dn = os.fstat(0), os.stat('/dev/null')
keys = ('ANTIGRAVITY_HEADLESS', 'TMPDIR', 'LANES_SCRATCH', 'GIT_OPTIONAL_LOCKS', 'GIT_PAGER', 'GIT_CONFIG_GLOBAL', 'GIT_ALLOW_PROTOCOL',
        'GIT_DIR', 'GIT_WORK_TREE', 'LANES_REVIEW_ENGINE')
present = ('GEMINI_API_KEY', 'GOOGLE_API_KEY', 'AGY_ADC_AUTH', 'GOOGLE_APPLICATION_CREDENTIALS', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY')
info = {'args': args, 'cwd': os.getcwd(), 'stdin_devnull': st0.st_rdev == dn.st_rdev and st0.st_ino == dn.st_ino,
        'env': {k: os.environ.get(k) for k in keys}, 'keys_present': [k for k in present if k in os.environ]}
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
if mut == 'git-hook':
    common = pathlib.Path(subprocess.check_output(['git', 'rev-parse', '--git-common-dir'], text=True).strip())
    (common / 'hooks').mkdir(exist_ok=True); (common / 'hooks' / 'post-checkout').write_text('#!/bin/sh\n')
if mut == 'gitlink': pathlib.Path('.git').write_text('gitdir: /nonexistent/elsewhere\n')
if mut == 'forge-state': pathlib.Path('logs/.rv.review-state').write_text('{"last_round": "1", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}\n')
if mut == 'forge-other-state': pathlib.Path('logs/.other.review-state').write_text('{"last_round": "1", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}\n')
outer_markers = lambda: glob.glob(os.path.join(os.environ['XDG_STATE_HOME'], 'lanewright', 'reuse-blocked', '*'))
if mut in ('del-marker', 'del-inner-marker', 'del-outer-marker'):
    targets = (['logs/.review-reuse-blocked'] if mut != 'del-outer-marker' else []) + (outer_markers() if mut != 'del-inner-marker' else [])
    for f in targets:
        try: os.unlink(f)
        except FileNotFoundError: pass
if mut == 'add-marker': pathlib.Path('logs/.review-reuse-blocked').write_text('')
if mut == 'swap-logs':
    # logs/ そのものを別のフォルダに差し替え、偽の再利用の記録を置く
    os.rename('logs', 'logs.moved'); os.mkdir('logs')
    pathlib.Path('logs/.rv.review-state').write_text('{"last_round": "1", "last_head": "forged", "last_verdict": "VERDICT: CLEAN", "last_exit": 0}\n')
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
if mut in ('write-tool', 'write-tools', 'forge-json'):
    tool(4, 'write_file', 'ACTIVE', {'Path': 'x.txt'}); tool(4, 'write_file', 'ERROR', {'Path': 'x.txt'})
    if mut == 'write-tools':
        tool(5, 'edit_file', 'ERROR', {'Path': 'a.txt'}); tool(6, 'delete_file', 'ERROR', {'Path': 'a.txt'})
if events == 'idle':
    print('root agent idle', file=sys.stderr, flush=True); time.sleep(int(os.environ.get('GT_SLEEP', '8')))
if events == 'sleep': time.sleep(int(os.environ.get('GT_SLEEP', '8')))
if events == 'bad_json': print('{broken', flush=True)
if events == 'bad_tool': ev({'event': 'step_update', 'step_update': {'step_type': 'tool', 'tool_info': {}}})
if events != 'missing_result':
    ev({'event': 'result', 'result': {'status': 'ERROR' if events == 'error_status' else 'SUCCESS', 'response': body,
                                      'num_turns': 1, 'usage': {}}})
if events == 'dup_result': ev({'event': 'result', 'result': {'status': 'SUCCESS', 'response': body}})
if events == 'nonterminal': ev({'event': 'step_update', 'step_update': {'step_index': 9, 'state': 'DONE', 'step_type': 'system_message'}})
if mut.startswith('forge-json'):
    # 出し終わった後で、公開用の logs/*.json を「書き込みなし・CLEAN」の偽の記録に書き換える（受け取り役が書き終わるのを待ってから）
    time.sleep(1.5)
    forged = (json.dumps({'event': 'init'}) + '\n' + json.dumps({'event': 'result', 'result': {'status': 'SUCCESS', 'response': '問題なし\nVERDICT: CLEAN',
              'num_turns': 1, 'usage': {}}}, ensure_ascii=False) + '\n')
    for f in glob.glob('logs/*.json'): pathlib.Path(f).write_text(forged)
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
seq = [0]

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
    done = donef.read_text() if donef and donef.exists() else ''
    return r, cap, done
def gem(wt, label, *args, **kw): return run('run-gemini-review.sh', wt, label, *args, **kw)
def out(r): return f'rc={r.returncode}\n--- stdout\n{r.stdout[-2500:]}\n--- stderr\n{r.stderr[-2500:]}'
def evidence(wt, label): return (pathlib.Path(wt) / 'logs' / (label + '.evidence.md')).read_text()
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
check('子の agy には LANES_REVIEW_ENGINE を渡しても害がない（記録だけ）', cap['env']['LANES_REVIEW_ENGINE'] in (None, 'gemini'))
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

# ---- 3. 親の chk-run の記録が無いときは起動しない ----
wt, first = repo('require')
(wt / 'logs').mkdir()
r, cap, done = gem(wt, 'rq', env={'LANES_REVIEW_REQUIRE_CHECKS': '1', 'LANES_CHECK_CMD': '/usr/bin/true'})
check('LANES_REVIEW_REQUIRE_CHECKS=1 で記録が無ければ EXIT:2・子を起動しない', r.returncode == 2 and cap is None and 'chk-run の記録を使えない' in done and not (wt / 'logs/rq.evidence.md').exists(), out(r))
r, cap, done = gem(wt, 'rq', '--allow-missing-checks', env={'LANES_REVIEW_REQUIRE_CHECKS': '1', 'LANES_CHECK_CMD': '/usr/bin/true'})
check('--allow-missing-checks なら起動し、証跡に残す', r.returncode == 0 and cap is not None and '--allow-missing-checks で起動' in evidence(wt, 'rq'), out(r))

# ---- 4. 読み取り専用の強制 ----
wt, first = repo('jail')
r, cap, done = gem(wt, 'j1')
check('素直な本文は CLEAN・EXIT:0', r.returncode == 0 and 'VERDICT: CLEAN' in done and 'EXIT:0' in done, out(r))
a = cap['args']
settings = json.loads(a[a.index('--settings') + 1])
deny = settings['permissions']['deny']
check('--mode plan と --sandbox が渡る', a[a.index('--mode') + 1] == 'plan' and '--sandbox' in a)
check('--dangerously-skip-permissions・accept-edits・auto は渡らない', '--dangerously-skip-permissions' not in a and 'accept-edits' not in a and 'auto' not in a)
check('settings: MCP と書き込み系を拒否する', {'mcp(*)', 'write_file(*)', 'write_file(/)'} <= set(deny), json.dumps(deny))
check('settings: commit・push・stash・tag・PR のマージなどのコマンドを拒否する',
      {'command(git commit)', 'command(git push)', 'command(git stash)', 'command(git tag)', 'command(gh pr merge)', 'command(agy)'} <= set(deny), json.dumps(deny))
check('settings: 端末サンドボックスを壊す相対パスの規則（write_file(.)）は入れない', not any(re.fullmatch(r'write_file\(\.[^)]*\)', x) for x in deny))
check('settings: 作業場所の外を触らせない・サンドボックス有効・既定の提供元・クレジットなし（実装と同じ）',
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
check('指示書: テンプレの役名を Gemini に読み替え、案件の指示・閉じ込め・出し方（全件列挙・秘密の扱い）・最終行の規則を付ける',
      merged.startswith('# レビュー本線（Gemini）') and '案件固有の検証指示（テスト）' in merged and 'このレビューの閉じ込め' in merged
      and '**全部** 列挙する' in merged and '## 秘密の値の扱い' in merged and merged.rstrip().endswith('VERDICT: CLEAN\nVERDICT: NEEDS_FIX')
      and 'Claude' not in merged.split('# 案件固有の指示')[0] and (lanes / 'templates/codex-review-focus.md').read_text().strip() in merged)
for help_kind, why in (('no-mode', '--mode'), ('no-plan', 'plan'), ('plan-elsewhere', '--mode の行の plan'), ('no-sandbox', '--sandbox'),
                      ('model-plan', '--mode（--model の説明の plan だけ）')):
    r, cap, done = gem(wt, 'j3', help=help_kind, env={})
    check(f'agy --help に {why} が無ければ起動しない', r.returncode == 2 and cap is None and 'EXIT:2' in done, out(r))
main = T / 'main-checkout'; main.mkdir(); git(main, 'init', '-q', '-b', 'main')
for k, v in (('user.name', 'Test User'), ('user.email', 'you@example.com'), ('commit.gpgSign', 'false')): git(main, 'config', k, v)
(main / '.gitignore').write_text('logs/\n'); git(main, 'add', '.'); git(main, 'commit', '-qm', 'test: 初期')
r, cap, done = gem(main, 'j4', '--base', 'HEAD')
check('本体 checkout（.git がディレクトリ）では起動しない', r.returncode == 2 and cap is None and '本体 checkout' in r.stderr, out(r))

# ---- 5. 子が作業ツリー・git の管理フォルダ・記録を変えたら NEEDS_FIX（EXIT:4）----
for mutation in ('overwrite', 'untracked', 'commit', 'git-config', 'git-tag', 'git-hook', 'gitlink', 'forge-state', 'forge-other-state'):
    wt, first = repo('mut-' + mutation)
    if mutation == 'gitlink': before_link = (wt / '.git').read_text()
    r, cap, done = gem(wt, 'rv', mutation=mutation)
    check(f'子の変更（{mutation}）は NEEDS_FIX・EXIT:4', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and 'EXIT:4' in done, out(r) + '\n' + done)
    if mutation in ('gitlink', 'git-config', 'git-hook'):
        check(f'git の制御ファイルの変更（{mutation}）は git を呼ぶ前に止め、証跡を作らない', 'git の制御ファイル' in done and not (wt / 'logs/rv.evidence.md').exists(), done)
    if mutation == 'gitlink': (wt / '.git').write_text(before_link)
    if mutation.startswith('forge'):
        names = sorted(p.name for p in (wt / 'logs').glob('.*.review-state'))
        check(f'偽造された再利用の記録（{mutation}）は戻す（作られた物は消す）', names == [] and '再利用の記録' in r.stderr, str(names))
wt, first = repo('mut-del-marker')
(wt / 'logs').mkdir(); (wt / 'logs/.review-reuse-blocked').write_text('')
r, cap, done = gem(wt, 'rv', mutation='del-marker')
check('使い回し禁止の印を消されたら NEEDS_FIX・EXIT:4・印を置き直す', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and (wt / 'logs/.review-reuse-blocked').exists(), out(r))

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
check('実機（agy 1.5.14）の形: 拒否された write_file・edit_file も書き込みの試み 2 件として不合格', r.returncode == 4 and '書き込みの試み 2 件' in evidence(wt, 'w4'), out(r) + evidence(wt, 'w4'))
r, cap, done = gem(wt, 'w5', replay=fixtures / 'read-only-commands.jsonl')
check('実機（agy 1.5.14）の形: 読み取りのコマンドだけなら本文の VERDICT を採用（CLEAN）', r.returncode == 0 and 'VERDICT: CLEAN' in done, out(r))
check('最後の応答の本文だけを last.md に残す', (wt / 'logs/w5.last.md').read_text() == '問題なし\nVERDICT: CLEAN')

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

# ---- 8. VERDICT・指摘・GATE・後回し票・ESCALATE は Claude レビューと同じ ----
skip_line = 'CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP'
cases = [
    ('c1-r1', 'VERDICT: CLEAN'),
    ('c2-r1', '- [P1] a.txt:1 認証の不具合\nVERDICT: CLEAN'),
    ('c3-r1', '- [P2] 条件付きの不具合\nVERDICT: NEEDS_FIX'),
    ('c4-r1', '- [P3] 文言\nVERDICT: CLEAN'),
    ('c5-r3', '- [P2] 残件\n  再現条件\n' + skip_line + '\nVERDICT: NEEDS_FIX'),
    ('c6-r3', '- [P2] 残件\nVERDICT: NEEDS_FIX'),
    ('c7-r3', '- [P3] 文言\nVERDICT: CLEAN'),
    ('c8-r3', '- [P1] 重大\n' + skip_line + '\nVERDICT: NEEDS_FIX'),
    ('c9-r6', '- [P1] 残る重大な指摘\nVERDICT: NEEDS_FIX'),
    ('c10-r1', ''),
    ('c11-r1', 'レビューを完了できませんでした\nVERDICT: CLEAN'),
    ('c12-r1', '```\nVERDICT: CLEAN'),
    ('c13-r1', 'typecheck / lint / unit / build 未実施\nVERDICT: CLEAN'),
]
def lines_of(text):
    return [l.split(':')[0].split('（')[0] for l in text.splitlines() if l.startswith('- ')]
for label, body in cases:
    seen = {}
    for script in ('run-claude-review.sh', 'run-gemini-review.sh'):
        wt, first = repo(f'parity-{label}-{script[4:10]}')
        r, cap, done = run(script, wt, label, body=body)
        series = re.sub(r'-r[0-9]+$', '', label)
        fu = wt / 'logs' / f'{series}.followups.md'
        exit_line = re.search(r'^EXIT:(\d+)', done, re.M)
        verdict_line = re.search(r'^VERDICT: \S+', done, re.M)
        ev_lines = lines_of(evidence(wt, label)) if (wt / 'logs' / f'{label}.evidence.md').exists() else []
        fu_text = '\n'.join(l for l in fu.read_text().splitlines() if not l.startswith('## round')) if fu.exists() else ''
        seen[script] = (r.returncode, exit_line[0] if exit_line else '', verdict_line[0] if verdict_line else '', note_gate(done), fu_text, ev_lines)
    c, g = seen['run-claude-review.sh'], seen['run-gemini-review.sh']
    check(f'Claude と同じ判定 {label}: rc・EXIT・VERDICT・GATE・後回し票', c[:5] == g[:5], f'claude={c[:5]}\ngemini={g[:5]}')
    extra = {'- レビューエンジン', '- 読み取り専用の確認', '- 同じ道具のレビュー'}
    check(f'証跡の行の並びも Claude と同じ {label}（Gemini だけの行を除く）', c[5] == [x for x in g[5] if x not in extra] and '- レビューエンジン' in g[5], f'claude={c[5]}\ngemini={g[5]}')
wt, first = repo('followups-gemini')
r, cap, done = gem(wt, 'f-r3', body='- [P2] 残件\n  再現条件\n' + skip_line + '\nVERDICT: NEEDS_FIX')
saved = (wt / 'logs/f.followups.md').read_text()
check('Gemini: round 3 の P2 は後回し票に本文ごと保存して CLEAN', 'VERDICT: CLEAN' in done and 'gate=MERGE_WITH_FOLLOWUP' in done and '残件' in saved and '再現条件' in saved, done)
r, cap, done = gem(wt, 'esc-r6', body='- [P1] 残る\nVERDICT: NEEDS_FIX')
check('Gemini: 周回の上限を超えたら ESCALATE と人に返す行', 'gate=ESCALATE' in done and '周回の上限' in evidence(wt, 'esc-r6'), done)

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
# 判定の関数の単体: 種別の一致は行全体、symlink は辿らない、gemini-review は実装に数えない
unit = T / 'unit-same'; unit.mkdir()
(unit / 'r.pid').write_text('lane=gemini-review\n'); (unit / 'q.pid').write_text('lane=qa\n')
(T / 'outside.pid').write_text('lane=gemini\n'); os.symlink(T / 'outside.pid', unit / 'link.pid')
def recorded(d, lane):
    # 戻り値（0 = 記録あり / 1 = 記録なし / 2 = 確かめられない）と REPLY を「戻り値:REPLY」の形で返す
    p = subprocess.run(['zsh', '-fc', 'LANES_DIR="$1"; source "$1/_common.sh"; unfunction TRAPEXIT TRAPZERR; rc=0; lanes_impl_lane_recorded "$2" "$3" || rc=$?; print -r -- "$rc:$REPLY"',
                        '_', str(lanes), str(d), lane], env=BASE, capture_output=True, text=True)
    return p.stdout.strip()
check('判定: lane=gemini-review・qa・外を指す symlink は Gemini 実装に数えない', recorded(unit, 'gemini') == '1:')
(unit / 'impl.pid').write_text('pid=1\nlane=gemini\n')
check('判定: lane=gemini の .pid を見つけて名前を返す', recorded(unit, 'gemini') == '0:impl.pid')
check('判定: logs/ が無ければ 1', recorded(T / 'no-such-logs', 'gemini') == '1:')
unreadable = T / 'unit-unreadable'; unreadable.mkdir(); (unreadable / 'old.pid').write_text('lane=gemini\n'); (unreadable / 'old.pid').chmod(0)
check('判定: 候補の .pid を読めなければ 2（確かめられない）と名前を返す', recorded(unreadable, 'gemini') == '2:読めない記録: old.pid', recorded(unreadable, 'gemini'))
(unreadable / 'old.pid').chmod(0o644)
os.symlink(unit, T / 'unit-link-logs')
check('判定: logs/ が symlink なら 2（確かめられない）', recorded(T / 'unit-link-logs', 'gemini').startswith('2:'))
wt, first = repo('same-unreadable')
(wt / 'logs').mkdir()
bad = wt / 'logs' / 'impl.pid'; bad.write_text('pid=1\nlane=gemini\n'); bad.chmod(0)
r, cap, done = gem(wt, 'su')
check('Gemini 実装の記録を読めなければ「記録なし」と取り違えず起動しない（EXIT:2・理由を .done に残す）',
      r.returncode == 2 and cap is None and 'EXIT:2' in done and '確かめられない' in done and 'impl.pid' in done, out(r) + done)
r, cap, done = gem(wt, 'su2', '--allow-same-engine')
check('--allow-same-engine なら回し、確かめられなかったことを証跡に残す', r.returncode == 0 and cap is not None and '確かめられない' in evidence(wt, 'su2'), out(r))
bad.chmod(0o644)

# ---- 11. 同じ head の結果の再利用と delta・dry-run ----
# round 3 からは後回しの方針が変わり条件の違いとして全体を見直すので（Claude レビューと同じ）、再利用と delta は round 1・2 で確かめる
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
check('用意: 同じ round を --force で回し直して NEEDS_FIX', 'VERDICT: NEEDS_FIX' in done, done)
(wt / 'd.txt').write_text('直し'); git(wt, 'add', 'd.txt'); git(wt, 'commit', '-qm', 'fix: 直し')
r, cap, done = gem(wt, 'd-r2', '--mode', 'delta')
merged = (wt / 'logs/d-r2.prompt.md').read_text()
check('前回 NEEDS_FIX なら明示 delta でも full に戻して未解決指摘を引き継ぐ', 'full レビュー' in merged and '直っていない' in merged and 'VERDICT: NEEDS_FIX' in done
      and f'git diff {first}...HEAD' in merged, done)
r, cap, done = gem(wt, 'd-r2', body='a.txt:1 の指摘は解消済み\nRESOLVED_PREVIOUS_FINDINGS: YES\nVERDICT: CLEAN', env={})
check('前回 NEEDS_FIX の後は、全件の解消の宣言があるときだけ CLEAN（Claude と同じ）', 'VERDICT: CLEAN' in done, done)
wt, first = repo('dry')
r, cap, done = gem(wt, 'dr', '--dry-run')
check('--dry-run は agy を起動せず .pid / .done / ログを作らない', r.returncode == 0 and cap is None and not (wt / 'logs/dr.pid').exists()
      and not (wt / 'logs/dr.done').exists() and not (wt / 'logs/dr.log').exists() and (wt / 'logs/dr.dry-run.prompt.md').exists()
      and '--mode plan --sandbox --settings' in r.stdout, out(r))

# ---- 12. 生死の見張り（lanes-status / lanes-watch / lanes-monitor）----
wt, first = repo('status')
gem(wt, 'st')
p = subprocess.run(['zsh', '-f', str(lanes / 'lanes-status.sh'), str(wt), 'st'], env=BASE, capture_output=True, text=True)
check('lanes-status.sh は Gemini レビューの終わりを DONE と読む', p.returncode == 0 and p.stdout.startswith('DONE') and 'VERDICT: CLEAN' in p.stdout, p.stdout + p.stderr)
runs = T / 'runs'; mon_wt = runs / 'app' / 'wt'
mon_wt.mkdir(parents=True)
git(mon_wt, 'init', '-q'); git(mon_wt, 'config', 'user.name', 'you'); git(mon_wt, 'config', 'user.email', 'you@example.com')
git(mon_wt, 'commit', '--allow-empty', '-qm', 'test: 監視用')
(mon_wt / 'logs').mkdir()
ident = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'lstart='], env={**BASE, 'LC_ALL': 'C', 'TZ': 'UTC'}, text=True).strip()
now = int(time.time())
for lb, lane in (('rev-gem', 'gemini-review'), ('rev-codex', 'codex-review'), ('impl-gem', 'gemini')):
    (mon_wt / 'logs' / (lb + '.pid')).write_text(f'pid={os.getpid()}\nlstart={ident}\nstarted_epoch={now}\nlane={lane}\nworktree={mon_wt}\n')
    (mon_wt / 'logs' / (lb + '.json')).write_text('{}\n')
mon_env = dict(BASE, LANES_WATCH_HEARTBEAT=str(T / 'absent-heartbeat'))
p = subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh')], env=mon_env, capture_output=True, text=True, timeout=60)
check('lanes-monitor.sh: 動いている Gemini レビューを数え、一覧に [gemini-review] の印', 'RUNNING 3（Claude 0 / Gemini 1 / Codex レビュー 1 / Gemini レビュー 1 / 他 0）' in p.stdout
      and '- rev-gem [gemini-review]' in p.stdout and '- impl-gem [gemini]' in p.stdout and '- rev-codex ' in p.stdout, p.stdout + p.stderr)
p = subprocess.run(['zsh', '-f', str(lanes / 'lanes-watch.sh'), '--check'], env=mon_env, capture_output=True, text=True, timeout=60)
check('lanes-watch.sh --check: Gemini レビューも生きているレーンとして数える', 'LANES RUNNING 3' in p.stdout, p.stdout + p.stderr)
(mon_wt / 'logs' / 'rev-gem.done').write_text('EXIT:0\nVERDICT: CLEAN\nfinished=x\nelapsed_min=1\nnote=gemini rc=0 gate=CLEAN\n')
p = subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh')], env=mon_env, capture_output=True, text=True, timeout=60)
check('lanes-monitor.sh: 終わった Gemini レビューを新規終了として出す（[gemini-review] の印）', re.search(r'- DONE app rev-gem \[gemini-review\] .*VERDICT: CLEAN', p.stdout) is not None
      and 'Gemini レビュー' not in p.stdout.splitlines()[1], p.stdout + p.stderr)

# ---- 13. 起動のときだけ LANES_REVIEW_ENGINE を渡しても、親の chk-run の記録を使い回せる ----
wt, first = repo('reuse', gitignore='logs/\nnode_modules/\n')
# 指紋に環境変数が入るので、chk-run.sh はランチャと同じ環境（LANES_REVIEW_ENGINE だけ無し）で回す
chk_env = make_env(env={'LANES_CHECK_CMD': '/usr/bin/true'})
p = subprocess.run(['bash', str(lanes / 'chk-run.sh'), str(wt), '49995', str(T / 'chk-out')], env=chk_env, capture_output=True, text=True, timeout=120)
check('用意: chk-run.sh が記録する', p.returncode == 0 and 'recorded=' in p.stdout, p.stdout + p.stderr)
r, cap, done = run('run-review.sh', wt, 'ru', env={'LANES_CHECK_CMD': '/usr/bin/true', 'LANES_REVIEW_ENGINE': 'gemini'})
ev_text = evidence(wt, 'ru')
check('LANES_REVIEW_ENGINE を起動のときだけ渡しても記録を使い回す（Gemini レビュー）', r.returncode == 0 and cap is not None and '親の chk-run の記録を使用' in ev_text
      and '親が同じ中身で実施済み' in (wt / 'logs/ru.prompt.md').read_text(), out(r) + ev_text)

# ---- 14. 起動前点検（lanes-doctor.sh）と役割の表示（lanes-roles.sh --print）----
def doctor(env=None, help='full'):
    e = make_env(help=help, env=env)
    return subprocess.run(['zsh', '-f', str(lanes / 'lanes-doctor.sh')], env=e, capture_output=True, text=True, timeout=60)
p = doctor()
check('doctor: 既定の設定では Gemini レビューの点検を足さない', p.returncode == 0 and 'gemini レビュー' not in p.stdout, p.stdout)
p = doctor(env={'LANES_REVIEW_ENGINE': 'gemini'})
check('doctor: LANES_REVIEW_ENGINE=gemini なら agy の --sandbox・--settings・--mode plan を確かめる', p.returncode == 0 and 'ok   gemini レビュー: agy が --sandbox・--settings・--mode plan に対応' in p.stdout, p.stdout)
for help_kind in ('no-plan', 'plan-elsewhere'):
    p = doctor(env={'LANES_REVIEW_ENGINE': 'gemini'}, help=help_kind)
    check(f'doctor: agy の --mode の行に plan が無ければ NG（{help_kind}）', p.returncode == 2 and 'NG   gemini レビュー: agy が --mode plan に対応していない' in p.stdout, p.stdout)
p = doctor(env={'LANES_REVIEW_ENGINE': 'gemini', 'LANES_TOOLS': 'claude codex'})
check('doctor: LANES_REVIEW_ENGINE=gemini なのに構成に gemini が無ければ NG', p.returncode == 2 and 'LANES_REVIEW_ENGINE=gemini だが構成' in p.stdout, p.stdout)
def roles(tools, extra_env=None):
    e = make_env(env=dict({'LANES_TOOLS': tools}, **(extra_env or {})))
    return subprocess.run(['zsh', '-f', str(lanes / 'lanes-roles.sh'), '--print'], env=e, capture_output=True, text=True, timeout=30).stdout
for tools in ('claude codex gemini', 'claude gemini'):
    check(f'roles --print [{tools}]: Gemini レビューは --engine gemini で選べると案内する', 'Gemini レビュー: 明示したときだけ（run-review.sh --engine gemini' in roles(tools))
for tools in ('claude codex', 'claude'):
    text = roles(tools)
    check(f'roles --print [{tools}]: gemini の無い構成では案内を出さない（既定の表示のまま）', 'Gemini レビュー' not in text and 'レビュー: ' in text, text)
check('roles --print: LANES_REVIEW_ENGINE を書いたらその指定を出す', 'レビュー役の指定: LANES_REVIEW_ENGINE=gemini' in roles('claude codex gemini', {'LANES_REVIEW_ENGINE': 'gemini'}))
env_out = subprocess.run(['zsh', '-f', str(lanes / 'lanes-roles.sh'), '--env'], env=make_env(), capture_output=True, text=True).stdout
check('roles --env の出力は変えない（4 行）', len(env_out.splitlines()) == 4 and env_out.startswith('LANES_PROFILE=full'), env_out)

# ---- 15. dry-run でも書き出し先を確かめる（前の実行の子が置いたリンクを辿らない）----
wt, first = repo('drysafe')
(wt / 'logs').mkdir()
outside = T / 'outside-target.txt'; outside.write_text('元の中身')
os.symlink(outside, wt / 'logs' / 'ds.dry-run.prompt.md')
r, cap, done = gem(wt, 'ds', '--dry-run')
dp = wt / 'logs' / 'ds.dry-run.prompt.md'
check('dry-run: 書き込み先が外を指す symlink でも辿らず、logs/ の中の新しい普通のファイルに書く',
      r.returncode == 0 and outside.read_text() == '元の中身' and not dp.is_symlink() and dp.read_text().startswith('# レビュー本線（Gemini）'), out(r))
for script, lb in (('run-claude-review.sh', 'dsc'), ('run-codex-review.sh', 'dsx')):
    os.symlink(outside, wt / 'logs' / f'{lb}.dry-run.prompt.md')
    r, cap, done = run(script, wt, lb, '--dry-run')
    dp = wt / 'logs' / f'{lb}.dry-run.prompt.md'
    check(f'dry-run（{script}）も書き込み先の symlink を辿らない', r.returncode == 0 and outside.read_text() == '元の中身' and not dp.is_symlink() and dp.stat().st_size > 0, out(r))
wt, first = repo('drysafe-link')
outdir = T / 'outside-logs'; outdir.mkdir()
os.symlink(outdir, wt / 'logs')
r, cap, done = gem(wt, 'dl', '--dry-run')
check('dry-run: logs/ が外を指す symlink なら書かずに止める（exit 2）', r.returncode == 2 and list(outdir.iterdir()) == [], out(r))
wt, first = repo('drysafe-ledger')
(wt / 'logs').mkdir()
ledger_target = T / 'outside-ledger.txt'; ledger_target.write_text('外の台帳')
os.symlink(ledger_target, wt / 'logs' / '.lanes-records')
r, cap, done = gem(wt, 'dg', '--dry-run')
check('dry-run: 台帳に載せられない（台帳が外を指す symlink）なら書かずに止める（exit 2）',
      r.returncode == 2 and ledger_target.read_text() == '外の台帳' and not (wt / 'logs' / 'dg.dry-run.prompt.md').exists() and '台帳' in r.stderr, out(r))

# ---- 16. 呼び出し元の git の場所の環境変数に引きずられない・最上位を確かめる ----
other, _ = repo('other-repo')
wt, first = repo('gitenv')
other_base = T / 'other-repo-base'
r, cap, done = gem(wt, 'ge', env={'GIT_DIR': str(other_base / '.git'), 'GIT_WORK_TREE': str(other_base), 'GIT_INDEX_FILE': str(other_base / '.git' / 'index')})
merged = (wt / 'logs' / 'ge.prompt.md').read_text() if (wt / 'logs' / 'ge.prompt.md').exists() else ''
want_gd = os.path.realpath(git(wt, 'rev-parse', '--path-format=absolute', '--git-dir'))
check('呼び出し元の GIT_DIR・GIT_WORK_TREE・GIT_INDEX_FILE を外し、対象の worktree をレビューする（子へ渡す管理領域・枝・起点も対象のもの）',
      r.returncode == 0 and cap is not None and os.path.realpath(cap['env']['GIT_DIR']) == want_gd
      and os.path.realpath(cap['env']['GIT_WORK_TREE']) == os.path.realpath(wt) and 'feat/gitenv' in merged and f'git diff {first}...HEAD' in merged, out(r))
(wt / 'sub').mkdir(); (wt / 'sub' / 'f.txt').write_text('x'); git(wt, 'add', 'sub'); git(wt, 'commit', '-qm', 'test: 下のフォルダ')
r, cap, done = gem(wt / 'sub', 'tl')
check('worktree の下のフォルダ（git の最上位でない）を渡したら起動しない', r.returncode == 2 and cap is None and '最上位ではない' in r.stderr, out(r))

# ---- 17. 親の Python はレビュー対象の同名のモジュールを読まない（作業場所を worktree にして起動しても）----
wt, first = repo('planted')
mark = T / 'planted-mark.txt'
for mod in ('json', 'hashlib', 'subprocess', 'uuid', 'base64', 'pathlib', 'tempfile'):
    (wt / f'{mod}.py').write_text(f'open({str(mark)!r}, "a").write({mod!r} + "\\n")\n')
git(wt, 'add', '.'); git(wt, 'commit', '-qm', 'test: 標準ライブラリと同名のモジュールを置く')
r, cap, done = gem(wt, 'pl', cwd=wt)
check('worktree を作業場所にして起動しても、親（ランチャ・監督役・受け取り役・監査）は worktree の同名のモジュールを読まない',
      r.returncode == 0 and 'VERDICT: CLEAN' in done and not mark.exists(), out(r) + (mark.read_text() if mark.exists() else ''))
check('子（agy）の作業場所は worktree', cap is not None and os.path.realpath(cap['cwd']) == os.path.realpath(wt))

# ---- 18. 監査は親が直接受け取った中身で行う（子が logs/<label>.json を書き換えても）----
wt, first = repo('forge-json')
r, cap, done = gem(wt, 'fj', mutation='forge-json')
pub = (wt / 'logs' / 'fj.json').read_text()
check('子が実行中に logs/<label>.json を「書き込みなし・CLEAN」に書き換えても、書き込みの試み 1 件で不合格（EXIT:4）',
      r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and '書き込みの試み 1 件' in evidence(wt, 'fj') and '改ざん' in evidence(wt, 'fj'), out(r) + done)
check('回収後に公開用の logs/<label>.json を受け取った中身で置き換える（偽の中身は残らない）', 'write_file' in pub and pub.count('"event": "init"') == 1, pub[:600])
wt, first = repo('forge-json-verdict')
r, cap, done = gem(wt, 'fv', mutation='forge-json-verdict', body='- [P1] a.txt:1 重大な不具合\nVERDICT: NEEDS_FIX')
check('公開用を CLEAN の偽の記録に書き換えても、判定は受け取った本文（NEEDS_FIX）。書き換えは改ざんとして EXIT:4',
      r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and (wt / 'logs' / 'fv.last.md').read_text().startswith('- [P1]'), out(r) + done)

# ---- 19. 書き込み違反・改ざんで不合格にしたら、系列の前回の CLEAN を失効させる ----
wt, first = repo('invalidate')
r, cap, done = gem(wt, 'iv-r1')
check('用意: 初回は CLEAN', r.returncode == 0 and 'VERDICT: CLEAN' in done, out(r))
r, cap, done = gem(wt, 'iv-r1', '--force', mutation='write-tool')
state = json.loads((wt / 'logs' / '.iv.review-state').read_text())
check('--force の再レビューで書き込みの試み（EXIT:4）→ 系列の前回の CLEAN を失効させる（last_exit=4）',
      r.returncode == 4 and state.get('last_exit') == 4 and 'last_invalidated' in state and state.get('last_round') == '1', json.dumps(state, ensure_ascii=False)[:400])
r, cap, done = gem(wt, 'iv-r1')
check('次の通常の起動は前回の CLEAN を再利用せず、レビューし直す（agy を起動する。skip-same-head にしない）',
      r.returncode == 0 and cap is not None and 'skip-same-head' not in evidence(wt, 'iv-r1') and 'VERDICT: CLEAN' in done, out(r))
wt, first = repo('invalidate-git')
gem(wt, 'ig-r1')
r, cap, done = gem(wt, 'ig-r1', '--force', mutation='git-config')
check('用意: git の制御ファイルの変更（git 未実行の EXIT:4）', r.returncode == 4 and 'git の制御ファイル' in done, out(r))
r, cap, done = gem(wt, 'ig-r1')
check('git の制御ファイルの変更で止めた後も、次の通常の起動は前回の CLEAN を再利用しない', cap is not None and 'skip-same-head' not in evidence(wt, 'ig-r1'), out(r))
wt, first = repo('invalidate-nf')
gem(wt, 'in-r1', body='- [P1] a.txt:1 直っていない\nVERDICT: NEEDS_FIX')
r, cap, done = gem(wt, 'in-r1', '--force', mutation='write-tool')
state = json.loads((wt / 'logs' / '.in.review-state').read_text())
check('前回が NEEDS_FIX の記録は残す（次の full に未解決の指摘を引き継ぐ）', r.returncode == 4 and state.get('last_verdict') == 'VERDICT: NEEDS_FIX' and state.get('last_exit') == 0, json.dumps(state, ensure_ascii=False)[:300])

# ---- 20. 書き込み違反の終了コード（4）は agy の失敗の終了コードより優先する ----
wt, first = repo('writes-rc')
r, cap, done = gem(wt, 'wr', mutation='write-tool', rc=7)
check('書き込みの試みがあれば agy の非 0（7）より EXIT:4 を優先し、agy の終了コードは証跡と .done に別に残す',
      r.returncode == 4 and 'EXIT:4' in done and 'VERDICT: NEEDS_FIX' in done and '終了コード 7' in evidence(wt, 'wr') and 'agy_rc=7' in done, out(r) + done)

# ---- 21. 「使い回し禁止」の印は置き場所ごとに前後を比べる ----
def outer_marker(wt):
    import hashlib
    key = hashlib.sha256(os.path.realpath(wt / 'logs').encode()).hexdigest()[:32]
    return T / 'state' / 'lanewright' / 'reuse-blocked' / key
def place_markers(wt):
    (wt / 'logs').mkdir(exist_ok=True)
    subprocess.run(['zsh', '-fc', 'source "$1/review-dedup.zsh"; rvd_mark_blocked "$2" 2>/dev/null', '_', str(lanes), str(wt / 'logs')], env=BASE, check=True)
    assert (wt / 'logs' / '.review-reuse-blocked').exists() and outer_marker(wt).exists()
wt, first = repo('marker-add')
(wt / 'logs').mkdir()
r, cap, done = gem(wt, 'rv', mutation='add-marker')
check('子が実行中に印を新設したら不合格（EXIT:4）にし、両方の置き場所に印を置いたままにする',
      r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and (wt / 'logs' / '.review-reuse-blocked').exists() and outer_marker(wt).exists(), out(r))
for mutation, why in (('del-inner-marker', 'logs/ の中の印だけ'), ('del-outer-marker', 'logs/ の外の印だけ')):
    wt, first = repo('marker-' + mutation)
    place_markers(wt)
    r, cap, done = gem(wt, 'rv', mutation=mutation)
    check(f'子が {why}を消しても不合格（EXIT:4）にし、印を置き直す', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done
          and (wt / 'logs' / '.review-reuse-blocked').exists() and outer_marker(wt).exists(), out(r))
wt, first = repo('swap-logs')
marker = outer_marker(wt)
r, cap, done = gem(wt, 'rv', mutation='swap-logs')
check('子が logs/ そのものを差し替えたら記録を書かずに止め（EXIT:5）、logs/ の外に使い回し禁止の印を置く', r.returncode == 5 and marker.exists(), out(r))

# ---- 22. 起動前点検は優先順位を解決した後のレビュー役で回す ----
wt, first = repo('route-resolved')
for eng, lane in (('codex', 'codex-review'), ('claude', 'claude-review')):
    r, cap, done = run('run-review.sh', wt, 'g-' + eng, '--engine', eng, env={'LANES_TOOLS': 'claude codex', 'LANES_REVIEW_ENGINE': 'gemini'})
    pidf = wt / 'logs' / f'g-{eng}.pid'
    check(f'設定が LANES_REVIEW_ENGINE=gemini（構成に gemini 無し）でも、--engine {eng} の起動は使わない Gemini の点検で止まらない',
          r.returncode == 0 and cap is None and pidf.exists() and f'lane={lane}' in pidf.read_text(), out(r) + done)

# ---- 23. scratch の相対指定は絶対パスに直して検査・作成・子への引き渡しをそろえる ----
wt, first = repo('relscratch')
r, cap, done = gem(wt, 'rs', cwd=T, env={'LANES_SCRATCH_ROOT': 'rel-scratch'})
scr = cap['env']['LANES_SCRATCH'] if cap else ''
a = cap['args'] if cap else []
check('LANES_SCRATCH_ROOT が相対パスでも、--add-dir・TMPDIR・LANES_SCRATCH・GIT_CONFIG_GLOBAL が同じ絶対パス（起動した場所から）を指す',
      r.returncode == 0 and scr.startswith(str(T / 'rel-scratch') + '/') and a[a.index('--add-dir') + 1] == scr and cap['env']['TMPDIR'] == scr + '/'
      and cap['env']['GIT_CONFIG_GLOBAL'] == scr + '/gitconfig' and (pathlib.Path(scr) / '.lane').is_file(), out(r) + json.dumps(cap['env'] if cap else {}, ensure_ascii=False))

# ---- 24. 専用の linked worktree だけで起動する（.git がファイルというだけでは通さない）----
sep_wt = T / 'sep-wt'; sep_git = T / 'sep.git'
subprocess.run(['git', 'init', '-q', '-b', 'main', '--separate-git-dir', str(sep_git), str(sep_wt)], env=BASE, check=True)
for k, v in (('user.name', 'Test User'), ('user.email', 'you@example.com'), ('commit.gpgSign', 'false')): git(sep_wt, 'config', k, v)
(sep_wt / '.gitignore').write_text('logs/\n'); (sep_wt / 'a.txt').write_text('初期'); git(sep_wt, 'add', '.'); git(sep_wt, 'commit', '-qm', 'test: 初期')
r, cap, done = gem(sep_wt, 'sp', '--base', 'HEAD')
check('管理領域を外に置いた本体 checkout（.git はファイル）では起動しない', r.returncode == 2 and cap is None and '専用の linked worktree ではない' in r.stderr, out(r))
r = subprocess.run(['zsh', '-f', str(lanes / 'run-gemini.sh'), str(sep_wt), str(prompt), 'gi', '--verify', 'true', '--allow-path', 'a.txt', '--no-push'],
                   env=make_env(), capture_output=True, text=True, timeout=120)
check('run-gemini.sh も同じ確かめ（管理領域を外に置いた本体 checkout では起動しない）', r.returncode == 2 and '専用の linked worktree ではない' in r.stderr, out(r))
sub_src = T / 'sub-src'; sub_src.mkdir(); git(sub_src, 'init', '-q', '-b', 'main')
for k, v in (('user.name', 'Test User'), ('user.email', 'you@example.com'), ('commit.gpgSign', 'false')): git(sub_src, 'config', k, v)
(sub_src / '.gitignore').write_text('logs/\n'); git(sub_src, 'add', '.'); git(sub_src, 'commit', '-qm', 'test: 初期')
sup = T / 'super'; sup.mkdir(); git(sup, 'init', '-q', '-b', 'main')
for k, v in (('user.name', 'Test User'), ('user.email', 'you@example.com'), ('commit.gpgSign', 'false')): git(sup, 'config', k, v)
git(sup, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(sub_src), 'sub'); git(sup, 'commit', '-qm', 'test: submodule')
r, cap, done = gem(sup / 'sub', 'sm', '--base', 'HEAD')
check('通常の submodule（.git はファイル）でも起動しない', r.returncode == 2 and cap is None and '専用の linked worktree ではない' in r.stderr, out(r))

# ---- 25. 役名の読み替えは実際のパス・枝名を変えない ----
wt, first = repo('ClaudeDir')
r, cap, done = gem(wt, 'cn')
merged = (wt / 'logs' / 'cn.prompt.md').read_text()
check('Gemini: Claude を含む worktree・枝でも、指示書のパス・枝名はそのまま（役名だけ Gemini に読み替え）',
      r.returncode == 0 and f'cwd: `{wt}`' in merged and '枝 `feat/ClaudeDir`' in merged and 'GeminiDir' not in merged and merged.startswith('# レビュー本線（Gemini）'), out(r))
r, cap, done = run('run-codex-review.sh', wt, 'cx', '--dry-run')
mc = (wt / 'logs' / 'cx.dry-run.prompt.md').read_text()
check('Codex: 同じく、指示書のパス・枝名はそのまま（役名だけ Codex に読み替え）', r.returncode == 0 and f'cwd: `{wt}`' in mc and 'CodexDir' not in mc, out(r))

# ---- 26. --mode はオプション名として照合する（--model の説明の plan で通さない）・独立性は選んだレビュー役で出す ----
p = doctor(env={'LANES_REVIEW_ENGINE': 'gemini'}, help='model-plan')
check('doctor: --mode が無く --model の説明に plan があるだけなら NG（--mode を単語として照合）', p.returncode == 2 and 'NG   gemini レビュー: agy が --mode に対応していない' in p.stdout, p.stdout)
text = roles('claude codex', {'LANES_REVIEW_ENGINE': 'claude'})
check('roles --print: claude codex 構成でも LANES_REVIEW_ENGINE=claude なら独立性は「弱い」と出す（実装と同じ Claude）',
      'レビューの独立性: 弱い' in text and 'レビューの独立性: あり' not in text and '構成の既定のレビュー役なら「あり」' in text, text)
text = roles('claude gemini', {'LANES_REVIEW_ENGINE': 'gemini'})
check('roles --print: claude gemini 構成で LANES_REVIEW_ENGINE=gemini なら独立性は「あり」（Claude の実装と別系統）',
      'レビューの独立性: あり' in text and 'レビューの独立性: 弱い' not in text, text)
check('roles --print: 指定が構成の既定と同じなら今までどおりの表示', 'レビューの独立性: あり（実装と別系統の道具で見る）' in roles('claude codex', {'LANES_REVIEW_ENGINE': 'codex'}))
env_out = subprocess.run(['zsh', '-f', str(lanes / 'lanes-roles.sh'), '--env'], env=make_env(env={'LANES_TOOLS': 'claude codex', 'LANES_REVIEW_ENGINE': 'claude'}),
                         capture_output=True, text=True).stdout
check('roles --env は構成の既定のまま（LANES_REVIEW_INDEPENDENT=1・4 行）', 'LANES_REVIEW_INDEPENDENT=1' in env_out and len(env_out.splitlines()) == 4, env_out)

print(f'PASS: {passed} 件 / EXIT:0')
PY
