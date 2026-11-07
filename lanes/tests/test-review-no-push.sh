#!/bin/zsh -f
# レビュー・QA の子プロセスから push できないこと（lanes_block_git_transport）のテスト。
# 一時リポとローカルの bare リポ（作業ツリーを持たない受け側のリポ）だけを使い、偽の CLI（tests/stubs）が子として push を試す。
# あわせて、レビュー・QA の子が裏に残したプロセス（テスト用のサーバーなどの孫）を、ランチャの終了までに監督役が回収することも確かめる。
# 本物の CLI・ネットワークには触らない。全データを一時領域に置く。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-nopush.XXXXXX")"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない（LANES_ で始まる変数・CLI のパス・モデル指定・git の通信の制限を外す）
for v in ${(k)parameters[(I)LANES_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN CLAUDE_MODEL CODEX_MODEL GEMINI_MODEL CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT \
    CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX XDG_CONFIG_HOME XDG_STATE_HOME GIT_ALLOW_PROTOCOL; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$T/no-such.conf" LANES_NOTIFY=0
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex" STUB_RUN_RC="$T/run.rc"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

# ---- 用意: 一時リポ・worktree・受け側の bare リポ ----
base="$T/base"; wt="$T/wt"; bare="$T/remote.git"
git init -q -b main "$base"; lanes_test_assert_repo "$base"
git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit --allow-empty -qm 'test: 初期化'
git init -q --bare "$bare"
git -C "$base" remote add origin "$bare"
git -C "$base" worktree add -q -b feat/test "$wt"
git -C "$wt" update-ref refs/remotes/origin/develop HEAD
print -r -- '担当の確認だけを行う。' > "$T/prompt.md"

# 対照: ランチャを通さなければ push できる（この用意で push が成り立つことを確かめる。成り立たないとテストの意味が無い）
git -C "$wt" push -q origin HEAD:refs/heads/control 2>/dev/null || fail "対照の push が通らない（用意が誤り）"
git -C "$bare" rev-parse -q --verify refs/heads/control >/dev/null || fail "対照の push が届いていない"
pass "対照: ランチャの外からは bare リポへ push できる"

# 子が試す push（リモート名・直接のパス・設定で通信を許す指定・リモートの pushurl の上書き）
typeset -a attempts
attempts=(
  'git push origin HEAD:refs/heads/by-name'
  'git -C . push "$NOPUSH_BARE" HEAD:refs/heads/by-path'
  'git -c protocol.allow=always -c protocol.file.allow=always push origin HEAD:refs/heads/by-config'
  'git -c remote.origin.pushurl="$NOPUSH_BARE" push origin HEAD:refs/heads/by-pushurl'
)
export NOPUSH_BARE="$bare"
n=0
try_push() {   # <構成> <ランチャ> [引数...]
  local tools="$1" name="$2"; shift 2
  local cmd label rc
  for cmd in "${attempts[@]}"; do
    n=$(( n + 1 )); label="np$n"; rc=0
    : > "$STUB_RUN_RC"
    LANES_TOOLS="$tools" STUB_RUN="$cmd" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@" > "$T/$label.out" 2>&1 || rc=$?
    (( rc == 0 )) || { cat "$T/$label.out" >&2; fail "$name [$tools] が完走しない（$rc）: $cmd"; }
    [[ -s "$STUB_RUN_RC" ]] || fail "$name の子が push を試していない（スタブが呼ばれない）: $cmd"
    [[ "$(< "$STUB_RUN_RC")" != 0 ]] || fail "$name の子の push が成功した: $cmd"
    [[ "$(git -C "$bare" for-each-ref --format='%(refname)' refs/heads/)" == refs/heads/control ]] || fail "$name の子の push が bare リポに届いた: $cmd"
  done
  pass "$name [$tools] の子は push できない（${#attempts} 通り）"
}
try_push "claude" run-claude-review.sh --base "$(git -C "$wt" rev-parse HEAD)"
try_push "claude codex" run-codex-review.sh
try_push "claude" run-qa.sh

# 接続先の上書き（ANTHROPIC_BASE_URL・OPENAI_BASE_URL）は、レーンの子に届かない（司令塔のシェルをローカルのモデルに向けていても、
# レーンはサブスクの正規の窓口へつなぐ）。実装・レビュー・QA のランチャで確かめる
for name in run-claude.sh run-claude-review.sh run-qa.sh; do
  n=$(( n + 1 )); rc=0; seen="$T/baseurl-$n.txt"; rm -f "$seen"
  typeset -a extra; extra=()
  [[ "$name" == run-claude-review.sh ]] && extra=(--base "$(git -C "$wt" rev-parse HEAD)")
  ANTHROPIC_BASE_URL=http://127.0.0.1:9/x OPENAI_BASE_URL=http://127.0.0.1:9/y LANES_TOOLS=claude \
    STUB_RUN="printf '%s|%s' \"\${ANTHROPIC_BASE_URL-unset}\" \"\${OPENAI_BASE_URL-unset}\" > '$seen'" \
    zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "np$n" "${extra[@]}" > "$T/np$n.out" 2>&1 || rc=$?
  [[ -s "$seen" ]] || { cat "$T/np$n.out" >&2; fail "$name の子が起動していない（スタブが呼ばれない・rc=$rc）"; }
  [[ "$(< "$seen")" == "unset|unset" ]] || fail "$name の子に接続先の上書きが届いた: $(< "$seen")"
  pass "$name の子には ANTHROPIC_BASE_URL・OPENAI_BASE_URL が届かない"
done

# レビュー・QA の子が裏に残した孫（テスト用のサーバーなど）は、ランチャの終了までに監督役が回収する
export NOPUSH_GRAND="$T/grand.pid"
for name in run-claude-review.sh run-qa.sh; do
  rm -f "$NOPUSH_GRAND"; n=$(( n + 1 )); rc=0
  typeset -a extra; extra=()
  [[ "$name" == run-claude-review.sh ]] && extra=(--base "$(git -C "$wt" rev-parse HEAD)")
  LANES_TOOLS=claude STUB_RUN='sleep 300 >/dev/null 2>&1 & echo $! > "$NOPUSH_GRAND"' \
    zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "np$n" "${extra[@]}" > "$T/np$n.out" 2>&1 || rc=$?
  (( rc == 0 )) || { cat "$T/np$n.out" >&2; fail "$name が完走しない（$rc）"; }
  [[ -s "$NOPUSH_GRAND" ]] || fail "$name の子が孫を起動していない（スタブが呼ばれない）"
  grand="$(< "$NOPUSH_GRAND")"
  if kill -0 "$grand" 2>/dev/null; then kill "$grand" 2>/dev/null || true; fail "$name の子が残した孫（pid $grand）が終了後も生きている"; fi
  pass "$name の子が裏に残した孫は、ランチャの終了までに回収される"
  grep -q '^# 案件固有の指示（司令塔が記入）$' "$wt/logs/np$n.prompt.md" || fail "$name の結合したプロンプトの見出しが「司令塔が記入」になっていない"
done

# 実装レーン（run-claude.sh）は通信を止めない（実装の後の push は人やランチャが行うため、制限を持ち込まない）
: > "$STUB_RUN_RC"
rc=0
LANES_TOOLS=claude STUB_RUN='git push -q origin HEAD:refs/heads/impl' zsh -f "$LANES_DIR/run-claude.sh" "$wt" "$T/prompt.md" impl > "$T/impl.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/impl.out" >&2; fail "run-claude.sh が完走しない（$rc）"; }
[[ "$(< "$STUB_RUN_RC")" == 0 ]] || fail "実装レーンの子の push まで止めた"
pass "実装レーン（run-claude.sh）の子の git の通信は止めない"

# QA の前後比較の「前」の写し（子が書ける $LANES_SCRATCH にある）を子が書き換えたら、比較を信用せず不合格にする
# （ここでは中身を変えずに書式だけ変える。前の版はこれを見逃して緑にした）
rc=0
LANES_TOOLS=claude STUB_RUN='python3 -c "import json, os; p = os.environ[\"LANES_SCRATCH\"] + \"/qa-before.json\"; d = json.load(open(p)); open(p, \"w\").write(json.dumps(d, indent=1))"' \
  zsh -f "$LANES_DIR/run-qa.sh" "$wt" "$T/prompt.md" qa-forge > "$T/qa-forge.out" 2>&1 || rc=$?
(( rc != 0 )) && grep -q 'VERDICT: NEEDS_FIX' "$wt/logs/qa-forge.done" || { cat "$T/qa-forge.out" >&2; fail "QA の前の写しの書き換えを見逃した（rc=$rc）"; }
grep -q 'QA 開始時の写し' "$T/qa-forge.out" "$wt/logs/qa-forge.log" || fail "QA の前の写しの書き換えの理由が出ない"
pass "QA の子が前後比較の前の写しを書き換えたら NEEDS_FIX（指紋はメモリに持つ）"

print -r -- "PASS: $count 件 / EXIT:0"
