#!/bin/zsh -f
# Gemini ランチャの回帰テスト。本物の agy と外部サービスは使わず、全データを scratch に置く。
# selftest: 構成ごと
# 構成（LANES_TOOLS、未指定なら full）に gemini が無いときは停止だけ確かめて exit 77（対象外）。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-/tmp}}"
[[ -d "$scratch_base" ]] || { print -u2 '一時領域の親ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-gemini.XXXXXX")"
trap 'st=$?; [[ $st -ne 0 && $st -ne 77 ]] || rm -rf -- "$T"' EXIT
export LANES_TOOLS="${LANES_TOOLS:-claude codex gemini}" LANES_CONF="$T/no-such.conf"
export LANES_SCRATCH_ROOT="$T/scratch" LANES_NOTIFY=0 GEMINI_POLL_SEC=1 GEMINI_IDLE_GRACE=1 GEMINI_IDLE_RESUME_GRACE=1 GEMINI_NOOUTPUT_SEC=20
export GEMINI_BIN="$T/agy-stub" GEMINI_PRINT_TIMEOUT=20s
mkdir -p "$T/bin"
# push はテストの失敗にする。ほかは実物の Git で使い捨て repo を検査する。
export GEM_TEST_GIT="$(command -v git)"
cat > "$T/bin/git" <<'SH'
#!/bin/zsh -f
if [[ "$1" == push ]]; then print -r -- push >> "$GEM_TEST_PUSH"; exit 99; fi
exec "$GEM_TEST_GIT" "$@"
SH
chmod +x "$T/bin/git"
cat > "$T/bin/uname" <<'SH'
#!/bin/zsh -f
if [[ "$GEM_TEST_CASE" == unsupported_platform ]]; then print Linux; else exec /usr/bin/uname "$@"; fi
SH
chmod +x "$T/bin/uname"
# 偽の npm / pnpm（依存の自動用意の呼ばれ方を記録するだけ。外へは通信しない）
for pm in npm pnpm; do
  print -r -- '#!/bin/zsh -f'$'\n''print -r -- "'"$pm"' $* @ $PWD" >> "${GEM_TEST_DEPS:-/dev/null}"' > "$T/bin/$pm"
  chmod +x "$T/bin/$pm"
done
export PATH="$T/bin:$PATH"
cat > "$GEMINI_BIN" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
case = os.environ['GEM_TEST_CASE']
if '--help' in sys.argv:
    print('--sandbox' if case == 'unsupported' else '--sandbox --settings')
    sys.exit(0)
Path(os.environ['GEM_TEST_STARTED']).write_text('started')
settings = json.loads(sys.argv[sys.argv.index('--settings') + 1])
assert '--sandbox' in sys.argv
assert settings['permissions']['deny'] == ['mcp(*)']
assert settings['allowNonWorkspaceAccess'] is False
assert settings['enableTerminalSandbox'] is True
assert os.environ['ANTIGRAVITY_HEADLESS'] == 'true'
assert not any(k in os.environ for k in ('GEMINI_API_KEY', 'GOOGLE_API_KEY', 'AGY_ADC_AUTH'))
scr = Path(os.environ['LANES_SCRATCH'])
def event(value):
    print(json.dumps(value), flush=True)
def result(status='SUCCESS'):
    event({'event':'result', 'result':{'status':status, 'response':'検証用の応答'}})
def message():
    (scr/'COMMIT_MSG.txt').write_text('fix: テスト用の変更\n\n担当ファイルを修正\n')
def change():
    Path('owned.txt').write_text('更新\n')
def write_event(path):
    event({'event':'step_update', 'step_update':{'step_type':'tool', 'tool_name':'write_file',
            'tool_info':{'parameters':{'Path':path}}}})
if case == 'empty':
    sys.exit(0)
event({'event':'init'})
if case == 'active_test':
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(4)'])
    print('root agent idle', file=sys.stderr, flush=True)
    assert child.wait() == 0
    Path(os.environ['GEM_TEST_CHILD']).write_text('completed')
elif case in ('change', 'verify_fail', 'idle_change', 'idle_stale', 'error_change', 'nonzero_success', 'message_symlink', 'bad_json_change', 'noout'):
    change()
    if case != 'idle_stale':
        message()
    if case == 'message_symlink':
        (scr/'COMMIT_MSG.txt').unlink()
        (scr/'COMMIT_MSG.txt').symlink_to(Path(os.environ['GEM_TEST_MSG']))
elif case in ('outside_scope', 'staged_outside'):
    change(); Path('other.txt').write_text('範囲外\n'); message()
    if case == 'staged_outside': subprocess.run(['git','add','other.txt'],check=True)
elif case == 'literal_paths':
    Path(':literal.txt').write_text('変更\n'); Path('space name.txt').write_text('変更\n'); message()
elif case == 'directory_scope':
    Path('src').mkdir(); Path('src/new.txt').write_text('変更\n'); message()
elif case == 'rename':
    Path('owned.txt').rename('renamed.txt'); message()
elif case == 'gitlink':
    # サンドボックスの外で走る git の入口（.git ファイル）の書き換えを模擬する。
    Path('.git').write_text('gitdir: ' + os.environ['GEM_TEST_OUTSIDE'] + '.gitdir\n'); change(); message()
elif case == 'head_changed':
    subprocess.run(['git','commit','--allow-empty','-qm','test: 禁止操作の模擬'],check=True)
elif case == 'tracked_log':
    Path('logs/tracked.txt').write_text('更新\n'); message()
elif case == 'symlink_change':
    Path('owned.txt').unlink(); Path('owned.txt').symlink_to(os.environ['GEM_TEST_OUTSIDE']); message()
elif case == 'plain_path':
    write_event('owned.txt'); change(); message()
elif case == 'alias':
    write_event('alias.txt')
elif case == 'outside_missing':
    write_event(os.environ['GEM_TEST_OUTSIDE'] + '.missing')
elif case == 'move_source':
    event({'event':'step_update', 'step_update':{'step_type':'tool','tool_name':'move_file',
           'tool_info':{'parameters':{'Source':os.environ['GEM_TEST_OUTSIDE'], 'Destination':'owned.txt'}}}})
elif case == 'bad_tool':
    event({'event':'step_update', 'step_update':{'step_type':'tool','tool_name':'write_file','tool_info':{}}})
elif case == 'missing_tool_name':
    event({'event':'step_update', 'step_update':{'step_type':'tool',
           'tool_info':{'parameters':{'Path':os.environ['GEM_TEST_OUTSIDE']}}}})
elif case == 'audit_injection':
    print('{broken', flush=True)
    event({'event':'result', 'result':{'status':'SUCCESS','num_turns':'0\naudit_ok=1'}})
    sys.exit(0)
elif case == 'missing_result':
    sys.exit(0)
elif case == 'invalid_utf8':
    sys.stdout.buffer.write(b'\xff\n'); sys.stdout.buffer.flush()
elif case == 'scalar':
    event([])
elif case == 'malformed_result':
    event({'event':'result', 'result':[]}); sys.exit(0)
elif case == 'scratch_links':
    # ランチャが子の後に scratch へ書くファイルを、外のファイルへの symlink にしておく（辿って上書きさせる試み）
    change(); message()
    for name in ('gemini-response.txt', 'gemini-audit.txt', 'wip.patch', 'wip.status'):
        (scr/name).unlink(missing_ok=True); (scr/name).symlink_to(os.environ['GEM_TEST_OUTSIDE'])
elif case == 'noout_links':
    change()
    for name in ('wip.patch', 'wip.status'):
        (scr/name).unlink(missing_ok=True); (scr/name).symlink_to(os.environ['GEM_TEST_OUTSIDE'])
elif case == 'log_link_idle':
    # 実行中に logs/<label>.log を外向きの symlink にして、見張りの追記を外へ向けさせる試み
    Path('logs/test.log').unlink(missing_ok=True); Path('logs/test.log').symlink_to(os.environ['GEM_TEST_OUTSIDE'])
elif case == 'retry':
    count = scr/'attempt'
    if not count.exists():
        count.write_text('1'); message()
        print('UNAVAILABLE 503',file=sys.stderr)
        result('ERROR'); sys.exit(1)
    change()
    # 再試行前に退避されたメッセージを利用せず、書かないまま終了する。
if case in ('noout', 'noout_links'):
    time.sleep(15); sys.exit(0)
result('ERROR' if case in ('idle_nochange', 'idle_change', 'idle_stale', 'error_change', 'log_link_idle') else 'SUCCESS')
if case in ('idle_nochange', 'idle_change', 'idle_stale', 'log_link_idle'):
    print('root agent idle', file=sys.stderr, flush=True); time.sleep(8)
if case in ('bad_json','bad_json_change'): print('{broken',flush=True)
if case == 'blank': print('',flush=True)
if case == 'missing_log': Path('logs/test.json').unlink()
if case in ('error_change','nonzero_success'): sys.exit(1)
PY
chmod +x "$GEMINI_BIN"
print -r -- '担当の修正だけを行う。' > "$T/prompt.md"
count=0

# 構成（LANES_TOOLS）に gemini が無いときは本体のテストは対象外。代わりに「run-gemini.sh が exit 2 で止まり、
# agy を起動せず .done を残す」ことだけを確かめ、終了コード 77（対象外）で終わる。
# 出力を先に変数へ受ける。パイプで grep -q に渡すと、grep が先に終わったとき書き手が SIGPIPE（読み手の終了による書き込み失敗）で
# 141 になり、pipefail 下で「gemini あり」の構成を「なし」と誤判定する
roles_env="$(LANES_CONF="$T/no-such.conf" zsh -f "$LANES_DIR/lanes-roles.sh" --env)"
if ! grep -qx 'LANES_ROLE_IMPL="claude gemini"' <<< "$roles_env"; then
  export GEM_TEST_CASE=change GEM_TEST_STARTED="$T/off-started"
  base="$T/repo-off"; repo="$T/wt-off"
  git init -q -b main "$base"; lanes_test_assert_repo "$base"
  git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit --allow-empty -qm 'test: 本体の初期化'
  git -C "$base" worktree add -q -b fix/off "$repo"
  actual=0
  zsh "$LANES_DIR/run-gemini.sh" "$repo" "$T/prompt.md" off --verify 'true' --allow-path owned.txt --no-push > "$T/off.log" 2>&1 || actual=$?
  [[ "$actual" == 2 ]] || { print -u2 -- "FAIL: gemini の無い構成で exit 2 にならない（$actual）"; exit 1; }
  grep -q 'この構成では使えない' "$T/off.log" || { print -u2 -- 'FAIL: 代わりの入口を案内しない'; exit 1; }
  [[ ! -e "$GEM_TEST_STARTED" ]] || { print -u2 -- 'FAIL: gemini の無い構成で agy を起動した'; exit 1; }
  grep -q '^EXIT:2$' "$repo/logs/off.done" || { print -u2 -- 'FAIL: .done（EXIT:2）が無い'; exit 1; }
  print -r -- "ok 1 run-gemini.sh は gemini の無い構成で exit 2・agy 未起動・.done あり"
  print -r -- "SKIP: gemini の無い構成なので Gemini ランチャ本体のテストは対象外（停止の確認だけ実施）"
  exit 77
fi
fail() { print -u2 -- "FAIL: $GEM_TEST_CASE / $*（$T）"; exit 1; }
setup() {
  export GEM_TEST_CASE="$1"
  # ランチャは専用の linked worktree だけを受け付ける。本体 checkout は base、作業場所は repo。
  base="$T/repo-$1"; repo="$T/wt-$1"
  git init -q -b main "$base"; lanes_test_assert_repo "$base"
  git -C "$base" config user.name "Test User"
  git -C "$base" config user.email you@example.com
  git -C "$base" config commit.gpgSign false
  git -C "$base" config core.hooksPath "$T/no-hooks"
  git -C "$base" commit --allow-empty -qm 'test: 本体の初期化'
  git -C "$base" worktree add -q -b fix/test "$repo"
  print -r -- '元の内容' > "$repo/owned.txt"
  print -r -- '範囲外の元の内容' > "$repo/other.txt"
  print -r -- '元の内容' > "$repo/:literal.txt"
  print -r -- '元の内容' > "$repo/space name.txt"
  mkdir -p "$repo/logs"
  print -r -- '追跡ログ' > "$repo/logs/tracked.txt"
  export GEM_TEST_OUTSIDE="$T/$1-outside.txt" GEM_TEST_STARTED="$T/$1-started" GEM_TEST_CHILD="$T/$1-child"
  export GEM_TEST_MSG="$T/$1-message" GEM_TEST_PUSH="$T/$1-push"
  print -r -- '外側の内容' > "$GEM_TEST_OUTSIDE"
  print -r -- 'fix: リンク先の古い文面' > "$GEM_TEST_MSG"
  ln -s "$GEM_TEST_OUTSIDE" "$repo/alias.txt"
  git -C "$repo" add --all
  git -C "$repo" commit -qm 'test: 初期状態'
  before="$(git -C "$repo" rev-parse HEAD)"
  verify_cmd='printf verified > "$LANES_SCRATCH/verified"'
  scope=(--allow-path owned.txt)
  scratch="$LANES_SCRATCH_ROOT/${base:t}/test"
}
run() {
  local expected="$1"; shift
  local -a push_args
  push_args=(--no-push)
  # 異常終了からの救済は、既定の push 有効状態でもローカル保存だけに留まる。
  case "$GEM_TEST_CASE" in idle_change|error_change|nonzero_success) push_args=() ;; esac
  actual=0
  zsh "$LANES_DIR/run-gemini.sh" "$repo" "$T/prompt.md" test --verify "$verify_cmd" "${scope[@]}" "${push_args[@]}" "$@" > "$T/$GEM_TEST_CASE.log" 2>&1 || actual=$?
  [[ "$actual" == "$expected" ]] || fail "終了コード expected=$expected actual=$actual"
  [[ ! -e "$GEM_TEST_PUSH" ]] || fail 'push が呼ばれた'
  count=$((count + 1)); print -r -- "ok $count $GEM_TEST_CASE EXIT:$actual"
}
unchanged() { [[ "$(git -C "$repo" rev-parse HEAD)" == "$before" ]] || fail 'commit された'; }
committed() { [[ "$(git -C "$repo" rev-parse HEAD)" != "$before" ]] || fail 'commit されなかった'; }

setup no_verify
actual=0
zsh "$LANES_DIR/run-gemini.sh" "$repo" "$T/prompt.md" test --allow-path owned.txt --no-push > "$T/no_verify.log" 2>&1 || actual=$?
[[ "$actual" == 2 && ! -e "$GEM_TEST_STARTED" ]] || fail '--verify なしで起動'
count=$((count + 1)); print -r -- "ok $count no_verify EXIT:$actual"
setup no_scope; scope=(); run 2; unchanged
setup blank_verify; verify_cmd='  '; run 2; unchanged
setup invalid_scope; scope=(--allow-path ../outside); run 2; unchanged
setup unsupported; run 2; unchanged
setup unsupported_platform; run 2; unchanged
for kind in dirty_tracked dirty_staged dirty_untracked dirty_logs; do
  setup "$kind"
  case "$kind" in
    dirty_tracked) print -r -- '前からの変更' >> "$repo/owned.txt" ;;
    dirty_staged) print -r -- '前からの変更' >> "$repo/owned.txt"; git -C "$repo" add owned.txt ;;
    dirty_untracked) print -r -- '前からの変更' > "$repo/new.txt" ;;
    dirty_logs) print -r -- '前からの変更' >> "$repo/logs/tracked.txt" ;;
  esac
  old_status="$(git -C "$repo" status --porcelain --untracked-files=all | grep -v '^?? logs/')"
  run 2; unchanged
  [[ ! -e "$GEM_TEST_STARTED" ]] || fail '開始前の変更を無視して起動'
  [[ "$(git -C "$repo" status --porcelain --untracked-files=all | grep -v '^?? logs/')" == "$old_status" ]] || fail '開始前の変更を改変'
done
setup main_checkout; repo="$base"; before="$(git -C "$repo" rev-parse HEAD)"; run 2; unchanged
[[ ! -e "$GEM_TEST_STARTED" ]] || fail '本体 checkout で agy を起動'
setup gitlink; run 4
[[ "$(git -C "$base" rev-parse fix/test)" == "$before" ]] || fail 'commit された'
[[ ! -e "$scratch/verified" ]] && grep -q 'agy の実行中に変わった' "$T/gitlink.log" || fail '.git の書き換え後に検証・git へ進んだ'
setup nochange; run 0; unchanged; [[ -f "$scratch/verified" ]] || fail '差分なしで検証を省略'
setup nochange_verify_fail; verify_cmd='exit 9'; run 7; unchanged
setup change; run 0; committed
[[ "$(git -C "$repo" show --pretty= --name-only HEAD)" == owned.txt ]] || fail '無関係な変更を保存'
setup verify_fail; verify_cmd='exit 9'; run 7; unchanged
setup outside_scope; run 4; unchanged
setup staged_outside; run 4; unchanged
setup verify_outside; verify_cmd='printf changed > other.txt'; run 4; unchanged
setup head_changed; run 4
# 本体の初期化・初期状態・stub の commit の 3 件だけ（ランチャが追加で保存していない）。
[[ "$(git -C "$repo" rev-list --count HEAD)" == 3 ]] || fail 'HEAD 変更後も保存した'
setup tracked_log; run 4; unchanged
setup symlink_change; run 4; unchanged
setup literal_paths; scope=(--allow-path :literal.txt --allow-path 'space name.txt'); run 0; committed
setup directory_scope; scope=(--allow-path src/); run 0; committed
setup rename; scope=(--allow-path owned.txt --allow-path renamed.txt); run 0; committed
setup plain_path; run 0; committed
for kind in bad_json bad_json_change blank empty missing_log invalid_utf8 scalar malformed_result missing_result bad_tool missing_tool_name audit_injection alias outside_missing move_source; do
  setup "$kind"; run 4; unchanged; [[ ! -e "$scratch/verified" ]] || fail '監査失敗後に検証へ進んだ'
done
setup idle_nochange; run 3; unchanged; [[ ! -e "$scratch/verified" ]] || fail 'idle 差分なしを救済した'
setup idle_change; run 3; committed; [[ -f "$scratch/verified" ]] || fail '未検証の救済保存'
setup idle_stale
# 前回の同じレーンの scratch を模す。.lane（所有情報）が無い既存フォルダはランチャが他人の物とみなして使わないため、
# ランチャと同じ形（git が返す worktree の最上位を実パスにしたもの）で worktree= を書いておく
mkdir -p "$scratch"; print -r -- 'fix: 前回の文面' > "$scratch/COMMIT_MSG.txt"
print -r -- "worktree=${$(git -C "$repo" rev-parse --path-format=absolute --show-toplevel):A}" > "$scratch/.lane"
run 3; unchanged
[[ ! -e "$scratch/COMMIT_MSG.txt" ]] || fail '古いメッセージが残存'
archived=("$scratch"/COMMIT_MSG.prev-*.txt(N))
[[ ${#archived} == 1 ]] || fail '前回のメッセージが退避されていない'
setup error_change; run 3; committed
setup nonzero_success; run 3; committed
setup message_symlink; run 5; unchanged
setup retry; run 5; unchanged
[[ -f "$repo/logs/test.try1.json" && ! -e "$scratch/COMMIT_MSG.txt" ]] || fail '再試行の古いメッセージを再利用'
# 子の終了から偽 agy の終了までの間に idle と見なされないよう、このケースだけ猶予を 5 秒にする（並列の負荷で 1 秒を超えるため）
setup active_test; GEMINI_IDLE_GRACE=5 run 0; unchanged; [[ -e "$GEM_TEST_CHILD" ]] || fail '実行中のテストを idle で停止'
# 依存の自動用意: worktree の直下・apps/*/・packages/*/ のロックファイルを見て、node_modules/.bin が無い所だけ入れる
deps_setup() {
  setup "$1"
  export GEM_TEST_DEPS="$T/$1-deps"
  print -r -- 'node_modules/' > "$repo/.gitignore"
  local d
  for d in "$@[2,-1]"; do mkdir -p "$repo/${d:h}"; print -r -- '{}' > "$repo/$d"; done
  git -C "$repo" add --all; git -C "$repo" commit -qm 'test: ロックファイル'
  before="$(git -C "$repo" rev-parse HEAD)"
}
deps_setup deps package-lock.json apps/web/package-lock.json packages/lib/package-lock.json packages/ready/package-lock.json \
  tools/deep/package-lock.json apps/web/nested/package-lock.json apps/yarnapp/yarn.lock
mkdir -p "$repo/packages/ready/node_modules/.bin"
GEM_TEST_CASE=nochange run 0; unchanged
want="npm ci --silent @ ${repo:A}
npm ci --silent @ ${repo:A}/apps/web
npm ci --silent @ ${repo:A}/packages/lib"
[[ "$(sed 's|@ /private/|@ /|' "$GEM_TEST_DEPS" | LC_ALL=C sort)" == "$(print -r -- "$want" | sed 's|@ /private/|@ /|' | LC_ALL=C sort)" ]] \
  || { cat "$GEM_TEST_DEPS" >&2; fail '依存の自動用意の場所が違う（直下・apps/*・packages/* だけ。.bin のある所と 2 段下は除く）'; }
grep -q 'yarn.lock の依存は自動では入れない.*apps/yarnapp' "$T/nochange.log" || fail 'yarn.lock だけの所の案内が無い'
deps_setup deps_pnpm pnpm-lock.yaml
GEM_TEST_CASE=nochange run 0; unchanged
grep -q '^pnpm install --frozen-lockfile --silent @ ' "$GEM_TEST_DEPS" || fail 'pnpm-lock.yaml の所で pnpm install --frozen-lockfile しない'
unset GEM_TEST_DEPS
setup noout; export GEMINI_NOOUTPUT_SEC=2; run 8; unchanged
[[ -e "$scratch/wip.patch" && ! -e "$scratch/verified" ]] || fail '無出力停止で検証・保存した'
# ランチャが scratch へ書くファイル（応答本文・監査・wip.*）が外向きの symlink にされていても、外のファイルは書き換えない
outside_unchanged() { [[ "$(< "$GEM_TEST_OUTSIDE")" == '外側の内容' ]] || fail "外のファイルが書き換えられた: $*"; }
setup scratch_links; run 0; committed; outside_unchanged 'scratch の symlink を辿った'
for f in gemini-response.txt gemini-audit.txt; do [[ -f "$scratch/$f" && ! -L "$scratch/$f" ]] || fail "$f が新しい普通のファイルとして作られていない"; done
setup noout_links; export GEMINI_NOOUTPUT_SEC=2; run 8; unchanged; outside_unchanged 'wip.* の symlink を辿った'
[[ -f "$scratch/wip.patch" && ! -L "$scratch/wip.patch" ]] || fail 'wip.patch が新しい普通のファイルとして作られていない'
export GEMINI_NOOUTPUT_SEC=20
# 実行中に logs/<label>.log を外向きの symlink にされても、見張りの追記は外へ届かず、子の後の確認で止まる（EXIT:5）
setup log_link_idle; run 5; unchanged; outside_unchanged '見張りの追記が symlink を辿った'
# 依存の導入先（packages/ など）が worktree の外を指す symlink なら、外で npm ci を動かさずに止める
setup deps_outside
export GEM_TEST_DEPS="$T/deps_outside-deps"
mkdir -p "$T/deps_outside-pkgs/lib"; print -r -- '{}' > "$T/deps_outside-pkgs/lib/package-lock.json"
ln -s "$T/deps_outside-pkgs" "$repo/packages"
git -C "$repo" add --all; git -C "$repo" commit -qm 'test: 外向きの packages'; before="$(git -C "$repo" rev-parse HEAD)"
run 2; unchanged
[[ ! -e "$GEM_TEST_DEPS" ]] || { cat "$GEM_TEST_DEPS" >&2; fail '外向きの packages/ で依存の導入を動かした'; }
grep -q '依存の導入先が worktree の外' "$T/deps_outside.log" || fail '止めた理由が出ていない'
unset GEM_TEST_DEPS
print -r -- "PASS: $count 件 / EXIT:0"
