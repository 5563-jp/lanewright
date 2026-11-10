#!/bin/zsh -f
# 親の chk-run.sh の記録を、本物の起動（dry-run でない）のレビューが使い回せることのテスト。
# 経緯: chk-run.sh が成功を記録した直後に detach-run.sh 経由でレビューを起動すると、証跡が毎回
#       「親の chk-run の記録は使わない: input-changed」になった。detach-run.sh が起動ログ（logs/launch.log）を
#       ランチャの問い合わせより先に書き、その無視対象のファイルが入力の指紋に入っていたため。
#       ランチャの記録（logs/ の直下の、ランチャが台帳 logs/.lanes-records に載せた持ち主のファイル）は指紋に入れないようにした。
#       名前だけで外していたときは、確認コマンドが読む logs/input.json のような「記録に似た名前の入力」まで外れ、
#       中身を失敗する内容に変えても古い成功の記録を使い回した。台帳に載っている持ち主の記録だけを外す。
# 確かめること:
#   1. node_modules と dist のある worktree で、chk-run.sh → detach-run.sh 経由の本物の起動（Codex・Claude のレビューとも）が
#      記録を使い回す（証跡と指示書の両方）。レビューの後も chk-run.sh は同じ確認を省く（skip=same-tree）
#   2. dry-run の後・実装レーン（Claude・Codex・Gemini）・QA レーン・画面 QA の準備の後・同じ worktree の 2 回目以降の起動でも使い回す
#   3. ランチャが logs/ に書く名前（Gemini・QA・回転した前回分を含む）でも、台帳に載っていない持ち主のものは入力のまま。
#      台帳に載せた後は、どれも入力に数えない
#   4. logs/ に置いた、ランチャの記録でないもの（ほかの名前・フォルダの中・リンク・ハードリンク・追跡ファイル・
#      下の階層の logs/）と、依存・生成物の変化では、今までどおり使い回さない（照合をすり抜けない）
#   5. 環境変数の条件は緩めていない（親のシェルに API キーの環境変数があっても同じ環境から呼べば使い回す。
#      起動のときだけ外すと使い回さず、証跡に理由と一言が出る）
#   6. 確認コマンドが logs/input.json を読む構成で、中身を失敗する内容に変えたら、古い成功の記録を使い回さない（回し直して失敗する）
#   7. 台帳の書き方（symlink・ハードリンクの台帳は辿らない・使わない。detach-run.sh は worktree の logs/ の直下のときだけ載せる）
#   8. FIFO（名前付きパイプ）で止まらない・辿らない（台帳が FIFO でも chk-run.sh・問い合わせ・レビューの起動・台帳へ載せる側が待たずに返る。
#      detach-run.sh は、起動ログが FIFO・ハードリンク・symlink なら、その先へ書かずに起動を断る）
#   9. python3 の入口が環境変数を書き換える Mac（Xcode の /usr/bin/python3・pyenv の shims など）でも使い回す。
#      detach-run.sh は、呼び出し元の環境変数をそのまま子へ渡す（入口が足した・書き換えた分を渡さない）。
#      同じ確認を、そのまま回しても chk-run.sh の確認コマンドの中から回しても、結果は同じ（回す場所で緑と赤が変わらない）
# 使い方: test-review-reuse-launch.sh [--core]
#   --core: 1 の最初の確認（Codex のレビューの、chk-run.sh の直後の本物の起動）だけを回して終わる。
#           9 が、同じ確認を回す場所を変えて回すのに使う（selftest.sh は引数なしで全部を回す）
# 偽の CLI（tests/stubs）と一時リポだけを使う。本物の CLI・ネットワークには触らない。全データを一時領域に置く。
set -euo pipefail
core_only=0
case "${1:-}" in
  '') ;;
  --core) core_only=1 ;;
  *) print -u2 -- "使い方: test-review-reuse-launch.sh [--core]"; exit 2 ;;
esac
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
SELF="${0:A}"   # このテスト自身の場所（9 が --core で呼び直す。作業場所を変える前に絶対パスにしておく）
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-reuse-launch.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない（LANES_ で始まる変数・CLI のパス・モデル指定・chk-run の記録の場所・git の通信の制限を外す）
for v in ${(k)parameters[(I)LANES_*]} ${(k)parameters[(I)CHK_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN CLAUDE_MODEL CODEX_MODEL GEMINI_MODEL \
    CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX \
    XDG_CONFIG_HOME XDG_STATE_HOME; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$T/no-such.conf" LANES_NOTIFY=0
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T" XDG_STATE_HOME="$T/state"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex"
# 確認済みの記録は一時領域のものだけを見る（本物の記録を読まない・書かない）。確認コマンドは何もしない成功
export CHK_CACHE="$T/chk-cache/passed.tsv" LANES_CHECK_CMD=/usr/bin/true
export PYTHONPYCACHEPREFIX="$T/pycache"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

# ---- 用意: node_modules（.bin のリンク付き）と dist のある worktree。どちらも logs/ と一緒に git に無視されている ----
mkrepo() {   # <名前> → REPLY に worktree のパス
  local base="$T/$1-base" wt="$T/$1"
  git init -q -b main "$base"; lanes_test_assert_repo "$base"
  print -r -- $'node_modules/\ndist/\nlogs/' > "$base/.gitignore"
  print -r -- '{"name":"t","private":true,"scripts":{"test":"echo ok"}}' > "$base/package.json"
  mkdir -p "$base/src"; print -r -- 'export const a = 1' > "$base/src/a.ts"
  git -C "$base" add -A
  git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: 初期化'
  git -C "$base" worktree add -q -b "feat/$1" "$wt"
  git -C "$wt" update-ref refs/remotes/origin/develop HEAD
  print -r -- 'export const b = 2' > "$wt/src/b.ts"; git -C "$wt" add -A
  git -C "$wt" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'feat: b を足す'
  mkdir -p "$wt/node_modules/pkg" "$wt/node_modules/.bin" "$wt/dist"
  print -r -- '{"name":"pkg","version":"1.0.0"}' > "$wt/node_modules/pkg/package.json"
  print -r -- $'#!/bin/sh\necho pkg' > "$wt/node_modules/pkg/cli.js"; chmod +x "$wt/node_modules/pkg/cli.js"
  ln -s ../pkg/cli.js "$wt/node_modules/.bin/pkg"
  print -r -- 'built' > "$wt/dist/a.js"
  REPLY="$wt"
}
print -r -- '担当の確認だけを行う。' > "$T/prompt.md"

chk() {   # <worktree> → chk-run.sh の出力を REPLY に（確認を通して記録するか、同じ確認を省く）
  local rc=0
  REPLY="$(bash "$LANES_DIR/chk-run.sh" "$1" 49997 "$T/chk-out" 2>&1)" || rc=$?
  (( rc == 0 )) || { print -u2 -r -- "$REPLY"; fail "chk-run.sh が失敗（$rc）: $1"; }
}
query() { bash "$LANES_DIR/chk-run.sh" "$1" --query 2>/dev/null || true; }   # <worktree> → reuse=yes … / reuse=no reason=…
# 本物の起動: detach-run.sh で切り離し、起動ログは README の例と同じく worktree の logs/ の中に置く
launch() {   # <worktree> <起動ログの名前> <ランチャ> <label> [引数...]
  local wt="$1" logname="$2" name="$3" label="$4" pid n=0; shift 4
  pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/$logname" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@")" \
    || fail "detach-run.sh で起動できない: $name $label"
  # ランチャの終了まで待つ（.done を書いてから終わる）
  while kill -0 "$pid" 2>/dev/null; do
    n=$(( n + 1 )); (( n <= 600 )) || fail "$name $label が 60 秒で終わらない（pid $pid）"
    sleep 0.1
  done
  [[ -f "$wt/logs/$label.done" ]] || { cat "$wt/logs/$logname" >&2; fail "$name $label が .done を残していない"; }
  grep -qx 'EXIT:0' "$wt/logs/$label.done" || { cat "$wt/logs/$logname" "$wt/logs/$label.done" >&2; fail "$name $label が失敗で終わった"; }
}
reused() {   # <worktree> <label> <説明>: 証跡と指示書の両方が「記録を使い回した」になっていること
  local wt="$1" label="$2"
  grep -q '^- 必須検証: 親の chk-run の記録を使用（head ' "$wt/logs/$label.evidence.md" \
    || { grep '必須検証' "$wt/logs/$label.evidence.md" >&2 || true; fail "$3: 証跡が記録の使用になっていない"; }
  grep -q '親が同じ中身で実施済み' "$wt/logs/$label.prompt.md" || fail "$3: 指示書に「回さないこと」が入っていない"
  if grep -q '記録は使わない' "$wt/logs/$label.evidence.md"; then fail "$3: 証跡に「使わない」が残っている"; fi
}

# ---- 1. chk-run.sh の直後に detach-run.sh 経由で起動したレビューが、記録を使い回す（Codex・Claude とも）----
for tools in "claude codex" "claude"; do
  if [[ "$tools" == *codex* ]]; then kind=codex; else kind=claude; fi
  export LANES_TOOLS="$tools"   # 入力の指紋に環境変数が入るので、chk-run.sh とレビューを同じ環境から呼ぶ
  mkrepo "wt-$kind"; wt="$REPLY"
  chk "$wt"; [[ "$REPLY" == *'recorded=tree '*'（full）'* ]] || fail "[$kind] chk-run.sh が記録しない: $REPLY"
  [[ "$(query "$wt")" == reuse=yes* ]] || fail "[$kind] 対照: 直後の問い合わせが reuse=yes にならない（用意が誤り）"
  [[ ! -e "$wt/logs" ]] || fail "[$kind] 対照: 起動前に logs/ がある（用意が誤り）"
  launch "$wt" launch.log run-review.sh "rev-$kind-r1" --base origin/develop --round 1
  [[ -s "$wt/logs/launch.log" ]] || fail "[$kind] 起動ログが worktree の logs/ に無い（用意が誤り）"
  reused "$wt" "rev-$kind-r1" "[$kind] chk-run.sh の直後の本物の起動"
  pass "[$kind] chk-run.sh の直後に detach-run.sh 経由で起動したレビューが、親の記録を使い回す（node_modules・dist あり）"
  if (( core_only )); then print -r -- "合格 $count 件（--core）"; exit 0; fi

  # レビューが logs/ に記録を書いた後も、chk-run.sh は同じ確認を省き、問い合わせも合う
  chk "$wt"; [[ "$REPLY" == *'skip=same-tree'* ]] || fail "[$kind] レビューの後の chk-run.sh が同じ確認を省かない: $REPLY"
  [[ "$(query "$wt")" == reuse=yes* ]] || fail "[$kind] レビューの後の問い合わせが reuse=yes にならない"
  pass "[$kind] レビューが logs/ に記録を書いた後も、chk-run.sh は同じ確認を省く（skip=same-tree）"

  # 同じ worktree の 2 回目（前回の記録が残り、起動ログは追記される）と、label ごとの起動ログ
  launch "$wt" launch.log run-review.sh "rev-$kind-r2" --base origin/develop --round 2 --force
  reused "$wt" "rev-$kind-r2" "[$kind] 2 回目の起動"
  launch "$wt" "rev-$kind-r2.launch.log" run-review.sh "rev-$kind-r2" --base origin/develop --round 2 --force
  reused "$wt" "rev-$kind-r2" "[$kind] 同じ label の起動し直し（前回分を回転）"
  [[ -n "$(print -l "$wt"/logs/rev-$kind-r2.prev-*.done(N))" ]] || fail "[$kind] 前回分が回転されていない（用意が誤り）"
  pass "[$kind] 2 回目以降の起動・同じ label の起動し直し（回転した前回分あり）でも使い回す"

  # dry-run（<label>.dry-run.prompt.md を書く）の後に本物を起動しても、dry-run の表示と証跡が食い違わない
  out="$(zsh -f "$LANES_DIR/run-review.sh" "$wt" "$T/prompt.md" "rev-$kind-r3" --base origin/develop --round 2 --force --dry-run 2>&1)" \
    || { print -u2 -r -- "$out"; fail "[$kind] dry-run が失敗"; }
  [[ "$out" == *'必須検証の使い回し: yes'* ]] || { print -u2 -r -- "$out"; fail "[$kind] dry-run の表示が使い回しになっていない"; }
  [[ -f "$wt/logs/rev-$kind-r3.dry-run.prompt.md" ]] || fail "[$kind] dry-run の指示書が無い（用意が誤り）"
  launch "$wt" launch.log run-review.sh "rev-$kind-r3" --base origin/develop --round 2 --force
  reused "$wt" "rev-$kind-r3" "[$kind] dry-run の後の本物の起動"
  pass "[$kind] dry-run の後に本物を起動しても、dry-run の表示（使い回し: yes）と証跡が同じ"
done

# ---- 2. 実装レーン（Claude・Codex）が logs/ に記録を残した後でも使い回す ----
export LANES_TOOLS="claude codex"
mkrepo wt-impl; wt="$REPLY"
chk "$wt"
launch "$wt" impl.launch.log run-impl.sh impl-claude
launch "$wt" impl.launch.log run-codex.sh impl-codex
[[ -f "$wt/logs/impl-claude.json" && -f "$wt/logs/impl-codex.last.md" ]] || fail "実装レーンの記録が logs/ に無い（用意が誤り）"
[[ "$(git -C "$wt" status --porcelain)" == "" ]] || fail "実装レーンの後に未 commit の変更がある（用意が誤り）"
[[ "$(query "$wt")" == reuse=yes* ]] || fail "実装レーンの記録が入力に数えられている: $(query "$wt")"
launch "$wt" launch.log run-review.sh rev-impl-r1 --base origin/develop --round 1
reused "$wt" rev-impl-r1 "実装レーンの後のレビュー"
pass "実装レーン（run-impl.sh・run-codex.sh）が logs/ に記録を残した後でも、レビューは使い回す"
# QA レーン（run-qa.sh）と画面 QA の準備（prepare-screen-qa.sh）の記録も、台帳に載るので入力に数えない
launch "$wt" qa.launch.log run-qa.sh qa-1
zsh -f "$LANES_DIR/prepare-screen-qa.sh" "$wt" screen-1 --url "http://localhost:49997/" > "$T/screen-qa.out" 2>&1 \
  || { cat "$T/screen-qa.out" >&2; fail "prepare-screen-qa.sh が失敗（用意が誤り）"; }
[[ -f "$wt/logs/qa-1.done" && -f "$wt/logs/screen-1.prompt.md" && -f "$wt/logs/screen-1.meta.txt" ]] || fail "QA・画面 QA の記録が logs/ に無い（用意が誤り）"
[[ "$(git -C "$wt" status --porcelain)" == "" ]] || fail "QA レーンの後に未 commit の変更がある（用意が誤り）"
[[ "$(query "$wt")" == reuse=yes* ]] || fail "QA レーン・画面 QA の準備の記録が入力に数えられている: $(query "$wt")"
for owner in label:impl-claude label:impl-codex label:rev-impl-r1 label:qa-1 label:screen-1 file:launch.log file:impl.launch.log file:qa.launch.log \
    file:.rev-impl.review-state file:rev-impl.followups.md file:.review-reuse-blocked; do
  grep -qxF -- "$owner" "$wt/logs/.lanes-records" || { cat "$wt/logs/.lanes-records" >&2; fail "台帳に載っていない: $owner"; }
done
[[ "$(sort "$wt/logs/.lanes-records" | uniq -d)" == "" ]] || fail "台帳に同じ行が 2 回載っている"
pass "QA レーン・画面 QA の準備の後でも使い回す。ランチャと detach-run.sh は、書く名前の持ち主を台帳（logs/.lanes-records）に 1 回ずつ載せる"
# Gemini レーン（run-gemini.sh。.verify.log なども書く）の記録も、台帳に載るので入力に数えない。
# 構成と Gemini の設定は環境変数（指紋に入る）なので、別の worktree で chk-run.sh から同じ環境で回し、終わったら元に戻す
wt_impl="$wt"
export LANES_TOOLS="claude codex gemini" GEMINI_BIN="$STUBS/agy" GEMINI_POLL_SEC=1 GEMINI_IDLE_GRACE=1 GEMINI_IDLE_RESUME_GRACE=1 GEMINI_NOOUTPUT_SEC=20 GEMINI_PRINT_TIMEOUT=20s
mkdir -p "$H/.gemini/antigravity-cli"   # 偽の agy のログイン情報の置き場所（ランチャはこの有無でログインを判定する）
mkrepo wt-gem; wt="$REPLY"
git -C "$wt" config user.name "Test User"; git -C "$wt" config user.email you@example.com   # Gemini レーンは commit の作者設定を確かめる
chk "$wt"; [[ "$REPLY" == *'recorded=tree '* ]] || fail "Gemini の構成で記録できない: $REPLY"
launch "$wt" gem.launch.log run-gemini.sh impl-gem --verify true --allow-path src/ --no-push
[[ -f "$wt/logs/impl-gem.json" && -f "$wt/logs/impl-gem.verify.log" && -f "$wt/logs/impl-gem.evidence.md" ]] || fail "Gemini レーンの記録が logs/ に無い（用意が誤り）"
[[ "$(git -C "$wt" status --porcelain)" == "" ]] || fail "Gemini レーンの後に未 commit の変更がある（用意が誤り）"
[[ "$(query "$wt")" == reuse=yes* ]] || fail "Gemini レーンの記録が入力に数えられている: $(query "$wt")"
unset GEMINI_BIN GEMINI_POLL_SEC GEMINI_IDLE_GRACE GEMINI_IDLE_RESUME_GRACE GEMINI_NOOUTPUT_SEC GEMINI_PRINT_TIMEOUT
export LANES_TOOLS="claude codex"; wt="$wt_impl"
[[ "$(query "$wt")" == reuse=yes* ]] || fail "環境を戻したのに、元の worktree の問い合わせが reuse=yes に戻らない（用意が誤り）: $(query "$wt")"
pass "Gemini レーン（run-gemini.sh）が logs/ に記録を残した後でも使い回す"

# ---- 3. ランチャが logs/ に書く名前でも、台帳に載っていない持ち主のものは入力のまま。台帳に載せた後は数えない ----
no_reuse() {   # <説明> [期待する理由]: 今の状態で問い合わせが reuse=no（既定の理由は input-changed）
  local got; got="$(query "$wt")"
  [[ "$got" == "reuse=no reason=${2:-input-changed}" ]] || fail "$1: 使い回してしまう・理由が違う（$got）"
}
yes_again() { [[ "$(query "$wt")" == reuse=yes* ]] || fail "$1: 元に戻したのに reuse=yes に戻らない（$(query "$wt")）"; }
claim() {   # <logdir> <label:名前|file:名前>...: ランチャと同じ関数で台帳へ載せる（_common.sh の lanes_records_claim）
  LANES_DIR="$LANES_DIR" zsh -fc 'source "$LANES_DIR/_common.sh"; lanes_records_claim "$@"' claim "$@"
}
# label x・rev-1.2_b-r3 と系列 rev-a は、この worktree で一度も起動していない（台帳に無い）
typeset -a records
records=(
  x.pid x.done x.lock x.log x.json x.stderr.log x.prompt.md x.dry-run.prompt.md x.evidence.md x.last.md x.completion.json
  x.try1.json x.try1.stderr.log x.verify.log x.meta.txt x.launch.log qa-deps-root.log qa-case.md
  rev-a.followups.md .rev-a.review-state .rev-a.review-state.tmp.12345 .x.pid.12345.0123456789ab.tmp
  .x.last.md.12345.1794270246011662000.tmp .x.completion.json.12345.1794270246011662001.tmp
  x.prev-20260101-000000.pid x.prev-20260101-000000-2.done x.stderr.prev-20260101-000000.log x.prompt.prev-20260101-000000.md
  x.evidence.prev-20260101-000000.md x.completion.prev-20260101-000000.json x.last.prev-20260101-000000-3.md rev-1.2_b-r3.json
)
# 指摘の形そのもの（確認コマンドが読むデータのつもりで置いた、記録と同じ語尾の名前）
typeset -a lookalikes
lookalikes=(input.json input.log data.done settings.prompt.md report.evidence.md notes.last.md cache.lock)
for f in "${records[@]}" "${lookalikes[@]}"; do
  print -r -- "入力 $f" > "$wt/logs/$f"
  no_reuse "台帳に無い持ち主の logs/$f（名前が記録に似ているだけ）"
  rm -f "$wt/logs/$f"
done
yes_again "記録に似た名前のファイルを消した後"
pass "台帳に載っていない持ち主のファイルは、名前が記録に似ていても入力のまま（$(( ${#records} + ${#lookalikes} )) 通り。logs/input.json を含む）"
# 台帳に載せた後は、置いても書き換えても入力に数えない（全部を一度に置いて、1 つでも数えられたら使い回さなくなる）
claim "$wt/logs" label:x label:rev-1.2_b-r3 file:x.launch.log file:qa-deps-root.log file:qa-case.md file:rev-a.followups.md file:.rev-a.review-state
for f in "${records[@]}" launch.log .review-reuse-blocked; do print -r -- "記録 $f" >> "$wt/logs/$f"; done
[[ "$(query "$wt")" == reuse=yes* ]] || fail "台帳に載せた持ち主の記録が入力に数えられている: $(query "$wt")"
for f in "${records[@]}" launch.log .review-reuse-blocked; do print -r -- "書き換え" >> "$wt/logs/$f"; done
[[ "$(query "$wt")" == reuse=yes* ]] || fail "台帳に載せた持ち主の記録の書き換えが入力に数えられている: $(query "$wt")"
pass "台帳に載せた持ち主の記録（$(( ${#records} + 2 )) 通り。Gemini・QA・回転した前回分・書きかけの一時ファイルを含む）は、置いても書き換えても入力に数えない"
# 台帳に載っていても、持ち主の決まった名前でないもの（label x の、ランチャが書かない語尾）は入力のまま
for f in x.txt x.config.json.bak x.pid.txt x-extra.json xx.json x.json.tmp.12345 launch.log.tmp.12345 .x.json.12345.tmp .x.json.abc.0123.tmp; do
  print -r -- "入力" > "$wt/logs/$f"; no_reuse "logs/$f（label x の決まった名前ではない）"; rm -f "$wt/logs/$f"
done
yes_again "label x の決まった名前でないファイルを消した後"
pass "台帳に載っている label でも、ランチャが書く決まった名前でないファイルは入力のまま"
# 台帳を消す・空にすると、何も外さない（載せた事実が無ければ、記録に似た名前はすべて入力）
cp "$wt/logs/.lanes-records" "$T/ledger.bak"
rm -f "$wt/logs/.lanes-records"; no_reuse "台帳を消した後"
: > "$wt/logs/.lanes-records"; no_reuse "台帳を空にした後"
cp "$T/ledger.bak" "$wt/logs/.lanes-records"; yes_again "台帳を戻した後"
pass "台帳が無い・空なら、記録に似た名前のファイルはすべて入力として数える"

# ---- 4. logs/ に置いた、ランチャの記録でないものは入力のまま（照合をすり抜けない）----
# ほかの名前のファイル（確認コマンドが読む設定やデータのつもりで置いたもの）
for f in input.txt config.yaml data.json.bak notes.md x.prompt.txt .hidden x.review-state "x.prev-2026.log.txt"; do
  print -r -- "入力" > "$wt/logs/$f"; no_reuse "logs/$f（記録でない名前）"; rm -f "$wt/logs/$f"; yes_again "logs/$f"
done
pass "logs/ に置いた、ランチャの記録でない名前のファイルは入力のまま（置くと使い回さない）"
# 記録した後で、logs/ に置いた入力の中身が変わる（記録の時点からある入力でも、変われば合わない）
print -r -- "入力 1" > "$wt/logs/input.txt"
chk "$wt"; [[ "$REPLY" == *'recorded=tree '* ]] || fail "logs/input.txt を置いた状態で記録できない: $REPLY"
yes_again "logs/input.txt を置いて記録した直後"
print -r -- "入力 2" > "$wt/logs/input.txt"; no_reuse "logs/input.txt の中身の変更"
print -r -- "入力 1" > "$wt/logs/input.txt"; yes_again "logs/input.txt の中身を戻す"
pass "logs/ に置いた入力の中身が記録の後で変われば、使い回さない"
# フォルダの中（記録の名前でも）・下の階層の logs/（.gitignore の logs/ はどの深さにも効く）
mkdir -p "$wt/logs/sub"; print -r -- x > "$wt/logs/sub/x.log"; no_reuse "logs/sub/x.log（フォルダの中）"; rm -rf "$wt/logs/sub"; yes_again "logs/sub"
mkdir -p "$wt/src/logs"; print -r -- x > "$wt/src/logs/x.log"; no_reuse "src/logs/x.log（下の階層の logs/）"; rm -rf "$wt/src/logs"; yes_again "src/logs"
pass "logs/ の中のフォルダと、下の階層の logs/ は入力のまま"
# リンク・ハードリンク（記録の名前でも入力のまま。ランチャ自身も logs/ にこれらがあると起動しない）
ln -s ../src/a.ts "$wt/logs/link.log"; no_reuse "logs/link.log（作業ツリー内を指す symlink）"; rm -f "$wt/logs/link.log"; yes_again "logs/link.log"
ln -s "$T/prompt.md" "$wt/logs/out.log"; no_reuse "logs/out.log（外を指す symlink）" unresolvable; rm -f "$wt/logs/out.log"; yes_again "logs/out.log"
print -r -- x > "$T/hard-src.txt"; ln "$T/hard-src.txt" "$wt/logs/hard.log"
no_reuse "logs/hard.log（ハードリンク）"; rm -f "$wt/logs/hard.log"; yes_again "logs/hard.log"
pass "logs/ の symlink・ハードリンクは、記録の名前でも入力のまま"
# 依存・生成物の変化（今までどおり）
print -r -- '{"name":"pkg","version":"1.0.1"}' > "$wt/node_modules/pkg/package.json"; no_reuse "node_modules の変更"
print -r -- '{"name":"pkg","version":"1.0.0"}' > "$wt/node_modules/pkg/package.json"; yes_again "node_modules を戻す"
print -r -- 'rebuilt' > "$wt/dist/a.js"; no_reuse "dist の変更"
print -r -- 'built' > "$wt/dist/a.js"; yes_again "dist を戻す"
pass "依存（node_modules）・生成物（dist）が記録の後で変われば、今までどおり使い回さない"
# 追跡している logs/ のファイル（.gitignore より追跡が勝つ）の変更は、未 commit の変更として止める
print -r -- 'tracked' > "$wt/logs/tracked.log"; git -C "$wt" add -f logs/tracked.log
git -C "$wt" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: logs/ のファイルを追跡する'
chk "$wt"; [[ "$REPLY" == *'recorded=tree '* ]] || fail "追跡ファイルを足した tree を記録できない: $REPLY"
yes_again "追跡ファイルを足して記録した直後"
print -r -- 'changed' > "$wt/logs/tracked.log"; no_reuse "追跡している logs/tracked.log の変更" uncommitted
git -C "$wt" checkout -q -- logs/tracked.log; yes_again "追跡ファイルを戻す"
pass "追跡している logs/ のファイルの変更は、記録の名前でも未 commit の変更として止める"

# ---- 5. 環境変数の条件は緩めていない（起動ログのせいではない違いは残る）----
[[ "$(export EXTRA_FOR_REUSE_TEST=1; query "$wt")" == "reuse=no reason=input-changed" ]] || fail "環境変数が違うのに使い回す"
pass "対照: 環境変数が違えば使い回さない（指紋の条件は緩めていない）"
# 親のシェルに API キーの環境変数があっても、chk-run.sh とレビューを同じ環境から呼べば使い回す
# （入口とランチャは CLI の子に渡す前に外し、問い合わせのときだけ元に戻す。値は鍵ではないダミー）
mkrepo wt-key; wt="$REPLY"
export ANTHROPIC_API_KEY=dummy
chk "$wt"; [[ "$REPLY" == *'recorded=tree '* ]] || fail "API キーの環境変数がある状態で記録できない: $REPLY"
launch "$wt" launch.log run-review.sh rev-key-r1 --base origin/develop --round 1
reused "$wt" rev-key-r1 "API キーの環境変数があるシェルからの起動"
pass "親のシェルに API キーの環境変数があっても、同じ環境から呼べば使い回す（detach-run.sh・入口経由）"
# 起動のときだけ外すと、環境変数の違いとして使い回さない。証跡に理由と、人が読める一言が出る
unset ANTHROPIC_API_KEY
launch "$wt" launch.log run-review.sh rev-key-r2 --base origin/develop --round 2 --force
grep -q '^- 必須検証: レビューの中で回すよう指示（親の chk-run の記録は使わない: input-changed＝記録の後で入力が変わった' "$wt/logs/rev-key-r2.evidence.md" \
  || { grep '必須検証' "$wt/logs/rev-key-r2.evidence.md" >&2 || true; fail "起動のときだけ環境変数を外したのに、証跡が「使わない: input-changed」と一言になっていない"; }
if grep -q '親が同じ中身で実施済み' "$wt/logs/rev-key-r2.prompt.md"; then fail "使い回さないのに、指示書に「回さないこと」が入っている"; fi
pass "起動のときだけ環境変数を外すと使い回さず、証跡に理由（input-changed）と一言が出る（証跡と指示書が食い違わない）"

# ---- 6. 指摘の再現: 確認コマンドが logs/input.json を読む構成で、中身を変えたら古い成功の記録を使い回さない ----
# （名前だけで外していたときは、logs/input.json も「ランチャの記録」として指紋から外れ、失敗する内容に変えても skip=same-tree になった）
mkrepo wt-input; wt="$REPLY"
print -r -- $'import pathlib, sys\nsys.exit(1 if pathlib.Path("logs/input.json").read_text().strip() == "fail" else 0)' > "$wt/check.py"
git -C "$wt" add check.py
git -C "$wt" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: logs/input.json を読む確認を足す'
mkdir -p "$wt/logs"; print -r -- ok > "$wt/logs/input.json"
export LANES_CHECK_CMD='python3 check.py'
chk "$wt"; [[ "$REPLY" == *'check=0（LANES_CHECK_CMD）'*'recorded=tree '* ]] || fail "logs/input.json を読む確認の成功を記録できない: $REPLY"
chk "$wt"; [[ "$REPLY" == *'skip=same-tree'* ]] || fail "入力が同じなのに省かない（用意が誤り）: $REPLY"
# 本物のレビューを起動しても（ランチャの記録が logs/ に増えても）、入力が同じ間は使い回す
launch "$wt" launch.log run-review.sh rev-input-r1 --base origin/develop --round 1
reused "$wt" rev-input-r1 "logs/input.json が同じ間の起動"
# 入力を失敗する内容に変える。古い成功の記録は使い回さず、回し直して失敗する
print -r -- fail > "$wt/logs/input.json"
no_reuse "logs/input.json を失敗する内容に変えた後の問い合わせ"
rc=0; out="$(bash "$LANES_DIR/chk-run.sh" "$wt" 49997 "$T/chk-out" 2>&1)" || rc=$?
[[ "$out" != *'skip='* && "$out" == *'check=1（LANES_CHECK_CMD）'* && "$out" != *'recorded='* && "$rc" == 1 ]] \
  || { print -u2 -r -- "$out"; fail "logs/input.json を失敗する内容に変えたのに、古い成功の記録を使い回した・失敗にならない（rc=$rc）"; }
launch "$wt" launch.log run-review.sh rev-input-r2 --base origin/develop --round 2 --force
grep -q '^- 必須検証: レビューの中で回すよう指示（親の chk-run の記録は使わない: input-changed' "$wt/logs/rev-input-r2.evidence.md" \
  || { grep '必須検証' "$wt/logs/rev-input-r2.evidence.md" >&2 || true; fail "入力が変わったのに、レビューの証跡が記録の使用になっている"; }
# 元に戻せば、また使い回す（入力の中身で決まる。ランチャの記録が増えたことは理由にならない）
print -r -- ok > "$wt/logs/input.json"; yes_again "logs/input.json を元に戻した後"
export LANES_CHECK_CMD=/usr/bin/true
pass "確認コマンドが読む logs/input.json を失敗する内容に変えたら、古い成功の記録を使い回さない（chk-run.sh は回し直して失敗・レビューも使わない）"

# ---- 7. 台帳の書き方: リンクの台帳は辿らない・使わない。detach-run.sh は worktree の logs/ の直下のときだけ載せる ----
mkrepo wt-ledger; wt="$REPLY"
chk "$wt"
launch "$wt" launch.log run-review.sh rev-ledger-r1 --base origin/develop --round 1
yes_again "台帳のテストの用意"
cp "$wt/logs/.lanes-records" "$T/ledger-copy"; cp "$T/ledger-copy" "$T/ledger-before"
# symlink の台帳: chk-run.sh は使わない（外を指すリンクとして入力に数える）。ランチャの関数・detach-run.sh はその先へ書かない
rm -f "$wt/logs/.lanes-records"; ln -s "$T/ledger-copy" "$wt/logs/.lanes-records"
no_reuse "symlink の台帳" unresolvable
note="$(claim "$wt/logs" label:evil 2>&1)" || fail "台帳へ載せる関数が失敗で返った（起動を止めない決まり）"
[[ "$note" == *'NOTE: ランチャの記録の台帳'*'載せられない'* ]] || fail "symlink の台帳に載せられないことを知らせない: $note"
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/evil.launch.log" /usr/bin/true)" || fail "symlink の台帳があると detach-run.sh が起動できない"
cmp -s "$T/ledger-copy" "$T/ledger-before" || fail "symlink の台帳を辿って、その先のファイルへ書いた"
[[ -f "$wt/logs/evil.launch.log" ]] || fail "symlink の台帳のとき、detach-run.sh が起動ログを書いていない（起動は続ける決まり）"
rm -f "$wt/logs/.lanes-records" "$wt/logs/evil.launch.log"
# ハードリンクの台帳: 同じく使わない・書かない
ln "$T/ledger-copy" "$wt/logs/.lanes-records"
no_reuse "ハードリンクの台帳"
claim "$wt/logs" label:evil 2>/dev/null
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/evil.launch.log" /usr/bin/true)" || fail "ハードリンクの台帳があると detach-run.sh が起動できない"
cmp -s "$T/ledger-copy" "$T/ledger-before" || fail "ハードリンクの台帳へ書いた"
rm -f "$wt/logs/.lanes-records" "$wt/logs/evil.launch.log"
cp "$T/ledger-before" "$wt/logs/.lanes-records"; yes_again "台帳を普通のファイルに戻した後"
pass "symlink・ハードリンクの台帳は chk-run.sh が使わず（記録を入力として数える）、ランチャと detach-run.sh もその先へ書かない"
# 不正な名前は載せない（/ や改行を含む名前・知らない種類）
before="$(cat "$wt/logs/.lanes-records")"
claim "$wt/logs" "file:../outside.json" 2>/dev/null; claim "$wt/logs" "file:a/b.log" 2>/dev/null; claim "$wt/logs" "other:x" 2>/dev/null
claim "$wt/logs" $'file:a\nlabel:input' 2>/dev/null; claim "$wt/logs" "label:" 2>/dev/null
[[ "$(cat "$wt/logs/.lanes-records")" == "$before" ]] || fail "不正な名前（/・改行・知らない種類・空）を台帳に載せた"
# 台帳に / を含む行・label の形でない行があっても、chk-run.sh は外さない（手で書き足しても logs/ の直下の決まった名前だけ）
print -r -- 'label:../src' >> "$wt/logs/.lanes-records"; print -r -- 'file:sub/x.log' >> "$wt/logs/.lanes-records"
mkdir -p "$wt/logs/sub"; print -r -- x > "$wt/logs/sub/x.log"; no_reuse "台帳に logs/ の下のフォルダの名前を書き足した"
rm -rf "$wt/logs/sub"; cp "$T/ledger-before" "$wt/logs/.lanes-records"; yes_again "台帳と logs/ を戻した後"
pass "不正な名前（/・改行・知らない種類・空）は台帳に載せず、台帳に書いてあっても logs/ の直下の名前しか外さない"
# detach-run.sh は、worktree の logs/ の直下の起動ログだけを台帳に載せる（同じ名前は 2 回載せない。ほかの場所には台帳を作らない）
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/again.launch.log" /usr/bin/true)" || fail "detach-run.sh で起動できない"
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/again.launch.log" /usr/bin/true)" || fail "detach-run.sh で 2 回目を起動できない"
[[ "$(grep -cxF 'file:again.launch.log' "$wt/logs/.lanes-records")" == 1 ]] || fail "detach-run.sh が起動ログの名前を 1 回だけ載せていない"
yes_again "detach-run.sh が起動ログを書いた後"
mkdir -p "$T/elsewhere"
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$T/elsewhere/launch.log" /usr/bin/true)" || fail "worktree の外の起動ログで起動できない"
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$T/elsewhere/logs/launch.log" /usr/bin/true)" || fail "worktree でない logs/ の起動ログで起動できない"
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$wt/src/logs/launch.log" /usr/bin/true)" || fail "下の階層の logs/ の起動ログで起動できない"
[[ ! -e "$T/elsewhere/.lanes-records" && ! -e "$T/elsewhere/logs/.lanes-records" && ! -e "$wt/src/logs/.lanes-records" ]] \
  || fail "detach-run.sh が、worktree の logs/ の直下でない場所に台帳を作った"
no_reuse "下の階層の logs/ に置いた起動ログ（入力のまま）"
rm -rf "$wt/src/logs"; yes_again "下の階層の logs/ を消した後"
pass "detach-run.sh は worktree の logs/ の直下の起動ログだけを台帳に載せる（同じ名前は 1 回。ほかの場所には台帳を作らない）"

# ---- 8. FIFO（名前付きパイプ）で止まらない・辿らない: 台帳と起動ログ ----
# 経緯: 台帳を O_RDONLY で開いていたので、台帳が FIFO で書き手がいないと open が返らず、種別の検査（普通のファイル以外は使わない）に
#       届かなかった。chk-run.sh と、--query を同期で呼ぶレビューの起動が止まった。detach-run.sh の起動ログ（O_WRONLY）も同じ形で、
#       FIFO だと読み手が現れるまで待ち続け、読み手がいればその先へ書いた。どちらも待たずに開き、開いた後で種別を確かめる。
# 時間内に終わること。<秒> <待たせうる FIFO> <説明> <コマンド...> → stdout を REPLY、stderr を within_err、終了コードを within_rc に入れる。
# macOS に timeout コマンドは無いので、裏で動かして終了を待つ。時間切れのときは、FIFO を読み手と書き手の両方として少しの間だけ開き、
# open で待っているプロセスを起こしてから失敗にする（待ち続けるプロセスを残さない）
within() {
  local limit="$1" fifo="$2" what="$3" out="$T/within.out" pid n=0; shift 3
  rm -f "$out" "$out.err" "$out.rc"
  { local rc=0; "$@" > "$out" 2> "$out.err" || rc=$?; print -r -- "$rc" > "$out.rc" } &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    n=$(( n + 1 ))
    if (( n > limit * 10 )); then
      python3 -I -c 'import os, sys, time
r = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
w = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
time.sleep(2)' "$fifo" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      fail "$what: $limit 秒たっても返らない（FIFO を開こうとして待ち続けている）"
    fi
    sleep 0.1
  done
  n=0; while [[ ! -s "$out.rc" ]]; do n=$(( n + 1 )); (( n <= 50 )) || fail "$what: 終了コードを取れない"; sleep 0.1; done
  within_rc="$(<"$out.rc")"; within_err="$(<"$out.err")"; REPLY="$(<"$out")"
}
mkrepo wt-fifo; wt="$REPLY"
chk "$wt"
launch "$wt" launch.log run-review.sh rev-fifo-r1 --base origin/develop --round 1
yes_again "FIFO のテストの用意"
cp "$wt/logs/.lanes-records" "$T/fifo-ledger-before"
fifo="$wt/logs/.lanes-records"
rm -f "$fifo"; mkfifo "$fifo"
# 問い合わせ: 待たずに返り、FIFO の台帳は使わない（何も外さないので、logs/ のランチャの記録が入力に数えられて合わなくなる）
within 60 "$fifo" "FIFO の台帳があるときの問い合わせ（chk-run.sh --query）" bash "$LANES_DIR/chk-run.sh" "$wt" --query
[[ "$REPLY" == "reuse=no reason=input-changed" ]] || fail "FIFO の台帳を使った・理由が違う（$REPLY / rc=$within_rc）"
pass "台帳が FIFO（書き手なし）でも、chk-run.sh --query は待たずに返り、台帳を使わない（reuse=no reason=input-changed）"
# 回すほう: 待たずに入力を取り、合う記録が無いので確認コマンドを回し直す
within 60 "$fifo" "FIFO の台帳があるときの chk-run.sh" bash "$LANES_DIR/chk-run.sh" "$wt" 49997 "$T/chk-out"
[[ "$within_rc" == 0 && "$REPLY" != *'skip='* && "$REPLY" == *'check=0（LANES_CHECK_CMD）'* ]] \
  || { print -u2 -r -- "$REPLY"; fail "FIFO の台帳があるとき、chk-run.sh が回し直さない・失敗する（rc=$within_rc）"; }
pass "台帳が FIFO でも、chk-run.sh は待たずに確認コマンドを回す"
# レビューの起動: 問い合わせで止まらず、logs/ に特殊ファイルがあることを理由に起動を断る（exit 2）
within 60 "$fifo" "FIFO の台帳があるときのレビューの起動" \
  zsh -f "$LANES_DIR/run-review.sh" "$wt" "$T/prompt.md" rev-fifo-r2 --base origin/develop --round 2 --force
[[ "$within_rc" == 2 && "$within_err" == *'logs/.lanes-records'*'特殊ファイル'* ]] \
  || { print -u2 -r -- "$within_err"; fail "FIFO の台帳があるとき、レビューの起動が「logs/ に特殊ファイルがある」で止まらない（rc=$within_rc）"; }
[[ ! -e "$wt/logs/rev-fifo-r2.pid" && ! -e "$wt/logs/rev-fifo-r2.done" ]] || fail "起動を断ったのに、レビューの記録を書いた"
pass "台帳が FIFO でも、レビューの起動は問い合わせで止まらず、logs/ の特殊ファイルを理由に起動を断る（exit 2）"
# 台帳へ載せる側（ランチャの関数・detach-run.sh）: 待たずに返り、FIFO へは書かない。起動は止めない
within 60 "$fifo" "FIFO の台帳へ載せる関数（lanes_records_claim）" claim "$wt/logs" label:evil
[[ "$within_rc" == 0 && "$within_err" == *'NOTE: ランチャの記録の台帳'*'載せられない'* ]] \
  || fail "FIFO の台帳に載せられないことを知らせない・失敗で返った（rc=$within_rc）: $within_err"
within 60 "$fifo" "FIFO の台帳があるときの detach-run.sh" zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/evil.launch.log" /usr/bin/true
[[ "$within_rc" == 0 && -f "$wt/logs/evil.launch.log" ]] || fail "FIFO の台帳があると detach-run.sh が起動できない（起動は続ける決まり。rc=$within_rc）"
[[ -p "$fifo" ]] || fail "FIFO の台帳が別の物に置き換わった"
rm -f "$fifo" "$wt/logs/evil.launch.log"
cp "$T/fifo-ledger-before" "$wt/logs/.lanes-records"; yes_again "台帳を普通のファイルに戻した後"
pass "台帳が FIFO でも、台帳へ載せる側（lanes_records_claim・detach-run.sh）は待たずに返り、起動を止めない"
# 起動ログが FIFO（読み手なし）: 待たずに起動を断り（exit 2）、コマンドを起動しない
log="$wt/logs/pipe.launch.log"; mkfifo "$log"
within 60 "$log" "FIFO の起動ログ（読み手なし）" zsh -f "$LANES_DIR/detach-run.sh" "$log" /usr/bin/touch "$T/started-fifo-log"
sleep 0.5
[[ "$within_rc" == 2 && "$REPLY" == "" && ! -e "$T/started-fifo-log" ]] || fail "FIFO の起動ログで起動を断らない・コマンドを起動した（rc=$within_rc）"
[[ "$within_err" == *'ERROR: 起動ログ'* && "$within_err" != *"$T"* ]] || fail "FIFO の起動ログを断った理由が出ない・パスを出した: $within_err"
# 起動ログが FIFO（読み手あり）: 開けてしまっても、その先へ書かず・コマンドの出力もつながない
cat "$log" > "$T/fifo-read.out" &
reader=$!
sleep 0.5
within 60 "$log" "FIFO の起動ログ（読み手あり）" zsh -f "$LANES_DIR/detach-run.sh" "$log" /usr/bin/touch "$T/started-fifo-log"
sleep 0.5
if kill -0 "$reader" 2>/dev/null; then kill "$reader" 2>/dev/null || true; fi
[[ "$within_rc" == 2 && ! -e "$T/started-fifo-log" ]] || fail "読み手のいる FIFO の起動ログで起動を断らない・コマンドを起動した（rc=$within_rc）"
[[ ! -s "$T/fifo-read.out" ]] || fail "FIFO の起動ログの先（読み手）へ書いた"
rm -f "$log"
pass "起動ログが FIFO なら、detach-run.sh は待たずに起動を断る（読み手がいても、その先へ書かない・コマンドを起動しない）"
# 起動ログがハードリンク: 追記が別の名前のファイルにも届くので、書かずに起動を断る
print -r -- keep > "$T/hard-target.txt"; ln "$T/hard-target.txt" "$wt/logs/hard.launch.log"
within 60 "" "ハードリンクの起動ログ" zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/hard.launch.log" /usr/bin/touch "$T/started-hard-log"
sleep 0.5
[[ "$within_rc" == 2 && ! -e "$T/started-hard-log" && "$(<"$T/hard-target.txt")" == keep ]] \
  || fail "ハードリンクの起動ログへ書いた・コマンドを起動した（rc=$within_rc）"
rm -f "$wt/logs/hard.launch.log"
# 起動ログが symlink: 今までどおり辿らずに断る
print -r -- keep > "$T/link-target.txt"; ln -s "$T/link-target.txt" "$wt/logs/link.launch.log"
within 60 "" "symlink の起動ログ" zsh -f "$LANES_DIR/detach-run.sh" "$wt/logs/link.launch.log" /usr/bin/touch "$T/started-link-log"
sleep 0.5
[[ "$within_rc" == 2 && ! -e "$T/started-link-log" && "$(<"$T/link-target.txt")" == keep ]] \
  || fail "symlink の起動ログを辿って書いた・コマンドを起動した（rc=$within_rc）"
rm -f "$wt/logs/link.launch.log"
pass "起動ログがハードリンク・symlink なら、detach-run.sh はその先へ書かずに起動を断る"
# 対照: 普通のファイル（新しく作る・追記する）と /dev/null（文字デバイス）は今までどおり使える
for log in "$wt/logs/plain.launch.log" "$wt/logs/plain.launch.log" /dev/null; do
  rm -f "$T/started-plain-log"
  within 60 "" "普通の起動ログ（$log）" zsh -f "$LANES_DIR/detach-run.sh" "$log" /usr/bin/touch "$T/started-plain-log"
  [[ "$within_rc" == 0 && "$REPLY" == <-> ]] || fail "起動ログ $log で起動できない（rc=$within_rc）: $within_err"
  n=0; while [[ ! -e "$T/started-plain-log" ]]; do n=$(( n + 1 )); (( n <= 100 )) || fail "起動ログ $log で、コマンドが起動していない"; sleep 0.1; done
done
[[ "$(grep -c '^=== detach-run ===$' "$wt/logs/plain.launch.log")" == 2 ]] || fail "普通の起動ログへ 2 回分を追記していない"
yes_again "起動ログのテストの後"
pass "対照: 普通のファイルの起動ログ（新規・追記）と /dev/null は、今までどおり起動できる"

# ---- 9. python3 の入口が環境変数を書き換える Mac でも使い回す。結果は、回す場所（普段のシェル・chk-run.sh の中）で変わらない ----
# 経緯: detach-run.sh は python3 でコマンドを切り離す。Mac の python3 は、本物の前に入口を通ることが多い（Xcode の /usr/bin/python3・
#       pyenv の shims など）。入口は、本物を起動する前に環境変数を書き換える（Xcode: MANPATH の先頭へ通るたびに足す・SDKROOT などを足す /
#       pyenv: PYENV_DIR に最初に通った場所を入れる・PATH の先頭に本物の場所を足す）。detach-run.sh が python3 から見えた環境変数を
#       そのまま子へ渡していたので、起動したランチャだけが呼び出し元と違う環境になり、指紋（環境変数が入る）が合わず、
#       本物の起動のたびに「使わない: input-changed」になった。
#       このテストも、回す場所で結果が変わった: 入口を一度通った後の環境（レーンの中・chk-run.sh の確認コマンドの中）から回すと緑、
#       普段のシェルから回すと赤（pyenv の形は、一度通ると PATH の先頭が本物になり、そこから先は入口を通らないので、赤が隠れた）。
# どの Mac でも同じ形になるよう、通るたびに環境変数を書き換える偽の入口を PATH の先頭に置いて確かめる。
# 偽の入口が起動する「本物」は、python3 自身が答える実体（sys.executable）にする。PATH から見つかる python3 が pyenv の shims のような
# 入口だと、その入口が PATH の先頭に本物の場所を足すので、2 回目から偽の入口を通らなくなる（毎回通る形にならない）
real_py="$(python3 -I -c 'import sys; print(sys.executable)')" || fail "python3 を起動できない（用意が誤り）"
[[ -n "$real_py" && -f "$real_py" && -x "$real_py" ]] || fail "本物の python3 の場所が分からない（用意が誤り）"
mkdir -p "$T/pyshim"
cat > "$T/pyshim/python3" <<EOF_PYSHIM
#!/bin/sh
# 偽の python3 の入口（テスト用）。本物の python3 を起動する前に環境変数を書き換える
# FAKE_PY_GROW: 通るたびに伸びる（Xcode の入口の MANPATH と同じ形）
FAKE_PY_GROW="hop:\${FAKE_PY_GROW-}"; export FAKE_PY_GROW
# FAKE_PY_DIR: 最初に通った場所を覚える（pyenv の入口の PYENV_DIR と同じ形）
[ -n "\${FAKE_PY_DIR-}" ] || FAKE_PY_DIR="\$PWD"; export FAKE_PY_DIR
exec ${(qq)real_py} "\$@"
EOF_PYSHIM
chmod +x "$T/pyshim/python3"
unset FAKE_PY_GROW FAKE_PY_DIR
export PATH="$T/pyshim:$PATH" LANES_TOOLS="claude codex"
# 用意の確認: 1 回通ると hop:、python3 の中からもう 1 回通ると hop:hop:（通るたびに伸びる）
[[ "$(python3 -I -c 'import os, subprocess; print(os.environ.get("FAKE_PY_GROW"), flush=True); subprocess.run(["python3", "-I", "-c", "import os; print(os.environ.get(\"FAKE_PY_GROW\"))"])' | tr '\n' ' ')" == "hop: hop:hop: " ]] \
  || fail "偽の python3 の入口が効いていない（用意が誤り）"
# 起動する場所を worktree 以外にする（pyenv の形: 入口が覚える「最初に通った場所」が、chk-run.sh のとき（worktree）と違う）
cd "$T"
mkrepo wt-pyshim; wt="$REPLY"
chk "$wt"; [[ "$REPLY" == *'recorded=tree '* ]] || fail "偽の入口を置いた環境で記録できない: $REPLY"
launch "$wt" launch.log run-review.sh rev-pyshim-r1 --base origin/develop --round 1
reused "$wt" rev-pyshim-r1 "python3 の入口が環境変数を書き換える環境での起動"
pass "python3 の入口が通るたびに環境変数を書き換えても（Xcode・pyenv の形）、detach-run.sh 経由で起動したレビューは親の記録を使い回す"

# detach-run.sh は、呼び出し元の環境変数をそのまま子へ渡す（入口が足した・書き換えた分を渡さない）。
# 直に起動したときと比べる。値は出さず、全体の指紋と名前の一覧で比べる（SHLVL は zsh を 1 つ挟むたびに増えるので除く）。
# 指紋を取る側は、名前の付いた変数を使わない（同じ名前の環境変数と取り違えない）
cat > "$T/envsum.zsh" <<'EOF_ENVSUM'
#!/bin/zsh -f
set -- ${${(ko)parameters[(R)*export*]}:#SHLVL}
print -r -- "指紋 $(while (( $# )); do print -rn -- "$1=${(P)1}"$'\0'; shift; done | shasum -a 256 | cut -d' ' -f1)"
print -r -- "FAKE_PY_GROW=${FAKE_PY_GROW-（無し）} FAKE_PY_DIR=${FAKE_PY_DIR+（あり）}"
print -rl -- "$@"
EOF_ENVSUM
# そのまま渡りにくい形の環境変数も置く: detach-run.sh の中の変数と同じ名前になりうるもの（k・log）・空の値・改行や = や日本語を含む値
export k=呼び出し元の値 log=呼び出し元の値 FAKE_ENV_EMPTY= FAKE_ENV_TEXT=$'1 行目\n2 行目 = 日本語'
zsh -f "$T/envsum.zsh" > "$T/env-direct.txt" || fail "環境変数の指紋を取れない（用意が誤り）"
pid="$(zsh -f "$LANES_DIR/detach-run.sh" "$T/env-detached.log" zsh -f "$T/envsum.zsh")" || fail "detach-run.sh で起動できない"
unset k log FAKE_ENV_EMPTY FAKE_ENV_TEXT
n=0; while kill -0 "$pid" 2>/dev/null; do n=$(( n + 1 )); (( n <= 100 )) || fail "環境変数の指紋を取るコマンドが 10 秒で終わらない"; sleep 0.1; done
sed '1,/^=== detach-run ===$/d' "$T/env-detached.log" > "$T/env-detached.txt"
grep -q '^指紋 [0-9a-f]\{64\}$' "$T/env-direct.txt" && grep -qx 'FAKE_PY_GROW=（無し） FAKE_PY_DIR=' "$T/env-direct.txt" \
  && grep -qx k "$T/env-direct.txt" && grep -qx log "$T/env-direct.txt" && grep -qx FAKE_ENV_EMPTY "$T/env-direct.txt" \
  || fail "直に起動したときの環境変数の指紋が取れていない（用意が誤り）"
cmp -s "$T/env-direct.txt" "$T/env-detached.txt" \
  || { diff "$T/env-direct.txt" "$T/env-detached.txt" >&2 || true; fail "detach-run.sh 経由で起動したコマンドの環境変数が、直に起動したときと違う（python3 の入口が書き換えた分が子に渡っている・呼び出し元の変数が落ちた・値が変わった）"; }
pass "detach-run.sh は、呼び出し元の環境変数をそのまま子へ渡す（python3 の入口が足した・書き換えた分を渡さない。k・log という名前や空の値・改行を含む値も、直に起動したときと同じ）"

# 同じ確認（--core = 1 の最初の確認だけ）を、そのまま回しても、chk-run.sh の確認コマンドの中から回しても、同じ結果（緑）になる。
# chk-run.sh は確認コマンドを python3 の監督役の下で起動するので、確認コマンドの中は「入口を一度通った後」の環境になる
# （LANES_CHK_ENV_LOADED・lanes.env が export する設定キー・LANES_CHECK_PORT・LANES_CHECK_OUTDIR も持ち込まれ、作業場所は worktree）
out="$(zsh -f "$SELF" --core 2>&1)" || { print -u2 -r -- "$out"; fail "そのまま回した --core が赤"; }
[[ "$out" == *'合格 1 件（--core）'* ]] || { print -u2 -r -- "$out"; fail "そのまま回した --core が、確認を 1 件通していない（用意が誤り）"; }
mkrepo wt-outer; wt="$REPLY"
rc=0; out="$(LANES_CHECK_CMD="zsh -f ${(qq)SELF} --core" bash "$LANES_DIR/chk-run.sh" "$wt" 49996 "$T/chk-out-outer" 2>&1)" || rc=$?
[[ "$rc" == 0 && "$out" == *'check=0（LANES_CHECK_CMD）'* ]] \
  || { print -u2 -r -- "$out"; tail -5 "$T/chk-out-outer/check.log" >&2 2>/dev/null || true; fail "chk-run.sh の確認コマンドの中から回した --core が赤（回す場所で結果が変わる。rc=$rc）"; }
grep -qx '合格 1 件（--core）' "$T/chk-out-outer/check.log" || fail "chk-run.sh の中から回した --core が、確認を 1 件通していない（用意が誤り）"
pass "同じ確認（--core）を、そのまま回しても chk-run.sh の確認コマンドの中から回しても、結果は同じ（緑。回す場所で変わらない）"

print -r -- "合格 $count 件"
