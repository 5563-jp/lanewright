#!/bin/zsh -f
# QA の内容比較とマージ後の対象固定を、本物のモデルや GitHub を使わず検証する。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
SOURCE_DIR="${0:A:h:h}"
T="$(mktemp -d "${LANES_SCRATCH:-$TMPDIR}/cleanup-qa.XXXXXX")"
export LANES_SCRATCH_ROOT="$T/scratch" LANES_ARCHIVE_ROOT="$T/archive" LANES_NOTIFY=0
export TEST_DOWNLOADS="$T/downloads" QA_FAKE_BIN="$T/bin/claude" TEST_RECEIPT="$T/receipt.json"
mkdir -p "$T/lanes/templates" "$T/bin"
cp "$SOURCE_DIR"/{_common.sh,lanes.env,lanes-roles.sh,review-dedup.zsh,run-qa.sh,after-develop-merge.sh,cleanup-after-merge.sh,detach-run.sh} "$T/lanes/"
cp "$SOURCE_DIR/templates/qa-bot.md" "$T/lanes/templates/"
cat >> "$T/lanes/_common.sh" <<'MOCK'
lanes_check_claude_subscription() { CLAUDE_BIN="$QA_FAKE_BIN"; }
MOCK
python3 - "$T/lanes/cleanup-after-merge.sh" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace('local dl="$HOME/Downloads"', 'local dl="$TEST_DOWNLOADS"')
    .replace('set -euo pipefail', 'set -euo pipefail\nif [[ -n "${TEST_QA_MUTATION:-}" ]]; then print changed > "$TEST_QA_MUTATION"; fi', 1))
PY
cat > "$QA_FAKE_BIN" <<'MOCK'
#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
prompt=sys.stdin.read()
action=os.environ.get("FAKE_ACTION", "clean")
if action=="edit": pathlib.Path("a").write_text("changed during QA\n")
if action=="new": pathlib.Path("new-file").write_text("new\n")
if action=="index": subprocess.run(["git","add","a"],check=True)
if action=="head": subprocess.run(["git","commit","--allow-empty","-qm","test: QA 中の履歴変更"],check=True)
if action=="chmod": pathlib.Path("a").chmod(0o755)
if action=="tracked_log": pathlib.Path("logs/tracked.txt").write_text("changed\n")
if action=="branch": subprocess.run(["git","checkout","-qb","qa-changed"],check=True)
if action=="ignored": pathlib.Path("local-data/manual-notes.txt").write_text("changed\n")
if action=="delete": pathlib.Path("a").unlink()
if action=="config": subprocess.run(["git","config","core.hooksPath","/dev/null"],check=True)
if action=="hook": pathlib.Path(".git/hooks/post-checkout").write_text("#!/bin/sh\n")
if action=="tag": subprocess.run(["git","tag","qa-tag"],check=True)
pathlib.Path(os.environ["TEST_RECEIPT"]).write_text(json.dumps({"cwd":os.getcwd(),"head":subprocess.check_output(["git","rev-parse","HEAD"]).decode().strip(),"prompt":prompt}))
print(json.dumps({"type":"result","is_error":False,"result":"VERDICT: CLEAN"}))
MOCK
cat > "$T/bin/gh" <<'MOCK'
#!/usr/bin/env python3
import json,os,sys
h,m,b,base=(os.environ.get(x,"") for x in ("FAKE_HEAD_A","FAKE_MERGE_A","FAKE_MERGE_B","FAKE_BASE_A"))
if sys.argv[1]=="api":
    data=[] if os.environ.get("FAKE_API_EMPTY")=="1" else [
        {"number":22,"title":"B","html_url":"https://example.invalid/22","merged_at":"yes","base":{"ref":"develop"},"head":{"sha":b},"merge_commit_sha":b},
        {"number":11,"title":"A","html_url":"https://example.invalid/11","merged_at":"yes","base":{"ref":"develop"},"head":{"sha":h},"merge_commit_sha":m}]
    for pr in data: pr["base"]["sha"]=base if pr["number"]==11 else ""
else:
    data=[{"number":22,"title":"B","url":"https://example.invalid/22","headRefOid":b,"mergeCommit":{"oid":b}},
          {"number":11,"title":"A","url":"https://example.invalid/11","headRefOid":h,"mergeCommit":{"oid":m},"baseRefOid":base}]
print(json.dumps(data))
MOCK
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
count=0; sleeper=""
finish() { if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; cd /; rm -rf "$T"; }
trap finish EXIT
fail() { print -u2 -- "FAIL: $*"; cat "$T/out"; exit 1; }
ok() { count=$((count+1)); print -- "ok $count $*"; }
init_repo() {
  git init -q -b develop "$1"; lanes_test_assert_repo "$1"
  git -C "$1" config user.name you; git -C "$1" config user.email you@example.com
  print a > "$1/a"; mkdir -p "$1/logs"; print tracked > "$1/logs/tracked.txt"
  git -C "$1" add .; git -C "$1" commit -qm 'test: 初期化'
}
print -- 'QA fixture' > "$T/prompt.md"
for action in clean edit new index head chmod tracked_log branch delete ignored config hook tag; do
  repo="$T/qa-$action"; init_repo "$repo"
  # 既存の M を開始時に作り、同じ M のまま内容だけ変わるケースを含める。
  if [[ "$action" == edit || "$action" == index ]]; then print before > "$repo/a"; fi
  if [[ "$action" == ignored ]]; then
    print 'local-data/' > "$repo/.gitignore"; mkdir -p "$repo/local-data"; print before > "$repo/local-data/manual-notes.txt"
  fi
  rc=0
  FAKE_ACTION="$action" zsh "$T/lanes/run-qa.sh" "$repo" "$T/prompt.md" qa > "$T/out" 2>&1 || rc=$?
  if [[ "$action" == clean ]]; then
    [[ "$rc" == 0 ]] && grep -q 'VERDICT: CLEAN' "$repo/logs/qa.done" || fail '正常 QA'
    grep -q "$LANES_SCRATCH_ROOT/qa-clean/qa" "$repo/logs/qa.prompt.md" || fail 'scratch 指示が無い'
  else
    [[ "$rc" == 4 ]] && grep -q 'VERDICT: NEEDS_FIX' "$repo/logs/qa.done" || fail "変化を合格にした: $action"
    case "$action" in
      config|hook|tag) grep -q '変更: git の管理フォルダ' "$repo/logs/qa.evidence.md" || fail "git 管理フォルダの変化を証跡に出さない: $action" ;;
    esac
  fi
  ok "QA 前後の比較: $action"
done

new_merge_case() {
  case_root="$T/$1"; repo="$case_root/repo"; wt="$case_root/feature"
  init_repo "$repo"
  # 本体のログは未追跡だけにする。このケースではソース一式の完全一致を確認する。
  git -C "$repo" rm -q logs/tracked.txt; print 'logs/' > "$repo/.gitignore"
  git -C "$repo" add .gitignore; git -C "$repo" commit -qm 'test: ログ除外'
  git init -q --bare "$case_root/origin.git"; git -C "$repo" remote add origin "$case_root/origin.git"
  git -C "$repo" checkout -qb feature-a; print A > "$repo/a.txt"; git -C "$repo" add a.txt; git -C "$repo" commit -qm 'test: A'
  export FAKE_HEAD_A="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q develop; git -C "$repo" merge -q --no-ff feature-a -m 'test: A の取り込み'
  export FAKE_MERGE_A="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -qb feature-b; print B > "$repo/b.txt"; git -C "$repo" add b.txt; git -C "$repo" commit -qm 'test: B'
  git -C "$repo" checkout -q develop; git -C "$repo" merge -q --no-ff feature-b -m 'test: B の取り込み'
  export FAKE_MERGE_B="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" push -q origin develop feature-a
  git -C "$repo" worktree add -q "$wt" feature-a
  cd "$T"
}
run_after() { env -u LANES_DETACH_QA zsh "$T/lanes/after-develop-merge.sh" "$wt" --repo fixture/repo --apply "$@" > "$T/out" 2>&1; }
new_merge_case ahead
print local > "$repo/local.txt"; git -C "$repo" add local.txt; git -C "$repo" commit -qm 'test: 未送信'
local_head="$(git -C "$repo" rev-parse HEAD)"; print dirty > "$repo/a"
run_after --label ahead || fail '先行/未保存のある本体から QA を開始できない'
python3 - "$TEST_RECEIPT" "$FAKE_MERGE_A" <<'PY' || fail '対象 A ではなく B/本体を検証した'
import json,pathlib,sys
r=json.load(open(sys.argv[1])); assert r['head']==sys.argv[2]
p=pathlib.Path(r['cwd']); assert (p/'a.txt').exists() and not (p/'b.txt').exists() and not (p/'local.txt').exists()
assert '#11' in r['prompt'] and '#22' not in r['prompt']
assert '`a.txt`' in r['prompt'] and '`b.txt`' not in r['prompt']
PY
[[ "$(git -C "$repo" rev-parse HEAD)" == "$local_head" && "$(cat "$repo/a")" == dirty ]] || fail '本体の変更を壊した'
ok '本体の先行履歴/未保存変更を保全し、後続 B から独立して A を QA'

new_merge_case fallback
FAKE_API_EMPTY=1 run_after --label fallback || fail 'PR 予備検索に失敗'
grep -q 'PR: 11' "$T/out" || fail 'Python への検索値の引き渡しに失敗'
ok '予備検索に固定した対象を渡す'

# QA の切り離しは設定キー LANES_DETACH_QA=1 のときだけ。私的な名前の環境変数（CURSOR_AGENT など）では切り離さない
new_merge_case nodetach
rm -f "$TEST_RECEIPT"
CURSOR_AGENT=1 SAND_AGENT=1 run_after --label nodetach || fail '切り離さない QA が失敗'
! grep -q 'QA 起動要求 pid=' "$T/out" && [[ -f "$TEST_RECEIPT" ]] || fail 'LANES_DETACH_QA なしで QA を切り離した'
ok 'LANES_DETACH_QA が無ければ、ほかの環境変数があっても QA へそのまま exec する'

new_merge_case detach
rm -f "$TEST_RECEIPT"
LANES_DETACH_QA=1 zsh "$T/lanes/after-develop-merge.sh" "$wt" --repo fixture/repo --apply --label detach > "$T/out" 2>&1 || fail '切り離した QA の起動に失敗'
grep -q 'QA 起動要求 pid=' "$T/out" || fail 'LANES_DETACH_QA=1 で QA を切り離さない'
qa_wt="$(sed -n 's/^== run-qa.sh: \(.*\) \/ detach ==$/\1/p' "$T/out")"
[[ -n "$qa_wt" ]] || fail 'QA の作業場所が出ない'
for _ in {1..100}; do [[ -f "$qa_wt/logs/detach.done" ]] && break; sleep 0.2; done
grep -q 'VERDICT: CLEAN' "$qa_wt/logs/detach.done" 2>/dev/null && [[ -f "$TEST_RECEIPT" ]] || fail '切り離した QA が終わらない'
ok 'LANES_DETACH_QA=1 なら QA を detach-run.sh で切り離して起動する'

new_merge_case baddetach
rc=0; LANES_DETACH_QA=yes zsh "$T/lanes/after-develop-merge.sh" "$wt" --repo fixture/repo --apply --label baddetach > "$T/out" 2>&1 || rc=$?
(( rc == 2 )) && grep -q 'LANES_DETACH_QA' "$T/out" && [[ -d "$wt" ]] || fail "LANES_DETACH_QA の不正な値で止まらない（rc=$rc）"
ok 'LANES_DETACH_QA が 0 / 1 でなければ何もせずに止める'

new_merge_case prompt
mkdir -p "$wt/prompts"; print 'CUSTOM-QA-PROMPT' > "$wt/prompts/case.md"
cd "$case_root"
run_after --label prompt --qa-prompt feature/prompts/case.md || fail '相対指示書を退避できない'
[[ ! -d "$wt" ]] || fail 'feature が消えていない'
python3 - "$TEST_RECEIPT" <<'PY' || fail '削除後に指示書が届かない'
import json,sys
assert 'CUSTOM-QA-PROMPT' in json.load(open(sys.argv[1]))['prompt']
PY
ok 'feature 内の相対指示書を削除前に退避'

new_merge_case missing
# 実装・レビューのレーンが使った scratch が残った状態で worktree が消えた（通常の経路）。
lane_scratch="$LANES_SCRATCH_ROOT/repo/impl-missing"
mkdir -p "$lane_scratch"; printf 'worktree=%s\nlabel=impl-missing\n' "$wt" > "$lane_scratch/.lane"; print keep > "$lane_scratch/note.txt"
git -C "$repo" worktree remove "$wt"
run_after --label missing --main-checkout "$repo" --feature-head "$FAKE_HEAD_A" || fail '削除済み feature（scratch 残り）から QA へ進めない'
python3 - "$TEST_RECEIPT" "$FAKE_MERGE_A" <<'PY' || fail '削除済み feature の対象が異なる'
import json,sys
assert json.load(open(sys.argv[1]))['head']==sys.argv[2]
PY
[[ -f "$lane_scratch/note.txt" ]] || fail '現世代を確認できない scratch を削除した'
grep -qF "$lane_scratch" "$T/out" && grep -q 'rm -rf' "$T/out" || fail '保全した scratch と手動削除の手順を出さない'
ok '削除済み feature は scratch を保全したまま本体と固定 HEAD で QA 続行'
rc=0; (cd "$T" && zsh "$T/lanes/cleanup-after-merge.sh" "$wt" --apply > "$T/out" 2>&1) || rc=$?
[[ "$rc" == 8 && -f "$lane_scratch/note.txt" ]] || fail "単体の後片付けが保全を終了コード 8 で知らせない（rc=$rc）"
ok '単体の後片付けは scratch 保全を終了コード 8 で返す'
rm -rf -- "$lane_scratch"

# fast-forward で取り込まれた feature（2 commit）。変更ファイルは先端 1 commit 分ではなく全体を出す。
new_ff_case() {
  case_root="$T/$1"; repo="$case_root/repo"; wt="$case_root/feature"
  init_repo "$repo"
  git -C "$repo" rm -q logs/tracked.txt; print 'logs/' > "$repo/.gitignore"
  git -C "$repo" add .gitignore; git -C "$repo" commit -qm 'test: ログ除外'
  git init -q --bare "$case_root/origin.git"; git -C "$repo" remote add origin "$case_root/origin.git"
  git -C "$repo" push -q origin develop
  export FAKE_BASE_A="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -qb feature-a
  print 1 > "$repo/ff-1.txt"; git -C "$repo" add ff-1.txt; git -C "$repo" commit -qm 'test: FF 1'
  print 2 > "$repo/ff-2.txt"; git -C "$repo" add ff-2.txt; git -C "$repo" commit -qm 'test: FF 2'
  export FAKE_HEAD_A="$(git -C "$repo" rev-parse HEAD)" FAKE_MERGE_A="$(git -C "$repo" rev-parse HEAD)" FAKE_MERGE_B="$(printf '0%.0s' {1..40})"
  git -C "$repo" checkout -q develop; git -C "$repo" merge -q --ff-only feature-a
  git -C "$repo" push -q origin develop feature-a
  git -C "$repo" worktree add -q "$wt" feature-a
  cd "$T"
}
check_ff_files() {
  python3 - "$TEST_RECEIPT" "$FAKE_HEAD_A" <<'PY_FF' || fail "fast-forward の変更ファイルが一部だけ: $1"
import json,sys
r=json.load(open(sys.argv[1])); assert r['head']==sys.argv[2]
assert '`ff-1.txt`' in r['prompt'] and '`ff-2.txt`' in r['prompt'], r['prompt']
PY_FF
}
new_ff_case ff_pr
run_after --label ff-pr || fail 'fast-forward（PR 基点あり）の QA に失敗'
check_ff_files 'PR 基点'
ok 'fast-forward は PR の基点から取り込み全体の変更ファイルを出す'
new_ff_case ff_reflog
FAKE_BASE_A="" run_after --label ff-reflog || fail 'fast-forward（PR 基点なし）の QA に失敗'
check_ff_files '更新記録'
ok 'fast-forward は PR 基点が無くても手元の更新記録から取り込み全体を出す'

new_merge_case retry
sleep 600 & sleeper=$!
started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$sleeper" | sed 's/^ *//; s/ *$//')"
mkdir -p "$wt/logs"
printf 'pid=%s\nlstart=%s\n' "$sleeper" "$started" > "$wt/logs/live.pid"
rc=0; run_after --label retry || rc=$?
[[ "$rc" == 7 && -d "$wt" && ! -e "$LANES_SCRATCH_ROOT/repo/retry-checkout" ]] || fail '後片付け失敗後に未起動 QA が残る'
[[ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" == 2 ]] || fail 'QA の登録が残る'
ok '稼働中レーンでの後片付け失敗は未起動 QA と登録だけを撤去'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
run_after --label retry || fail '停止後に同じ QA を再実行できない'
[[ -f "$LANES_SCRATCH_ROOT/repo/retry-checkout/logs/retry.done" ]] || fail '再試行で QA が完了しない'
ok '原因解消後は同じ label で QA を完了できる'

new_merge_case preserve
sleep 600 & sleeper=$!
started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$sleeper" | sed 's/^ *//; s/ *$//')"
mkdir -p "$wt/logs"
printf 'pid=%s\nlstart=%s\n' "$sleeper" "$started" > "$wt/logs/live.pid"
qa_target="$LANES_SCRATCH_ROOT/repo/preserve-checkout"
rc=0; TEST_QA_MUTATION="$qa_target/logs/other-lane.pid" run_after --label preserve || rc=$?
[[ "$rc" == 7 && -f "$qa_target/logs/other-lane.pid" && -f "$qa_target/logs/qa-case.md" ]] || fail '別処理が触った QA を撤去した'
ok '後片付け中に別処理が触った QA は無視対象の追加物も保全'
rc=0; run_after --label preserve || rc=$?
[[ "$rc" == 2 && -f "$qa_target/logs/other-lane.pid" ]] || fail '既存 QA を上書きした'
ok '既存 QA の無条件な上書き・撤去を拒否'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""

# QA 専用 worktree の準備: 本体の .env 系を複製して一致確認、依存はロックファイルから入れ直す。
# 終わった QA worktree は次回の after-develop-merge で後片付けへ流す。
new_merge_case prepared
# 依存のロックファイルを持つ feature を develop へ取り込み、その取り込みを QA 対象にする。
merged_feature() {   # <枝> <ファイル> → wt / FAKE_HEAD_A / FAKE_MERGE_A
  git -C "$repo" checkout -q -b "$1" develop; print "$1" > "$repo/$2"; git -C "$repo" add "$2"; git -C "$repo" commit -qm "test: $1"
  export FAKE_HEAD_A="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q develop; git -C "$repo" merge -q --no-ff "$1" -m "test: $1 の取り込み"
  export FAKE_MERGE_A="$(git -C "$repo" rev-parse HEAD)"; git -C "$repo" push -q origin develop "$1"
  wt="$case_root/$1"; git -C "$repo" worktree add -q "$wt" "$1"
}
git -C "$repo" worktree remove "$wt"
print 'logs/\nnode_modules/\n.env*' > "$repo/.gitignore"
mkdir -p "$repo/apps/web"; print '{}' > "$repo/package-lock.json"; print '{}' > "$repo/apps/web/package-lock.json"
git -C "$repo" add .gitignore package-lock.json apps/web/package-lock.json; git -C "$repo" commit -qm 'test: 依存のロックファイル'
merged_feature feature-c c.txt
print 'TEST_ONLY_VALUE=1' > "$repo/.env.local"; print 'TEST_ONLY_WEB=1' > "$repo/apps/web/.env"
print 'TEST_ONLY_SENTRY=1' > "$repo/.env.sentry-build-plugin"
cat > "$T/bin/npm" <<'MOCK'
#!/bin/zsh -f
# npm ci の模擬: 実行場所を記録し、依存の目印だけ作る。
[[ "$1" == ci ]] || exit 9
[[ -z "${FAKE_NPM_FAIL:-}" ]] || { print 'npm ci の模擬失敗'; exit 1; }
print -r -- "$PWD" >> "$TEST_NPM_LOG"; mkdir -p node_modules/.bin; print dep > node_modules/marker
MOCK
chmod +x "$T/bin/npm"; export TEST_NPM_LOG="$T/npm.log"; : > "$TEST_NPM_LOG"
FAKE_NPM_FAIL=1 run_after --label prep-fail && fail '依存の用意に失敗しても進んだ'
[[ -d "$wt" && -d "$LANES_SCRATCH_ROOT/repo/prep-fail-checkout" ]] || fail '依存の失敗で feature を消した／調査用の QA を残さない'
grep -q 'worktree remove --force' "$T/out" || fail '依存の失敗で撤去手順を出さない'
git -C "$repo" worktree remove --force "$LANES_SCRATCH_ROOT/repo/prep-fail-checkout"
ok '依存の用意に失敗したら feature を残して停止し、撤去手順を出す'
: > "$TEST_NPM_LOG"
run_after --label prep1 || fail '準備付きの QA を完了できない'
qa1="$LANES_SCRATCH_ROOT/repo/prep1-checkout"
cmp -s "$repo/.env.local" "$qa1/.env.local" && cmp -s "$repo/apps/web/.env" "$qa1/apps/web/.env" || fail '.env 系を本体と同一に複製しない'
[[ ! -e "$qa1/.env.sentry-build-plugin" ]] || fail 'ソースマップ送信用の鍵を QA に複製した'
! grep -q 'TEST_ONLY_' "$T/out" || fail '.env の中身を出力した'
[[ -f "$qa1/node_modules/marker" && -f "$qa1/apps/web/node_modules/marker" && ! -e "$repo/node_modules" ]] || fail '依存を QA worktree の中に用意しない'
# macOS の /tmp は /private/tmp へのリンクなので、記録側も実体のパスへ直してから比べる
npm_dirs=("${(@f)$(cat "$TEST_NPM_LOG")}"); npm_dirs=("${^npm_dirs[@]:A}")
[[ "$(print -l "${npm_dirs[@]}" | sort)" == "$(print -l "${qa1:A}" "${qa1:A}/apps/web" | sort)" ]] || fail "npm ci の実行場所が違う: $(cat "$TEST_NPM_LOG")"
[[ -f "$qa1/logs/prep1.done" ]] && grep -q 'EXIT:0' "$qa1/logs/prep1.done" || fail '準備付き QA が完了しない'
ok 'QA worktree に .env 系を一致確認つきで複製し、依存をロックファイルから入れて QA 完了'
# 2 本目のマージ（feature-b）の QA で、終わった 1 本目を後片付けへ流す。稼働中に見える QA は残す。
busy="$LANES_SCRATCH_ROOT/repo/busy-checkout"
git -C "$repo" worktree add -q --detach "$busy" "$FAKE_MERGE_A"; mkdir -p "$busy/logs"; print 'pid=0' > "$busy/logs/busy.pid"
merged_feature feature-d d.txt
run_after --label prep2 || fail '2 本目の QA に失敗'
[[ ! -e "$qa1" ]] || fail '終わった QA worktree を片付けない'
! grep -qF -- "$qa1" <<< "$(git -C "$repo" worktree list --porcelain)" || fail '終わった QA worktree の登録が残る'
[[ -n "$(print -l "$LANES_ARCHIVE_ROOT"/repo/*detached-prep1-checkout*/logs/prep1.done(N))" ]] || fail '片付けた QA のログを退避しない'
[[ -z "$(print -l "$LANES_ARCHIVE_ROOT"/repo/**/.env*(DN))" ]] || fail '.env 系を退避先へ写した'
[[ -d "$busy" ]] || fail '.done の無い QA worktree を片付けた'
[[ -f "$LANES_SCRATCH_ROOT/repo/prep2-checkout/logs/prep2.done" ]] || fail '2 本目の QA が完了しない'
ok '次の QA の開始時に終わった QA worktree を後片付けへ流し、未完了のものは残す'
git -C "$repo" worktree remove --force "$busy"

# 固定した QA 履歴の親リンクが、本体と違う場所へ向いていても設定を領域外へ複製しない。
for kind in absolute relative nested dangling loop internal; do
  new_merge_case "env-link-$kind"
  git -C "$repo" worktree remove "$wt"
  qa_target="$LANES_SCRATCH_ROOT/repo/env-$kind-checkout"
  outside="${qa_target}-outside"; mkdir -p "$outside"
  case "$kind" in
    absolute) target="$outside" ;;
    relative) target="../${outside:t}" ;;
    nested) target="$outside"; mkdir -p "$repo/config" ;;
    dangling) target="$outside/missing" ;;
    loop) target=config ;;
    internal) target=safe; mkdir -p "$repo/safe"; print keep > "$repo/safe/keep" ;;
  esac
  env_parent=config
  [[ "$kind" != nested ]] || env_parent=config/deep
  ln -s "$target" "$repo/$env_parent"
  git -C "$repo" add config
  [[ "$kind" != internal ]] || git -C "$repo" add safe
  git -C "$repo" commit -qm 'test: QA 履歴の親リンク'
  merged_feature "env-$kind-feature" "env-$kind.txt"
  rm "$repo/$env_parent"; mkdir -p "$repo/$env_parent"; print keep > "$repo/$env_parent/keep"
  git -C "$repo" add config; git -C "$repo" commit -qm 'test: 本体側の親を通常ディレクトリに変更'
  : > "$repo/$env_parent/.env.local"
  rm -f "$TEST_RECEIPT"
  rc=0; run_after --no-deps --label "env-$kind" || rc=$?
  if [[ "$kind" == internal ]]; then
    [[ "$rc" == 0 && -f "$qa_target/safe/.env.local" && -f "$TEST_RECEIPT" ]] || fail 'QA 内で完結する親リンクを拒否した'
    ok 'QA 内で完結する親リンクでは設定を複製できる'
  else
    [[ "$rc" != 0 && -d "$wt" && ! -f "$TEST_RECEIPT" ]] || fail "危険な親リンクで QA へ進んだ: $kind"
    [[ -z "$(print -l "$outside"/**/.env*(DN))" ]] || fail "QA 領域外へ設定を複製した: $kind"
    ok "親リンクを解決できない／QA 領域外なら複製前に停止: $kind"
  fi
done

# 指示書と依存の準備も、同じ親リンクの境界確認を通す。
for kind in logs dependency dependency-return; do
  new_merge_case "prepare-link-$kind"
  git -C "$repo" worktree remove "$wt"
  outside="$case_root/outside"; mkdir -p "$outside"
  if [[ "$kind" == logs ]]; then
    rm -rf "$repo/logs"; ln -s "$outside" "$repo/logs"; git -C "$repo" add -f logs
  else
    mkdir -p "$outside/web"; print '{}' > "$outside/web/package-lock.json"
    ln -s "$outside" "$repo/apps"; git -C "$repo" add apps
    if [[ "$kind" == dependency-return ]]; then
      ln -s "$LANES_SCRATCH_ROOT/repo/prepare-$kind-checkout/node_modules" "$outside/web/node_modules"
    fi
  fi
  git -C "$repo" commit -qm 'test: 準備先の親リンク'
  merged_feature "prepare-$kind-feature" "prepare-$kind.txt"
  : > "$TEST_NPM_LOG"; rm -f "$TEST_RECEIPT"
  rc=0; run_after --label "prepare-$kind" --qa-prompt "$T/prompt.md" || rc=$?
  [[ "$rc" != 0 && -d "$wt" && ! -f "$TEST_RECEIPT" ]] || fail "準備先リンクで QA へ進んだ: $kind"
  [[ ! -e "$outside/qa-case.md" && ! -e "$outside/web/node_modules" && ! -s "$TEST_NPM_LOG" ]] || fail "準備先の領域外を書き換えた: $kind"
  ok "指示書／依存の準備先が QA 領域外なら停止: $kind"
done

new_merge_case long_history
# 履歴が大きい場合の早期 grep 終了による SIGPIPE を再現する（実コミットの大量生成は不要）。
git -C "$repo" worktree remove "$wt"
git -C "$repo" worktree add -q --detach "$wt" "$FAKE_MERGE_B"
export TEST_LONG_HEAD="$FAKE_MERGE_B" REAL_GIT="$(command -v git)"
cat > "$T/bin/git" <<'MOCK'
#!/bin/zsh -f
if [[ "$*" == *"rev-list --first-parent $TEST_LONG_HEAD" ]]; then
  python3 -c 'import sys; print(sys.argv[1]); print("a" * 40 + "\n", end=""); print(("b" * 40 + "\n") * 10000, end="")' "$TEST_LONG_HEAD"
else exec "$REAL_GIT" "$@"; fi
MOCK
chmod +x "$T/bin/git"
run_after --label long-history || fail '長い履歴の先頭一致で誤停止'
python3 - "$TEST_RECEIPT" "$TEST_LONG_HEAD" <<'PY_LONG' || fail '長い履歴の対象が違う'
import json,sys
assert json.load(open(sys.argv[1]))['head']==sys.argv[2]
PY_LONG
ok '長い履歴でも pipefail で一致を取りこぼさない'
print -- "PASS: $count 件"
