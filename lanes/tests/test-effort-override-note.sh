#!/bin/zsh -f
# 環境変数の effort が、設定ファイル（無ければ既定）と違う値で勝っているときに、ランチャが注意を 1 行出すことのテスト。
# 経緯: アプリから起動したシェルが CLAUDE_EFFORT を環境変数として持っていて、設定ファイルに書いた値が黙って負けたことがあった。
#       勝つ順番（環境変数 > 設定ファイル > 既定）は変えず、ランチャの起動時に知らせるだけにした（_common.sh の lanes_effort_override_note）。
# 確かめること:
#   1. 環境変数の effort が設定ファイル（無ければ既定）と違うときだけ、そのランチャが使うキーの注意を 1 行だけ出す（stderr）
#   2. 同じ値・環境変数なし・設定ファイルで固定（値をそのまま書く）のときは出さない。ほかのランチャのキーの注意も出さない
#   3. CLI に渡す値は今までどおり（環境変数が勝つ。固定したら設定ファイルが勝つ）。注意のための控えは子の CLI の環境に渡らない
# 偽の CLI（tests/stubs）と一時リポだけを使う。本物の CLI・ネットワークには触らない。全データを一時領域に置く。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-effort-note.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H/.gemini/antigravity-cli"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない（LANES_ で始まる変数・CLI のパス・モデルと effort の指定を外す）
for v in ${(k)parameters[(I)LANES_*]} ${(k)parameters[(I)CHK_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN CLAUDE_MODEL CODEX_MODEL GEMINI_MODEL \
    CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX \
    XDG_CONFIG_HOME XDG_STATE_HOME; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
conf="$T/lanes.conf"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$conf" LANES_NOTIFY=0 LANES_REVIEW_REUSE_CHECKS=0
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T" XDG_STATE_HOME="$T/state"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex" GEMINI_BIN="$STUBS/agy"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

# ---- 用意: 一時リポと worktree、見本と同じ書き方（環境変数が勝つ）の設定ファイル ----
base="$T/base"; wt="$T/wt"
git init -q -b main "$base"; lanes_test_assert_repo "$base"
print -r -- 'logs/' > "$base/.gitignore"; git -C "$base" add -A
git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: 初期化'
git -C "$base" worktree add -q -b feat/test "$wt"
git -C "$wt" update-ref refs/remotes/origin/develop HEAD
print -r -- '担当の確認だけを行う。' > "$T/prompt.md"
conf_sample() {   # 見本（lanes.conf.example）と同じ、環境変数が勝つ書き方
  print -r -- 'LANES_TOOLS="${LANES_TOOLS:-claude codex gemini}"'
  print -r -- 'CLAUDE_EFFORT="${CLAUDE_EFFORT-high}"'
  print -r -- 'CODEX_EFFORT="${CODEX_EFFORT-high}"'
  print -r -- 'GEMINI_EFFORT="${GEMINI_EFFORT-medium}"'
}
conf_sample > "$conf"

# <ランチャ> [引数...] を回し、stdout を $T/out、stderr を $T/err に取る。環境変数は呼び出し側で前置きする
run() {
  local rc=0
  zsh -f "$LANES_DIR/$1" "$wt" "$T/prompt.md" "${@:2}" > "$T/out" 2> "$T/err" || rc=$?
  (( rc == 0 )) || { cat "$T/out" "$T/err" >&2; fail "$1 ${*:2} が失敗（$rc）"; }
}
notes() { grep -c '^注意: [A-Z]*_EFFORT は環境変数の値' "$T/err" || true; }
no_note() { [[ "$(notes)" == 0 ]] || { cat "$T/err" >&2; fail "$1: 注意が出た"; }; }
one_note() {   # <説明> <キー> <環境変数の値の表示> <設定の値の表示>
  [[ "$(notes)" == 1 ]] || { cat "$T/err" >&2; fail "$1: 注意が 1 行ではない（$(notes) 行）"; }
  grep -q "^注意: $2 は環境変数の値「$3」で動く" "$T/err" || { cat "$T/err" >&2; fail "$1: 注意に環境変数の値（$3）が無い"; }
  grep -q "^注意: $2 .*の値「$4」は使われない" "$T/err" || { cat "$T/err" >&2; fail "$1: 注意に設定の値（$4）が無い"; }
  grep -q "^注意: $2 .*$2=\"$4\"" "$T/err" || { cat "$T/err" >&2; fail "$1: 注意に固定の書き方が無い"; }
}

# ---- 1. Claude 実装: 環境変数が設定ファイルと違うときだけ注意を 1 行。渡す値は環境変数のまま ----
CLAUDE_EFFORT=low run run-claude.sh e1 --dry-run
one_note "環境変数 low・設定 high" CLAUDE_EFFORT low high
grep -q -- '--effort low ' "$T/out" || fail "環境変数の値が渡っていない（勝つ順番が変わった）"
pass "環境変数の effort が設定ファイルと違うとき、注意を 1 行出す（渡す値は環境変数のまま）"

run run-claude.sh e2 --dry-run
no_note "環境変数なし"; grep -q -- '--effort high ' "$T/out" || fail "設定ファイルの値が渡っていない"
CLAUDE_EFFORT=high run run-claude.sh e3 --dry-run
no_note "環境変数と設定が同じ値"
CODEX_EFFORT=low GEMINI_EFFORT=low run run-claude.sh e4 --dry-run
no_note "ほかの道具のキーだけが違う"
pass "環境変数なし・同じ値・ほかの道具のキーだけが違うときは、注意を出さない"

CLAUDE_EFFORT= run run-claude.sh e5 --dry-run
one_note "環境変数が空・設定 high" CLAUDE_EFFORT '（空＝付けない）' high
! grep -q -- '--effort' "$T/out" || fail "空の環境変数なのに --effort が付いた"
pass "環境変数の空（--effort を付けない）が設定ファイルの値に勝つときも、注意を出す"

# 設定ファイルで固定（値をそのまま書く）すると、設定ファイルが勝ち、注意も出ない
{ conf_sample | grep -v '^CLAUDE_EFFORT='; print -r -- 'CLAUDE_EFFORT="high"'; } > "$conf"
CLAUDE_EFFORT=low run run-claude.sh e6 --dry-run
no_note "設定ファイルで固定"; grep -q -- '--effort high ' "$T/out" || fail "固定した値が渡っていない"
pass "設定ファイルに値をそのまま書いて固定すると、環境変数に負けず、注意も出ない"

# 設定ファイルにその行が無い・設定ファイル自体が無いときは、既定の値と比べる
conf_sample | grep -v '^CLAUDE_EFFORT=' > "$conf"
CLAUDE_EFFORT=low run run-claude.sh e7 --dry-run
one_note "設定ファイルに行が無い（既定 xhigh）" CLAUDE_EFFORT low xhigh
LANES_CONF="$T/no-such.conf" LANES_TOOLS=claude CLAUDE_EFFORT=low run run-claude.sh e8 --dry-run
one_note "設定ファイルが無い（既定 xhigh）" CLAUDE_EFFORT low xhigh
LANES_CONF="$T/no-such.conf" LANES_TOOLS=claude CLAUDE_EFFORT=xhigh run run-claude.sh e9 --dry-run
no_note "設定ファイルが無く、既定と同じ値"
pass "設定ファイルに行が無い・設定ファイルが無いときは、既定の値と比べて注意を出す"
conf_sample > "$conf"

# ---- 2. 入口経由でも 1 行だけ。レビュー・Codex・Gemini・QA のランチャも、自分のキーの注意を出す ----
CLAUDE_EFFORT=low run run-impl.sh e10 --dry-run
one_note "run-impl.sh 経由" CLAUDE_EFFORT low high
CODEX_EFFORT=low run run-codex.sh e11 --dry-run
one_note "run-codex.sh" CODEX_EFFORT low high
CLAUDE_EFFORT=low run run-codex.sh e12 --dry-run
no_note "run-codex.sh に CLAUDE_EFFORT だけ"
CODEX_EFFORT=low run run-review.sh e13 --base origin/develop --dry-run
one_note "run-review.sh（Codex レビュー）" CODEX_EFFORT low high
LANES_TOOLS=claude CLAUDE_EFFORT=low run run-review.sh e14 --base origin/develop --dry-run
one_note "run-review.sh（Claude レビュー）" CLAUDE_EFFORT low high
GEMINI_EFFORT=low run run-impl.sh e15 --engine gemini --verify true --allow-path src --dry-run
one_note "run-impl.sh --engine gemini" GEMINI_EFFORT low medium
CLAUDE_EFFORT=low run run-qa.sh e16 --dry-run
one_note "run-qa.sh" CLAUDE_EFFORT low high
pass "入口（run-impl.sh・run-review.sh）経由でも 1 行だけ。Codex・Gemini・レビュー・QA のランチャも自分のキーの注意を出す"

# ---- 3. 本物の起動（偽の CLI）: 渡す引数は環境変数の値。注意のための控えは子の CLI の環境に渡らない ----
export STUB_LOG="$T/stub.log" STUB_RUN_RC="$T/run.rc"
: > "$STUB_LOG"
CLAUDE_EFFORT=low STUB_RUN="env | grep -c '^LANES_EFFORT' > '$T/child-env.txt'; printf '%s' \"\${CLAUDE_EFFORT-unset}\" > '$T/child-effort.txt'" \
  run run-claude.sh e17
one_note "本物の起動" CLAUDE_EFFORT low high
python3 -I - "$STUB_LOG" <<'PY' || fail "子の CLI に渡した --effort が環境変数の値ではない"
import json, sys
calls = [json.loads(line)["args"] for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
runs = [a for a in calls if "-p" in a]
assert runs, "claude -p が呼ばれていない"
a = runs[-1]
assert a[a.index("--effort") + 1] == "low", a
PY
[[ "$(< "$T/child-env.txt")" == 0 ]] || fail "注意のための控え（LANES_EFFORT で始まる変数）が子の CLI の環境に渡った"
[[ "$(< "$T/child-effort.txt")" == low ]] || fail "子の CLI の環境の CLAUDE_EFFORT が変わった: $(< "$T/child-effort.txt")"
pass "本物の起動でも注意は 1 行。渡す引数と子の環境は今までどおりで、控えは子に渡らない"

# ---- 4. 起動前点検（lanes-doctor.sh）も同じ内容を注意の行として出す。--quiet（ランチャが起動前に使う）では何も出さない ----
out="$(LANES_TOOLS="claude codex" CODEX_EFFORT=low zsh -f "$LANES_DIR/lanes-doctor.sh" 2>&1)" || { print -u2 -r -- "$out"; fail "lanes-doctor.sh が失敗"; }
[[ "$(grep -c '^注意 CODEX_EFFORT は環境変数の値「low」で動く' <<< "$out")" == 1 ]] || { print -u2 -r -- "$out"; fail "lanes-doctor.sh が effort の上書きを注意の行に出さない"; }
[[ "$out" != *'CLAUDE_EFFORT は環境変数'* ]] || fail "lanes-doctor.sh が、上書きされていないキーの注意を出した"
out="$(LANES_TOOLS="claude codex" zsh -f "$LANES_DIR/lanes-doctor.sh" 2>&1)" || { print -u2 -r -- "$out"; fail "lanes-doctor.sh が失敗"; }
[[ "$out" != *'は環境変数の値'* ]] || fail "環境変数が無いのに lanes-doctor.sh が注意を出した"
out="$(LANES_TOOLS="claude codex" CODEX_EFFORT=low zsh -f "$LANES_DIR/lanes-doctor.sh" --quiet 2>&1)" || { print -u2 -r -- "$out"; fail "lanes-doctor.sh --quiet が失敗"; }
[[ -z "$out" ]] || fail "lanes-doctor.sh --quiet が、足りないものが無いのに出力した"
pass "lanes-doctor.sh も同じ内容を注意の行として出す（--quiet では何も出さない）"

print -r -- "合格 $count 件"
