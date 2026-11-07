#!/bin/zsh -f
# 子プロセスが logs/ を symlink や別のフォルダに差し替えたとき、または logs/ の中のファイルを外向きの symlink・ハードリンクにしたとき、ランチャが差し替え先へ記録（.done・証跡）を書かずに止まることのテスト。
# 起動時に logs/ が symlink なら起動しないことも確かめる。
# 一時リポと偽の CLI（tests/stubs）だけを使い、本物の CLI・ネットワークには触らない。全データを一時領域に置く。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-logdir.XXXXXX")"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H"
STUBS="$LANES_DIR/tests/stubs"
# 呼び出し元の設定を持ち込まない
for v in ${(k)parameters[(I)LANES_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN CLAUDE_MODEL CODEX_MODEL GEMINI_MODEL CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT \
    CLAUDE_IMPL_PERMISSION_MODE CLAUDE_IMPL_ALLOWED_TOOLS CODEX_IMPL_SANDBOX CODEX_REVIEW_SANDBOX XDG_CONFIG_HOME XDG_STATE_HOME GIT_ALLOW_PROTOCOL; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
export HOME="$H" PATH="$STUBS:$PATH" LANES_CONF="$T/no-such.conf" LANES_NOTIFY=0
export LANES_SCRATCH_ROOT="$T/scratch" TMPDIR="$T/" LANES_SCRATCH="$T"
export CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

base="$T/base"; wt="$T/wt"
git init -q -b main "$base"; lanes_test_assert_repo "$base"
git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit --allow-empty -qm 'test: 初期化'
git -C "$base" worktree add -q -b feat/test "$wt"
git -C "$wt" update-ref refs/remotes/origin/develop HEAD
print -r -- '担当の確認だけを行う。' > "$T/prompt.md"
head="$(git -C "$wt" rev-parse HEAD)"

n=0
# <構成> <差し替え方 symlink|dir> <ランチャ> [引数...]
swap_case() {
  local tools="$1" how="$2" name="$3"; shift 3
  local label rc=0 evil="$T/evil$n"
  n=$(( n + 1 )); label="lg$n"
  rm -rf -- "$wt/logs" "$wt/logs.moved" "$evil"; mkdir -p "$evil"
  local cmd
  if [[ "$how" == symlink ]]; then cmd='mv logs logs.moved && ln -s "$LG_EVIL" logs'
  else cmd='mv logs logs.moved && mkdir logs'; fi
  LANES_TOOLS="$tools" LG_EVIL="$evil" STUB_RUN="$cmd" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@" > "$T/$label.out" 2>&1 || rc=$?
  [[ -d "$wt/logs.moved" ]] || { cat "$T/$label.out" >&2; fail "$name: 子が logs/ を差し替えていない（スタブが呼ばれない）"; }
  (( rc != 0 )) || { cat "$T/$label.out" >&2; fail "$name [$how]: 差し替え後も成功で終わった"; }
  grep -q 'logs/ が差し替え' "$T/$label.out" || { cat "$T/$label.out" >&2; fail "$name [$how]: 差し替えの理由が出ていない"; }
  [[ -z "$(ls -A "$evil")" ]] || fail "$name [$how]: symlink の先に書いた: $(ls -A "$evil")"
  if [[ "$how" == dir ]]; then
    [[ ! -e "$wt/logs/$label.done" && ! -e "$wt/logs/$label.evidence.md" ]] || fail "$name [$how]: 差し替え後のフォルダに記録を書いた"
  fi
  [[ ! -e "$wt/logs.moved/$label.done" ]] || fail "$name [$how]: 元のフォルダに .done を書いた（差し替え後は書かない）"
  pass "$name [$tools / $how]: 差し替えられた logs/ へ書かずに止まる（rc=$rc）"
}
for how in symlink dir; do
  swap_case claude "$how" run-claude.sh
  swap_case claude "$how" run-claude-review.sh --base "$head"
  swap_case "claude codex" "$how" run-codex-review.sh
  swap_case claude "$how" run-qa.sh
done

# logs/ の中のファイル 1 つずつを外向きの symlink（既存の先・行き先の無い先）やハードリンクにされても、外のファイルを書き換えない
# <構成> <仕掛け link|dangling|hardlink> <ランチャ> [引数...]
file_case() {
  local tools="$1" how="$2" name="$3"; shift 3
  local label rc=0 out="$T/out$n" f cmd=""
  n=$(( n + 1 )); label="lf$n"
  rm -rf -- "$wt/logs" "$wt/logs.moved" "$out"; mkdir -p "$out"
  for f in done evidence.md log json stderr.log last.md; do
    case "$how" in
      link)     print -r -- "元の中身" > "$out/$f"; cmd+="ln -s '$out/$f' 'logs/$label.$f' 2>/dev/null; " ;;
      dangling) cmd+="ln -s '$out/$f' 'logs/$label.$f' 2>/dev/null; " ;;
      hardlink) print -r -- "元の中身" > "$out/$f"; cmd+="rm -f 'logs/$label.$f'; ln '$out/$f' 'logs/$label.$f' 2>/dev/null; " ;;
    esac
  done
  LANES_TOOLS="$tools" STUB_RUN="$cmd" zsh -f "$LANES_DIR/$name" "$wt" "$T/prompt.md" "$label" "$@" > "$T/$label.out" 2>&1 || rc=$?
  (( rc != 0 )) || { cat "$T/$label.out" >&2; fail "$name [$how]: logs/ の中に外向きのファイルがあるのに成功で終わった"; }
  grep -q 'logs/ が差し替え' "$T/$label.out" || { cat "$T/$label.out" >&2; fail "$name [$how]: 理由が出ていない"; }
  for f in done evidence.md log json stderr.log last.md; do
    case "$how" in
      dangling) [[ ! -e "$out/$f" ]] || fail "$name [$how]: 行き先の無い symlink を辿って外に作った: $f" ;;
      *) [[ "$(< "$out/$f")" == "元の中身" ]] || fail "$name [$how]: 外のファイルを書き換えた: $f" ;;
    esac
  done
  pass "$name [$tools / $how]: logs/ の中の外向きのファイルを辿って書かない（rc=$rc）"
}
for how in link dangling hardlink; do
  file_case claude "$how" run-claude.sh
  file_case claude "$how" run-claude-review.sh --base "$head"
  file_case "claude codex" "$how" run-codex-review.sh
  file_case claude "$how" run-qa.sh
  file_case "claude codex" "$how" run-codex.sh
done

# Codex 実装の最終メッセージ（-o）は、子の書ける場所（worktree・TMPDIR）の外へ書かせ、子の後に logs/ へ写す
rm -rf -- "$wt/logs" "$wt/logs.moved"
export STUB_LOG="$T/stub.jsonl"; : > "$STUB_LOG"
rc=0; LANES_TOOLS="claude codex" STUB_CODEX_RESULT=$'最終本文（スタブ）\nVERDICT: CLEAN' zsh -f "$LANES_DIR/run-codex.sh" "$wt" "$T/prompt.md" lg-out > "$T/lg-out.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/lg-out.out" >&2; fail "run-codex.sh が完走しない（$rc）"; }
o="$(python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    a=json.loads(l)["args"]
    if "-o" in a: print(a[a.index("-o")+1])' "$STUB_LOG" | tail -1)"
# （このテストでは HOME 自体が一時領域の中にあるので、ランチャ専用の場所の下で worktree の外にあることだけを確かめる）
[[ -n "$o" && "$o" != "$wt"/* && "$o" == "$H/.local/state/lanewright/out/"* ]] || fail "-o の書き先が子の書ける場所の外（ランチャ専用の場所）でない: $o"
[[ ! -e "$o" && ! -e "${o:h}" ]] || fail "-o の一時フォルダが残った: ${o:h}"
grep -q '最終本文（スタブ）' "$wt/logs/lg-out.last.md" || fail "最終メッセージが logs/ へ写されていない"
unset STUB_LOG
pass "run-codex.sh: -o はランチャ専用の場所へ書かせ、子の後に logs/ へ写して片付ける"

# 子の記録（.pid の書き換え）は、.pid が外のフォルダ・ファイルへの symlink にされていても外へ書かず、.pid を普通のファイルに戻す
for kind in dir file; do
  d="$T/pidrec-$kind"; out="$T/pidrec-$kind-out"; rm -rf -- "$d" "$out"; mkdir -p "$d"
  if [[ "$kind" == dir ]]; then mkdir -p "$out"; else print -r -- '外の元の中身' > "$out"; fi
  ln -s "$out" "$d/x.pid"
  zsh -fc 'source "$1/_common.sh"; LANES_PIDFILE="$2/x.pid" LANES_PIDFILE_BASE=$'"'"'pid=1\nlane=test'"'"'; lanes_record_child $$' rec "$LANES_DIR" "$d" \
    > "$T/pidrec-$kind.out" 2>&1 || { cat "$T/pidrec-$kind.out" >&2; fail ".pid の書き換えが失敗（$kind）"; }
  [[ -f "$d/x.pid" && ! -L "$d/x.pid" ]] || fail ".pid が普通のファイルに戻っていない（$kind）"
  grep -q '^child_pid=' "$d/x.pid" && grep -q '^lane=test$' "$d/x.pid" || fail ".pid の中身が違う（$kind）"
  if [[ "$kind" == dir ]]; then [[ -z "$(ls -A "$out")" ]] || fail "外のフォルダに書いた: $(ls -A "$out")"
  else [[ "$(< "$out")" == '外の元の中身' ]] || fail "外のファイルを書き換えた"; fi
  [[ -z "$(ls -A "$d" | grep -v '^x\.pid$' || true)" ]] || fail "一時ファイルが残った: $(ls -A "$d")"
done
pass "子の記録は、.pid が外向きの symlink（フォルダ・ファイル）でも外へ書かず、普通のファイルとして置き換える"

# 起動時点で logs/ の中に symlink があれば起動しない
rm -rf -- "$wt/logs"; mkdir -p "$wt/logs"; ln -s "$T/nowhere" "$wt/logs/old.log"
rc=0; LANES_TOOLS=claude zsh -f "$LANES_DIR/run-claude.sh" "$wt" "$T/prompt.md" lg-start2 > "$T/lg-start2.out" 2>&1 || rc=$?
(( rc != 0 )) || fail "logs/ の中に symlink があるのに起動した"
grep -q 'logs/old.log' "$T/lg-start2.out" || { cat "$T/lg-start2.out" >&2; fail "起動拒否で問題のファイル名が出ていない"; }
[[ ! -e "$T/nowhere" ]] || fail "symlink の先に書いた"
pass "起動時に logs/ の中に symlink があれば起動しない"
rm -rf -- "$wt/logs"

# 起動時点で logs/ が symlink なら起動しない（先へ何も書かない）
rm -rf -- "$wt/logs" "$wt/logs.moved"; evil="$T/evil-start"; mkdir -p "$evil"; ln -s "$evil" "$wt/logs"
rc=0; LANES_TOOLS=claude zsh -f "$LANES_DIR/run-claude.sh" "$wt" "$T/prompt.md" lg-start > "$T/lg-start.out" 2>&1 || rc=$?
(( rc != 0 )) || fail "logs/ が symlink なのに起動した"
grep -q '本物のフォルダではない' "$T/lg-start.out" || { cat "$T/lg-start.out" >&2; fail "起動拒否の理由が出ていない"; }
[[ -z "$(ls -A "$evil")" ]] || fail "symlink の先に記録を書いた: $(ls -A "$evil")"
pass "起動時に logs/ が symlink なら起動しない"
rm -f -- "$wt/logs"

print -r -- "PASS: logdir guard（$count 件）"
