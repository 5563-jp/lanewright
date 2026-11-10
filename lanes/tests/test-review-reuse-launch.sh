#!/bin/zsh -f
# 親の chk-run.sh の記録を、本物の起動（dry-run でない）のレビューが使い回せることのテスト。
# 経緯: chk-run.sh が成功を記録した直後に detach-run.sh 経由でレビューを起動すると、証跡が毎回
#       「親の chk-run の記録は使わない: input-changed」になった。detach-run.sh が起動ログ（logs/launch.log）を
#       ランチャの問い合わせより先に書き、その無視対象のファイルが入力の指紋に入っていたため。
#       ランチャの記録（logs/ の直下の決まった名前のファイル）は指紋に入れないようにした。
# 確かめること:
#   1. node_modules と dist のある worktree で、chk-run.sh → detach-run.sh 経由の本物の起動（Codex・Claude のレビューとも）が
#      記録を使い回す（証跡と指示書の両方）。レビューの後も chk-run.sh は同じ確認を省く（skip=same-tree）
#   2. dry-run の後・実装レーンの後・同じ worktree の 2 回目以降の起動でも使い回す
#   3. ランチャが logs/ に書く名前（Gemini・QA・回転した前回分を含む）は、どれも入力に数えない
#   4. logs/ に置いた、ランチャの記録でないもの（ほかの名前・フォルダの中・リンク・ハードリンク・追跡ファイル・
#      下の階層の logs/）と、依存・生成物の変化では、今までどおり使い回さない（照合をすり抜けない）
# 偽の CLI（tests/stubs）と一時リポだけを使う。本物の CLI・ネットワークには触らない。全データを一時領域に置く。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
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
  ! grep -q '記録は使わない' "$wt/logs/$label.evidence.md" || fail "$3: 証跡に「使わない」が残っている"
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

# ---- 3. ランチャが logs/ に書く名前は、どれも入力に数えない（Gemini・QA・画面 QA・回転した前回分・書きかけの一時ファイル）----
typeset -a records
records=(
  x.pid x.done x.lock x.log x.json x.stderr.log x.prompt.md x.dry-run.prompt.md x.evidence.md x.last.md x.completion.json
  x.try1.json x.try1.stderr.log x.verify.log x.meta.txt x.launch.log launch.log qa-deps-root.log qa-case.md
  rev-a.followups.md .rev-a.review-state .rev-a.review-state.tmp.12345 .review-reuse-blocked .x.pid.12345.0123456789ab.tmp
  x.prev-20260101-000000.pid x.prev-20260101-000000-2.done x.stderr.prev-20260101-000000.log x.prompt.prev-20260101-000000.md
  x.evidence.prev-20260101-000000.md x.completion.prev-20260101-000000.json x.last.prev-20260101-000000-3.md rev-1.2_b-r3.json
)
for f in "${records[@]}"; do
  print -r -- "記録 $f" > "$wt/logs/$f"
  [[ "$(query "$wt")" == reuse=yes* ]] || fail "ランチャの記録の名前が入力に数えられている: logs/$f → $(query "$wt")"
  print -r -- "書き換え" >> "$wt/logs/$f"
  [[ "$(query "$wt")" == reuse=yes* ]] || fail "ランチャの記録の書き換えが入力に数えられている: logs/$f"
done
pass "ランチャが logs/ に書く名前（${#records} 通り。Gemini・QA・回転した前回分を含む）は、置いても書き換えても入力に数えない"

# ---- 4. logs/ に置いた、ランチャの記録でないものは入力のまま（照合をすり抜けない）----
no_reuse() {   # <説明> [期待する理由]: 今の状態で問い合わせが reuse=no（既定の理由は input-changed）
  local got; got="$(query "$wt")"
  [[ "$got" == "reuse=no reason=${2:-input-changed}" ]] || fail "$1: 使い回してしまう・理由が違う（$got）"
}
yes_again() { [[ "$(query "$wt")" == reuse=yes* ]] || fail "$1: 元に戻したのに reuse=yes に戻らない（$(query "$wt")）"; }
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

# ---- 5. 対照: 環境変数が違えば、今までどおり使い回さない（起動ログのせいではない違いは残る）----
[[ "$(export EXTRA_FOR_REUSE_TEST=1; query "$wt")" == "reuse=no reason=input-changed" ]] || fail "環境変数が違うのに使い回す"
pass "対照: 環境変数が違えば使い回さない（指紋の条件は緩めていない）"

print -r -- "合格 $count 件"
