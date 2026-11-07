#!/bin/zsh -f
# Claude Code の Stop フック（lanes/hooks/claude-stop-watch-guard.sh）のテスト。
# 本物の見張りは使わず、--check の出力を返す偽の lanes-watch.sh と、一時ファイルのやりとりの記録だけで確かめる。
set -euo pipefail
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-stop-guard.XXXXXX")"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
hook="$LANES_DIR/hooks/claude-stop-watch-guard.sh"
count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

# 偽の lanes-watch.sh: --check で GUARD_TEST_OUT の中身を出す（空なら何も出さずに失敗）
fake="$T/lanes-watch.sh"
print -r -- '#!/bin/zsh -f
[[ "$1" == --check ]] || exit 9
[[ -n "${GUARD_TEST_OUT:-}" ]] || exit 1
print -r -- "$GUARD_TEST_OUT"
[[ "$GUARD_TEST_OUT" == "WATCH OK"* ]] && exit 0 || exit 1' > "$fake"
export LANES_WATCH_GUARD_WATCH="$fake"
commander="$T/commander.jsonl"; other="$T/other.jsonl"
# 司令塔: Bash ツールで見張りを実行した記録（パスを引用符で囲んだ形）がある
print -r -- '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"zsh -f \"/kit/lanes/lanes-watch.sh\" --until-wake --max-hours 3"}}]}}' > "$commander"
# ほか: 見張りのコマンドを文中で言及しただけ（説明・手順の読み上げ）。実行はしていない
{ print -r -- '{"type":"user","message":{"content":"lanes-watch.sh --until-wake の使い方を教えて"}}'
  print -r -- '{"type":"assistant","message":{"content":[{"type":"text","text":"zsh -f lanes/lanes-watch.sh --until-wake をバックグラウンドで回す"},{"type":"tool_use","name":"Read","input":{"file_path":"lanes-watch.sh --until-wake"}}]}}'
  # Bash で中身を調べただけ（lanes-watch.sh が grep の引数）。見張りは起動していない
  print -r -- '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -n -- \"--until-wake\" lanes/lanes-watch.sh"}}]}}'; } > "$other"
# 司令塔の別の形: cd の後に起動
direct="$T/direct.jsonl"
print -r -- '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cd /kit && ./lanes/lanes-watch.sh --interval 300 --until-wake"}}]}}' > "$direct"
# 行継続（\ と改行）の後に --until-wake、空白を含む引用パス、変数の代入つき
cont="$T/cont.jsonl"; spaced="$T/spaced.jsonl"
print -r -- '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"zsh -f lanes/lanes-watch.sh \\\n  --until-wake --max-hours 3"}}]}}' > "$cont"
print -r -- '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"LANES_RUNS_ROOT=/x zsh -f \"/Users/you/my kit/lanes/lanes-watch.sh\" --until-wake"}}]}}' > "$spaced"
dead_running=$'WATCH DEAD\nLANES RUNNING 2（うち STALLED 0）\n直近10分 DONE（次工程待ち）: 0 件'
dead_waiting=$'WATCH STALE age=1200 pid=5\nLANES RUNNING 0（うち STALLED 0）\n直近10分 DONE（次工程待ち）: 1 件'
dead_idle=$'WATCH DEAD\nLANES RUNNING 0（うち STALLED 0）\n直近10分 DONE（次工程待ち）: 0 件'
ok_running=$'WATCH OK age=30 pid=5\nLANES RUNNING 2（うち STALLED 0）\n直近10分 DONE（次工程待ち）: 1 件'

# <期待 block|none> <説明> <transcript> <stop_hook_active> <--check の出力>
case_run() {
  local want="$1" name="$2" tr="$3" active="$4" out="$5" got rc=0
  got="$(print -r -- "{\"session_id\":\"s\",\"transcript_path\":\"$tr\",\"stop_hook_active\":$active}" | GUARD_TEST_OUT="$out" zsh -f "$hook")" || rc=$?
  (( rc == 0 )) || fail "$name: フックが 0 以外で終わった（$rc）"
  if [[ "$want" == block ]]; then
    print -r -- "$got" | python3 -I -c 'import json,sys
d=json.load(sys.stdin); assert d["decision"]=="block" and "--until-wake" in d["reason"]' 2>/dev/null || fail "$name: 止めていない（出力: $got）"
  else
    [[ -z "$got" ]] || fail "$name: 止めるべきでないのに出力がある（$got）"
  fi
  pass "$name"
}
case_run block "司令塔のセッションで見張りが死に、レーンが動いていれば止める" "$commander" false "$dead_running"
case_run block "見張りが古く、次工程待ちがあれば止める" "$commander" false "$dead_waiting"
case_run block "cd の後に起動した見張りも司令塔として見る" "$direct" false "$dead_running"
case_run block "行継続の後の --until-wake も見張りの起動として見る" "$cont" false "$dead_running"
case_run block "空白を含む引用パス・変数の代入つきの起動も見る" "$spaced" false "$dead_running"
case_run none "見張りが生きていれば止めない" "$commander" false "$ok_running"
case_run none "動いているレーンも次工程待ちも無ければ止めない" "$commander" false "$dead_idle"
case_run none "見張りを文中で言及した・grep で中身を調べただけのセッションは止めない" "$other" false "$dead_running"
case_run none "止めた後の 2 回目（stop_hook_active）は止めない" "$commander" true "$dead_running"
case_run none "やりとりの記録が無ければ止めない" "$T/no-such.jsonl" false "$dead_running"
case_run none "--check が何も返さなければ止めない" "$commander" false ""
ln -s "$commander" "$T/link.jsonl"
case_run none "やりとりの記録が symlink なら読まない" "$T/link.jsonl" false "$dead_running"
rc=0; got="$(print -r -- 'こわれた入力' | GUARD_TEST_OUT="$dead_running" zsh -f "$hook")" || rc=$?
(( rc == 0 )) && [[ -z "$got" ]] || fail "壊れた入力で止めた・失敗した"
pass "壊れた入力では止めない"
print -r -- "PASS: stop guard（$count 件）"
