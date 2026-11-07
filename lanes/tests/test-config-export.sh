#!/bin/zsh -f
# 設定ファイル（LANES_CONF）に書いた値が、設定ファイルを読まない側（Python のスクリプト・bash の chk-run.sh）まで
# 届くことのテスト。lanes.env が LANES_* を export し、chk-run.sh と lanes-watch.sh が lanes.env を通ることを確かめる。
# 本物の CLI・ネットワーク・GitHub には触らない。全データを一時領域に置く。構成（LANES_TOOLS）には左右されない。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-config-export.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
# 呼び出し元の設定を持ち込まない
for v in ${(k)parameters[(I)LANES_*]} CHK_CACHE XDG_CONFIG_HOME XDG_STATE_HOME; do unset "$v" 2>/dev/null || true; done
LANES_DIR="${0:A:h:h}"   # 上で LANES_ で始まる変数ごと外したので入れ直す
export HOME="$T/home" LANES_NOTIFY=0
mkdir -p "$HOME"
# GitHub の CLI（gh）は偽物に置き換え、認証関連の環境変数も外す（監視が gh auth status を呼んでも外部通信しない）。
# 偽 gh は呼ばれた引数を記録し、未ログインと同じ終了コードを返す
for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_CONFIG_DIR GH_REPO; do unset "$v" 2>/dev/null || true; done
mkdir -p "$T/bin"
print -r -- $'#!/bin/zsh -f\nprint -r -- "$*" >> "${0:A:h}/gh-calls"\nprint -u2 -- "テスト用の偽 gh（外部通信しない）"\nexit 4' > "$T/bin/gh"
chmod +x "$T/bin/gh"; : > "$T/bin/gh-calls"
export PATH="$T/bin:$PATH"
[[ "$(command -v gh)" == "$T/bin/gh" ]] || { print -u2 -- "偽 gh が PATH の先頭に無い"; exit 1; }

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

conf="$T/lanes.conf"
{
  print -r -- 'LANES_BASE_BRANCH="${LANES_BASE_BRANCH:-trunk}"'
  print -r -- "LANES_RUNS_ROOT=\"\${LANES_RUNS_ROOT:-$T/runs}\""
  # chk-run.sh は bash -c で回すので bash の書き方。$LANES_CHECK_OUTDIR は実行時に展開させる
  print -r -- 'LANES_CHECK_CMD="${LANES_CHECK_CMD:-echo from-conf > \$LANES_CHECK_OUTDIR/marker}"'
  print -r -- 'LANES_SCREEN_QA_MAP="${LANES_SCREEN_QA_MAP:-owner/my-app|https://preview.example.com|/Users/you/qa.md}"'
  print -r -- 'LANES_VERCEL_PROJECT="${LANES_VERCEL_PROJECT:-my-app}"'
  print -r -- 'LANES_VERCEL_SCOPE="${LANES_VERCEL_SCOPE:-my-team}"'
  print -r -- 'LANES_DOWNLOADS_SCAN="${LANES_DOWNLOADS_SCAN:-1}"'
} > "$conf"
export LANES_CONF="$conf"

# ---- 1. lanes.env を読んだシェルの子（Python）に設定キーが見える ----
got="$(zsh -fc 'source "$1/lanes.env"; python3 -I -c "import os
for k in (\"LANES_BASE_BRANCH\", \"LANES_RUNS_ROOT\", \"LANES_SCRATCH_ROOT\", \"LANES_CHECK_CMD\", \"LANES_SCREEN_QA_MAP\", \"LANES_VERCEL_PROJECT\", \"LANES_VERCEL_SCOPE\", \"LANES_DOWNLOADS_SCAN\"):
    print(k + \"=\" + os.environ.get(k, \"<無い>\"))"' _ "$LANES_DIR")"
for want in "LANES_BASE_BRANCH=trunk" "LANES_RUNS_ROOT=$T/runs" "LANES_SCRATCH_ROOT=$T/runs/_scratch" \
            "LANES_SCREEN_QA_MAP=owner/my-app|https://preview.example.com|/Users/you/qa.md" \
            "LANES_VERCEL_PROJECT=my-app" "LANES_VERCEL_SCOPE=my-team" "LANES_DOWNLOADS_SCAN=1"; do
  grep -qxF -- "$want" <<< "$got" || fail "Python 側に届かない: $want（実際: $got）"
done
grep -qxF -- 'LANES_CHECK_CMD=echo from-conf > $LANES_CHECK_OUTDIR/marker' <<< "$got" || fail "Python 側に LANES_CHECK_CMD が届かない"
pass "lanes.env を読んだシェルから Python へ設定キーが届く"

# CLI のパス・モデル・effort は子へ渡さない（各 CLI が同じ名前の環境変数を読むことがあるため）
leak="$(env -u CLAUDE_EFFORT -u GEMINI_MODEL zsh -fc 'source "$1/lanes.env"; python3 -I -c "import os; print(os.environ.get(\"CLAUDE_EFFORT\", \"\") + os.environ.get(\"GEMINI_MODEL\", \"\"))"' _ "$LANES_DIR")"
[[ -z "$leak" ]] || fail "CLI 用の変数まで export している"
pass "CLI 用の変数（モデル・effort）は export しない"

# 環境変数は設定ファイルに勝つ
got="$(LANES_VERCEL_PROJECT=other zsh -fc 'source "$1/lanes.env"; python3 -I -c "import os; print(os.environ[\"LANES_VERCEL_PROJECT\"])"' _ "$LANES_DIR")"
[[ "$got" == other ]] || fail "環境変数が設定ファイルに勝たない: $got"
pass "環境変数が設定ファイルに勝つ"

# ---- 2. Python のモジュールが設定ファイルの値で動く ----
got="$(zsh -fc 'source "$1/lanes.env"; cd "$1"; python3 -B -c "import vercel_autoredeploy as v, lanes_monitor as m; print(v.PROJECT, v.SCOPE, v.RUNS, m.RUNS, m.SCRATCH)"' _ "$LANES_DIR")"
[[ "$got" == "my-app my-team $T/runs $T/runs $T/runs/_scratch" ]] || fail "Python のモジュールが設定ファイルの値を使わない: $got"
pass "vercel_autoredeploy.py / lanes_monitor.py が設定ファイルの値を使う"

# ---- 3. lanes-monitor.sh（_common.sh 経由）と lanes-watch.sh（lanes.env 経由）が設定ファイルの置き場所を使う ----
mkdir -p "$T/runs"
zsh -f "$LANES_DIR/lanes-monitor.sh" > "$T/monitor.out" 2>&1 || fail "lanes-monitor.sh が失敗: $(tail -3 "$T/monitor.out")"
[[ -f "$T/runs/.lanes-monitor-state.json" && -f "$T/runs/lanes-monitor-now.txt" ]] || fail "lanes-monitor.sh が設定ファイルの LANES_RUNS_ROOT に状態を書かない"
pass "lanes-monitor.sh が設定ファイルの LANES_RUNS_ROOT に状態を書く"
# gh は偽物だけが呼ばれ、未ログイン扱いなので PR の照会（gh pr list）まで進まない
! grep -qv '^auth status$' "$T/bin/gh-calls" || fail "偽 gh に auth status 以外の呼び出しがある: $(cat "$T/bin/gh-calls")"
pass "監視の gh 呼び出しは偽 gh に届き、外部へ照会しない"
# 設定ファイルの置き場所に、生きているプロセスの心拍ファイルを置く。そこを見ていれば WATCH OK になる
sleep 60 &
sleeper=$!
python3 -I - "$T/runs/.lanes-watch.heartbeat" "$sleeper" <<'PY'
import json, os, subprocess, sys, time
pid = int(sys.argv[2])
out = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
                     capture_output=True, text=True).stdout
open(sys.argv[1], "w").write(json.dumps({"pid": pid, "epoch": time.time(), "lstart": " ".join(out.split())}))
PY
rc=0; zsh -f "$LANES_DIR/lanes-watch.sh" --check > "$T/watch.out" 2>&1 || rc=$?
kill "$sleeper" 2>/dev/null || true
(( rc == 0 )) && grep -q '^WATCH OK' "$T/watch.out" || fail "lanes-watch.sh が設定ファイルの LANES_RUNS_ROOT の心拍ファイルを見ない（rc=$rc: $(head -1 "$T/watch.out")）"
pass "lanes-watch.sh が設定ファイルの LANES_RUNS_ROOT の心拍ファイルを見る"

# ---- 4. bash の chk-run.sh が設定ファイルの LANES_CHECK_CMD と LANES_RUNS_ROOT を使う ----
wt="$T/wt"; mkdir -p "$wt"
git -C "$wt" init -q; lanes_test_assert_repo "$wt"
git -C "$wt" config user.email test@example.com; git -C "$wt" config user.name test
print -r -- a > "$wt/a.txt"; git -C "$wt" add a.txt; git -C "$wt" commit -qm init
rc=0; bash "$LANES_DIR/chk-run.sh" "$wt" 39123 "$T/out" > "$T/chk.out" 2>&1 || rc=$?
(( rc == 0 )) || fail "chk-run.sh が失敗（rc=$rc）: $(tail -5 "$T/chk.out")"
[[ "$(cat "$T/out/marker" 2>/dev/null)" == from-conf ]] || fail "chk-run.sh が設定ファイルの LANES_CHECK_CMD を回さない: $(tail -5 "$T/chk.out")"
[[ -s "$T/runs/_chk-cache/passed.tsv" ]] || fail "chk-run.sh が設定ファイルの LANES_RUNS_ROOT に確認済みの記録を書かない"
pass "chk-run.sh が設定ファイルの LANES_CHECK_CMD を回し、LANES_RUNS_ROOT に記録する"
# 環境変数の LANES_CHECK_CMD は設定ファイルに勝つ
rm -f "$T/out/marker"
rc=0; LANES_CHECK_CMD='echo from-env > "$LANES_CHECK_OUTDIR/marker"' bash "$LANES_DIR/chk-run.sh" "$wt" 39123 "$T/out" --force > "$T/chk2.out" 2>&1 || rc=$?
(( rc == 0 )) || fail "chk-run.sh（環境変数）が失敗（rc=$rc）: $(tail -5 "$T/chk2.out")"
[[ "$(cat "$T/out/marker" 2>/dev/null)" == from-env ]] || fail "環境変数の LANES_CHECK_CMD が設定ファイルに勝たない"
pass "chk-run.sh でも環境変数が設定ファイルに勝つ"

# ---- 5. 数値・0/1 の設定は、計算に使う前に確かめて止める（zsh の (( )) は値の中の a[$(コマンド)] を実行してしまう）----
# lanes.env は不正な値で return 2 する。読み込む側はどれも set -e なので、そこで止まる（下も同じ形で読む）
mark="$T/injected"
for key in LANES_PROMPT_MAX_BYTES LANES_STALL_MINUTES LANES_NOTIFY LANES_DOWNLOADS_SCAN LANES_DETACH_QA; do
  for bad in 'a[$(touch '"$mark"')]' '-1' '12x' '1 + 1' '0x10'; do
    rm -f "$mark"
    rc=0; env "$key=$bad" zsh -fc 'set -e; source "$1/lanes.env"; print reached' _ "$LANES_DIR" > "$T/num.out" 2>&1 || rc=$?
    (( rc == 2 )) && ! grep -q reached "$T/num.out" && grep -q "$key" "$T/num.out" || fail "$key='$bad' で止まらない（rc=$rc: $(head -1 "$T/num.out")）"
    [[ ! -e "$mark" ]] || fail "$key の値の中のコマンドが実行された"
  done
done
# 設定ファイルに書いた不正な値でも止まる。ランチャ（lanes_require_prompt の計算）・bash の chk-run.sh も同じ入口を通る
rm -f "$mark"
print -r -- 'LANES_PROMPT_MAX_BYTES="${LANES_PROMPT_MAX_BYTES:-a[\$(touch '"$mark"')]}"' > "$T/bad.conf"
rc=0; LANES_CONF="$T/bad.conf" zsh -f "$LANES_DIR/lanes-status.sh" "$wt" none > "$T/num.out" 2>&1 || rc=$?
(( rc == 2 )) && [[ ! -e "$mark" ]] || fail "設定ファイルの不正な LANES_PROMPT_MAX_BYTES でランチャが止まらない（rc=$rc）"
rc=0; LANES_CONF="$T/bad.conf" bash "$LANES_DIR/chk-run.sh" "$wt" 39123 "$T/out" --force > "$T/num.out" 2>&1 || rc=$?
(( rc == 2 )) && [[ ! -e "$mark" ]] || fail "設定ファイルの不正な LANES_PROMPT_MAX_BYTES で chk-run.sh が止まらない（rc=$rc）"
for v in 0 1; do LANES_NOTIFY=$v LANES_DETACH_QA=$v LANES_DOWNLOADS_SCAN=$v zsh -fc 'source "$1/lanes.env"' _ "$LANES_DIR" || fail "0 / 1 の値（$v）で止まった"; done
rc=0; LANES_STALL_MINUTES=0 zsh -fc 'set -e; source "$1/lanes.env"' _ "$LANES_DIR" 2>/dev/null || rc=$?
(( rc == 2 )) || fail "LANES_STALL_MINUTES=0 で止まらない"
# lanes.env の後で値が変わっても、プロンプトの大きさの計算の直前でも確かめる
rm -f "$mark"; print -r -- x > "$T/small-prompt.md"
rc=0; zsh -fc 'set -euo pipefail; LANES_DIR="$1"; source "$1/_common.sh"; LANES_PROMPT_MAX_BYTES="a[\$(touch $2)]"; lanes_require_prompt "$3"' _ "$LANES_DIR" "$mark" "$T/small-prompt.md" > "$T/num.out" 2>&1 || rc=$?
(( rc == 2 )) && [[ ! -e "$mark" ]] || fail "計算の直前に LANES_PROMPT_MAX_BYTES を確かめない（rc=$rc）"
# 誤りを保留する印（LANES_DEFER_CONFIG_ERROR）を環境から持ち込んでも、ランチャ以外は今までどおりその場で止まる
rc=0; env LANES_DEFER_CONFIG_ERROR=1 LANES_NOTIFY=true zsh -fc 'set -e; source "$1/lanes.env"; print reached' _ "$LANES_DIR" > "$T/num.out" 2>&1 || rc=$?
(( rc == 2 )) && ! grep -q reached "$T/num.out" || fail "環境から持ち込んだ LANES_DEFER_CONFIG_ERROR で止まらなくなった（rc=$rc）"
rc=0; env LANES_DEFER_CONFIG_ERROR=1 LANES_NOTIFY=true zsh -f "$LANES_DIR/lanes-status.sh" "$wt" none > "$T/num.out" 2>&1 || rc=$?
(( rc == 2 )) || fail "環境から持ち込んだ LANES_DEFER_CONFIG_ERROR で lanes-status.sh が止まらない（rc=$rc）"
# ランチャが置く印（export しない）なら止めずに既定へ戻し、誤りを LANES_CONFIG_ERROR に残す（値の中身は実行しない）
rm -f "$mark"
out="$(env "LANES_NOTIFY=a[\$(touch $mark)]" zsh -fc 'set -e; typeset +x LANES_DEFER_CONFIG_ERROR=1; source "$1/lanes.env"; print -r -- "$LANES_NOTIFY|$LANES_CONFIG_ERROR"' _ "$LANES_DIR" 2>&1)" || fail "ランチャの印があるのに止まった: $out"
[[ "$out" == '1|LANES_NOTIFY '* && ! -e "$mark" ]] || fail "保留した設定値の誤りが既定に戻らない・残らない: $out"
pass "数値・0/1 の設定は整数か確かめてから使い、不正なら値の中身を実行せずに exit 2"

# ---- 6. Claude のレビュー・QA のツール集合と拒否の一覧は、外から読み取り専用を崩せない ----
review_args() {   # 環境変数を付けて run-claude-review.sh を dry-run し、出力を $T/rv.out に置く。終了コードを返す
  local rc=0
  env CLAUDE_BIN="$LANES_DIR/tests/stubs/claude" LANES_TOOLS=claude "$@" \
    zsh -f "$LANES_DIR/run-claude-review.sh" "$wt" "$T/rv-prompt.md" rv --base "$(git -C "$wt" rev-parse HEAD)" --dry-run > "$T/rv.out" 2>&1 || rc=$?
  return $rc
}
print -r -- 'レビューして' > "$T/rv-prompt.md"
review_args || fail "既定の設定で dry-run が通らない: $(tail -2 "$T/rv.out")"
grep -qF -- '--tools=Bash,Read,Glob,Grep' "$T/rv.out" && grep -qF -- 'Bash(git push*)' "$T/rv.out" || fail "既定のツール集合・拒否の一覧が渡らない: $(tail -2 "$T/rv.out")"
for bad in Read,Edit Write 'Read, MultiEdit' NotebookEdit Bash,Agent Task 'Bash(git status*)'; do
  rc=0; review_args CLAUDE_REVIEW_TOOLS="$bad" || rc=$?
  (( rc == 2 )) && grep -q 'CLAUDE_REVIEW_TOOLS' "$T/rv.out" || fail "CLAUDE_REVIEW_TOOLS='$bad' で止まらない（rc=$rc）"
done
# 拒否の一覧を置き換えようとしても、固定の一覧は残り、書いたものは足される（環境変数・設定ファイルのどちらでも）
review_args CLAUDE_REVIEW_DENY='Bash(make deploy*)' || fail "拒否を足すと dry-run が通らない"
grep -qF -- 'Edit,Write,MultiEdit,NotebookEdit,Agent' "$T/rv.out" && grep -qF -- 'Bash(gh pr merge*)' "$T/rv.out" && grep -qF -- ',Bash(make deploy*)' "$T/rv.out" \
  || fail "環境変数の CLAUDE_REVIEW_DENY で固定の一覧が外れた・足したものが入らない: $(grep -o -- '--disallowedTools=[^ ]*' "$T/rv.out" | cut -c1-120)"
print -r -- 'CLAUDE_REVIEW_DENY="Read"' > "$T/deny.conf"
review_args LANES_CONF="$T/deny.conf" || fail "設定ファイルで拒否を書くと dry-run が通らない"
grep -qF -- 'Bash(git push*)' "$T/rv.out" && grep -qF -- ',Read ' "$T/rv.out" || fail "設定ファイルの CLAUDE_REVIEW_DENY で固定の一覧が外れた"
grep -q 'lanes_claude_review_resolve' "$LANES_DIR/run-qa.sh" && grep -q 'LANES_CLAUDE_REVIEW_DENY' "$LANES_DIR/run-qa.sh" || fail "run-qa.sh が同じ確認を通らない"
pass "CLAUDE_REVIEW_TOOLS に編集系・サブエージェントがあれば exit 2、CLAUDE_REVIEW_DENY は固定の一覧に足すだけ"

print -r -- "PASS: $count 件"
