#!/bin/zsh -f
# review-dedup.zsh の自己テスト。一時 git リポで round / 前回 head / モード / ゲート / 後回し票を確かめる。
# 実行: zsh -f lanes/tests/test-review-dedup.sh（キットのルートから）
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
LANES_DIR="${0:A:h:h}"; source "$LANES_DIR/_common.sh"; source "$LANES_DIR/review-dedup.zsh"
scratch_root="${LANES_SCRATCH:-${TMPDIR:?LANES_SCRATCH または TMPDIR が必要}}"
root="$(mktemp -d "${scratch_root%/}/test-review-dedup.XXXXXX")"
trap 'cd /; rm -rf -- "$root"' EXIT
cd "$root"
git init -q r; lanes_test_assert_repo r; cd r; git config user.email you@example.com; git config user.name you
print a > a.txt; git add a.txt; git commit -qm c1; h1=$(git rev-parse HEAD)
mkdir -p logs
tree1="$(rvd_snapshot .)"
pass=0; fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); print -- "ok   $1 = $2"; else fail=$((fail+1)); print -- "FAIL $1: '$2'（期待 '$3'）"; fi; }
eq series        "$(rvd_series rev-wap83-r5)" rev-wap83
eq series-nor    "$(rvd_series rev-foo)" rev-foo
eq round-label   "$(rvd_round logs rev-wap83 rev-wap83-r5 0)" 5
eq round-arg     "$(rvd_round logs rev-wap83 rev-wap83-r5 7)" 7
eq round-new     "$(rvd_round logs rev-foo rev-foo 0)" 1
eq mode-r1       "$(rvd_decide_mode . "$(rvd_prev_head logs rev-wap83 1)")" full
# round 1 の evidence（旧形式）を置く
print -- "- VERDICT: NEEDS_FIX\n- 実行: x / 約 1 分 / EXIT:0\n- HEAD: ${h1:0:12} → ${h1:0:12} / 作業ツリー差分行 0" > logs/rev-wap83-r1.evidence.md
eq prev-r2       "$(rvd_prev_head logs rev-wap83 2)" "${h1:0:12}"
eq mode-same     "$(rvd_decide_mode . "${h1:0:12}" "VERDICT: CLEAN" ctx ctx "$tree1" "$tree1")" same
eq prev-verdict  "$(rvd_prev_verdict logs rev-wap83 2)" "VERDICT: NEEDS_FIX"
print b >> a.txt; git commit -qam c2
eq mode-delta    "$(rvd_decide_mode . "${h1:0:12}" "VERDICT: CLEAN" ctx ctx "$(rvd_snapshot .)" "$tree1")" delta
git checkout -q --orphan other; git commit -qm o --allow-empty
eq mode-notanc   "$(rvd_decide_mode . "${h1:0:12}")" full
git checkout -q master 2>/dev/null || git checkout -q main
eq mode-badsha   "$(rvd_decide_mode . deadbeef)" full
# 失敗した round の evidence は飛ばして、その前を使う
print -- "- VERDICT: NONE\n- 実行: x / EXIT:1\n- HEAD: aaaa → bbbb" > logs/rev-wap83-r2.evidence.md
eq prev-skipfail "$(rvd_prev_head logs rev-wap83 3)" "${h1:0:12}"
# state（label に -r が無い系列）
rvd_save_state logs rev-foo 2 "$h1" "VERDICT: NEEDS_FIX" FIX rev-foo
eq state-round   "$(rvd_round logs rev-foo rev-foo 0)" 3
eq state-prev    "$(rvd_prev_head logs rev-foo 3)" "$h1"
# ゲート
eq gate-r2-p2    "$(rvd_gate 2 'VERDICT: NEEDS_FIX' 0 0)" FIX
eq gate-r3-p2    "$(rvd_gate 3 'VERDICT: NEEDS_FIX' 0 0)" MERGE_WITH_FOLLOWUP
eq gate-r3-p1    "$(rvd_gate 3 'VERDICT: NEEDS_FIX' 0 1)" STOP_P0P1
eq gate-r1-p0    "$(rvd_gate 1 'VERDICT: NEEDS_FIX' 1 0)" FIX
eq gate-clean    "$(rvd_gate 5 'VERDICT: CLEAN' 0 0)" CLEAN
# 後回し票
print -- "本文\n- [P2] **a** — x\n- [P3] b\n- [P1] c" > logs/r.log
rvd_write_followups logs/r.log logs/rev-wap83.followups.md 3 abc rev-wap83-r3
eq followups-n   "$(grep -c '^- \[P[23]\]' logs/rev-wap83.followups.md)" 2
eq followups-p1  "$(grep -c '\[P1\]' logs/rev-wap83.followups.md)" 0
eq delta-note    "$(rvd_delta_note . "${h1:0:12}" 3 | grep -c 'round 3 以降')" 1
eq unresolved-format "$(rvd_unresolved_note "$(rvd_prev_record logs rev-foo 3)" | grep -c '箇条書き・引用・表・コードブロック・行内コード・太字にしない')" 1
eq prev-failed-pair "$(rvd_prev_verdict logs rev-wap83 3)" "VERDICT: NEEDS_FIX"
eq gate-conflict-p1 "$(rvd_gate 3 'VERDICT: CLEAN' 0 1)" STOP_P0P1
# 周回の上限（既定 5）: 超えた周で CLEAN でなければ ESCALATE（人に返す）。上限以内・CLEAN はそのまま
eq escalate-r6     "$(rvd_escalate 6 'VERDICT: NEEDS_FIX' STOP_P0P1)" ESCALATE
eq escalate-r5     "$(rvd_escalate 5 'VERDICT: NEEDS_FIX' STOP_P0P1)" STOP_P0P1
eq escalate-clean  "$(rvd_escalate 9 'VERDICT: CLEAN' MERGE_WITH_FOLLOWUP)" MERGE_WITH_FOLLOWUP
eq escalate-raised "$(LANES_REVIEW_MAX_ROUNDS=8 rvd_escalate 6 'VERDICT: NEEDS_FIX' FIX)" FIX
eq gate-conflict-p0 "$(rvd_gate 1 'VERDICT: CLEAN' 1 0)" FIX
eq mode-legacy "$(rvd_decide_mode . "$h1")" full
eq mode-unresolved "$(rvd_decide_mode . "$h1" 'VERDICT: NEEDS_FIX' ctx ctx clean:a clean:a)" full
eq mode-conditions "$(rvd_decide_mode . "$h1" 'VERDICT: CLEAN' ctx changed clean:a clean:a)" full
eq mode-dirty "$(rvd_decide_mode . "$h1" 'VERDICT: CLEAN' ctx ctx dirty:a clean:a)" full
if rvd_save_state logs invalid 1 "$h1" 'VERDICT: NONE' FIX invalid; then eq state-none accepted rejected; else eq state-none rejected rejected; fi
print -- "---- 単体 $pass passed, $fail failed"
(( fail == 0 ))

# 実ランチャは使い捨てコピーから模擬 CLI だけを呼ぶ。監視も外部コマンドを置換する。
python3 - "$LANES_DIR" "$root" <<'PY_INTEGRATION'
import contextlib, importlib.util, io, json, os, pathlib, runpy, shutil, subprocess, sys, types
from unittest import mock
src, root = map(pathlib.Path, sys.argv[1:])
lanes = root / 'lanes'
lanes.mkdir()
for name in ['_common.sh', 'chk-run.sh', 'codex-review-output.py', 'lanes-roles.sh', 'review-dedup.zsh', 'run-codex-review.sh', 'run-claude-review.sh', 'lanes-monitor.sh']:
    shutil.copy(src / name, lanes / name)
shutil.copytree(src / 'templates', lanes / 'templates')
cli = root / 'mock-cli'
cli.write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
if args[:2] == ['login', 'status']:
    if os.environ.get('RVD_PREP_MUTATION') == 'prompt': pathlib.Path(os.environ['RVD_PROMPT']).write_text('準備中に変更')
    if os.environ.get('RVD_PREP_MUTATION') == 'source': pathlib.Path(os.environ['RVD_WT'], 'a.txt').write_text('準備中に変更')
    print('Logged in using ChatGPT'); sys.exit()
if args[:2] == ['auth', 'status']:
    print(json.dumps({'loggedIn': True, 'authMethod': 'claude.ai'})); sys.exit()
pathlib.Path(os.environ['RVD_CAPTURE']).write_text(json.dumps(args))
mutation = os.environ.get('RVD_MUTATION', '')
if mutation in ('overwrite', 'commit'):
    pathlib.Path('a.txt').write_text('レビュー中の上書き')
if mutation == 'commit':
    subprocess.run(['git', 'add', 'a.txt'], check=True)
    subprocess.run(['git', 'commit', '-qm', 'test: 模擬変更'], check=True)
if mutation == 'empty-commit': subprocess.run(['git', 'commit', '--allow-empty', '-qm', 'test: 履歴だけ変更'], check=True)
if mutation == 'untracked': pathlib.Path('new.txt').write_text('追加')
if mutation == 'prompt': pathlib.Path(os.environ['RVD_PROMPT']).write_text('レビュー中に指示変更')
if mutation == 'submodule': pathlib.Path('module/new.txt').write_text('既存未追跡の上書き')
if mutation == 'chmod': pathlib.Path('a.txt').chmod(0o755)
if mutation == 'stage': subprocess.run(['git', 'add', 'a.txt'], check=True)
if mutation == 'delete': pathlib.Path('a.txt').unlink()
if mutation == 'git-config': subprocess.run(['git', '-C', '.', 'config', 'core.hooksPath', 'x'], check=True)
if mutation == 'git-tag': subprocess.run(['git', '-C', '.', 'tag', 't'], check=True)
if mutation == 'git-hook':
    hook = pathlib.Path(subprocess.check_output(['git', 'rev-parse', '--git-common-dir'], text=True).strip()) / 'hooks' / 'post-checkout'
    hook.parent.mkdir(parents=True, exist_ok=True); hook.write_text('#!/bin/sh\n')
if mutation == 'git-branch': subprocess.run(['git', '-C', '.', 'branch', 'side'], check=True)
if mutation == 'symlink':
    pathlib.Path('a.txt').unlink(); pathlib.Path('a.txt').symlink_to('missing')
if mutation == 'ignored': pathlib.Path('.env.local').write_text('書き換え')
if mutation == 'ignored-new': pathlib.Path('local-data/new.txt').write_text('追加')
if mutation == 'forge-state': pathlib.Path('logs/.review.review-state').write_text('{"last_round": "0", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}\n')
if mutation == 'forge-other-state': pathlib.Path('logs/.other.review-state').write_text('{"last_round": "1", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}\n')
if mutation == 'forge-hard':
    pathlib.Path('logs/.review.review-state').write_text('{"last_round": "1", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}\n')
    z = pathlib.Path('logs/.zzz.review-state'); z.write_text('読めない'); z.chmod(0)
    pathlib.Path('logs/.aaa.review-state/sub').mkdir(parents=True)
if mutation == 'del-marker':
    import glob
    for f in ['logs/.review-reuse-blocked'] + glob.glob(os.path.join(os.environ['XDG_STATE_HOME'], 'lanewright', 'reuse-blocked', '*')):
        try: os.unlink(f)
        except FileNotFoundError: pass
if mutation == 'lock-logs':
    pathlib.Path('logs/.review.review-state').write_text('{"last_round": "1", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}\n')
    pathlib.Path('logs').chmod(0o500)
if mutation == 'undeletable':
    sub = pathlib.Path('logs/.aaa.review-state/sub'); sub.mkdir(parents=True); (sub / 'x').write_text('x'); sub.chmod(0o500)
if mutation == 'generated':
    for name in ('node_modules/pkg/index.js', 'apps/web/node_modules/x.js', 'apps/web/dist/out.js', 'src/__pycache__/m.pyc', 'logs/extra.log'):
        pathlib.Path(name).parent.mkdir(parents=True, exist_ok=True); pathlib.Path(name).write_text('生成')
body = os.environ.get('RVD_BODY', '問題なし\nVERDICT: CLEAN')
if args[:2] == ['exec', 'review']:
    print(json.dumps({'type': 'turn.started'}))
    print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': body}}))
    if os.environ.get('RVD_EVENTS') != 'truncated': print(json.dumps({'type': 'turn.completed', 'usage': {}}))
else: print(json.dumps({'type': 'result', 'result': body, 'is_error': False}))
sys.exit(int(os.environ.get('RVD_RC', '0')))
''')
cli.chmod(0o755)
# 実設定や認証情報を読まず、模擬値で構成する。
(lanes / 'lanes.env').write_text(f'''# Codex レビューを使う構成に固定する（呼び出し元の LANES_TOOLS に左右されない）
LANES_TOOLS='claude codex'
CODEX_BIN='{cli}'
CLAUDE_BIN='{cli}'
CODEX_MODEL=test
CODEX_EFFORT=test
CLAUDE_MODEL=test
CLAUDE_EFFORT=test
CLAUDE_REVIEW_TOOLS=Read
CLAUDE_REVIEW_DENY=Edit
LANES_PROMPT_MAX_BYTES=100000
LANES_SCRATCH_ROOT='{root}/scratch'
LANES_NOTIFY=0
''')
with (lanes / '_common.sh').open('a') as f:
    f.write('\nlanes_codex_no_mcp_args() { [[ $# == 1 && -d "$1" ]] || lanes_die "検証対象 worktree が必要"; typeset -ga LANES_CODEX_NO_MCP_ARGS=(-c "mcp_servers.test.enabled=false"); }\n')
passed = 0
def check(name, condition):
    global passed
    if not condition: raise AssertionError(name)
    passed += 1
    print('ok   ' + name)
def git(wt, *args):
    return subprocess.check_output(['git', '-C', str(wt), *args], stderr=subprocess.DEVNULL, text=True).strip()
def repo(name):
    wt = root / name; wt.mkdir()
    git(wt, 'init', '-q', '-b', 'main')
    assert os.path.realpath(subprocess.check_output(['git', '-C', str(wt), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(wt)), '一時リポの外の git に届いている: ' + str(wt)   # 本物のリポを書き換えない
    git(wt, 'config', 'user.name', 'you'); git(wt, 'config', 'user.email', 'you@example.com')
    (wt / 'a.txt').write_text('初期')
    (wt / '.gitignore').write_text('logs/\n')
    git(wt, 'add', '.'); git(wt, 'commit', '-qm', 'test: 初期')
    base = git(wt, 'rev-parse', 'HEAD'); git(wt, 'update-ref', 'refs/remotes/origin/develop', base)
    return wt, base
prompt = root / 'case.md'; prompt.write_text('案件固有の検証指示')
def launch_env(wt, body, mutation, prep, rc, extra_env):
    env = dict(os.environ, RVD_CAPTURE=str(root / 'capture.json'), RVD_BODY=body, RVD_MUTATION=mutation, RVD_RC=str(rc), RVD_PREP_MUTATION=prep, RVD_PROMPT=str(prompt), RVD_WT=str(wt))
    # 確認済みの記録（chk-run.sh）は一時領域のものだけを見る（本物の記録を読まない）
    env.pop('LANES_CHECK_CMD', None); env['CHK_CACHE'] = str(root / 'chk-cache' / 'passed.tsv')
    # 「使い回し禁止」の外の印は一時領域に置く（本物の ~/.local/state を触らない）
    env['XDG_STATE_HOME'] = str(root / 'state'); env.update(extra_env or {})
    return env
# 親の最終確認（chk-run.sh）。レビューと同じ環境で回す（入力の指紋に環境変数が入る）
def chk(wt, *, body='問題なし\nVERDICT: CLEAN', mutation='', prep='', rc=0, extra_env=None):
    r = subprocess.run(['bash', str(lanes / 'chk-run.sh'), str(wt), '49998', str(root / 'chk-out')],
                       env=launch_env(wt, body, mutation, prep, rc, extra_env), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0 and 'recorded=' in r.stdout, f'chk-run.sh が記録しない: {r.stdout} {r.stderr}'
def launch(wt, label, *, claude=False, body='問題なし\nVERDICT: CLEAN', mutation='', prep='', rc=0, args=(), extra_env=None):
    capture = root / 'capture.json'; capture.unlink(missing_ok=True)
    env = launch_env(wt, body, mutation, prep, rc, extra_env)
    result = subprocess.run(['zsh', '-f', str(lanes / ('run-claude-review.sh' if claude else 'run-codex-review.sh')), str(wt), str(prompt), label, *args], env=env, capture_output=True, text=True, timeout=30)
    if result.returncode not in (0, 2, 3, 4, 7):
        raise AssertionError(f'{label}: exit={result.returncode} {result.stdout} {result.stderr}')
    argv = json.loads(capture.read_text()) if capture.exists() else None
    done = (wt / 'logs' / (label + '.done')).read_text()
    return result, argv, done
wt, base = repo('delivery')
r, argv, done = launch(wt, 'review-r1')
check('full-成功', r.returncode == 0 and 'VERDICT: CLEAN' in done)
dev = json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
check('full-実入力の制約と案件指示', all(t in dev for t in ['コード編集・commit', '本番 DB には接続しない', 'typecheck / lint / unit test を全件', 'build はレビューでは回さない', 'build=SKIP', '案件固有の検証指示']))
check('full-build必須の要求を渡さない', 'build=PASS と記す' not in dev and '（typecheck / lint / unit / build）に未実施' not in dev)
check('MCP-共通配列引数', 'mcp_servers.test.enabled=false' in argv)
r, argv, done = launch(wt, 'review-r2')
check('同一条件-省略', argv is None and 'VERDICT: CLEAN' in done)
(wt / 'a.txt').write_text('未保存変更')
r, argv, done = launch(wt, 'review-r2')
check('未保存変更-省略禁止', argv is not None and r.returncode == 0)
(wt / 'new.txt').write_text('未追跡')
r, argv, done = launch(wt, 'review-r2')
check('未追跡-省略禁止', argv is not None)
r, argv, done = launch(wt, 'explicit-delta-r1', args=('--mode', 'delta', '--base', base))
dev = json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
check('dirtyの明示delta-fullへ昇格', 'full レビュー' in dev and '未追跡ソースも対象' in dev)
wt, base = repo('conditions')
launch(wt, 'review-r1')
prompt.write_text('変更した案件指示')
r, argv, done = launch(wt, 'review-r2')
check('指示変更-省略禁止', argv is not None)
(lanes / 'templates' / 'codex-review-focus.md').write_text('変更した重点')
r, argv, done = launch(wt, 'review-r2')
check('テンプレ変更-省略禁止', argv is not None)
git(wt, 'commit', '--allow-empty', '-qm', 'test: 比較起点変更')
new_base = git(wt, 'rev-parse', 'HEAD')
r, argv, done = launch(wt, 'review-r2', args=('--base', new_base))
check('起点変更-full', argv[argv.index('--base') + 1] == new_base)
r, argv, done = launch(wt, 'review-r2', args=('--base', base))
check('同一HEADで起点変更-省略禁止', argv is not None and argv[argv.index('--base') + 1] == base)
wt, base = repo('default-base-change')
git(wt, 'commit', '--allow-empty', '-qm', 'test: 変更を追加')
launch(wt, 'review-r1')
git(wt, 'update-ref', 'refs/remotes/origin/develop', git(wt, 'rev-parse', 'HEAD'))
r, argv, done = launch(wt, 'review-r2')
check('既定の起点更新-省略禁止', argv is not None)

wt, base = repo('unresolved')
r, argv, done = launch(wt, 'review-r1', body='- [P1] a.txt:1 未解決の認証不具合\nVERDICT: CLEAN')
check('P1-CLEAN矛盾-不合格', 'VERDICT: NEEDS_FIX' in done)
(wt / 'b.txt').write_text('別の変更'); git(wt, 'add', 'b.txt'); git(wt, 'commit', '-qm', 'test: 別の変更')
r, argv, done = launch(wt, 'review-r2', args=('--mode', 'delta'))
dev = json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
check('未解決本文引継ぎ-full', '未解決の認証不具合' in dev and '箇条書き・引用・表・コードブロック・行内コード・太字にしない' in dev and argv[argv.index('--base') + 1] == base)
check('解消確認なし-CLEAN禁止', 'VERDICT: NEEDS_FIX' in done)
# コード例・引用・表・箇条書き・行内コードの中の書式例や、否定と併記された解消宣言では未解決指摘を解除しない。
for index, body in enumerate((
    '解消宣言の書式:\n```\nRESOLVED_PREVIOUS_FINDINGS: YES\n```\nVERDICT: CLEAN',
    '> RESOLVED_PREVIOUS_FINDINGS: YES\nVERDICT: CLEAN',
    '| RESOLVED_PREVIOUS_FINDINGS: YES |\nVERDICT: CLEAN',
    '- RESOLVED_PREVIOUS_FINDINGS: YES\nVERDICT: CLEAN',
    '`RESOLVED_PREVIOUS_FINDINGS: YES`\nVERDICT: CLEAN',
    'RESOLVED_PREVIOUS_FINDINGS: YES\nRESOLVED_PREVIOUS_FINDINGS: NO\nVERDICT: CLEAN',
)):
    r, argv, done = launch(wt, 'review-r3', body=body)
    dev = json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
    check(f'書式例の解消宣言で解除しない-{index}', r.returncode == 0 and 'VERDICT: NEEDS_FIX' in done and '未解決の認証不具合' in dev)
r, argv, done = launch(wt, 'review-r3', body='a.txt:1 の全指摘について解消根拠を確認\nRESOLVED_PREVIOUS_FINDINGS: YES\nVERDICT: CLEAN')
dev = json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
check('未解決本文-次回も保持', '未解決の認証不具合' in dev)
check('全件解消確認-合格', 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'review-r3', body='- [P1] 再実行でも残る指摘\nVERDICT: NEEDS_FIX', args=('--force',))
r, argv, done = launch(wt, 'review-r3')
check('同じround-未解決を隠さない', argv is not None and 'VERDICT: NEEDS_FIX' in done)
r, argv, done = launch(wt, 'review-r3', body='- [P1] 未解決指摘\nVERDICT: NEEDS_FIX')
check('未解決P1-STOP判定維持', 'gate=STOP_P0P1' in done)

wt, base = repo('failure')
launch(wt, 'review-r1')
r, argv, done = launch(wt, 'review-r2', rc=7, args=('--force',))
check('失敗の終了記録', r.returncode == 7 and 'EXIT:7' in done)
r, argv, done = launch(wt, 'review-r2')
check('失敗回を混ぜない再利用', argv is None and 'VERDICT: CLEAN' in done and 'VERDICT: NONE' not in done)
r, argv, done = launch(wt, 'review-r3')
check('失敗後のr3-NONE禁止', r.returncode == 0 and 'VERDICT: CLEAN' in done and 'VERDICT: NONE' not in done)
r, argv, done = launch(wt, 'empty-r1', body='')
check('NONE-正常終了禁止', r.returncode == 3 and 'EXIT:3' in done)
r, argv, done = launch(wt, 'p3-r3', body='- [P3] 文言の残件')
check('P3のみ-後回し票保存', '文言の残件' in (wt / 'logs' / 'p3.followups.md').read_text())
checks_line = 'CHECKS: typecheck=PASS lint=PASS unit=PASS build=PASS'
skip_line = 'CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP'
# 前回から残る軽微な指摘は、本文から省かれていても後回し票へ移してから通す。
for level in ('P2', 'P3'):
    for repeated in (False, True, 'omitted-needs-fix'):
        previous_wt, _ = repo(f'previous-{level}-{repeated}')
        previous = f'[{level}] 前回から残る指摘\n  再現条件を保持する'
        launch(previous_wt, 'review-r2', body=previous+'\n'+skip_line+'\nVERDICT: NEEDS_FIX')
        body = (previous+'\n' if repeated is True else '')+skip_line+'\nVERDICT: '+('NEEDS_FIX' if repeated == 'omitted-needs-fix' else 'CLEAN')
        r, argv, done = launch(previous_wt, 'review-r3', body=body)
        followup = previous_wt/'logs/review.followups.md'
        saved = followup.read_text() if followup.exists() else ''
        state = json.loads((previous_wt/'logs/.review.review-state').read_text())
        check(f'前回の{level}を後回し票で通過-{repeated}', r.returncode == 0 and 'VERDICT: CLEAN' in done and 'gate=MERGE_WITH_FOLLOWUP' in done)
        check(f'前回の{level}本文を保存-{repeated}', '前回から残る指摘' in saved and '再現条件を保持する' in saved and state['last_gate'] == 'MERGE_WITH_FOLLOWUP')
        dev = json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
        check(f'前回の{level}の引継ぎ指示-{repeated}', '前回から残る指摘' in dev and '後回し票' in dev)
        r, argv, done = launch(previous_wt, 'review-r4')
        check(f'後回し票へ保存後の再利用-{level}-{repeated}', argv is None and 'VERDICT: CLEAN' in done)
for prior in ('P0', 'P1', 'unknown'):
    previous_wt, _ = repo('previous-blocker-'+prior)
    previous = ('必須検証が未実施' if prior == 'unknown' else f'[{prior}] 前回の重大な指摘\n[P2] 前回の軽微な指摘')
    launch(previous_wt, 'review-r2', body=previous+'\nVERDICT: NEEDS_FIX')
    r, argv, done = launch(previous_wt, 'review-r3', body='[P2] 今回の軽微な指摘\n'+skip_line+'\nVERDICT: CLEAN')
    check('重大度不明／重大な前回指摘を無宣言で解除しない-'+prior, 'VERDICT: NEEDS_FIX' in done and 'gate=FIX' in done)
    r, argv, done = launch(previous_wt, 'review-r4', body='[P3] 今回の別の指摘\n'+skip_line+'\nVERDICT: CLEAN')
    check('未解消の前回指摘を次回も保持-'+prior, 'VERDICT: NEEDS_FIX' in done)
for label, body, round_arg in (
    ('early', skip_line+'\nVERDICT: CLEAN', '2'),
    ('unchecked', 'VERDICT: CLEAN', '3'),
    ('incomplete', '[P2] 軽微\nレビューを完了できませんでした\nVERDICT: CLEAN', '3'),
    ('high', '[P1] 今回の重大な指摘\n'+skip_line+'\nVERDICT: CLEAN', '3'),
    ('failure', skip_line+'\nVERDICT: CLEAN', '3'),
    ('writefail', skip_line+'\nVERDICT: CLEAN', '3'),
):
    previous_wt, _ = repo('previous-guard-'+label)
    launch(previous_wt, 'review-r2', body='[P2] 前回の軽微な指摘\nVERDICT: NEEDS_FIX')
    if label == 'writefail': (previous_wt/'logs/review.followups.md').mkdir()
    r, argv, done = launch(previous_wt, 'review-r'+round_arg, body=body, rc=7 if label == 'failure' else 0)
    check('前回の軽微な指摘も安全条件を必須にする-'+label, 'VERDICT: CLEAN' not in done)
    if label == 'writefail': check('前回の後回し票保存失敗は異常終了', r.returncode == 3 and 'VERDICT: NONE' in done and 'gate=FIX' in done)

r, argv, done = launch(wt, 'p2-r3', body='- [P2] 条件付きの残件\n'+checks_line+'\nVERDICT: NEEDS_FIX')
check('P2-後回し票保存と合格', '条件付きの残件' in (wt / 'logs' / 'p2.followups.md').read_text() and 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'p2-explanation-r3', body='[P2] ビルド失敗時の処理を修正\nE2E 検証は省略（一時環境なし）\n'+checks_line+'\nVERDICT: NEEDS_FIX')
check('必須検証成功と説明中の失敗・任意検証の省略を区別', 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'notest-r3', body='検証未実施\nVERDICT: NEEDS_FIX')
check('指摘なしの検証不足-不合格', 'VERDICT: NEEDS_FIX' in done)
# 軽微な指摘と未実施が同居しても、round による昇格を許可しない。
for index, report in enumerate((
    '型検査・lint・unit・build が未実施',
    'typecheck / lint / unit test / build: not run',
    'Could not run typecheck',
    '単体テストを実行していない',
    'ビルドに失敗',
    '検証未完了\n'+checks_line,
    'CHECKS: typecheck=PASS lint=SKIP unit=PASS build=PASS',
    '| unit | FAIL |\n'+checks_line,
    'ビルド: 失敗\n'+skip_line,
    'typecheck / build: 未実施\n'+skip_line,
    'CHECKS: typecheck=PASS lint=PASS unit=PASS build=FAIL',
    'lint: BLOCKED\n'+checks_line,
    '```\n'+checks_line+'\n```',
    '> '+checks_line,
    '成功したかどうかの記載なし',
)):
    for level in ('P2', 'P3'):
        label=f'check{index}-{level}-r3'
        r, argv, done = launch(wt, label, body=f'[{level}] 残件\n{report}\nVERDICT: NEEDS_FIX')
        check('必須検証不足の昇格禁止-'+label, r.returncode==0 and 'VERDICT: NEEDS_FIX' in done and 'gate=FIX' in done)
for index, report in enumerate(('', '| build | 未実施（最終検証で担保） |', '| lint | 未実施（環境なし） |\n'+skip_line)):
    r, argv, done = launch(wt, f'p3-explicit-incomplete{index}-r3', body='[P3] 文言\n'+report+'\nVERDICT: CLEAN')
    check('P3の明示CLEANでも成功確認必須-'+str(index), 'VERDICT: NEEDS_FIX' in done and 'gate=FIX' in done)
# build はレビューで回さない。build だけの未実施を正直に書いた報告は、round 3 以降の昇格を妨げない。
for index, report in enumerate((
    skip_line,
    'build: 未実施（最終検証で担保）\n'+skip_line,
    '| build | 未実施（最終検証で担保） |\n'+skip_line,
    '- build: 未実施（実施条件に当たらない）\n'+skip_line,
    '| build | SKIP |\n'+checks_line,
)):
    for level in ('P2', 'P3'):
        label = f'buildskip{index}-{level}-r3'
        r, argv, done = launch(wt, label, body=f'[{level}] 残件\n{report}\nVERDICT: NEEDS_FIX')
        check('build未実施の正直な報告は昇格-'+label, r.returncode == 0 and 'VERDICT: CLEAN' in done and 'gate=MERGE_WITH_FOLLOWUP' in done)
r, argv, done = launch(wt, 'buildskip-clean-r1', body='build: 未実施（最終検証で担保）\n'+skip_line+'\nVERDICT: CLEAN')
check('build未実施の明示CLEANは合格', 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'p3-checked-r3', body='[P3] 文言\n'+checks_line+'\nVERDICT: CLEAN')
check('P3の明示CLEANと成功確認は合格', 'VERDICT: CLEAN' in done)
for claude in (False, True):
    r, argv, done = launch(wt, 'explicit-incomplete-'+str(claude)+'-r1', claude=claude,
                          body='typecheck / lint / unit / build 未実施\nVERDICT: CLEAN')
    check('明示CLEANでも必須検証不足は不合格-'+str(claude), 'VERDICT: NEEDS_FIX' in done)
# 不完全レビューは round 3 の後回し票ルールでも合格へ昇格しない。
for sev in ('P1', 'P2', 'P3'):
    r, argv, done = launch(wt, 'incomplete-'+sev+'-r3', body=f'[{sev}] 残件\nレビューを完了できませんでした\nVERDICT: CLEAN')
    check('未完了優先-'+sev, r.returncode == 3 and 'VERDICT: NONE' in done)
for index, prefix in enumerate(('', '+ ', '* ', '- ', '1. ', '2) ', '**')):
    title = prefix + '[P2]' + ('**' if prefix == '**' else '') + ' 保存対象'
    label = f'forms{index}-r3'
    r, argv, done = launch(wt, label, body=title+'\n  再現条件と修正方針\n'+checks_line+'\nVERDICT: NEEDS_FIX')
    saved = (wt/'logs'/f'forms{index}.followups.md').read_text()
    check('全指摘形式の保存-'+str(index), title in saved and '再現条件と修正方針' in saved and 'VERDICT: CLEAN' in done)
(wt/'logs'/'writefail.followups.md').mkdir()
r, argv, done = launch(wt, 'writefail-r3', body='[P2] 保存不能の残件\nVERDICT: NEEDS_FIX')
check('後回し票保存失敗-合格禁止', r.returncode == 3 and 'VERDICT: NONE' in done)
for claude in (False, True):
    for mutation in ('overwrite', 'commit', 'empty-commit', 'untracked', 'chmod', 'stage', 'delete', 'symlink'):
        wt, base = repo(f'mutation-{claude}-{mutation}')
        (wt / 'a.txt').write_text('レビュー前から未保存')
        r, argv, done = launch(wt, 'review-r1', claude=claude, mutation=mutation)
        check(f'内容変更-{claude}-{mutation}', r.returncode == 4 and 'VERDICT: CLEAN' not in done)
    # Claude レビュー（③④）は git の設定・hooks・タグの書き換えも不合格にする。枝の作成は並行レーンと区別できないため見ない（docs/roles.md）
    if claude:
        for mutation, want_rc in (('git-config', 4), ('git-tag', 4), ('git-hook', 4), ('git-branch', 0)):
            wt, base = repo(f'mutation-{claude}-{mutation}')
            r, argv, done = launch(wt, 'review-r1', claude=claude, mutation=mutation)
            check(f'git管理フォルダ-{claude}-{mutation}', r.returncode == want_rc and (('VERDICT: CLEAN' in done) == (want_rc == 0)))
    # 無視対象のファイル（.env.local・手元のデータ）の書き換え・追加も検出する。既知の生成物と logs/ はどの深さでも比べない
    for mutation, want_rc in (('ignored', 4), ('ignored-new', 4), ('generated', 0)):
        wt, base = repo(f'mutation-{claude}-{mutation}')
        (wt / '.gitignore').write_text('logs/\n.env.local\nlocal-data/\nnode_modules/\ndist/\n__pycache__/\n')
        git(wt, 'commit', '-qam', 'test: 無視の設定')
        (wt / '.env.local').write_text('元'); (wt / 'local-data').mkdir(); (wt / 'local-data' / 'keep.txt').write_text('元')
        (wt / 'node_modules').mkdir(); (wt / 'node_modules' / 'old.js').write_text('元')
        r, argv, done = launch(wt, 'review-r1', claude=claude, mutation=mutation)
        check(f'無視対象-{claude}-{mutation}', r.returncode == want_rc and (('VERDICT: CLEAN' in done) == (want_rc == 0)))
    child, _ = repo(f'child-{claude}')
    wt, base = repo(f'submodule-{claude}')
    git(wt, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(child), 'module')
    git(wt, 'commit', '-qam', 'test: 子リポを追加')
    (wt / 'module' / 'new.txt').write_text('既にある未追跡')
    r, argv, done = launch(wt, 'review-r1', claude=claude, mutation='submodule')
    check(f'子リポの未追跡上書き-{claude}', r.returncode == 4 and 'VERDICT: CLEAN' not in done)
    wt, base = repo(f'conflict-{claude}')
    r, argv, done = launch(wt, 'review-r1', claude=claude, body='- [P0] 重大な指摘\nVERDICT: CLEAN')
    check(f'P0矛盾-{claude}', 'VERDICT: NEEDS_FIX' in done)
    if claude:
        clean_wt, _ = repo('claude-clean')
        clean_result, _, clean_done = launch(clean_wt, 'review-r1', claude=True)
        check('Claude-正常本文の末尾判定を保持', clean_result.returncode == 0 and 'VERDICT: CLEAN' in clean_done)
        check('Claude-MCP隔離維持', '--strict-mcp-config' in argv)
        r, argv, done = launch(wt, 'empty-r1', claude=True, body='')
        check('Claude-NONE正常終了禁止', r.returncode == 3 and 'EXIT:3' in done)
# develop の無い repo（main だけの運用）。full でも明示した --base を比較起点に使う。
def main_only(name):
    wt = root / name; wt.mkdir()
    git(wt, 'init', '-q', '-b', 'main')
    assert os.path.realpath(subprocess.check_output(['git', '-C', str(wt), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(wt)), '一時リポの外の git に届いている: ' + str(wt)   # 本物のリポを書き換えない
    git(wt, 'config', 'user.name', 'you'); git(wt, 'config', 'user.email', 'you@example.com')
    (wt / 'a.txt').write_text('初期'); (wt / '.gitignore').write_text('logs/\n')
    git(wt, 'add', '.'); git(wt, 'commit', '-qm', 'test: 初期')
    first = git(wt, 'rev-parse', 'HEAD')
    (wt / 'a.txt').write_text('変更'); git(wt, 'commit', '-qam', 'test: 変更')
    return wt, first
def dry(script, wt, label, *args):
    env = dict(os.environ, RVD_CAPTURE=str(root / 'unused.json'), RVD_PROMPT=str(prompt), RVD_WT=str(wt), CHK_CACHE=str(root / 'chk-cache' / 'passed.tsv'))
    return subprocess.run(['zsh', '-f', str(lanes / script), str(wt), str(prompt), label, *args, '--dry-run'],
                          env=env, capture_output=True, text=True, timeout=30)
wt, first = main_only('main-only')
r = dry('run-claude-review.sh', wt, 'mainonly-full', '--mode', 'full', '--base', first[:12])
merged = (wt / 'logs' / 'mainonly-full.dry-run.prompt.md').read_text() if r.returncode == 0 else ''
check('main だけ-claude full と --base で起動', r.returncode == 0 and f'git diff {first}...HEAD' in merged and '無視' not in r.stderr)
r = dry('run-claude-review.sh', wt, 'mainonly-nobase', '--mode', 'full')
check('main だけ-claude full で起点なしは案内して停止', r.returncode == 2 and '--base' in r.stderr)
r = dry('run-claude-review.sh', wt, 'mainonly-badbase', '--mode', 'full', '--base', 'deadbeef00')
check('main だけ-claude 解決できない起点は停止', r.returncode == 2)
r = dry('run-codex-review.sh', wt, 'mainonly-codex', '--mode', 'full', '--base', first)
check('main だけ-codex full と --base で起動', r.returncode == 0 and f'base={first}' in r.stdout)
r = dry('run-codex-review.sh', wt, 'mainonly-codex-nobase', '--mode', 'full')
check('main だけ-codex 起点なしは案内して停止', r.returncode == 2 and '--base' in r.stderr)
for prep in ('prompt', 'source'):
    wt, base = repo('prepare-' + prep)
    r, argv, done = launch(wt, 'review-r1', prep=prep)
    check('準備中の変更で停止-' + prep, r.returncode == 2 and argv is None and 'EXIT:2' in done)
wt, base = repo('prompt-during-review')
r, argv, done = launch(wt, 'review-r1', mutation='prompt')
check('レビュー中の指示変更-不合格', r.returncode == 4 and 'VERDICT: CLEAN' not in done)
# 必須検証の「該当なし（NA）」は自己申告だけを根拠にしない。ランチャが対象の仕組み（package.json の scripts・
# LANES_CHECK_CMD・.lanes/check.sh）を見て、仕組みがある項目の NA・汎用の仕組みがあるのに全部 NA を不合格にする
na_one = 'unit: 該当なし（未導入）\nCHECKS: typecheck=PASS lint=PASS unit=NA build=SKIP\nVERDICT: CLEAN'
na_all = 'CHECKS: typecheck=NA lint=NA unit=NA build=SKIP\nVERDICT: CLEAN'
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'na-none-{kind}')
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=na_one)
    check(f'仕組みが無い項目のNAは受理-{kind}', r.returncode == 0 and 'VERDICT: CLEAN' in done)
    wt, base = repo(f'na-none-all-{kind}')
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=na_all)
    check(f'仕組みが無ければ全部NAも受理-{kind}', r.returncode == 0 and 'VERDICT: CLEAN' in done)
    wt, base = repo(f'na-pkg-{kind}')
    (wt / 'package.json').write_text(json.dumps({'scripts': {'lint': 'eslint .', 'test': 'vitest run'}}))
    git(wt, 'add', 'package.json'); git(wt, 'commit', '-qm', 'test: scripts')
    git(wt, 'update-ref', 'refs/remotes/origin/develop', git(wt, 'rev-parse', 'HEAD'))
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=na_one)
    check(f'scriptsにあるunitのNAは不合格-{kind}', r.returncode == 0 and 'VERDICT: NEEDS_FIX' in done)
    evidence = (wt / 'logs' / 'review-r1.evidence.md').read_text()
    check(f'見た仕組みを証跡に残す-{kind}', 'lint unit' in evidence)
    wt, base = repo(f'na-cmd-{kind}')
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=na_all, extra_env={'LANES_CHECK_CMD': 'make check'})
    check(f'LANES_CHECK_CMDがあるのに全部NAは不合格-{kind}', r.returncode == 0 and 'VERDICT: NEEDS_FIX' in done)
    wt, base = repo(f'na-cmd-part-{kind}')
    r, argv, done = launch(wt, 'review-r1', claude=claude, body='CHECKS: typecheck=PASS lint=NA unit=NA build=SKIP\nVERDICT: CLEAN', extra_env={'LANES_CHECK_CMD': 'make check'})
    check(f'LANES_CHECK_CMDがあっても一部のNAは受理-{kind}', r.returncode == 0 and 'VERDICT: CLEAN' in done)
    wt, base = repo(f'na-script-{kind}')
    (wt / '.lanes').mkdir(); (wt / '.lanes' / 'check.sh').write_text('#!/bin/sh\nexit 0\n')
    (wt / '.gitignore').write_text('logs/\n.lanes/\n'); git(wt, 'add', '.gitignore'); git(wt, 'commit', '-qm', 'test: 無視')
    git(wt, 'update-ref', 'refs/remotes/origin/develop', git(wt, 'rev-parse', 'HEAD'))
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=na_all)
    check(f'.lanes/check.shがあるのに全部NAは不合格-{kind}', r.returncode == 0 and 'VERDICT: NEEDS_FIX' in done)

# 検証の設定はレビューの再利用条件に入る。未導入で CLEAN の後に検証を足したら、同じ HEAD でも前回の CLEAN を使わない
wt, base = repo('check-config-change')
r, argv, done = launch(wt, 'review-r1', body=na_all)
check('検証未導入で全部NA-CLEAN', r.returncode == 0 and 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'review-r2', body=na_all)
check('検証の設定が同じなら省略', argv is None and 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'review-r2', body=na_all, extra_env={'LANES_CHECK_CMD': 'false'})
check('LANES_CHECK_CMDを足したら同じHEADでも再レビュー', argv is not None and 'VERDICT: NEEDS_FIX' in done)
# 値を変えただけでも再利用しない（前回 CLEAN・同じ HEAD で確かめる）
wt, base = repo('check-cmd-value')
na_part = 'CHECKS: typecheck=PASS lint=NA unit=NA build=SKIP\nVERDICT: CLEAN'
r, argv, done = launch(wt, 'review-r1', body=na_part, extra_env={'LANES_CHECK_CMD': 'make check-a'})
check('検証コマンドありでCLEAN', r.returncode == 0 and 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'review-r2', body=na_part, extra_env={'LANES_CHECK_CMD': 'make check-a'})
check('検証コマンドが同じ値なら省略', argv is None and 'VERDICT: CLEAN' in done)
r, argv, done = launch(wt, 'review-r2', body=na_part, extra_env={'LANES_CHECK_CMD': 'make check-b'})
check('LANES_CHECK_CMDの値の変更も再利用しない', argv is not None and 'VERDICT: CLEAN' in done)
wt, base = repo('check-script-change')
(wt / '.gitignore').write_text('logs/\n.lanes/\n'); git(wt, 'add', '.gitignore'); git(wt, 'commit', '-qm', 'test: 無視')
git(wt, 'update-ref', 'refs/remotes/origin/develop', git(wt, 'rev-parse', 'HEAD'))
launch(wt, 'review-r1', body=na_all)
(wt / '.lanes').mkdir(); (wt / '.lanes' / 'check.sh').write_text('#!/bin/sh\nexit 1\n')
r, argv, done = launch(wt, 'review-r2', body=na_all)
check('.lanes/check.shを足したら同じHEADでも再レビュー', argv is not None and 'VERDICT: NEEDS_FIX' in done)

# ---- Claude レビューも Codex レビューと同じ自動の full / delta / 同じ HEAD の使い回し（review-dedup.zsh）----
def sent(wt, label, claude, argv):
    if claude: return (wt / 'logs' / (label + '.prompt.md')).read_text()
    return json.loads(next(a.split('=', 1)[1] for a in argv if a.startswith('developer_instructions=')))
# 周回の上限を超えて P1 が残ると ESCALATE で止める。受け入れ済みの限界はレビューの指示書に必ず入る（Codex・Claude とも）
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'escalate-{kind}')
    (wt / '.lanes').mkdir(exist_ok=True)
    (wt / '.lanes' / 'accepted-limitations.md').write_text('- レビューの子が同じ利用者の権限で logs/ の外の印を消せる件（気づく守りまで）\n')
    r, argv, done = launch(wt, 'esc-r6', claude=claude, body='- [P1] 受け入れ済みでない重大な指摘\nVERDICT: NEEDS_FIX')
    text = sent(wt, 'esc-r6', claude, argv); evidence = (wt / 'logs' / 'esc-r6.evidence.md').read_text()
    check(f'周回の上限を超えたら ESCALATE で人に返す-{kind}', 'gate=ESCALATE' in done and '周回の上限' in evidence and 'VERDICT: NEEDS_FIX' in done)
    check(f'受け入れ済みの限界が指示書に入る-{kind}', '受け入れ済みの限界' in text and 'logs/ の外の印を消せる件' in text and 'P0〜P2 にしない' in text)
wt, base = repo('claude-auto')
r, argv, done = launch(wt, 'crev-r1', claude=True)
first = git(wt, 'rev-parse', 'HEAD'); text = sent(wt, 'crev-r1', True, argv)
check('Claude-auto-初回はfull', r.returncode == 0 and 'VERDICT: CLEAN' in done and 'full レビュー' in text and f'git diff {base}...HEAD' in text)
(wt / 'a.txt').write_text('軽い修正'); git(wt, 'commit', '-qam', 'test: 軽い修正')
r, argv, done = launch(wt, 'crev-r2', claude=True)
text = sent(wt, 'crev-r2', True, argv)
check('Claude-auto-前回CLEAN後はdelta', argv is not None and 'delta 再レビュー' in text and f'git diff {first}...HEAD' in text and '再レビュー（round 2・delta' in text)
check('Claude-auto-deltaの証跡', 'モード: delta' in (wt / 'logs' / 'crev-r2.evidence.md').read_text())
# 同じ round を呼び直す（round 3 からは後回しの方針が変わるので、条件の違いとして全体を見直す）
r, argv, done = launch(wt, 'crev-r2', claude=True)
check('Claude-auto-同じHEADは前回の結果を使う', argv is None and r.returncode == 0 and 'VERDICT: CLEAN' in done and 'skip-same-head' in (wt / 'logs' / 'crev-r2.evidence.md').read_text())
r, argv, done = launch(wt, 'crev-r2', claude=True, args=('--force',), body='- [P1] a.txt:1 認証の不具合\nVERDICT: NEEDS_FIX')
check('Claude-auto---forceで回す', argv is not None and 'VERDICT: NEEDS_FIX' in done)
(wt / 'b.txt').write_text('修正'); git(wt, 'add', 'b.txt'); git(wt, 'commit', '-qm', 'test: 修正')
r, argv, done = launch(wt, 'crev-r4', claude=True, args=('--mode', 'delta'))
text = sent(wt, 'crev-r4', True, argv)
check('Claude-NEEDS_FIX後は明示deltaでもfullで引継ぎ', 'full レビュー' in text and '認証の不具合' in text and f'git diff {base}...HEAD' in text)
check('Claude-解消宣言なしはCLEAN禁止', 'VERDICT: NEEDS_FIX' in done)
r, argv, done = launch(wt, 'crev-r5', claude=True, body='a.txt:1 の指摘は解消済み\nRESOLVED_PREVIOUS_FINDINGS: YES\nVERDICT: CLEAN')
check('Claude-全件解消の確認で合格', 'VERDICT: CLEAN' in done)
r = dry('run-claude-review.sh', wt, 'crev-r5')
check('Claude-dry-runでも同じHEADは省略を案内', r.returncode == 0 and '同じ head をもう一度レビューしない' in r.stdout)
# round 3 以降の P2/P3 の後回し（Codex と同じ）
skip_line = 'CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP'
wt, base = repo('claude-followups')
r, argv, done = launch(wt, 'cf-r3', claude=True, body='- [P2] 文言の残件\n  再現条件\n'+skip_line+'\nVERDICT: NEEDS_FIX')
saved = (wt / 'logs' / 'cf.followups.md').read_text()
check('Claude-round3のP2は後回し票に保存してCLEAN', r.returncode == 0 and 'VERDICT: CLEAN' in done and 'gate=MERGE_WITH_FOLLOWUP' in done and '文言の残件' in saved and '再現条件' in saved)
r, argv, done = launch(wt, 'cf2-r3', claude=True, body='- [P2] 成功確認の無い残件\nVERDICT: NEEDS_FIX')
check('Claude-round3でも成功確認が無ければ通さない', 'VERDICT: NEEDS_FIX' in done and 'gate=FIX' in done)
r, argv, done = launch(wt, 'cf3-r2', claude=True, body='- [P2] round 2 の残件\n'+skip_line+'\nVERDICT: NEEDS_FIX')
check('Claude-round2のP2は止める', 'VERDICT: NEEDS_FIX' in done and 'gate=FIX' in done)
r, argv, done = launch(wt, 'cf4-r3', claude=True, body='- [P1] 重大\n'+skip_line+'\nVERDICT: NEEDS_FIX')
check('Claude-round3のP1はSTOP', 'VERDICT: NEEDS_FIX' in done and 'gate=STOP_P0P1' in done)
r, argv, done = launch(wt, 'cf5', claude=True, args=('--round', '3'), body='- [P3] 軽微\n'+skip_line+'\nVERDICT: CLEAN')
check('Claude---roundでも後回し票', 'VERDICT: CLEAN' in done and '軽微' in (wt / 'logs' / 'cf5.followups.md').read_text())
# 子が再利用の記録を偽造したら元に戻して不合格（Codex と同じ）
wt, base = repo('claude-forge-state')
launch(wt, 'review-r1', claude=True)
state = wt / 'logs' / '.review.review-state'; state_save = state.read_text()
r, argv, done = launch(wt, 'review-r2', claude=True, args=('--force',), mutation='forge-state')
check('Claude-再利用の記録の偽造は戻して不合格', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and state.read_text() == state_save)
# 別の系列（other）の記録に偽の CLEAN を作られても、子の前の状態に戻して不合格（Codex・Claude とも）
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'forge-other-{kind}')
    r, argv, done = launch(wt, 'review-r1', claude=claude, mutation='forge-other-state')
    check(f'別の系列の記録の偽造も戻して不合格-{kind}', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done and not (wt / 'logs' / '.other.review-state').exists())
# 戻す処理は 1 つ失敗しても最後まで試す（読めない記録・同じ名前のフォルダでも、偽の記録を残さない）。
# どうしても消せない物を置かれたら印（logs/.review-reuse-blocked）を置き、次は同じ HEAD でも前回の記録を使わない
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'forge-hard-{kind}')
    launch(wt, 'review-r1', claude=claude)
    logs = wt / 'logs'; state = logs / '.review.review-state'; state_save = state.read_text()
    r, argv, done = launch(wt, 'review-r2', claude=claude, args=('--force',), mutation='forge-hard')
    check(f'読めない記録・同名フォルダがあっても最後まで戻す-{kind}', r.returncode == 4 and 'VERDICT: NEEDS_FIX' in done
          and state.read_text() == state_save and not (logs / '.zzz.review-state').exists() and not (logs / '.aaa.review-state').exists()
          and not (logs / '.review-reuse-blocked').exists())
    r, argv, done = launch(wt, 'review-r3', claude=claude, args=('--force',), mutation='undeletable')
    check(f'戻しきれなければ印を置いて不合格-{kind}', 'VERDICT: NEEDS_FIX' in done and (logs / '.review-reuse-blocked').exists())
    (logs / '.aaa.review-state' / 'sub').chmod(0o700)
    r, argv, done = launch(wt, 'review-r4', claude=claude)
    check(f'印があれば同じ HEAD でも前回の記録を使わずレビューする-{kind}', argv is not None and 'skip-same-head' not in done)
    outer = list((root / 'state' / 'lanewright' / 'reuse-blocked').glob('*'))
    check(f'印は logs/ の外にも置く-{kind}', len(outer) >= 1)
    # 子が印（中・外とも）を消しても、前後の比較で気づいて不合格にし、印を置き直す
    r, argv, done = launch(wt, 'review-r5', claude=claude, mutation='del-marker')
    check(f'印を消されたら不合格にして置き直す-{kind}', 'VERDICT: NEEDS_FIX' in done and (logs / '.review-reuse-blocked').exists()
          and any((root / 'state' / 'lanewright' / 'reuse-blocked').glob('*')))
    for f in [logs / '.review-reuse-blocked'] + list((root / 'state' / 'lanewright' / 'reuse-blocked').glob('*')):
        f.unlink()
# 子が記録を偽造してから logs/ を書けなくしても、logs/ の外に印が残り、権限を戻した後も偽の記録を使わない
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'lock-logs-{kind}')
    launch(wt, 'review-r1', claude=claude)
    logs = wt / 'logs'
    # logs/ を書けないので、ランチャは記録を書けずに失敗で終わる（終了コードは問わない）
    try:
        launch(wt, 'review-r2', claude=claude, args=('--force',), mutation='lock-logs')
        locked_failed = False
    except (AssertionError, OSError):
        locked_failed = True
    finally:
        logs.chmod(0o700)
    done2 = (logs / 'review-r2.done').read_text() if (logs / 'review-r2.done').exists() else ''
    check(f'logs/ を書けなくされても外の印が残る-{kind}', (locked_failed or 'VERDICT: CLEAN' not in done2)
          and any((root / 'state' / 'lanewright' / 'reuse-blocked').glob('*')))
    r, argv, done = launch(wt, 'review-r3', claude=claude)
    check(f'権限を戻した後も偽の記録を使わない-{kind}', argv is not None and 'skip-same-head' not in done)
    for f in [logs / '.review-reuse-blocked'] + list((root / 'state' / 'lanewright' / 'reuse-blocked').glob('*')):
        if f.exists(): f.unlink()
# 記録が大量にあっても（引数の長さの上限を超える量）、戻す処理は標準入力で受け取るので落ちない
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'many-states-{kind}')
    (wt / 'logs').mkdir(exist_ok=True)
    for i in range(16):
        (wt / 'logs' / f'.big{i}.review-state').write_text('{"report": "' + 'あ' * 25000 + '"}\n')
    r, argv, done = launch(wt, 'review-r1', claude=claude)
    check(f'記録が大量でも落ちずに判定できる-{kind}', r.returncode == 0 and 'VERDICT: CLEAN' in done)

# ---- 親の検証結果（chk-run.sh の記録）の使い回し（Codex・Claude のレビューとも）----
unrun = 'typecheck / lint / unit: 未実施（親の chk-run で実施済み）\nVERDICT: CLEAN'
check_env = {'LANES_CHECK_CMD': 'true'}
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'reuse-{kind}')
    chk(wt, body=unrun, extra_env=check_env)
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=unrun, extra_env=check_env)
    text = sent(wt, 'review-r1', claude, argv); evidence = (wt / 'logs' / 'review-r1.evidence.md').read_text()
    check(f'使い回し-指示書に回さない旨-{kind}', '親が同じ中身で実施済み' in text and '回さないこと' in text and '該当テスト 1 本か小さな再現だけ' in text)
    check(f'使い回し-必須検証は済んだものとしてCLEAN-{kind}', r.returncode == 0 and 'VERDICT: CLEAN' in done)
    check(f'使い回し-証跡に記録を出す-{kind}', '必須検証: 親の chk-run の記録を使用（head ' in evidence)
    # 1 回目のレビューが logs/ に書いた記録（.pid・.done・ログ・証跡・再利用の記録）は、chk-run の入力に数えない。
    # 同じ HEAD で呼び直しても記録と合うので、条件は変わらず前回の結果を使う（同じレビューを繰り返さない）
    r, argv, done = launch(wt, 'review-r2', claude=claude, body=unrun, extra_env=check_env)
    evidence = (wt / 'logs' / 'review-r2.evidence.md').read_text()
    check(f'ランチャの記録が増えても同じHEADは前回の結果を使う-{kind}', argv is None and 'skip-same-head' in done and 'VERDICT: CLEAN' in done)
    check(f'省略の証跡も記録の使用を出す-{kind}', '必須検証: 親の chk-run の記録を使用（head ' in evidence)
    # logs/ に置いた、ランチャの記録でないファイルは入力のまま。置けば記録と合わなくなり、条件の変化として
    # 同じ HEAD でも前回の結果を使わずにレビューの中で回させる（logs/ に入力を置いて照合をすり抜けられない）
    (wt / 'logs' / 'input.txt').write_text('確認コマンドが読むかもしれない入力')
    r, argv, done = launch(wt, 'review-r2', claude=claude, body=unrun, extra_env=check_env)
    text = sent(wt, 'review-r2', claude, argv); evidence = (wt / 'logs' / 'review-r2.evidence.md').read_text()
    check(f'記録と合わなくなれば同じHEADでも再レビュー-{kind}', argv is not None and 'VERDICT: NEEDS_FIX' in done and '親が同じ中身で実施済み' not in text and 'CHECKS:' in text)
    check(f'使い回し無し-証跡に理由-{kind}', '親の chk-run の記録は使わない: input-changed' in evidence)
    # 使い回さないときの証跡は「回すよう指示」と書く（回せたかは成功確認の行。未実施なのに「実施」と書かない）
    check(f'使い回し無し-証跡は実施と言い切らない-{kind}', 'レビューの中で回すよう指示' in evidence and 'レビューの中で実施' not in evidence and '必須検証の成功確認: INCOMPLETE' in evidence)
    # 親が回し直して記録が合えば、また使い回す（前回 NEEDS_FIX なので full で見直す）
    # （本文は模擬 CLI へ環境変数で渡すので、chk-run も同じ本文の環境で回す）
    resolved_body = 'RESOLVED_PREVIOUS_FINDINGS: YES\n' + unrun
    chk(wt, body=resolved_body, extra_env=check_env)
    r, argv, done = launch(wt, 'review-r2', claude=claude, body=resolved_body, extra_env=check_env)
    check(f'回し直した記録でまた使い回す-{kind}', argv is not None and 'VERDICT: CLEAN' in done and '親が同じ中身で実施済み' in sent(wt, 'review-r2', claude, argv))
    # 使い回すときでも、レビュアーが自分で回したテストの失敗の報告は不合格
    wt, base = repo(f'reuse-fail-{kind}')
    failed = 'unit: 失敗（1 本だけ回した）\nVERDICT: CLEAN'
    chk(wt, body=failed, extra_env=check_env)
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=failed, extra_env=check_env)
    check(f'使い回し-失敗の報告は不合格-{kind}', 'VERDICT: NEEDS_FIX' in done)
    # round 3 の P2 は、使い回しなら成功行が無くても後回し票で通す
    wt, base = repo(f'reuse-r3-{kind}')
    p2 = '- [P2] 文言の残件\nVERDICT: NEEDS_FIX'
    chk(wt, body=p2, extra_env=check_env)
    r, argv, done = launch(wt, 'review-r3', claude=claude, body=p2, extra_env=check_env)
    check(f'使い回し-round3のP2は後回し票でCLEAN-{kind}', 'VERDICT: CLEAN' in done and 'gate=MERGE_WITH_FOLLOWUP' in done)
    # 記録が無ければ今までどおり（必須検証の未実施は不合格。指示書は成功行の書き方）
    wt, base = repo(f'noreuse-{kind}')
    (wt / 'c.txt').write_text('ほかの repo と tree を分ける'); git(wt, 'add', 'c.txt'); git(wt, 'commit', '-qm', 'test: tree を分ける')
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=unrun, extra_env=check_env)
    text = sent(wt, 'review-r1', claude, argv)
    check(f'使い回し無し-今までどおり-{kind}', 'VERDICT: NEEDS_FIX' in done and '親が同じ中身で実施済み' not in text and 'CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP' in text)
    check(f'記録が無ければ理由を証跡に-{kind}', '親の chk-run の記録は使わない: no-record' in (wt / 'logs' / 'review-r1.evidence.md').read_text())
    # LANES_REVIEW_REUSE_CHECKS=0 なら記録があっても使わない
    wt, base = repo(f'reuse-off-{kind}')
    off_env = dict(check_env, LANES_REVIEW_REUSE_CHECKS='0')
    chk(wt, body=unrun, extra_env=off_env)
    r, argv, done = launch(wt, 'review-r1', claude=claude, body=unrun, extra_env=off_env)
    check(f'LANES_REVIEW_REUSE_CHECKS=0は使わない-{kind}', 'VERDICT: NEEDS_FIX' in done and 'LANES_REVIEW_REUSE_CHECKS=0' in (wt / 'logs' / 'review-r1.evidence.md').read_text())
# LANES_REVIEW_REUSE_CHECKS=0 なら問い合わせ自体をしない（chk-run.sh を呼ばない）
real_chk = (lanes / 'chk-run.sh').read_text(); mark = root / 'chk-called'
(lanes / 'chk-run.sh').write_text(f'#!/bin/bash\ntouch {mark}\necho "reuse=no reason=stub"\nexit 1\n')
for claude in (False, True):
    kind = 'claude' if claude else 'codex'
    wt, base = repo(f'reuse-noquery-{kind}')
    mark.unlink(missing_ok=True)
    launch(wt, 'review-r1', claude=claude, extra_env={'LANES_REVIEW_REUSE_CHECKS': '0'})
    check(f'LANES_REVIEW_REUSE_CHECKS=0は問い合わせない-{kind}', not mark.exists())
    launch(wt, 'review-r2', claude=claude, args=('--force',), extra_env={'LANES_REVIEW_REUSE_CHECKS': '1'})
    check(f'LANES_REVIEW_REUSE_CHECKS=1は問い合わせる-{kind}', mark.exists())
(lanes / 'chk-run.sh').write_text(real_chk)

# MCP 無効化の共通関数が無ければ、安全を確認できないので起動しない。
common = lanes / '_common.sh'
with common.open('a') as f: f.write('\nunfunction lanes_codex_no_mcp_args\n')
wt, base = repo('without-mcp-helper')
r, argv, done = launch(wt, 'review-r1')
check('MCP-共通関数が無ければ起動禁止', r.returncode != 0 and argv is None)
# 監視の対象と外部コマンドをメモリ上で置換し、本物の _runs や外部サービスを触らない。
runs = root / 'monitor-runs'; logdir = runs / 'my-app' / 'fixture' / 'logs'; logdir.mkdir(parents=True)
for i in range(13):
    (logdir / f'lane{i}.pid').write_text('pid=0\n')
    (logdir / f'lane{i}.done').write_text('EXIT:0\nVERDICT: CLEAN\n')
(logdir / 'none.pid').write_text('pid=0\n')
(logdir / 'none.done').write_text('EXIT:0\nVERDICT: NONE\n')
redeploy = mock.Mock(return_value=([], [])); module = types.ModuleType('vercel_autoredeploy'); module.run = redeploy
original_expand = os.path.expanduser
def expand(path): return str(runs) if path == '~/dev/_runs' else original_expand(path)
def monitor(allow=False):
    # このテストの先頭で _common.sh（lanes.env）を読んでいて LANES_RUNS_ROOT が export 済みなので、ここで差し替える
    env = {'LANES_STATUS': 'unused', 'LANES_RUNS_ROOT': str(runs), 'LANES_SCRATCH_ROOT': str(runs/'_scratch'), 'LM_RESET': '0', 'LM_APPEND': '0', 'LM_ALLOW_REDEPLOY': '1' if allow else '0', 'LM_NO_VERCEL': '0'}
    with mock.patch.dict(os.environ, env), mock.patch('os.path.expanduser', side_effect=expand), mock.patch('subprocess.run', return_value=types.SimpleNamespace(returncode=0, stdout='[]')), mock.patch.dict(sys.modules, {'vercel_autoredeploy': module}), contextlib.redirect_stdout(io.StringIO()) as out:
        try: runpy.run_path(str(src / 'lanes_monitor.py'), run_name='__main__')
        except SystemExit as e: assert e.code == 0
        return out.getvalue()
out = monitor()
check('監視-13本全件表示', all(f'lane{i} ' in out for i in range(13)))
check('監視-NONEはFAILED', 'FAILED my-app none' in out)
check('監視-既定の外部書き込みなし', redeploy.call_count == 0)
check('監視-既読の次回はQUIET', monitor().startswith('QUIET'))
monitor(True); check('監視-明示指定だけ再公開', redeploy.call_count == 1)
# シェルのフラグは継承環境の有効値を既定で打ち消す。
bindir = root / 'bin'; bindir.mkdir(); wrapper = bindir / 'python3'
wrapper.write_text('#!/bin/sh\nprintf "%s" "$LM_ALLOW_REDEPLOY"\n'); wrapper.chmod(0o755)
for args, expected in [((), '0'), (('--no-append',), '0'), (('--allow-redeploy',), '1')]:
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'], LM_ALLOW_REDEPLOY='1')
    r = subprocess.run(['zsh', '-f', str(lanes / 'lanes-monitor.sh'), *args], env=env, capture_output=True, text=True, timeout=10)
    check('監視フラグ-' + str(args), r.returncode == 0 and r.stdout == expected)
print(f'---- 結合 {passed} passed, 0 failed')
PY_INTEGRATION
