#!/bin/zsh -f
# Gemini レビューランチャ（run-gemini-review.sh）のテスト。本物の agy・外部サービスは使わない（偽の agy: tests/stubs/agy）。
# この中で構成（LANES_TOOLS）を自分で固定するので、呼び出し元の構成には左右されない。全データを一時領域に置く。
# 確かめること:
#   1. 構成に gemini が無ければ exit 2・.done あり・agy を起動しない。本体 checkout・オプションの足りない agy・誤った GEMINI_REVIEW_DENY でも起動しない
#   2. agy に --sandbox / --settings（permissions.deny の固定の一覧 + GEMINI_REVIEW_DENY）/ --mode plan / stream-json / --print-timeout /
#      --add-dir（scratch）を渡し、ANTIGRAVITY_HEADLESS=true・git の通信止め・GIT_OPTIONAL_LOCKS=0 の環境で起動する。
#      --model / --effort は空なら付けない。.pid（lane=gemini-review）と証跡にモデルと effort が残る
#   3. 終了コード 0 でも result.status が ERROR・空の応答・result が無い・JSON の破損なら EXIT:3・VERDICT: NONE（本文・エラーの本文の VERDICT は拾わない）
#   4. 禁止の道具（ファイルを書く道具・MCP・ブラウザ・Web・ワークフロー）や質問の道具（ask_*）を使ったら EXIT:4・VERDICT: NEEDS_FIX
#   5. 作業ツリーの変更・git の制御ファイルの変更・再利用の記録の偽造を検出して不合格（EXIT:4）。制御ファイルの変更の後は git を呼ばない
#   6. review-dedup の連携: r1 full → r2 delta、同じ HEAD は前回の結果を使う（--force で回す）、前回 NEEDS_FIX の引き継ぎ、
#      round 3 以降の P2/P3 の後回し票、LANES_REVIEW_REQUIRE_CHECKS=1 と chk-run.sh の記録の使い回し。記録にレビュー役（gemini）が残る
#   7. 一時エラーは 1 回だけやり直す。出力が止まれば EXIT:8。--dry-run は記録を作らず agy を起動しない
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-gemini-review.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H/.gemini/antigravity-cli"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない（LANES_ / STUB_ / GEMINI_ で始まる変数・CLI のパス・モデル指定・chk-run の記録の場所を外す）
for v in ${(k)parameters[(I)LANES_*]} ${(k)parameters[(I)CHK_*]} ${(k)parameters[(I)STUB_*]} ${(k)parameters[(I)GEMINI_*]} \
    CLAUDE_BIN CODEX_BIN CLAUDE_MODEL CODEX_MODEL CLAUDE_EFFORT CODEX_EFFORT CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS \
    CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX XDG_CONFIG_HOME XDG_STATE_HOME; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$T/no-such.conf" LANES_NOTIFY=0 LANES_TOOLS="claude codex gemini"
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T" XDG_STATE_HOME="$T/state"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex" GEMINI_BIN="$STUBS/agy"
export CHK_CACHE="$T/chk-cache/passed.tsv" PYTHONPYCACHEPREFIX="$T/pycache"
export GEMINI_POLL_SEC=1 GEMINI_IDLE_GRACE=5 GEMINI_IDLE_RESUME_GRACE=5 GEMINI_NOOUTPUT_SEC=30 GEMINI_REVIEW_PRINT_TIMEOUT=20s
export STUB_LOG="$T/stub.jsonl"; : > "$STUB_LOG"
CLEAN=$'問題なし\\nVERDICT: CLEAN'

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

newrepo() {   # <名前> → base（本体 checkout）と wt（linked worktree）を作る。logs/ は git に無視されている
  base="$T/base-$1"; wt="$T/wt-$1"
  git init -q -b main "$base"; lanes_test_assert_repo "$base"
  print -r -- 'logs/' > "$base/.gitignore"; print -r -- "元の内容 $1" > "$base/a.txt"
  git -C "$base" add -A
  git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: 初期化'
  git -C "$base" worktree add -q -b "feat/$1" "$wt"
  git -C "$wt" config user.name "Test User"; git -C "$wt" config user.email you@example.com; git -C "$wt" config commit.gpgSign false
  git -C "$wt" update-ref refs/remotes/origin/develop HEAD
}
change() { print -r -- "$1" >> "$wt/a.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm "test: $1"; }
print -r -- '担当の変更を確かめる（案件固有の目印）。' > "$T/prompt.md"
# <期待の終了コード> <label> [引数...]: run-gemini-review.sh を本物の起動で回す（偽の agy）。偽の CLI の記録は起動のたびに空にする
grv() {
  local want="$1" label="$2" rc=0; shift 2
  : > "$STUB_LOG"
  zsh -f "$LANES_DIR/run-gemini-review.sh" "$wt" "$T/prompt.md" "$label" "$@" > "$T/out" 2>&1 || rc=$?
  (( rc == want )) || { cat "$T/out" >&2; fail "$label: 終了コード expected=$want got=$rc"; }
}
has() { grep -qF -- "$2" "$1" || { cat "$1" >&2; fail "${1:t} に「$2」が無い"; }; }
hasnt() { if grep -qF -- "$2" "$1"; then cat "$1" >&2; fail "${1:t} に「$2」がある"; fi; }
calls() { python3 -I -c 'import json, sys
print(sum(1 for l in open(sys.argv[1], encoding="utf-8") if l.strip() and "-p" in json.loads(l)["args"]))' "$STUB_LOG"; }
# 直前の起動で agy に渡した引数・環境を Python で確かめる（<説明> <Python の式の並び>。a = 引数、env = 環境、s = 設定）
argcheck() {
  local what="$1"; shift
  python3 -I - "$STUB_LOG" "$@" <<'PY' || { cat "$STUB_LOG" >&2; fail "$what"; }
import json, sys
runs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
runs = [r for r in runs if "-p" in r["args"]]
assert runs, "agy の -p の呼び出しが無い"
a, env = runs[-1]["args"], runs[-1]["env"]
s = json.loads(a[a.index("--settings") + 1])
for expr in sys.argv[2:]:
    assert eval(expr), expr
PY
}

# ---- 1. 起動しない場面 ----
newrepo off
LANES_TOOLS="claude codex" grv 2 off1
has "$T/out" 'この構成では使えない'
has "$wt/logs/off1.done" 'EXIT:2'
[[ "$(calls)" == 0 ]] || fail "gemini の無い構成で agy を起動した"
pass "構成に gemini が無ければ exit 2・.done（EXIT:2）・agy 未起動"
wt="$base" grv 2 main1
has "$T/out" '本体 checkout'
[[ "$(calls)" == 0 ]] || fail "本体 checkout で agy を起動した"
pass "本体 checkout（.git がフォルダ）では起動しない"
STUB_AGY_HELP=$'--sandbox\n--settings' grv 2 help1
has "$T/out" '--mode に未対応'
has "$wt/logs/help1.done" 'EXIT:2'
[[ "$(calls)" == 0 ]] || fail "--mode の無い agy を起動した"
pass "agy --help に --mode が無ければ起動しない（--sandbox / --settings / --mode を確かめる）"
GEMINI_REVIEW_DENY=$'bad\nname' grv 2 deny-bad
has "$T/out" 'GEMINI_REVIEW_DENY'
[[ "$(calls)" == 0 ]] || fail "誤った GEMINI_REVIEW_DENY で agy を起動した"
pass "制御文字の入った GEMINI_REVIEW_DENY は exit 2（起動しない）"

# ---- 2. 正常な起動: 引数・設定・環境・記録 ----
newrepo ok
GEMINI_MODEL=model-g GEMINI_EFFORT=medium STUB_AGY_RESPONSE="$CLEAN" grv 0 basic
argcheck "agy に読み取り専用の引数・設定・環境が渡っていない" \
  '"--sandbox" in a' 'a[a.index("--mode") + 1] == "plan"' \
  'a[a.index("--output-format") + 1] == "stream-json"' 'a[a.index("--print-timeout") + 1] == "20s"' \
  'a[a.index("--model") + 1] == "model-g"' 'a[a.index("--effort") + 1] == "medium"' \
  'a[a.index("--add-dir") + 1] == env["LANES_SCRATCH"] and "/scratch/" in env["LANES_SCRATCH"]' \
  'set(["mcp(*)", "write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit", "notebook_execution", "delete_knowledge", "generate_image", "invoke_subagent", "define_subagent", "manage_subagents", "browser_subagent", "open_browser_url", "read_url_content", "search_web", "schedule", "run_workflow"]) <= set(s["permissions"]["deny"])' \
  's["allowNonWorkspaceAccess"] is False and s["enableTerminalSandbox"] is True and s["modelProvider"] == "" and s["useG1Credits"] is False' \
  'env["ANTIGRAVITY_HEADLESS"] == "true" and env["GIT_ALLOW_PROTOCOL"] == "lanes-no-transport" and env["GIT_OPTIONAL_LOCKS"] == "0"' \
  'env["GIT_CONFIG_GLOBAL"].startswith(env["LANES_SCRATCH"])' \
  'a.index("-p") == len(a) - 2'
pass "agy に --sandbox / --settings（固定の拒否の一覧）/ --mode plan / stream-json / --print-timeout / --add-dir と --model / --effort を渡す"
argcheck "プロンプトの中身が違う" \
  '"レビュー本線（Gemini）" in a[-1] and "レビュー本線（Claude）" not in a[-1]' \
  '"案件固有の目印" in a[-1] and "# レビューの出し方（必須）" in a[-1] and "## 重さの決め方（必須）" in a[-1]' \
  '"ask_ で始まるもの" in a[-1] and "一時ファイルの置き場所" in a[-1]' \
  'a[-1].rstrip().endswith("VERDICT: NEEDS_FIX")'
pass "プロンプトは Claude レビューのテンプレ（役名を Gemini に）+ 案件固有の指示 + Codex と同じレビューの出し方 + 読み取り専用の約束"
L="$wt/logs"
has "$L/basic.done" 'VERDICT: CLEAN'; has "$L/basic.done" 'EXIT:0'
has "$L/basic.evidence.md" '## Gemini レビュー証跡（basic）'
has "$L/basic.evidence.md" '- モデル: model-g / effort medium'
has "$L/basic.evidence.md" '禁止の道具 0 件'
grep -qx 'lane=gemini-review' "$L/basic.pid" && grep -qx 'model=model-g' "$L/basic.pid" && grep -qx 'effort=medium' "$L/basic.pid" \
  || { cat "$L/basic.pid" >&2; fail ".pid に lane=gemini-review / model / effort が無い"; }
[[ "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["last_reviewer"])' "$L/.basic.review-state")" == gemini ]] \
  || fail "再利用の記録にレビュー役 gemini が残らない"
copy="$(sed -n 's/^scratch=//p' "$L/basic.pid" | head -1)/gemini-settings.json"
argcheck "設定の写し（scratch の gemini-settings.json）が渡した設定と違う" "json.load(open('$copy')) == s"
pass ".pid（lane=gemini-review・model・effort）・証跡・再利用の記録（last_reviewer=gemini）・設定の写しが残る"
GEMINI_MODEL= GEMINI_EFFORT= STUB_AGY_RESPONSE="$CLEAN" grv 0 noflags
argcheck "空のモデル・effort なのに --model / --effort を付けた" '"--model" not in a and "--effort" not in a'
has "$L/noflags.evidence.md" '- モデル: (CLI の既定) / effort (CLI の既定)'
pass "GEMINI_MODEL / GEMINI_EFFORT が空なら --model / --effort を付けない"
GEMINI_REVIEW_DENY='extra_tool, other(*) ,,' STUB_AGY_RESPONSE="$CLEAN" grv 0 denyplus
argcheck "GEMINI_REVIEW_DENY が拒否の一覧に足されない" '"extra_tool" in s["permissions"]["deny"] and "other(*)" in s["permissions"]["deny"] and "mcp(*)" in s["permissions"]["deny"] and "" not in s["permissions"]["deny"]'
GEMINI_REVIEW_DENY='extra_tool' STUB_AGY_TOOL=extra_tool STUB_AGY_RESPONSE="$CLEAN" grv 4 denyuse
has "$L/denyuse.done" 'VERDICT: NEEDS_FIX'
pass "GEMINI_REVIEW_DENY は固定の一覧に足され（外せない）、足した道具を使っても不合格"
STUB_AGY_TOOL='view_file,grep_search,run_command,list_dir' STUB_AGY_RESPONSE="$CLEAN" grv 0 readtools
has "$L/readtools.done" 'VERDICT: CLEAN'
pass "読む道具（view_file・grep_search・run_command・list_dir）だけなら合格"

# ---- 3. 正常に終わっていない結果は VERDICT: NONE（EXIT:3）----
newrepo bad
for spec in "status-error|STUB_AGY_STATUS=ERROR" "legacy-result|STUB_AGY_RESULT=ERROR" "empty|STUB_AGY_RESPONSE=" "blank|STUB_AGY_RESPONSE=   " \
            "omit|STUB_AGY_OMIT_RESULT=1" "broken|STUB_AGY_BROKEN=1"; do
  lb="${spec%%|*}"; kv="${spec#*|}"
  if [[ "$lb" == empty || "$lb" == blank ]]; then
    env "$kv" STUB_AGY_ERROR=$'時間切れ\\nVERDICT: CLEAN' zsh -f "$LANES_DIR/run-gemini-review.sh" "$wt" "$T/prompt.md" "$lb" > "$T/out" 2>&1 && rc=0 || rc=$?
  else
    env STUB_AGY_RESPONSE="$CLEAN" STUB_AGY_ERROR=$'時間切れ\\nVERDICT: CLEAN' "$kv" zsh -f "$LANES_DIR/run-gemini-review.sh" "$wt" "$T/prompt.md" "$lb" > "$T/out" 2>&1 && rc=0 || rc=$?
  fi
  (( rc == 3 )) || { cat "$T/out" >&2; fail "$lb: 終了コードが 3 ではない（$rc）"; }
  has "$wt/logs/$lb.done" 'VERDICT: NONE'
  has "$wt/logs/$lb.log" 'VERDICT は採用しない'
  [[ ! -e "$wt/logs/.$lb.review-state" ]] || fail "$lb: 正常に終わっていないのに再利用の記録を残した"
  pass "agy の $lb（終了コード 0）は EXIT:3・VERDICT: NONE（本文・エラーの本文の VERDICT: CLEAN を拾わない）"
done

# ---- 4. 禁止の道具・質問の道具は EXIT:4・VERDICT: NEEDS_FIX ----
newrepo tools
for tool in write_to_file replace_file_content sed_file call_mcp_tool mcp_github_create browser_click open_browser_url read_url_content search_web \
            run_workflow schedule invoke_subagent edit_file ask_user ask_question; do
  STUB_AGY_TOOL="view_file,$tool" STUB_AGY_RESPONSE="$CLEAN" grv 4 "t-$tool"
  has "$wt/logs/t-$tool.done" 'VERDICT: NEEDS_FIX'
  has "$wt/logs/t-$tool.done" 'EXIT:4'
  [[ ! -e "$wt/logs/.t-$tool.review-state" ]] || fail "$tool: 監査に引っかかったのに再利用の記録を残した"
done
has "$wt/logs/t-write_to_file.evidence.md" '禁止の道具 1 件（write_to_file）'
has "$wt/logs/t-ask_user.evidence.md" '質問・承認の道具 1 回'
pass "禁止の道具（書く・MCP・ブラウザ・Web・ワークフロー・予約・サブエージェント）と質問の道具（ask_*）は本文が CLEAN でも EXIT:4"

# ---- 5. 作業ツリー・git の管理フォルダ・再利用の記録の変更 ----
newrepo dirty
STUB_RUN='printf "上書き\n" >> a.txt' STUB_AGY_RESPONSE="$CLEAN" grv 4 d-tracked
has "$wt/logs/d-tracked.done" 'VERDICT: NEEDS_FIX'; has "$wt/logs/d-tracked.evidence.md" '変更検出 1'
git -C "$wt" checkout -q -- a.txt
STUB_RUN='printf "新規\n" > new.txt' STUB_AGY_RESPONSE="$CLEAN" grv 4 d-untracked
rm -f -- "$wt/new.txt"
STUB_RUN='git commit --allow-empty -qm "test: 履歴の変更"' STUB_AGY_RESPONSE="$CLEAN" grv 4 d-commit
git -C "$wt" reset -q --hard HEAD~1
pass "作業ツリーの上書き・未追跡の追加・commit は EXIT:4・VERDICT: NEEDS_FIX"
common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
cp -p "$common/config" "$T/config.save"
print -r -- $'#!/bin/sh\n: > "$GRV_MARK"' > "$T/fsmon.sh"; chmod +x "$T/fsmon.sh"
GRV_MARK="$T/fsmon.mark" STUB_RUN="git config --file '$common/config' core.fsmonitor '$T/fsmon.sh'" STUB_AGY_RESPONSE="$CLEAN" grv 4 d-ctl
has "$wt/logs/d-ctl.done" 'git の制御ファイル'
[[ ! -e "$T/fsmon.mark" ]] || fail "git の制御ファイルの変更の後に git を回して fsmonitor を動かした"
[[ ! -e "$wt/logs/d-ctl.evidence.md" ]] || fail "git の制御ファイルの変更の後に証跡（git の要約）を作った"
cp -p "$T/config.save" "$common/config"
pass "git の制御ファイル（共通の config）が変わったら git を呼ばずに EXIT:4"
STUB_AGY_RESPONSE="$CLEAN" grv 0 rs
state="$wt/logs/.rs.review-state"; saved="$(<"$state")"
forge='{"last_round": "0", "last_head": "forged", "last_verdict": "VERDICT: CLEAN"}'
STUB_RUN="printf '%s\n' '$forge' > '$state'" STUB_AGY_RESPONSE="$CLEAN" grv 4 rs --force
[[ "$(<"$state")" == "$saved" ]] || fail "子が偽造した再利用の記録を元に戻さない"
has "$wt/logs/rs.done" 'VERDICT: NEEDS_FIX'
pass "子が再利用の記録を偽造したら元に戻して EXIT:4"

# ---- 6. review-dedup の連携 ----
newrepo dedup; L="$wt/logs"
STUB_AGY_RESPONSE="$CLEAN" grv 0 dd-r1
has "$L/dd-r1.evidence.md" 'モード: full'
change 'r2 の変更'
STUB_AGY_RESPONSE="$CLEAN" grv 0 dd-r2
has "$L/dd-r2.evidence.md" 'モード: delta'
argcheck "delta の説明が渡らない" '"# 再レビュー（round 2・delta" in a[-1] and "test: r2 の変更" in a[-1]'
STUB_AGY_RESPONSE="$CLEAN" grv 0 dd-r2
[[ "$(calls)" == 0 ]] || fail "同じ HEAD なのに agy を起動した"
has "$L/dd-r2.done" 'skip-same-head'
has "$L/dd-r2.evidence.md" '## Gemini レビュー証跡（dd-r2）'
STUB_AGY_RESPONSE="$CLEAN" grv 0 dd-r2 --force
[[ "$(calls)" == 1 ]] || fail "--force でも agy を起動しない"
pass "r1 full → r2 delta → 同じ HEAD は前回の結果を使う（--force で回す）"
newrepo fix; L="$wt/logs"
STUB_AGY_RESPONSE=$'- [P1] a.txt:1 認証の不具合（起きる条件: 普通の入力）\\nVERDICT: NEEDS_FIX' grv 0 fx-r1
has "$L/fx-r1.done" 'VERDICT: NEEDS_FIX'
change '直した'
STUB_AGY_RESPONSE="$CLEAN" grv 0 fx-r2
argcheck "前回の未解決指摘が引き継がれない" '"# 前回の未解決指摘" in a[-1] and "認証の不具合" in a[-1]'
has "$L/fx-r2.evidence.md" 'モード: delta'
has "$L/fx-r2.done" 'VERDICT: NEEDS_FIX'   # 解消の宣言が無いので通さない
pass "前回 NEEDS_FIX の後は前回の HEAD からの delta で、未解決指摘を引き継ぐ（解消の宣言が無ければ通さない）"
newrepo fu; L="$wt/logs"
STUB_AGY_RESPONSE=$'- [P2] 文言の残件\\nCHECKS: typecheck=NA lint=NA unit=NA build=SKIP\\nVERDICT: NEEDS_FIX' grv 0 fu-r3
has "$L/fu-r3.done" 'VERDICT: CLEAN'; has "$L/fu-r3.done" 'gate=MERGE_WITH_FOLLOWUP'
has "$L/fu.followups.md" '文言の残件'
pass "round 3 以降の P2 は後回し票に保存して通す（必須検証の成功行あり）"
newrepo chk; L="$wt/logs"
mkdir -p "$L"   # logs/ が無い初回の起動では .done を作らない決まりなので、先に作っておく（logs/ は git に無視されている）
export LANES_CHECK_CMD=/usr/bin/true STUB_AGY_RESPONSE="$CLEAN"
( export LANES_REVIEW_REQUIRE_CHECKS=1; grv 2 rq-r1 )
[[ "$(calls)" == 0 ]] || fail "記録が無いのに LANES_REVIEW_REQUIRE_CHECKS=1 で agy を起動した"
has "$L/rq-r1.done" 'chk-run の記録を使えない'
has "$T/out" 'no-record'
out="$(bash "$LANES_DIR/chk-run.sh" "$wt" 49995 "$T/chk-out" 2>&1)" || { print -u2 -r -- "$out"; fail "chk-run.sh が失敗"; }
( export LANES_REVIEW_REQUIRE_CHECKS=1; grv 0 rq-r1 )
argcheck "必須検証の使い回しの指示が渡らない" '"# 必須検証の使い回し（ランチャが確認済み）" in a[-1]'
has "$L/rq-r1.evidence.md" '親の chk-run の記録を使用'
unset LANES_CHECK_CMD STUB_AGY_RESPONSE
pass "LANES_REVIEW_REQUIRE_CHECKS=1 は記録が無ければ止め、chk-run.sh の記録があれば使い回す"

# ---- 7. 見張り・再試行・dry-run ----
newrepo watch; L="$wt/logs"
STUB_AGY_FIRST_ERROR="$T/first-error.flag" STUB_AGY_RESPONSE="$CLEAN" grv 0 retry
[[ "$(calls)" == 2 ]] || fail "一時エラーの後にやり直していない（呼び出し $(calls) 回）"
[[ -f "$L/retry.try1.json" && -f "$L/retry.try1.stderr.log" ]] || fail "1 回目の記録（try1）が残らない"
has "$L/retry.evidence.md" '一時エラーで 1 回やり直し'
has "$L/retry.done" 'VERDICT: CLEAN'
pass "作業ツリーの変わらない一時エラー（503）は 1 回だけやり直す"
GEMINI_NOOUTPUT_SEC=2 STUB_AGY_SLEEP=8 STUB_AGY_RESPONSE="$CLEAN" grv 8 noout
has "$L/noout.done" 'VERDICT: NONE'; has "$L/noout.evidence.md" '出力 2 秒なしで止めた'
pass "出力が止まれば EXIT:8・VERDICT: NONE"
STUB_AGY_RESPONSE="$CLEAN" grv 0 dry --dry-run
has "$T/out" '--mode plan'; has "$T/out" '--sandbox'
[[ "$(calls)" == 0 ]] || fail "dry-run で agy を起動した"
[[ ! -e "$L/dry.pid" && ! -e "$L/dry.done" && -f "$L/dry.dry-run.prompt.md" ]] || fail "dry-run が .pid / .done を作った、または結合したプロンプトが無い"
pass "--dry-run は agy を起動せず、.pid / .done を作らず、結合したプロンプトだけ残す"

print -r -- "PASS: $count 件 / EXIT:0"
