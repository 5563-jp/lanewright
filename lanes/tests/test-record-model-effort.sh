#!/bin/zsh -f
# ランチャが、使ったモデルと effort（考える深さ）を記録に残すことのテスト。
# 経緯: 後から「どの設定で回したレーンか」を集計しようとしたら、.pid にも証跡にも残っていなかった（Gemini の証跡だけにあった）。
# 確かめること:
#   1. 6 種類のレーン（Claude 実装・Codex 実装・Gemini 実装・Codex レビュー・Claude レビュー・QA）の .pid に model= / effort= が残る
#   2. 値は、その起動で子の CLI に実際に渡した引数と同じ。起動ごとに環境変数で変えた値・自分用の名前の変数で変えた値も残る
#   3. 空にした設定（引数を付けない＝CLI の既定に任せる）は、.pid では空、証跡では「(CLI の既定)」
#   4. 証跡（<label>.evidence.md）に「モデル / effort」の行が 1 行ある
#   5. 行が増えた .pid を lanes-status.sh が今までどおり読める
# 偽の CLI（tests/stubs）と一時リポだけを使う。本物の CLI・ネットワークには触らない。全データを一時領域に置く。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-record-me.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H/.gemini/antigravity-cli"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない（LANES_ で始まる変数・CLI のパス・モデルと effort の指定・4b で使う自分用の名前の変数を外す）
for v in ${(k)parameters[(I)LANES_*]} ${(k)parameters[(I)CHK_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN CLAUDE_MODEL CODEX_MODEL GEMINI_MODEL \
    CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX \
    XDG_CONFIG_HOME XDG_STATE_HOME MY_CLAUDE_EFFORT; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
conf="$T/lanes.conf"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$conf" LANES_NOTIFY=0 LANES_REVIEW_REUSE_CHECKS=0
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T" XDG_STATE_HOME="$T/state"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex" GEMINI_BIN="$STUBS/agy"
export STUB_LOG="$T/stub.log"; : > "$STUB_LOG"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

# ---- 用意: 一時リポと worktree。設定は、道具ごとに違うモデル名と effort（見本と同じ、環境変数が勝つ書き方）----
base="$T/base"; wt="$T/wt"
git init -q -b main "$base"; lanes_test_assert_repo "$base"
print -r -- 'logs/' > "$base/.gitignore"; mkdir -p "$base/src"; print -r -- 'x' > "$base/src/a.txt"; git -C "$base" add -A
git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: 初期化'
git -C "$base" worktree add -q -b feat/test "$wt"
git -C "$wt" update-ref refs/remotes/origin/develop HEAD
print -r -- '担当の確認だけを行う。' > "$T/prompt.md"
conf_sample() {
  print -r -- 'LANES_TOOLS="${LANES_TOOLS:-claude codex gemini}"'
  print -r -- 'CLAUDE_MODEL="${CLAUDE_MODEL-model-c}"'
  print -r -- 'CODEX_MODEL="${CODEX_MODEL-model-x}"'
  print -r -- 'GEMINI_MODEL="${GEMINI_MODEL-model-g}"'
  print -r -- 'CLAUDE_EFFORT="${CLAUDE_EFFORT-high}"'
  print -r -- 'CODEX_EFFORT="${CODEX_EFFORT-low}"'
  print -r -- 'GEMINI_EFFORT="${GEMINI_EFFORT-medium}"'
}
conf_sample > "$conf"
logs="$wt/logs"

# <ランチャ> <label> [引数...] を本物の起動で回す（偽の CLI）。終了コードは問わない（.pid は起動の直後に書かれる）。
# 偽の CLI の引数の記録（STUB_LOG）は起動のたびに空にする（その起動で渡した引数だけを見るため）
launch() {
  : > "$STUB_LOG"
  zsh -f "$LANES_DIR/$1" "$wt" "$T/prompt.md" "${@:2}" > "$T/out" 2> "$T/err" || true
  [[ -f "$logs/$2.pid" ]] || { cat "$T/out" "$T/err" >&2; fail "$1 $2: .pid が無い（起動できていない）"; }
}
field() { sed -n "s/^$2=//p" "$logs/$1.pid" | head -1; }
# <label> <lane> <モデル> <effort>: .pid の 4 行が期待どおりで、model= / effort= は 1 行ずつ
pid_is() {
  [[ "$(field "$1" lane)" == "$2" ]] || { cat "$logs/$1.pid" >&2; fail "$1: lane が $2 ではない"; }
  [[ "$(grep -c '^model=' "$logs/$1.pid")" == 1 && "$(grep -c '^effort=' "$logs/$1.pid")" == 1 ]] \
    || { cat "$logs/$1.pid" >&2; fail "$1: .pid の model= / effort= が 1 行ずつではない"; }
  [[ "$(field "$1" model)" == "$3" ]] || { cat "$logs/$1.pid" >&2; fail "$1: model が「$3」ではない"; }
  [[ "$(field "$1" effort)" == "$4" ]] || { cat "$logs/$1.pid" >&2; fail "$1: effort が「$4」ではない"; }
}
# <label> <モデルの表示> <effort の表示>: 証跡に「モデル / effort」の行がちょうど 1 行
evidence_is() {
  local f="$logs/$1.evidence.md"
  [[ -f "$f" ]] || { cat "$T/out" "$T/err" >&2; fail "$1: 証跡が無い"; }
  [[ "$(grep -c '^- モデル: ' "$f")" == 1 ]] || { cat "$f" >&2; fail "$1: 証跡の「モデル」の行が 1 行ではない"; }
  grep -qF -- "- モデル: $2 / effort $3" "$f" || { cat "$f" >&2; fail "$1: 証跡の行が「モデル: $2 / effort $3」ではない"; }
}
# <説明> <偽の CLI の名前> <目印の引数> <並び>...: 直前の起動で、目印の引数を含む呼び出しに、指定の並びが全部ある。
# 並びは「|」区切りの隣り合う引数（例: "--model|model-c"）。「!」で始めた引数は、その呼び出しに無いことを確かめる。
# 記録した値が、その起動で子の CLI に実際に渡した引数と同じであることを見る（レーン名と使う設定の対応がずれたら赤になる）
args_have() {
  python3 -I - "$STUB_LOG" "${@:2}" <<'PY' || { cat "$STUB_LOG" >&2; fail "$1: 子の CLI に渡した引数が、記録した値と違う"; }
import json, sys
log, binname, marker, wants = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
calls = [json.loads(line) for line in open(log, encoding="utf-8") if line.strip()]
runs = [c["args"] for c in calls if c.get("bin", binname) == binname and marker in c["args"]]
assert runs, f"{binname} の、{marker} を含む呼び出しが無い"
a = runs[-1]
for w in wants:
    if w.startswith("!"):
        assert w[1:] not in a, (w, a)
        continue
    seq = w.split("|")
    assert any(a[i:i + len(seq)] == seq for i in range(len(a))), (w, a)
PY
}

# ---- 1. 6 種類のレーンの .pid と証跡に、そのランチャが CLI に渡す値が残る（道具ごとに違う値で、取り違えを赤にする）----
launch run-claude.sh m1
pid_is m1 claude model-c high; evidence_is m1 model-c high
args_have "Claude 実装" claude -p '--model|model-c' '--effort|high'
launch run-codex.sh m2
pid_is m2 codex model-x low; evidence_is m2 model-x low
args_have "Codex 実装" codex exec '-m|model-x' '-c|model_reasoning_effort=low'
launch run-codex-review.sh m4 --base origin/develop
pid_is m4 codex-review model-x low; evidence_is m4 model-x low
args_have "Codex レビュー" codex review '-c|model=model-x' '-c|model_reasoning_effort=low'
LANES_TOOLS=claude launch run-claude-review.sh m5 --base origin/develop
pid_is m5 claude-review model-c high; evidence_is m5 model-c high
args_have "Claude レビュー" claude -p '--model|model-c' '--effort|high'
launch run-qa.sh m6
pid_is m6 qa model-c high; evidence_is m6 model-c high
args_have "QA" claude -p '--model|model-c' '--effort|high'
pass "Claude 実装・Codex 実装・Codex レビュー・Claude レビュー・QA: .pid と証跡の値が、子の CLI に渡した引数と同じ"

# ---- 2. Gemini 実装は .pid だけを見る ----
# ここの偽の CLI では Gemini のレーンは最後まで走らない（専用の偽 CLI が要る）。証跡の「モデル」の行は前からあり、書き方は変えていない
launch run-gemini.sh m3 --verify true --allow-path src
pid_is m3 gemini model-g medium
pass "Gemini 実装の .pid にも model= / effort= が残る"

# ---- 3. 起動ごとに環境変数で変えた値が残る。入口（run-impl.sh）経由でも同じ ----
CLAUDE_MODEL=model-other CLAUDE_EFFORT=xhigh launch run-impl.sh m7
pid_is m7 claude model-other xhigh; evidence_is m7 model-other xhigh
args_have "起動ごとの値" claude -p '--model|model-other' '--effort|xhigh'
pass "起動ごとに変えた値が .pid と証跡に残り、子の CLI に渡した引数と同じ"

# ---- 4. 空にした設定（引数を付けない）は、.pid では空、証跡では「(CLI の既定)」----
CLAUDE_MODEL= CLAUDE_EFFORT= launch run-claude.sh m8
pid_is m8 claude "" ""; evidence_is m8 '(CLI の既定)' '(CLI の既定)'
args_have "空の設定" claude -p '!--model' '!--effort'
pass "空にした設定は、.pid では空、証跡では「(CLI の既定)」。子の CLI に --model / --effort を渡さない"

# ---- 4b. docs/config.md の書き方: 自分用の名前の変数だけを受ける設定で、起動ごとに変える ----
{ conf_sample | grep -v '^CLAUDE_EFFORT='; print -r -- 'CLAUDE_EFFORT="${MY_CLAUDE_EFFORT:-high}"'; } > "$conf"
CLAUDE_EFFORT=low launch run-claude.sh m9   # アプリが持ち込んだ形の環境変数は受けない
pid_is m9 claude model-c high
args_have "自分用の変数なし" claude -p '--effort|high'
if grep -q '^注意: CLAUDE_EFFORT は環境変数の値' "$T/err"; then cat "$T/err" >&2; fail "固定した設定なのに、上書きの注意が出た"; fi
CLAUDE_EFFORT=low MY_CLAUDE_EFFORT=xhigh launch run-claude.sh m10
pid_is m10 claude model-c xhigh; evidence_is m10 model-c xhigh
args_have "自分用の変数あり" claude -p '--effort|xhigh'
conf_sample > "$conf"
pass "自分用の名前の変数だけを受ける設定: 渡さなければ設定の値、渡せばその起動だけ変わり、記録にも残る"

# ---- 5. 行が増えた .pid を lanes-status.sh が今までどおり読める ----
out="$(zsh -f "$LANES_DIR/lanes-status.sh" "$wt" m1 2>&1)" || { print -u2 -r -- "$out"; fail "lanes-status.sh が失敗"; }
[[ "$out" == *DONE* ]] || { print -u2 -r -- "$out"; fail "lanes-status.sh が DONE を返さない"; }
pass "lanes-status.sh は、行の増えた .pid を今までどおり読む"

# ---- 6. 関数単体: 知らないレーン名は何も足さない。値の中の改行は空白にする（1 行の記録を壊さない）----
cat > "$T/unit.zsh" <<'UNIT'
set -euo pipefail
LANES_DIR="$1"
source "$LANES_DIR/lanes.env"; source "$LANES_DIR/_common.sh"
lanes_model_effort_evidence fake
if lanes_lane_model_effort fake; then print -r -- "known=yes"; else print -r -- "known=no"; fi
CODEX_MODEL=$'a\nb\rc'; lanes_lane_model_effort codex; print -r -- "model=[$LANES_REC_MODEL]"
UNIT
out="$(zsh -f "$T/unit.zsh" "$LANES_DIR" 2>&1)" || { print -u2 -r -- "$out"; fail "関数単体の確認が失敗"; }
[[ "$out" == $'known=no\nmodel=[a b c]' ]] || { print -u2 -r -- "$out"; fail "知らないレーン名・改行の扱いが違う"; }
pass "知らないレーン名は何も足さず、値の中の改行は空白にする"

print -r -- "合格 $count 件"
