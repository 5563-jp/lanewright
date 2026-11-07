#!/bin/zsh -f
# 役割の割り振り（lanes-roles.sh）と、構成に合わせたランチャの停止・入口（run-impl.sh / run-review.sh）の振り分けのテスト。
# 本物の CLI は使わない。一時 HOME と偽の CLI（tests/stubs）だけで、全データを一時領域に置く。
# この中で 4 構成をすべて試すので、呼び出し元の LANES_TOOLS には左右されない。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-roles.XXXXXX")"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H/.gemini/antigravity-cli"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない（LANES_ で始まる変数・CLI のパス・モデル指定を外す）
for v in ${(k)parameters[(I)LANES_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN CLAUDE_MODEL CODEX_MODEL GEMINI_MODEL CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT XDG_CONFIG_HOME XDG_STATE_HOME \
    CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$T/no-such.conf" LANES_NOTIFY=0
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex" GEMINI_BIN="$STUBS/agy" STUB_LOG="$T/stub.jsonl"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }
roles() { zsh -f "$LANES_DIR/lanes-roles.sh" "$@"; }

# ---- 1. 4 構成の割り振り ----
typeset -A expect
expect=(
  "claude codex gemini" 'full|claude gemini|codex|1'
  "claude codex"        'claude-codex|claude|codex|1'
  "claude gemini"       'claude-gemini|claude gemini|claude|0'
  "claude"              'claude-only|claude|claude|0'
  "gemini codex claude" 'full|claude gemini|codex|1'
  "claude,codex"        'claude-codex|claude|codex|1'
  "claude claude"       'claude-only|claude|claude|0'
)
for tools in "${(@k)expect}"; do
  out="$(LANES_TOOLS="$tools" roles --env)" || fail "割り振りが失敗: $tools"
  got="$(print -r -- "$out" | python3 -c '
import sys
d = dict(l.split("=", 1) for l in sys.stdin.read().splitlines())
print("|".join([d["LANES_PROFILE"], d["LANES_ROLE_IMPL"].strip("\""), d["LANES_ROLE_REVIEW"], d["LANES_REVIEW_INDEPENDENT"]]))')"
  [[ "$got" == "${expect[$tools]}" ]] || fail "割り振り [$tools] expected=${expect[$tools]} got=$got"
  pass "割り振り [$tools] → $got"
done
# 既定（何も指定しない）は claude-only
[[ "${${(f)"$(roles --env)"}[1]}" == LANES_PROFILE=claude-only ]] || fail "既定が claude-only でない"
pass "既定の構成は claude-only"

# ---- 2. --print の注意（③④ だけ独立性が弱いと出す）----
for tools in "claude codex gemini" "claude codex"; do
  out="$(LANES_TOOLS="$tools" roles --print)"
  [[ "$out" != *"独立性が弱い"* && "$out" == *"レビューの独立性: あり"* ]] || fail "--print [$tools] に独立性の注意が出た"
  pass "--print [$tools] は独立性あり"
done
for tools in "claude gemini" "claude"; do
  out="$(LANES_TOOLS="$tools" roles --print)"
  [[ "$out" == *"レビューが実装と同じ系統の道具なので独立性が弱い"* || "$out" == *"同じ系統の道具（Claude）なので独立性が弱い"* ]] || fail "--print [$tools] に独立性の注意が無い"
  [[ "$out" == *"run-claude-review.sh"* ]] || fail "--print [$tools] がレビューの入口を示さない"
  pass "--print [$tools] は独立性が弱いと注意する"
done

# ---- 3. 誤った構成は exit 2 ----
for tools in "codex" "gemini codex" "claude foo" "claude cursor" ; do
  rc=0; LANES_TOOLS="$tools" roles --print > "$T/err.out" 2>&1 || rc=$?
  (( rc == 2 )) || fail "誤った構成 [$tools] で exit 2 にならない（$rc）"
  grep -q 'ERROR' "$T/err.out" || fail "誤った構成 [$tools] に理由が無い"
  pass "誤った構成 [$tools] は exit 2"
done
rc=0; roles --bogus >/dev/null 2>&1 || rc=$?; (( rc == 2 )) || fail "不明なオプションで exit 2 にならない"
pass "不明なオプションは exit 2"

# ---- 4. 設定ファイル（環境変数 > 設定ファイル > 既定）----
conf="$T/lanes.conf"
print -r -- 'LANES_TOOLS="${LANES_TOOLS:-claude codex}"' > "$conf"
[[ "${${(f)"$(LANES_CONF="$conf" roles --env)"}[1]}" == LANES_PROFILE=claude-codex ]] || fail "設定ファイルの LANES_TOOLS が効かない"
pass "設定ファイルの LANES_TOOLS が既定に勝つ"
[[ "${${(f)"$(LANES_CONF="$conf" LANES_TOOLS=claude roles --env)"}[1]}" == LANES_PROFILE=claude-only ]] || fail "環境変数が設定ファイルに勝たない"
pass "環境変数が設定ファイルに勝つ"
print -r -- 'LANES_BASE_BRANCH="${LANES_BASE_BRANCH:-trunk}"' > "$T/base.conf"
got="$(env -u LANES_SCRATCH_ROOT LANES_CONF="$T/base.conf" zsh -fc 'source "$1/lanes.env"; print -r -- "$LANES_BASE_BRANCH|$LANES_RUNS_ROOT|$LANES_ARCHIVE_ROOT|$LANES_SCRATCH_ROOT|$CLAUDE_MODEL|$CLAUDE_EFFORT"' _ "$LANES_DIR")"
[[ "$got" == "trunk|$H/dev/_runs|$H/dev/_runs|$H/dev/_runs/_scratch||xhigh" ]] || fail "lanes.env の既定が docs/config.md と違う: $got"
pass "lanes.env の既定（置き場所・空のモデル・effort）が docs/config.md どおり"

# ---- 5. 構成に無い道具のランチャは exit 2 で止まり .done を残す ----
base="$T/base"; wt="$T/wt"
git init -q -b main "$base"; lanes_test_assert_repo "$base"
git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit --allow-empty -qm 'test: 初期化'
git -C "$base" worktree add -q -b feat/test "$wt"
git -C "$wt" update-ref refs/remotes/origin/develop HEAD
print -r -- '担当の修正だけを行う。' > "$T/prompt.md"
n=0
launch() {   # <期待 rc> <構成> <ランチャ> [引数...]
  local want="$1" tools="$2" name="$3"; shift 3
  n=$(( n + 1 )); local label="l$n" rc=0
  : > "$STUB_LOG"
  LANES_TOOLS="$tools" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@" > "$T/$label.out" 2>&1 || rc=$?
  (( rc == want )) || { cat "$T/$label.out" >&2; fail "$name [$tools] expected=$want got=$rc"; }
  LAST_LABEL="$label"
}
for spec in "run-codex.sh|codex" "run-codex-review.sh|codex" "run-gemini.sh|gemini"; do
  name="${spec%%|*}"; tool="${spec##*|}"
  for tools in "claude" "claude codex" "claude gemini"; do
    [[ " $tools " == *" $tool "* ]] && continue
    extra=(); [[ "$name" == run-gemini.sh ]] && extra=(--verify true --allow-path owned.txt --no-push)
    launch 2 "$tools" "$name" "${extra[@]}"
    grep -q 'この構成では使えない' "$T/$LAST_LABEL.out" || fail "$name [$tools] が理由を出さない"
    grep -q 'run-impl.sh' "$T/$LAST_LABEL.out" && grep -q 'run-review.sh' "$T/$LAST_LABEL.out" || fail "$name [$tools] が代わりの入口を出さない"
    grep -q '^EXIT:2$' "$wt/logs/$LAST_LABEL.done" || fail "$name [$tools] が .done（EXIT:2）を残さない"
    [[ ! -s "$STUB_LOG" ]] || fail "$name [$tools] が CLI を呼んだ"
    pass "$name は [$tools] で exit 2・.done あり・CLI 未呼び出し"
  done
done
# claude 抜きの構成では Claude のランチャも止まる（構成そのものが誤り）
launch 2 "codex" run-claude.sh
grep -q 'claude が無い' "$T/$LAST_LABEL.out" || fail "claude 抜きで理由を出さない"
pass "claude 抜きの構成では run-claude.sh も exit 2"
# QA ランチャも同じ点検を通す（誤った構成で Claude を起動しない）
for tools in "codex" "claude foo"; do
  launch 2 "$tools" run-qa.sh
  grep -q '^EXIT:2$' "$wt/logs/$LAST_LABEL.done" || fail "run-qa.sh [$tools] が .done（EXIT:2）を残さない"
  [[ ! -s "$STUB_LOG" ]] || fail "run-qa.sh [$tools] が CLI を呼んだ（認証確認より前に止まっていない）"
  pass "run-qa.sh は誤った構成 [$tools] で exit 2・.done あり・CLI 未呼び出し"
done

# ---- 6. モデル・effort が空なら付けない ----
launch 0 "claude" run-claude.sh
python3 - "$STUB_LOG" <<'PY' || fail "空のモデル指定で --model を付けた / effort が消えた"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if "-p" in c["args"]][0]
assert "--model" not in run and run[run.index("--effort") + 1] == "xhigh", run
PY
pass "CLAUDE_MODEL が空なら --model を付けない（effort は既定 xhigh）"
CLAUDE_MODEL=my-model CLAUDE_EFFORT= launch 0 "claude" run-claude.sh
python3 - "$STUB_LOG" <<'PY' || fail "モデル指定が渡らない / 空の effort を付けた"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if "-p" in c["args"]][0]
assert run[run.index("--model") + 1] == "my-model" and "--effort" not in run, run
PY
pass "CLAUDE_MODEL を渡し、空の CLAUDE_EFFORT は付けない"
launch 0 "claude codex" run-codex-review.sh
python3 - "$STUB_LOG" <<'PY' || fail "Codex レビューに空のモデル指定を付けた"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if "review" in c["args"]][0]
assert not any(a.startswith("model=") for a in run) and "model_reasoning_effort=xhigh" in run, run
PY
pass "CODEX_MODEL が空なら model= を付けない（Codex レビューは stub で CLEAN）"

# ---- 6b. 許可と sandbox を明示して渡す（利用者の設定に任せない）----
launch 0 "claude" run-claude.sh
python3 - "$STUB_LOG" <<'PY2' || fail "Claude 実装に許可モード・許可ツールが渡らない"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if "-p" in c["args"]][0]
assert "--permission-mode=acceptEdits" in run, run
assert "--allowedTools=Bash,Edit,Write,Read,Glob,Grep,TodoWrite" in run, run
# 可変長オプションの後ろにプロンプトを置かない（-p が最後で、プロンプトは stdin）
assert run[-1] == "-p", run
PY2
pass "Claude 実装は --permission-mode=acceptEdits と --allowedTools=... を = 形式で渡し、-p を最後に置く"
# フォルダは -x でも真になるので、CLI のパスとして使わず PATH から探し直す（ランチャ側の判定）
CLAUDE_BIN="$T" launch 0 "claude" run-claude.sh
grep -q '"-p"' "$STUB_LOG" || fail "CLAUDE_BIN のフォルダを使って起動できなかった（PATH から探し直していない）"
pass "CLAUDE_BIN にフォルダを書いても PATH の CLI で起動する"
CLAUDE_IMPL_PERMISSION_MODE= CLAUDE_IMPL_ALLOWED_TOOLS= launch 0 "claude" run-claude.sh
python3 - "$STUB_LOG" <<'PY2' || fail "空の許可設定でも付けた"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if "-p" in c["args"]][0]
assert not any(a.startswith(("--permission-mode", "--allowedTools")) for a in run), run
PY2
pass "空の CLAUDE_IMPL_PERMISSION_MODE / CLAUDE_IMPL_ALLOWED_TOOLS は付けない"
CLAUDE_IMPL_PERMISSION_MODE=bypassPermissions CLAUDE_IMPL_ALLOWED_TOOLS="Read,Edit" launch 0 "claude" run-claude.sh
python3 - "$STUB_LOG" <<'PY2' || fail "許可設定の上書きが効かない"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if "-p" in c["args"]][0]
assert "--permission-mode=bypassPermissions" in run and "--allowedTools=Read,Edit" in run, run
PY2
pass "CLAUDE_IMPL_PERMISSION_MODE / CLAUDE_IMPL_ALLOWED_TOOLS の上書きが効く"
launch 0 "claude codex" run-codex.sh
python3 - "$STUB_LOG" "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" "$(git -C "$wt" rev-parse --path-format=absolute --git-dir)" <<'PY2' || fail "Codex 実装に sandbox が渡らない"
import json, os, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if c["args"][:1] == ["exec"] and "-o" in c["args"]][0]
assert run[run.index("--sandbox") + 1] == "workspace-write", run
roots = [a for a in run if a.startswith("sandbox_workspace_write.writable_roots=")]
assert len(roots) == 1, run
got = json.loads(roots[0].split("=", 1)[1])
common, gitdir = os.path.realpath(sys.argv[2]), os.path.realpath(sys.argv[3])
want = sorted([gitdir] + [os.path.join(common, d) for d in ("objects", "refs", "logs")])
assert sorted(os.path.realpath(p) for p in got) == want, (got, want)
# 共通の config・hooks（後でサンドボックスの外の git から実行され得る）と、管理フォルダ全体は書ける場所に入れない
assert all(os.path.realpath(p) != common for p in got), got
assert run[-1] == "-", run
PY2
pass "Codex 実装は --sandbox workspace-write と、commit に要る git の管理フォルダの一部（gitdir・objects・refs・logs）だけを書ける場所に渡す"
CODEX_IMPL_SANDBOX=danger-full-access launch 0 "claude codex" run-codex.sh
python3 - "$STUB_LOG" <<'PY2' || fail "CODEX_IMPL_SANDBOX の上書きが効かない"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if c["args"][:1] == ["exec"] and "-o" in c["args"]][0]
assert run[run.index("--sandbox") + 1] == "danger-full-access", run
assert not any(a.startswith("sandbox_workspace_write.") for a in run), run
PY2
pass "CODEX_IMPL_SANDBOX=danger-full-access を渡し、書ける場所の追加はしない"
# 子の実行中に git の制御ファイル（共通の config・gitdir の commondir / config.worktree）が変わったら、git を 1 回も呼ばずに EXIT:4
cdx_common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
cdx_gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir)"
print -r -- '#!/bin/sh
: > "$CDX_MARK"' > "$T/fsmon.sh"; chmod +x "$T/fsmon.sh"
for target in "$cdx_common/config" "$cdx_gitdir/commondir" "$cdx_gitdir/config.worktree"; do
  cp -p "$cdx_common/config" "$T/config.save"; [[ -e "$target" ]] && cp -p "$target" "$T/target.save" || rm -f -- "$T/target.save"
  rm -f -- "$T/fsmon.mark"
  if [[ "$target" == "$cdx_common/config" ]]; then
    run_cmd="git config --file '$target' core.fsmonitor '$T/fsmon.sh'"
  else
    run_cmd="printf '%s\n' '[core]' '	fsmonitor = $T/fsmon.sh' >> '$target'"
  fi
  CDX_MARK="$T/fsmon.mark" STUB_RUN="$run_cmd" launch 4 "claude codex" run-codex.sh
  grep -q '^EXIT:4$' "$wt/logs/$LAST_LABEL.done" && grep -q 'git の制御ファイル' "$wt/logs/$LAST_LABEL.done" \
    || { cat "$T/$LAST_LABEL.out" >&2; fail "git の制御ファイルの変更（$target）で EXIT:4・理由が残らない"; }
  [[ ! -e "$T/fsmon.mark" ]] || fail "制御ファイルの変更（$target）の後に git を回して fsmonitor を動かした"
  [[ ! -e "$wt/logs/$LAST_LABEL.evidence.md" ]] || fail "制御ファイルの変更（$target）の後に証跡（git の要約）を作った"
  cp -p "$T/config.save" "$cdx_common/config"
  if [[ -e "$T/target.save" ]]; then cp -p "$T/target.save" "$target"; else rm -f -- "$target"; fi
  pass "Codex 実装の実行中に $target:t が変わったら git を呼ばずに EXIT:4"
done
git -C "$wt" status --porcelain > /dev/null || fail "制御ファイルを戻した後に worktree が壊れている"
CODEX_IMPL_SANDBOX=bogus launch 2 "claude codex" run-codex.sh
grep -q 'CODEX_IMPL_SANDBOX' "$T/$LAST_LABEL.out" && grep -q '^EXIT:2$' "$wt/logs/$LAST_LABEL.done" || fail "誤った CODEX_IMPL_SANDBOX で理由・.done が無い"
! grep -q '"-o"' "$STUB_LOG" || fail "誤った CODEX_IMPL_SANDBOX で Codex を起動した"
pass "誤った CODEX_IMPL_SANDBOX は exit 2（起動しない）"
launch 0 "claude codex" run-codex-review.sh
python3 - "$STUB_LOG" <<'PY2' || fail "Codex レビューに読み取り専用が渡らない"
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
run = [c["args"] for c in calls if "review" in c["args"]][0]
i = run.index('sandbox_mode="read-only"')
assert run[i - 1] == "-c", run
PY2
pass "Codex レビューは -c sandbox_mode=\"read-only\" で読み取り専用を強制する"
for bad in danger-full-access bogus; do
  CODEX_REVIEW_SANDBOX="$bad" launch 2 "claude codex" run-codex-review.sh
  grep -q 'CODEX_REVIEW_SANDBOX' "$T/$LAST_LABEL.out" || fail "CODEX_REVIEW_SANDBOX=$bad の理由が無い"
  ! grep -q '"review"' "$STUB_LOG" || fail "CODEX_REVIEW_SANDBOX=$bad で Codex レビューを起動した"
  pass "CODEX_REVIEW_SANDBOX=$bad は exit 2（レビューを起動しない）"
done

# Codex レビューも、子の実行中に git の制御ファイル（worktree の .git・共通の config・gitdir の commondir）が変わったら、
# git を 1 回も呼ばずに EXIT:4（workspace-write の子は worktree の .git ファイルを書ける。read-only でも同じく比べる）
git init -q --bare "$T/fake-gitdir"
for target in "$wt/.git" "$cdx_common/config" "$cdx_gitdir/commondir"; do
  cp -p "$cdx_common/config" "$T/config.save"; cp -p "$target" "$T/target.save"
  rm -f -- "$T/fsmon.mark"
  case "$target" in
    "$wt/.git") run_cmd="printf 'gitdir: %s\n' '$T/fake-gitdir' > '$target'" ;;
    "$cdx_common/config") run_cmd="git config --file '$target' core.fsmonitor '$T/fsmon.sh'" ;;
    *) run_cmd="printf '%s\n' '$T/fake-gitdir' > '$target'" ;;
  esac
  for sandbox in workspace-write read-only; do
    CDX_MARK="$T/fsmon.mark" STUB_RUN="$run_cmd" CODEX_REVIEW_SANDBOX="$sandbox" launch 4 "claude codex" run-codex-review.sh
    grep -q '^EXIT:4$' "$wt/logs/$LAST_LABEL.done" && grep -q 'git の制御ファイル' "$wt/logs/$LAST_LABEL.done" \
      || { cat "$T/$LAST_LABEL.out" >&2; fail "Codex レビュー中の制御ファイルの変更（$target:t / $sandbox）で EXIT:4・理由が残らない"; }
    [[ ! -e "$T/fsmon.mark" ]] || fail "Codex レビュー中の制御ファイルの変更（$target:t）の後に git を回して fsmonitor を動かした"
    [[ ! -e "$wt/logs/$LAST_LABEL.evidence.md" ]] || fail "Codex レビュー中の制御ファイルの変更（$target:t）の後に証跡（git の要約）を作った"
    cp -p "$T/config.save" "$cdx_common/config"; cp -p "$T/target.save" "$target"
  done
  pass "Codex レビューの実行中に $target:t が変わったら（workspace-write / read-only とも）git を呼ばずに EXIT:4"
done
git -C "$wt" status --porcelain > /dev/null || fail "制御ファイルを戻した後に worktree が壊れている"
# 設定・hooks の書き換え（rvd_git_guard の対象。git の制御ファイルの指紋に入らない info/attributes）も不合格にする
CODEX_REVIEW_SANDBOX=workspace-write STUB_RUN="mkdir -p '$cdx_common/info' && printf '* diff=x\n' > '$cdx_common/info/attributes'" \
  launch 4 "claude codex" run-codex-review.sh
grep -q 'VERDICT: NEEDS_FIX' "$wt/logs/$LAST_LABEL.done" || fail "Codex レビュー中の info/attributes の変更で NEEDS_FIX にならない"
rm -f -- "$cdx_common/info/attributes"
pass "Codex レビューの実行中の git 管理フォルダ側の変更（info/attributes）も NEEDS_FIX・EXIT:4"
# 再利用の記録（logs/.<series>.review-state）を子が偽造したら、元の中身に戻して不合格にする（次の auto で偽の CLEAN を使わない）
rs_run() { local want="$1" rc=0; shift
  LANES_TOOLS="claude codex" CODEX_REVIEW_SANDBOX=workspace-write zsh -f "$LANES_DIR/run-codex-review.sh" "$wt" "$T/prompt.md" "$@" > "$T/rs.out" 2>&1 || rc=$?
  (( rc == want )) || { cat "$T/rs.out" >&2; fail "run-codex-review.sh $* expected=$want got=$rc"; }; }
forge='{"last_round": "0", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}'
rs_run 0 rstate
state="$wt/logs/.rstate.review-state"; [[ -f "$state" ]] || fail "1 回目のレビューの記録が無い"
state_save="$(<"$state")"
STUB_RUN="printf '%s\n' '$forge' > '$state'" rs_run 4 rstate --force
[[ "$(<"$state")" == "$state_save" ]] || fail "子が偽造した再利用の記録を元に戻さない"
grep -q 'VERDICT: NEEDS_FIX' "$wt/logs/rstate.done" || fail "再利用の記録の偽造で NEEDS_FIX にならない"
STUB_RUN="printf '%s\n' '$forge' > '$wt/logs/.rstate2.review-state'" rs_run 4 rstate2
[[ ! -e "$wt/logs/.rstate2.review-state" ]] || fail "前回の記録が無いのに、子が作った偽の記録を残した"
pass "Codex レビューの子が再利用の記録を偽造したら、元に戻して（無ければ消して）EXIT:4"

# ---- 7. 入口の振り分け（--dry-run で行き先だけ見る）----
entry() {   # <期待 rc> <構成> <入口> [引数...]
  local want="$1" tools="$2" name="$3"; shift 3
  n=$(( n + 1 )); local rc=0
  LANES_TOOLS="$tools" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "e$n" "$@" > "$T/e$n.out" 2>&1 || rc=$?
  (( rc == want )) || { cat "$T/e$n.out" >&2; fail "$name [$tools] $* expected=$want got=$rc"; }
  OUT="$(< "$T/e$n.out")"
}
entry 0 "claude codex" run-impl.sh --dry-run
[[ "$OUT" == *"$STUBS/claude"* && "$OUT" == *"--strict-mcp-config"* ]] || fail "run-impl.sh が Claude に振り分けない"
pass "run-impl.sh は既定で Claude（run-claude.sh）"
entry 2 "claude codex" run-impl.sh --engine gemini --dry-run
[[ "$OUT" == *"gemini が無い"* ]] || fail "gemini の無い構成で --engine gemini の理由が無い"
pass "run-impl.sh --engine gemini は gemini の無い構成で exit 2"
entry 2 "claude codex gemini" run-impl.sh --verify true --dry-run
[[ "$OUT" == *"gemini 用のオプション"* ]] || fail "Claude 実装に gemini 用オプションを通した"
pass "run-impl.sh は Claude 実装に gemini 用のオプションを通さない"
entry 2 "claude codex gemini" run-impl.sh --engine bogus
pass "run-impl.sh --engine の誤りは exit 2"
entry 0 "claude gemini" run-impl.sh --engine gemini --verify true --allow-path owned.txt --no-push --dry-run
[[ "$OUT" == *"$STUBS/agy"* && "$OUT" == *"必須検証"* ]] || fail "run-impl.sh --engine gemini が run-gemini.sh に振り分けない"
pass "run-impl.sh --engine gemini は run-gemini.sh"

for tools in "claude codex gemini" "claude codex"; do
  entry 0 "$tools" run-review.sh --dry-run
  [[ "$OUT" == *"$STUBS/codex"* && "$OUT" == *"exec"*"review"* ]] || fail "run-review.sh [$tools] が Codex に振り分けない"
  pass "run-review.sh [$tools] は Codex（run-codex-review.sh）"
done
for tools in "claude gemini" "claude"; do
  entry 0 "$tools" run-review.sh --dry-run
  [[ "$OUT" == *"$STUBS/claude"* && "$OUT" == *"--permission-mode"* && "$OUT" == *"--disallowedTools="* ]] || fail "run-review.sh [$tools] が Claude 読み取り専用に振り分けない"
  [[ -f "$wt/logs/e$n.dry-run.prompt.md" ]] && grep -q 'full' "$wt/logs/e$n.dry-run.prompt.md" || fail "run-review.sh [$tools] の既定が full でない"
  pass "run-review.sh [$tools] は Claude（run-claude-review.sh・full）"
done
entry 0 "claude" run-review.sh --base feat/test --mode delta --force --dry-run
sha="$(git -C "$wt" rev-parse HEAD)"
grep -q "$sha" "$wt/logs/e$n.dry-run.prompt.md" || fail "Claude レビューが --base の枝名を commit に直さない"
[[ "$OUT" == *"mode=full"* ]] || fail "前回の記録が無いのに Claude レビューの明示 delta を full に戻さない"
pass "run-review.sh は Claude レビューへ --base の枝名・--force・--mode delta をそのまま渡す（前回の記録が無ければ full）"
entry 0 "claude" run-review.sh --round 3 --dry-run
[[ "$OUT" == *"round=3"* && "$OUT" == *"$STUBS/claude"* ]] || fail "run-review.sh が Claude レビューへ --round を渡さない"
pass "run-review.sh は Claude レビューの構成でも --round を通す"
entry 2 "claude" run-review.sh --round x
[[ "$OUT" == *"--round"* ]] || fail "Claude レビューの --round の誤りの理由が無い"
pass "Claude レビューの --round の誤りは exit 2（理由つき）"
entry 2 "claude" run-review.sh --base no-such-ref
pass "run-review.sh は解決できない --base を exit 2"
entry 2 "claude codex" run-review.sh --mode bogus
pass "run-review.sh の --mode の誤りは exit 2"

# ---- 8. 入口は起動前点検を通す（未ログインなら振り分け先へ進まない）----
: > "$STUB_LOG"
STUB_CLAUDE_AUTH=none entry 2 "claude" run-impl.sh --dry-run
[[ "$OUT" == *"lanes-doctor"* && "$OUT" == *"NG"* ]] || fail "run-impl.sh が点検の結果を出さない"
! grep -q '"-p"' "$STUB_LOG" || fail "点検で止まったのに Claude を起動した"
pass "run-impl.sh は点検で止まる（未ログイン）"
STUB_CODEX_AUTH=apikey entry 2 "claude codex" run-review.sh --dry-run
[[ "$OUT" == *"API キーでログイン"* && "$OUT" != *"stub-not-a-real-key"* ]] || fail "run-review.sh が API キーのログインで止まらない / 本文を出した"
pass "run-review.sh は点検で止まる（API キーのログイン・本文非表示）"

# ---- 9. 同じ label で前回成功した後に点検で止まったら、今回の失敗（FAILED・EXIT:2）を残す ----
# 前回の .done（EXIT:0）が残ったままだと lanes-status.sh が DONE を返し、起動していないのに成功と取り違える
status_of() {   # <label> → 状態の語（DONE / FAILED など）
  local rc=0 out
  out="$(zsh -f "$LANES_DIR/lanes-status.sh" "$wt" "$1" 2>&1)" || rc=$?
  print -r -- "$out"
}
again() {   # <構成> <入口> <label> <点検を落とす変数> [引数...]
  local tools="$1" name="$2" label="$3" breaker="$4"; shift 4
  local rc=0
  LANES_TOOLS="$tools" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@" > "$T/$label.1.out" 2>&1 || rc=$?
  (( rc == 0 )) || { cat "$T/$label.1.out" >&2; fail "$name [$tools] 1 回目が成功しない（$rc）"; }
  [[ "$(status_of "$label")" == *DONE* ]] || fail "$name [$tools] 1 回目の状態が DONE でない"
  rc=0
  env "$breaker" LANES_TOOLS="$tools" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@" > "$T/$label.2.out" 2>&1 || rc=$?
  (( rc == 2 )) || { cat "$T/$label.2.out" >&2; fail "$name [$tools] 点検で止まらない（$rc）"; }
  grep -q '^EXIT:2$' "$wt/logs/$label.done" || fail "$name [$tools] 点検の失敗が .done に残らない（前回の成功のまま）"
  local st; st="$(status_of "$label")"
  [[ "$st" == *FAILED* && "$st" != *DONE* ]] || fail "$name [$tools] 点検で止まったのに状態が FAILED でない: $st"
  pass "$name [$tools] は前回成功の label でも点検の失敗を FAILED（EXIT:2）で残す"
}
again "claude" run-impl.sh r1 STUB_CLAUDE_AUTH=none
again "claude codex" run-impl.sh r2 STUB_CODEX_AUTH=apikey
again "claude codex" run-review.sh r3 STUB_CODEX_AUTH=apikey
again "claude" run-review.sh r4 STUB_CLAUDE_AUTH=none --base HEAD
git -C "$wt" config user.name "Test User"; git -C "$wt" config user.email you@example.com
mkdir -p "$T/home-nogem"   # Gemini のログイン情報の置き場所が無い HOME（点検で NG になる）
again "claude gemini" run-impl.sh r5 HOME="$T/home-nogem" --engine gemini --verify true --allow-path owned.txt --no-push

# ---- 10. 排他を取る前の誤り（引数・--base の形・設定の値）でも、前回の DONE を残したまま止まらない ----
# 前回の成功（.done EXIT:0）を置いておき、誤った引数で起動 → exit 2・今回の .done（EXIT:2・起動前の誤り）・状態 FAILED
fake_done() {   # <label>: 前回の成功の記録を作る（生きていない pid）
  print -r -- $'pid=999999\nlstart=\nlane=claude' > "$wt/logs/$1.pid"
  print -r -- $'EXIT:0\nVERDICT: CLEAN\nfinished=2000-01-01 00:00:00 JST\nelapsed_min=1' > "$wt/logs/$1.done"
  [[ "$(status_of "$1")" == *DONE* ]] || fail "前回の成功の記録が DONE にならない: $1"
}
typeset -ga early_env=()   # ランチャにだけ渡す環境変数（KEY=値。前回の記録づくりと status 確認には渡さない）
early() {   # <label> <構成> <ランチャ> [引数...]
  local label="$1" tools="$2" name="$3"; shift 3
  fake_done "$label"
  local rc=0
  LANES_TOOLS="$tools" env "${early_env[@]}" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@" > "$T/$label.out" 2>&1 || rc=$?
  (( rc == 2 )) || { cat "$T/$label.out" >&2; fail "$name [$tools] $* が exit 2 にならない（$rc）"; }
  grep -q '^EXIT:2$' "$wt/logs/$label.done" && grep -q '^note=起動前の誤り' "$wt/logs/$label.done" \
    || { cat "$T/$label.out" "$wt/logs/$label.done" >&2; fail "$name [$tools] $* の誤りが今回の .done に残らない"; }
  ls "$wt/logs/$label".prev-*.done >/dev/null 2>&1 || fail "$name [$tools] 前回の .done を回転していない"
  local st; st="$(status_of "$label")"
  [[ "$st" == *FAILED* ]] || fail "$name [$tools] $* の後の状態が FAILED でない: $st"
  pass "$name [$tools] $* は排他前の誤りでも今回の FAILED（EXIT:2）を残す"
}
early p1 "claude" run-claude.sh --bogus
early p2 "claude" run-claude-review.sh --base not-a-sha
early p3 "claude codex" run-codex-review.sh --mode bogus
early p4 "claude codex" run-codex-review.sh --round x
early p5 "claude" run-qa.sh --mode full
early p6 "claude" run-impl.sh --engine bogus
early p7 "claude" run-impl.sh --engine gemini
early p12 "claude" run-impl.sh --mode full     # 値の付いた不明なオプション（値を label と取り違えない）
early p13 "claude gemini" run-impl.sh --engine gemini --bogus
# label を省いたときは指示書のファイル名が label。不明なオプションの値を label にしない
fake_done prompt
rc=0; LANES_TOOLS=claude zsh -f "$LANES_DIR/run-impl.sh" "$wt" "$T/prompt.md" --mode full > "$T/p14.out" 2>&1 || rc=$?
(( rc == 2 )) && grep -q '^EXIT:2$' "$wt/logs/prompt.done" && grep -q '不明なオプション: --mode' "$wt/logs/prompt.done" \
  || { cat "$T/p14.out" >&2; fail "label 省略・値の付いた不明なオプションの誤りが指示書の名前の .done に残らない（$rc）"; }
[[ ! -e "$wt/logs/full.done" ]] || fail "不明なオプションの値を label として扱った"
pass "label を省いても、不明なオプションの誤りは指示書の名前の .done に残す（値を label にしない）"
# --name=value の形なら、後ろの label はそのまま label として使う
fake_done p15
rc=0; LANES_TOOLS=claude zsh -f "$LANES_DIR/run-impl.sh" "$wt" "$T/prompt.md" --bogus=1 p15 > "$T/p15.out" 2>&1 || rc=$?
(( rc == 2 )) && grep -q '^EXIT:2$' "$wt/logs/p15.done" || { cat "$T/p15.out" >&2; fail "--name=value の後ろの label に誤りが残らない（$rc）"; }
pass "--name=value の形の不明なオプションでは、後ろの label をそのまま使う"
# 全ランチャで同じ: label を省いて値付きの不明なオプションを書いても、値を label にせず指示書の名前の .done に残す
nolabel() {   # <構成> <ランチャ> [引数...]
  local tools="$1" name="$2"; shift 2
  fake_done prompt; rm -f "$wt/logs/full.done" "$wt/logs/full.pid"
  local rc=0
  LANES_TOOLS="$tools" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$@" > "$T/nolabel.out" 2>&1 || rc=$?
  (( rc == 2 )) && grep -q '^EXIT:2$' "$wt/logs/prompt.done" && grep -q '不明なオプション: --bogus' "$wt/logs/prompt.done" \
    || { cat "$T/nolabel.out" >&2; fail "$name [$tools] label 省略・値の付いた不明なオプションの誤りが指示書の名前の .done に残らない（$rc）"; }
  [[ ! -e "$wt/logs/full.done" && ! -e "$wt/logs/full.pid" ]] || fail "$name [$tools] 不明なオプションの値を label として扱った"
  pass "$name [$tools] label を省いても、不明なオプションの値（$*）を label にしない"
}
nolabel "claude" run-claude.sh --bogus full
nolabel "claude" run-claude-review.sh --bogus full
nolabel "claude codex" run-codex-review.sh --bogus full
nolabel "claude codex" run-codex.sh --bogus full
nolabel "claude" run-qa.sh --bogus full
nolabel "claude gemini" run-gemini.sh --bogus full --verify true --allow-path owned.txt --no-push
nolabel "claude" run-review.sh --bogus full
nolabel "claude codex" run-review.sh --bogus full
# --name=value の形と、次がオプションのときは読み捨てない（後ろの label・--dry-run をそのまま使う）
fake_done p16
rc=0; LANES_TOOLS=claude zsh -f "$LANES_DIR/run-claude.sh" "$wt" "$T/prompt.md" --bogus=1 p16 > "$T/p16.out" 2>&1 || rc=$?
(( rc == 2 )) && grep -q '^EXIT:2$' "$wt/logs/p16.done" || { cat "$T/p16.out" >&2; fail "run-claude.sh --name=value の後ろの label に誤りが残らない（$rc）"; }
fake_done p17
rc=0; LANES_TOOLS="claude codex" zsh -f "$LANES_DIR/run-codex.sh" "$wt" "$T/prompt.md" p17 --bogus --dry-run > "$T/p17.out" 2>&1 || rc=$?
(( rc == 2 )) && grep -q '^EXIT:0$' "$wt/logs/p17.done" || { cat "$T/p17.out" >&2; fail "run-codex.sh 不明なオプションの次の --dry-run を値として読み捨てた（$rc）"; }
pass "--name=value・次がオプションのときは、後ろの語を読み捨てない"
early p8 "claude" run-review.sh --round x
early p9 "claude" run-review.sh --base no-such-ref
GEMINI_POLL_SEC=x early p10 "claude gemini" run-gemini.sh --verify true --allow-path owned.txt --no-push
# 設定値の誤り（lanes.env の数値・0/1 の確かめ）も、排他を取れれば今回の失敗として残す（前回の DONE を残さない）
early_env=(LANES_NOTIFY=true); early c1 "claude" run-claude.sh
early_env=(LANES_NOTIFY=true); early c2 "claude" run-claude-review.sh --base HEAD
early_env=(LANES_NOTIFY=true); early c3 "claude codex" run-codex-review.sh
early_env=(LANES_NOTIFY=true); early c4 "claude codex" run-codex.sh
early_env=(LANES_NOTIFY=true); early c5 "claude" run-qa.sh
early_env=(LANES_NOTIFY=true); early c6 "claude" run-impl.sh
early_env=(LANES_NOTIFY=true); early c7 "claude" run-review.sh
early_env=(LANES_STALL_MINUTES=0); early c8 "claude gemini" run-gemini.sh --verify true --allow-path owned.txt --no-push
early_env=()
grep -q '設定の誤り: LANES_NOTIFY' "$wt/logs/c6.done" || fail "設定値の誤りの理由が .done に残らない"
pass "設定値の誤りの理由（キーの名前）を .done に残す"
# dry-run の誤りは記録に触らない
fake_done d1
rc=0; LANES_TOOLS=claude zsh -f "$LANES_DIR/run-claude.sh" "$wt" "$T/prompt.md" d1 --dry-run --bogus > "$T/d1.out" 2>&1 || rc=$?
(( rc == 2 )) && grep -q '^EXIT:0$' "$wt/logs/d1.done" || fail "dry-run の誤りで前回の記録を書き換えた（$rc）"
pass "dry-run の誤りは前回の記録に触らない"
# 同じ label が実行中（排他が取れない）なら、その旨を出して前回の記録に触らない
fake_done busy
: >> "$wt/logs/busy.lock"
zsh -fc 'zmodload zsh/system zsh/zselect; zsystem flock -f fd "$1" || exit 1; print ready > "$2"; zselect -t 3000 || true' _ "$wt/logs/busy.lock" "$T/busy.ready" &
holder=$!
for _ in {1..50}; do [[ -f "$T/busy.ready" ]] && break; sleep 0.1; done
[[ -f "$T/busy.ready" ]] || { kill "$holder" 2>/dev/null; fail "排他を握るプロセスが用意できない"; }
rc=0; LANES_TOOLS=claude zsh -f "$LANES_DIR/run-claude.sh" "$wt" "$T/prompt.md" busy --bogus > "$T/busy.out" 2>&1 || rc=$?
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
(( rc == 2 )) || fail "実行中の label で誤った引数が exit 2 にならない（$rc）"
grep -q '^EXIT:0$' "$wt/logs/busy.done" || fail "実行中の label の前回の記録を書き換えた"
grep -q '実行中のため、前回の記録' "$T/busy.out" || fail "実行中なので記録に触らない旨を出さない"
pass "排他が取れない（実行中）ときは前回の記録に触らず、その旨を出す"

# ---- 11. 旧名のランチャ・互換の入口は置かない（公開版は新しい名前だけ） ----
# 置いてあるランチャ（run-*.sh）とレビュー出力の整形（*-output.py）が、新しい名前の一覧と一致すること
want_launchers="codex-review-output.py run-claude-review.sh run-claude.sh run-codex-review.sh run-codex.sh run-gemini.sh run-impl.sh run-qa.sh run-review.sh"
typeset -a have_list; have_list=("$LANES_DIR"/run-*.sh(N:t) "$LANES_DIR"/*-output.py(N:t))
have_list=(${(o)have_list}); have_launchers="${(j: :)have_list}"
[[ "$have_launchers" == "$want_launchers" ]] || fail "ランチャの一覧が新しい名前だけになっていない（$have_launchers）"
pass "旧名のランチャ・互換の入口は置かない（ランチャは新しい名前の一覧どおり）"

print -r -- "PASS: $count 件 / EXIT:0"
