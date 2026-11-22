#!/bin/zsh -f
# 親の chk-run.sh の記録を使えないとき、レビューの子を起動せずに止めること（LANES_REVIEW_REQUIRE_CHECKS=1）のテスト。
# 経緯: 記録が無いまま起動したレビューは、読み取り専用の閉じ込めの中で必須検証を回せず、毎回「必須検証が未完了」の指摘で終わっていた
#       （直しのレーンでは直せない指摘）。証跡に「先に chk-run.sh を通す」と出るだけで、止まらなかった。
# 確かめること:
#   1. 既定（0）では今までどおり起動する（証跡の文言も変えない）。--allow-missing-checks を付けても何も変わらない
#   2. 1 のとき、記録が無い（no-record）・未 commit の変更がある（uncommitted）・記録の後で入力が変わった（input-changed）なら、
#      子の CLI を起動せずに止める（EXIT:2）。.done に今回の失敗として理由と、理由ごとの直し方が残り、lanes-status.sh は FAILED を返す
#   3. 1 のときでも、記録を使えるなら起動する。値は chk-run.sh の入力の指紋に入らない（chk-run.sh は値なしで通し、
#      起動のときだけ環境変数で 1 を渡しても記録が合う）。止まった後に chk-run.sh を通せば、同じ label でやり直せる
#   4. --allow-missing-checks を付けた起動は記録なしで回り、証跡にその旨が残る
#   5. 1 のときでも、確認コマンドが未設定の案件・LANES_REVIEW_REUSE_CHECKS=0・記録の後で照合できなくなった（unresolvable など）は止めない。
#      問い合わせそのものの失敗（query-failed）は止める（記録を確かめられないまま「必須検証あり」として起動しない）
#   6. 前回 CLEAN の後で記録が合わなくなったら、同じ head でも前回の結果を使わずに止める（抜け道を付ければ回る）
#   7. 入口（run-review.sh）経由でも、Claude のレビュー（run-claude-review.sh）でも同じ。入口は --allow-missing-checks を渡す
#   8. --dry-run でも止まる。値は 0 か 1 だけ（ほかの値は設定の誤りとして止まる）
# 偽の CLI（tests/stubs）と一時リポだけを使う。本物の CLI・ネットワークには触らない。全データを一時領域に置く。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-require-chk.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない（LANES_ で始まる変数・CLI のパス・モデル指定・chk-run の記録の場所を外す）
for v in ${(k)parameters[(I)LANES_*]} ${(k)parameters[(I)CHK_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN CLAUDE_MODEL CODEX_MODEL GEMINI_MODEL \
    CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX \
    XDG_CONFIG_HOME XDG_STATE_HOME; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$T/no-such.conf" LANES_NOTIFY=0 LANES_TOOLS="claude codex"
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T" XDG_STATE_HOME="$T/state"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex"
# 確認済みの記録は一時領域のものだけを見る（本物の記録を読まない・書かない）。確認コマンドは何もしない成功
export CHK_CACHE="$T/chk-cache/passed.tsv" LANES_CHECK_CMD=/usr/bin/true
export PYTHONPYCACHEPREFIX="$T/pycache"
export STUB_LOG="$T/stub.log"; : > "$STUB_LOG"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

mkrepo() {   # <名前> → REPLY に worktree のパス（node_modules と logs/ は git に無視されている）
  local base="$T/$1-base" wt="$T/$1"
  git init -q -b main "$base"; lanes_test_assert_repo "$base"
  print -r -- $'node_modules/\nlogs/' > "$base/.gitignore"
  # 中身をリポごとに変える（同じ中身だと tree が同じになり、別のリポの記録と照合されて no-record ではなく input-changed になる）
  mkdir -p "$base/src"; print -r -- "export const name = '$1'" > "$base/src/a.ts"
  git -C "$base" add -A
  git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: 初期化'
  git -C "$base" worktree add -q -b "feat/$1" "$wt"
  git -C "$wt" update-ref refs/remotes/origin/develop HEAD
  print -r -- 'export const b = 2' > "$wt/src/b.ts"; git -C "$wt" add -A
  git -C "$wt" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'feat: b を足す'
  mkdir -p "$wt/node_modules/pkg"; print -r -- '{"name":"pkg","version":"1.0.0"}' > "$wt/node_modules/pkg/package.json"
  REPLY="$wt"
}
print -r -- '担当の確認だけを行う。' > "$T/prompt.md"
chk() {   # <worktree>: 確認を通して記録する
  local out rc=0
  out="$(bash "$LANES_DIR/chk-run.sh" "$1" 49996 "$T/chk-out" 2>&1)" || rc=$?
  (( rc == 0 )) || { print -u2 -r -- "$out"; fail "chk-run.sh が失敗（$rc）: $1"; }
}
query() { bash "$LANES_DIR/chk-run.sh" "$1" --query 2>/dev/null || true; }
# <ランチャ> <worktree> <label> [引数...] を本物の起動で回す。終了コードを RC に入れる。偽の CLI の記録は起動のたびに空にする
run() {
  : > "$STUB_LOG"; RC=0
  zsh -f "$LANES_DIR/$1" "$2" "$T/prompt.md" "${@:3}" > "$T/out" 2> "$T/err" || RC=$?
}
# 同じ起動を、LANES_REVIEW_REQUIRE_CHECKS=1 を「起動のときだけ」環境変数で渡して回す（chk-run.sh には渡さない。
# 値が入力の指紋に入っていると、ここで毎回 input-changed になる）
rrun() { local -x LANES_REVIEW_REQUIRE_CHECKS=1; run "$@"; }
reviewed() {   # 偽の CLI がレビューとして呼ばれたか（codex は exec review、claude は -p）
  python3 -I - "$STUB_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
ok = any(("review" in c["args"] and "exec" in c["args"]) or "-p" in c["args"] for c in calls)
sys.exit(0 if ok else 1)
PY
}
# <説明> <worktree> <label> <理由> <直し方の語>: 止まった（EXIT:2・子は未起動・.done に理由と直し方・status は FAILED）
blocked() {
  local done="$2/logs/$3.done" out
  (( RC == 2 )) || { cat "$T/out" "$T/err" >&2; fail "$1: 終了コードが 2 ではない（$RC）"; }
  if reviewed; then cat "$STUB_LOG" >&2; fail "$1: 止めるはずなのに、子の CLI がレビューとして起動された"; fi
  [[ -f "$done" ]] || { cat "$T/err" >&2; fail "$1: .done が無い"; }
  grep -q '^EXIT:2' "$done" || { cat "$done" >&2; fail "$1: .done が EXIT:2 ではない"; }
  grep -q "^note=起動前の誤り: .*chk-run の記録を使えない.*（$4" "$done" || { cat "$done" >&2; fail "$1: .done の note に理由（$4）が無い"; }
  grep -q -- "$5" "$done" && grep -q -- '--allow-missing-checks' "$done" || { cat "$done" >&2; fail "$1: .done の note に直し方（$5）が無い"; }
  [[ "$(grep -c '' "$done")" -le 6 && "$(grep -c '^note=' "$done")" == 1 ]] || { cat "$done" >&2; fail "$1: .done の note が 1 行に収まっていない"; }
  grep -q "chk-run の記録を使えない" "$T/err" || { cat "$T/err" >&2; fail "$1: 標準エラーに理由が出ていない"; }
  [[ ! -e "$2/logs/$3.evidence.md" ]] || fail "$1: 起動していないのに証跡がある"
  out="$(zsh -f "$LANES_DIR/lanes-status.sh" "$2" "$3" 2>&1)" || true
  [[ "$out" == *FAILED* ]] || { print -u2 -r -- "$out"; fail "$1: lanes-status.sh が FAILED を返さない"; }
}
# <説明> <worktree> <label> <証跡にあるはずの語>: 起動した（子がレビューとして呼ばれ、証跡がある）
launched() {
  reviewed || { cat "$T/out" "$T/err" >&2; fail "$1: 子の CLI がレビューとして起動されていない（終了コード $RC）"; }
  grep -q -- "$4" "$2/logs/$3.evidence.md" || { cat "$2/logs/$3.evidence.md" >&2; fail "$1: 証跡に「$4」が無い"; }
  if grep -q '^note=起動前の誤り' "$2/logs/$3.done"; then cat "$2/logs/$3.done" >&2; fail "$1: 起動前の誤りとして記録された"; fi
}

# ---- 1. 既定（0）では、記録が無くても今までどおり起動する（証跡の文言も同じ。抜け道を付けても変わらない） ----
mkrepo a; a="$REPLY"
[[ "$(query "$a")" == *reason=no-record* ]] || fail "用意: 記録が無い状態になっていない: $(query "$a")"
want='- 必須検証: レビューの中で回すよう指示（親の chk-run の記録は使わない: no-record＝この中身の確認済みの記録が無い。先に chk-run.sh を通す（通したのに無いときは、chk-run.sh の出力の record=no の行に、記録しなかった理由が出ている））。回せたかは「必須検証の成功確認」の行を見る'
run run-codex-review.sh "$a" r1 --base origin/develop
launched "既定" "$a" r1 'no-record'
[[ "$(grep '^- 必須検証: ' "$a/logs/r1.evidence.md")" == "$want" ]] || { grep '^- 必須検証: ' "$a/logs/r1.evidence.md" >&2; fail "既定: 証跡の「必須検証:」の行が今までと違う"; }
run run-codex-review.sh "$a" r1b --base origin/develop --allow-missing-checks
launched "既定＋抜け道" "$a" r1b 'no-record'
[[ "$(grep '^- 必須検証: ' "$a/logs/r1b.evidence.md")" == "$want" ]] || fail "既定: --allow-missing-checks を付けたら証跡の行が変わった"
pass "既定（LANES_REVIEW_REQUIRE_CHECKS=0）では今までどおり起動し、証跡の文言も変わらない（抜け道を付けても同じ）"

# ---- 2. 1 のとき、記録が無ければ子を起動せずに止める ----
rrun run-codex-review.sh "$a" r2 --base origin/develop
blocked "no-record" "$a" r2 no-record 'recorded= が出たことを確かめて'
grep -q 'record=no と出るなら' "$a/logs/r2.done" || fail "no-record: record=no の案内が無い"
pass "1 のとき、記録が無い（no-record）なら子を起動せずに止め、.done に理由と直し方を残す（status は FAILED）"

# ---- 3. --allow-missing-checks を付けた起動は、記録なしで回り、証跡にその旨が残る ----
rrun run-codex-review.sh "$a" r3 --base origin/develop --allow-missing-checks
launched "--allow-missing-checks" "$a" r3 'no-record.*--allow-missing-checks で起動'
pass "--allow-missing-checks を付けた起動は記録なしで回り、証跡に残る"

# ---- 4. chk-run.sh を通せば、止まったのと同じ label でやり直せる。値は入力の指紋に入らない ----
# chk-run.sh は値なしで通し、起動のときだけ 1 を渡す（値が指紋に入っていると、ここで input-changed になって止まり続ける）
chk "$a"
[[ "$(query "$a")" == reuse=yes* ]] || fail "用意: 記録を使える状態になっていない: $(query "$a")"
[[ "$(LANES_REVIEW_REQUIRE_CHECKS=1 query "$a")" == reuse=yes* ]] || fail "値を環境変数で渡すと、記録が合わなくなる: $(LANES_REVIEW_REQUIRE_CHECKS=1 query "$a")"
rrun run-codex-review.sh "$a" r2 --base origin/develop
launched "記録あり（同じ label のやり直し）" "$a" r2 '親の chk-run の記録を使用'
(( RC == 0 )) || { cat "$T/out" "$T/err" >&2; fail "記録あり: 終了コードが 0 ではない（$RC）"; }
grep -q '^EXIT:0' "$a/logs/r2.done" || { cat "$a/logs/r2.done" >&2; fail "記録あり: .done が今回の結果に替わっていない"; }
pass "chk-run.sh を通せば同じ label でやり直せる。起動のときだけ値を渡しても記録が合う（値は入力の指紋に入らない）"

# ---- 5. 未 commit の変更・記録の後の入力の変化でも止める（直し方は理由ごと） ----
print -r -- 'export const c = 3' > "$a/src/c.ts"
[[ "$(query "$a")" == *reason=uncommitted* ]] || fail "用意: uncommitted になっていない: $(query "$a")"
rrun run-codex-review.sh "$a" r5 --base origin/develop
blocked "uncommitted" "$a" r5 uncommitted '変更を commit してから'
rm -f -- "$a/src/c.ts"
print -r -- '{"name":"pkg","version":"2.0.0"}' > "$a/node_modules/pkg/package.json"
[[ "$(query "$a")" == *reason=input-changed* ]] || fail "用意: input-changed になっていない: $(query "$a")"
rrun run-codex-review.sh "$a" r6 --base origin/develop
blocked "input-changed" "$a" r6 input-changed '同じ環境から通し直して'
pass "未 commit の変更（uncommitted）・記録の後の入力の変化（input-changed）でも止め、理由ごとの直し方を出す"

# ---- 6. 前回 CLEAN の後で記録が合わなくなったら、同じ head でも前回の結果を使わずに止める ----
# r2 は記録ありで CLEAN（同じ系列の次の回として r2 を回し直す形にするため、系列 s を新しく作る）
print -r -- '{"name":"pkg","version":"1.0.0"}' > "$a/node_modules/pkg/package.json"
[[ "$(query "$a")" == reuse=yes* ]] || fail "用意: 記録を使える状態に戻っていない: $(query "$a")"
rrun run-codex-review.sh "$a" s-r1 --base origin/develop
launched "系列 s の 1 回目" "$a" s-r1 '親の chk-run の記録を使用'
grep -q '^VERDICT: CLEAN' "$a/logs/s-r1.done" || { cat "$a/logs/s-r1.done" >&2; fail "用意: 系列 s の 1 回目が CLEAN ではない"; }
print -r -- '{"name":"pkg","version":"3.0.0"}' > "$a/node_modules/pkg/package.json"
rrun run-codex-review.sh "$a" s-r2 --base origin/develop
blocked "CLEAN の後で入力が変わった" "$a" s-r2 input-changed '同じ環境から通し直して'
rrun run-codex-review.sh "$a" s-r2 --base origin/develop --allow-missing-checks
launched "CLEAN の後＋抜け道" "$a" s-r2 '--allow-missing-checks で起動'
if grep -q 'skip-same-head' "$a/logs/s-r2.evidence.md"; then cat "$a/logs/s-r2.evidence.md" >&2; fail "記録が合わないのに、同じ head の前回の結果を使った"; fi
pass "前回 CLEAN の後で記録が合わなくなったら、同じ head でも前回の結果を使わずに止める（抜け道を付ければレビューし直す）"

# ---- 7. 確認コマンドが未設定の案件・LANES_REVIEW_REUSE_CHECKS=0 のときは止めない ----
mkrepo b; b="$REPLY"
( unset LANES_CHECK_CMD; [[ "$(query "$b")" == *reason=no-check* ]] ) || fail "用意: no-check になっていない"
( unset LANES_CHECK_CMD; rrun run-codex-review.sh "$b" r7 --base origin/develop; launched "確認コマンドなし" "$b" r7 'no-check' ) || exit 1
( export LANES_REVIEW_REUSE_CHECKS=0; rrun run-codex-review.sh "$b" r8 --base origin/develop; launched "使い回しなし" "$b" r8 'LANES_REVIEW_REUSE_CHECKS=0' ) || exit 1
pass "確認コマンドが未設定の案件・LANES_REVIEW_REUSE_CHECKS=0 のときは止めない"

# ---- 8. 関数単体: 止める・止めないの振り分け（本物の起動では作りにくい理由も含めて） ----
cat > "$T/unit.zsh" <<'UNIT'
set -euo pipefail
LANES_DIR="$1"
source "$LANES_DIR/lanes.env"; source "$LANES_DIR/_common.sh"; source "$LANES_DIR/review-dedup.zsh"
t() {   # <REQUIRE> <REUSE> <理由> <allow> → block / pass と、抜け道を使ったか
  LANES_REVIEW_REQUIRE_CHECKS="$1" RVD_CHECKS_REUSE="$2" RVD_CHECKS_REASON="$3"
  local -a msg_lines
  if rvd_checks_block "$4"; then msg_lines=("${(@f)RVD_CHECKS_BLOCK}"); print -r -- "block allowed=$RVD_CHECKS_ALLOWED lines=${#msg_lines}"; else print -r -- "pass allowed=$RVD_CHECKS_ALLOWED msg=[$RVD_CHECKS_BLOCK]"; fi
}
for r in no-record uncommitted input-changed query-failed; do t 1 no "$r" 0; t 1 no "$r" 1; t 0 no "$r" 0; done
for r in no-check cache-link unresolvable state-error 'chk-run.sh が無い' ''; do t 1 no "$r" 0; done
t 1 yes '' 0; t 1 off 'LANES_REVIEW_REUSE_CHECKS=0' 0
UNIT
out="$(zsh -f "$T/unit.zsh" "$LANES_DIR" 2>&1)" || { print -u2 -r -- "$out"; fail "関数単体の確認が失敗"; }
want_unit="$(for i in 1 2 3 4; do print -r -- 'block allowed=0 lines=1'; print -r -- 'pass allowed=1 msg=[]'; print -r -- 'pass allowed=0 msg=[]'; done
  for i in 1 2 3 4 5 6 7 8; do print -r -- 'pass allowed=0 msg=[]'; done)"
[[ "$out" == "$want_unit" ]] || { print -u2 -r -- "$out"; fail "止める・止めないの振り分けが違う"; }
pass "振り分け: 4 つの理由（記録なし・未 commit・入力の変化・問い合わせの失敗）だけを止め（文言は 1 行）、確認コマンドなし・照合できない・記録あり・問い合わせなしは止めない"

# ---- 9. 入口（run-review.sh）経由でも、Claude のレビューでも同じ。入口は --allow-missing-checks を渡す ----
rrun run-review.sh "$b" r9 --base origin/develop
blocked "入口（Codex）" "$b" r9 no-record 'recorded= が出たことを確かめて'
rrun run-review.sh "$b" r10 --base origin/develop --allow-missing-checks
launched "入口（Codex）＋抜け道" "$b" r10 '--allow-missing-checks で起動'
( export LANES_TOOLS=claude
  rrun run-review.sh "$b" r11 --base origin/develop; blocked "入口（Claude）" "$b" r11 no-record 'recorded= が出たことを確かめて'
  rrun run-claude-review.sh "$b" r12 --base origin/develop --allow-missing-checks; launched "Claude＋抜け道" "$b" r12 '--allow-missing-checks で起動' ) || exit 1
pass "入口（run-review.sh）経由でも、Claude のレビューでも同じ。入口は --allow-missing-checks を渡す"

# ---- 10. --dry-run でも、止まることが分かる（子は起動しない・.done は作らない） ----
rrun run-codex-review.sh "$b" r13 --base origin/develop --dry-run
(( RC == 2 )) || { cat "$T/out" "$T/err" >&2; fail "dry-run: 終了コードが 2 ではない（$RC）"; }
grep -q "chk-run の記録を使えない" "$T/err" || fail "dry-run: 理由が出ていない"
[[ ! -e "$b/logs/r13.done" && ! -e "$b/logs/r13.pid" ]] || fail "dry-run なのに .pid / .done を作った"
pass "--dry-run でも止まる理由が出る（.pid / .done は作らない）"

# ---- 11. 値は 0 か 1 だけ ----
( export LANES_REVIEW_REQUIRE_CHECKS=2; run run-codex-review.sh "$b" r14 --base origin/develop
  (( RC == 2 )) || { cat "$T/out" "$T/err" >&2; fail "不正な値: 終了コードが 2 ではない（$RC）"; }
  if reviewed; then fail "不正な値なのに子を起動した"; fi
  grep -q 'LANES_REVIEW_REQUIRE_CHECKS は 0 か 1' "$T/err" || { cat "$T/err" >&2; fail "不正な値: 設定の誤りの案内が無い"; } ) || exit 1
pass "LANES_REVIEW_REQUIRE_CHECKS は 0 か 1 だけ（ほかの値は設定の誤りとして止まる）"

print -r -- "合格 $count 件"
