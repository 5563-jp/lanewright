#!/bin/zsh -f
# scratch（レーン専用の作業場所）の作成〜マージ後削除の小さな通しテスト。
# 使い捨て repo / bare origin / worktree を $LANES_SCRATCH/lanes-scratch-test.* に作り、本物の _runs・~/Downloads・GitHub は触らない。
# 一時 PostgreSQL があれば起動して「cleanup が先に止めてから消す」ことも確かめる。codex / claude は起動しない。
# PG が入っているのに initdb / 起動に失敗したら、後片付け試験を最後まで走らせたうえで FAIL にする
# （停止経路を試さないまま PASS にしない）。失敗の模擬試験だけ LANES_TEST_PG_FAILURE_EXPECTED=1 で許す。
# ソケット（PostgreSQL への接続口のファイル）は一時領域の中にだけ置く（/tmp などの外へは逃がさない）。一時領域が深くて
# パスが 103 バイトを超えるときは、LANES_TEST_SOCKET_ROOT（許可された一時領域の中の浅いフォルダ。selftest.sh は自分の一時領域の
# 浅い場所を渡す）の下に置く。それでも超えるなら PG は起動せず、後片付け試験を最後まで走らせてから exit 77（対象外・理由付き）。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
SOURCE_DIR="${0:A:h:h}"
scratch_base="${${LANES_SCRATCH:-$TMPDIR}:A}"
T="$(mktemp -d "$scratch_base/s.XXXXXX")"
LANES_DIR="$T/lanes"
mkdir -p "$LANES_DIR/templates"
cp "$SOURCE_DIR"/{_common.sh,codex-review-output.py,lanes.env,lanes-roles.sh,run-codex-review.sh,run-claude-review.sh,run-claude.sh,review-dedup.zsh,cleanup-after-merge.sh} "$LANES_DIR/"
cp "$SOURCE_DIR"/templates/*.md "$LANES_DIR/templates/"
# 認証照会は代用品に置き換える。本物の CLI / 認証情報には触れない。
cat >> "$LANES_DIR/_common.sh" <<'MOCK'
lanes_check_codex_subscription() { CODEX_BIN=/usr/bin/true; }
lanes_check_claude_subscription() { CLAUDE_BIN=/usr/bin/true; }
lanes_codex_no_mcp_args() {
  [[ $# == 1 && -d "$1" ]] || lanes_die "検証対象 worktree が必要"
  typeset -ga LANES_CODEX_NO_MCP_ARGS=(-c "features.apps=false")
}
MOCK
export TEST_DOWNLOADS="$T/downloads"
python3 - "$LANES_DIR/cleanup-after-merge.sh" <<'PY_FIXTURE'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace('local dl="$HOME/Downloads"', 'local dl="$TEST_DOWNLOADS"'))
PY_FIXTURE
export LANES_SCRATCH_ROOT="$T/scratch" LANES_ARCHIVE_ROOT="$T/archive" LANES_NOTIFY=0
fail() { print -u2 -- "FAIL: $*"; exit 1; }
pgpid=""; keep=0; pg_started=0; pg_failed=0; pg_skipped=""; short_socket=""
finish() {
  if (( pg_started )); then
    if LC_ALL=C LANG=C "$pgbin/pg_ctl" -D "$d/pg" stop -m fast -w >/dev/null 2>&1; then pg_started=0; else keep=1; fi
  fi
  # ソケット用に作った短い専用フォルダは、PG を止めたあとに消す（ソケットだけの置き場所。データは $T の下）
  if [[ -n "$short_socket" && -d "$short_socket" ]] && (( ! pg_started )); then rm -rf -- "$short_socket"; fi
  cd /
  if (( keep )); then print -- "原因調査用ログを保持: $T/diagnostics"; else rm -rf -- "$T"; fi
}
trap finish EXIT

cd "$T"
git init -q --bare "$T/origin.git"
git init -q -b develop "$T/repo"; lanes_test_assert_repo "$T/repo"; cd "$T/repo"
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git remote add origin "$T/origin.git"
git checkout -q -b fix/scratch-test
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m change
git push -q origin develop fix/scratch-test
git checkout -q develop && git merge -q --ff-only fix/scratch-test && git push -q origin develop
git worktree add -q "$T/wt" fix/scratch-test
wt="$T/wt"
print "# test" > "$T/prompt.md"

# 1) ランチャ dry-run: scratch パスが出る・Downloads 指示がプロンプトに入る（codex / claude は起動しない）
# Codex レビューのランチャを試すので、呼び出し元の構成（LANES_TOOLS）に関係なく codex を含む構成で回す
out="$(LANES_TOOLS="claude codex" zsh "$LANES_DIR/run-codex-review.sh" "$wt" "$T/prompt.md" codex-t --dry-run)"
grep -q "scratch: $LANES_SCRATCH_ROOT/repo/codex-t" <<< "$out" || fail "codex dry-run に scratch が無い: $out"
grep -q 'Downloads' "$wt/logs/codex-t.dry-run.prompt.md" || fail "codex プロンプトに置き場所の指示が無い"
out="$(zsh "$LANES_DIR/run-claude.sh" "$wt" "$T/prompt.md" claude-t --dry-run)"
grep -q "TMPDIR=.*claude-t" <<< "$out" || fail "claude dry-run に TMPDIR が無い: $out"
grep -q "$LANES_SCRATCH_ROOT/repo/claude-t" "$wt/logs/claude-t.dry-run.prompt.md" || fail "claude プロンプトに scratch が無い"
[[ ! -e "$LANES_SCRATCH_ROOT/repo/codex-t" ]] || fail "dry-run なのに scratch を作った"
rm -rf "$wt/logs"
print "ok 1 dry-run"

# 2) prepare: TMPDIR / .lane / 他 worktree と label がぶつかったらずらす
d="$(LANES_DIR="$LANES_DIR" zsh -f -c 'set -euo pipefail; source "$LANES_DIR/_common.sh"; lanes_scratch_prepare "$1" codex-t codex-review; [[ "$TMPDIR" == "$LANES_SCRATCH/" ]] || exit 9; print -- "$LANES_SCRATCH"' _ "$wt")"
[[ "$d" == "$LANES_SCRATCH_ROOT/repo/codex-t" && -f "$d/.lane" ]] || fail "prepare: $d"
mkdir -p "$LANES_SCRATCH_ROOT/repo/other-t"; print "worktree=/somewhere/else" > "$LANES_SCRATCH_ROOT/repo/other-t/.lane"
d2="$(LANES_DIR="$LANES_DIR" zsh -f -c 'set -euo pipefail; source "$LANES_DIR/_common.sh"; lanes_scratch_path "$1" other-t' _ "$wt")"
[[ "$d2" == "$LANES_SCRATCH_ROOT/repo/other-t-2" ]] || fail "label 衝突でずれない: $d2"
print "ok 2 prepare"

# 3) 一時 PostgreSQL を scratch に立てる（あれば）
pgbin="${LANES_TEST_PGBIN:-$(print -l /opt/homebrew/opt/postgresql@*/bin(N) /usr/local/opt/postgresql@*/bin(N) | tail -1)}"
pg_result="未導入"
if [[ -n "$pgbin" ]]; then
  mkdir -p "$T/diagnostics"
  socket="$T"
  # macOS の sockaddr_un.sun_path は末尾 NUL を除いて 103 バイト。
  socket_bytes_of() { python3 -c 'import os,sys; print(len(os.fsencode(sys.argv[1]+"/.s.PGSQL.56999")))' "$1"; }
  socket_bytes="$(socket_bytes_of "$socket")"
  # 起動失敗の模擬試験ではソケットを使わないため、長い TMPDIR でもその経路まで進める。
  socket_limit="${LANES_TEST_SOCKET_LIMIT:-103}"
  if (( socket_bytes > socket_limit )); then
    # 一時領域が深い（レビューのレーンの中から回したとき等）とソケットのパスが上限を超える。入口から
    # LANES_TEST_SOCKET_ROOT（許可された一時領域の中の浅いフォルダ）を渡されたときだけ、その下にこのテスト専用の
    # フォルダを作ってソケットを置く。データ・ログは $T の下のまま。/tmp などの指定されていない場所へは逃がさない
    short_root="${LANES_TEST_SOCKET_ROOT:-}"
    # 専用フォルダの名前は短くする（p.XXXXX。少しでも上限に収まりやすいように）
    if [[ -n "$short_root" && -d "$short_root" ]] && (( $(socket_bytes_of "${short_root%/}/p.XXXXX") <= socket_limit )); then
      short_socket="$(mktemp -d "${short_root%/}/p.XXXXX")" || short_socket=""
      if [[ -n "$short_socket" ]]; then
        socket="$short_socket"; socket_bytes="$(socket_bytes_of "$socket")"
        print -- "一時領域が深いので、ソケットだけ LANES_TEST_SOCKET_ROOT の下の専用フォルダに置く: $socket"
      fi
    fi
  fi
  pg_options="$(python3 -c 'import shlex,sys; print(shlex.join(["-k",sys.argv[1],"-p","56999","-c","listen_addresses="]))' "$socket")"
  if (( socket_bytes > socket_limit )); then
    if [[ -n "${LANES_TEST_SOCKET_ROOT:-}" ]]; then why="LANES_TEST_SOCKET_ROOT の下でも収まらない、または使えない: $LANES_TEST_SOCKET_ROOT"
    else why="LANES_TEST_SOCKET_ROOT（許可された一時領域の中の浅いフォルダ）が未指定"; fi
    pg_skipped="Unix ソケットのパスが ${socket_bytes} バイトで上限103を超える（$why）。一時領域の外には書かないので PG の試験は対象外。浅い TMPDIR / LANES_SCRATCH か LANES_TEST_SOCKET_ROOT を渡して回し直す"
    print -- "$pg_skipped" | tee "$T/diagnostics/pg-reason.log"
    keep=1; pg_result="パス長による対象外"
  # LANG / LC_ALL が空の環境では postmaster がロケール設定で起動に失敗する。C ロケールを明示する。
  elif ! LC_ALL=C LANG=C "$pgbin/initdb" -D "$d/pg" -U postgres -A trust --no-locale -E UTF8 > "$T/diagnostics/initdb.log" 2>&1; then
    print -- "initdb 失敗。原因ログ: $T/diagnostics/initdb.log"
    keep=1; pg_result="initdb 失敗"; pg_failed=1
  elif ! LC_ALL=C LANG=C "$pgbin/pg_ctl" -D "$d/pg" -o "$pg_options" -l "$T/diagnostics/pg.log" -w start > "$T/diagnostics/start.log" 2>&1; then
    print -- "PG 起動失敗。原因ログ: $T/diagnostics/pg.log / start.log"
    keep=1; pg_result="起動失敗"; pg_failed=1
    # 起動待ちのタイムアウトで処理が残った場合は、生成元の pg_ctl で停止してから試験を続ける。
    LC_ALL=C LANG=C "$pgbin/pg_ctl" -D "$d/pg" stop -m fast -w >/dev/null 2>&1 || true
  else
    pgpid="$(head -1 "$d/pg/postmaster.pid")"; kill -0 "$pgpid" || fail "pg が起動しない"
    pg_started=1; pg_result="起動成功"
  fi
fi
print -- "ok 3 PG: $pg_result（後続の後片付け試験へ進む）"

# 4) cleanup dry-run は消さない → --apply で pg 停止＋scratch 削除。他人の scratch は残る
cd "$T/repo"
zsh "$LANES_DIR/cleanup-after-merge.sh" "$wt" | sed 's/^/   /'
[[ -d "$d" ]] || fail "dry-run で消えた"
# Downloads の見張りは使い捨てコピーの参照先だけ置換する（HOME は変更しない）。LANES_DOWNLOADS_SCAN=1 のときだけ見る
mkdir -p "$T/downloads/my-app-review.abc" "$T/downloads/notes"
out0="$(LANES_DOWNLOADS_SCAN=0 zsh "$LANES_DIR/cleanup-after-merge.sh" "$wt")"
grep -q 'downloads/' <<< "$out0" && fail "LANES_DOWNLOADS_SCAN=0 なのに Downloads を報告した"
out="$(LANES_DOWNLOADS_SCAN=1 zsh "$LANES_DIR/cleanup-after-merge.sh" "$wt" --apply)"; print -- "$out" | sed 's/^/   /'
grep -q 'downloads/my-app-review.abc' <<< "$out" || fail "Downloads の報告が無い"
grep -q 'downloads/notes$' <<< "$out" && fail "レビュー出力らしくない物を報告した"
[[ -d "$T/downloads/my-app-review.abc" && -d "$T/downloads/notes" ]] || fail "Downloads の物を消した"
[[ ! -e "$d" ]] || fail "scratch が残った"
[[ -z "$pgpid" ]] || ! kill -0 "$pgpid" 2>/dev/null || fail "pg が止まっていない"
pgpid=""; pg_started=0
[[ -d "$LANES_SCRATCH_ROOT/repo/other-t" ]] || fail "他レーンの scratch を消した"
git -C "$T/repo" show-ref -q --verify refs/heads/develop || fail "develop が消えた"
print "ok 4 cleanup"
if (( pg_failed )) && [[ "${LANES_TEST_PG_FAILURE_EXPECTED:-0}" != 1 ]]; then
  fail "PostgreSQL が入っているのに起動できず、停止経路を試せていない（$pg_result。原因ログ: $T/diagnostics）"
fi
if [[ -n "$pg_skipped" ]]; then
  # 後片付け試験は通ったが PG の停止経路は試せていないので、緑にせず対象外（77）で理由を出す
  print -- "SKIP: 後片付け試験 4 件は通過。PG の試験は対象外: $pg_skipped"
  exit 77
fi
print "PASS: 4 件（PG: $pg_result）"
