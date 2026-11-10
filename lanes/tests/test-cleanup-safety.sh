#!/bin/zsh -f
# 後片付けの破壊的経路を、使い捨て repo / 共有先だけで再現する。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
SOURCE_DIR="${0:A:h:h}"
T="$(mktemp -d "${LANES_SCRATCH:-$TMPDIR}/cleanup-safety.XXXXXX")"
export LANES_SCRATCH_ROOT="$T/scratch" LANES_ARCHIVE_ROOT="$T/archive" LANES_NOTIFY=0
export TEST_DOWNLOADS="$T/downloads"
mkdir -p "$T/lanes" "$T/bin"
cp "$SOURCE_DIR"/{_common.sh,lanes.env,cleanup-after-merge.sh,cleanup-merged-worktrees.sh} "$T/lanes/"
python3 - "$T/lanes/cleanup-after-merge.sh" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace('local dl="$HOME/Downloads"', 'local dl="$TEST_DOWNLOADS"'))
PY
count=0; sleeper=""
finish() { if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; cd /; rm -rf "$T"; }
trap finish EXIT
fail() { print -u2 -- "FAIL: $*（ログ: $T/out）"; cat "$T/out"; exit 1; }
ok() { count=$((count + 1)); print -- "ok $count $*"; }
new_case() {
  local name="$1"
  case_root="$T/$name"; repo="$case_root/repo"; wt="$case_root/wt"
  git init -q --bare "$case_root/origin.git"
  git init -q -b develop "$repo"; lanes_test_assert_repo "$repo"
  git -C "$repo" config user.name you; git -C "$repo" config user.email you@example.com
  print -- 'logs/\nlocal-data/\nnode_modules/' > "$repo/.gitignore"
  print initial > "$repo/a"; git -C "$repo" add .; git -C "$repo" commit -qm 'test: 初期化'
  git -C "$repo" checkout -qb feature
  print feature > "$repo/a"; git -C "$repo" commit -qam 'test: 変更'
  git -C "$repo" checkout -q develop; git -C "$repo" merge -q --ff-only feature
  git -C "$repo" remote add origin "$case_root/origin.git"; git -C "$repo" push -q origin develop feature
  git -C "$repo" worktree add -q "$wt" feature
  d="$LANES_SCRATCH_ROOT/$name/lane"; mkdir -p "$d"
  printf 'worktree=%s\nlabel=lane\n' "$wt" > "$d/.lane"
  cd "$T"
}
cleanup() { zsh "$T/lanes/cleanup-after-merge.sh" "$wt" --apply > "$T/out" 2>&1; }
new_case active
sleep 600 & sleeper=$!
started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$sleeper" | sed 's/^ *//; s/ *$//')"
mkdir -p "$wt/logs"
printf 'pid=%s\nlstart=%s\n' "$sleeper" "$started" > "$wt/logs/live.pid"
rc=0; cleanup || rc=$?
[[ "$rc" == 7 && -d "$wt" && -f "$wt/logs/live.pid" && -d "$d" ]] || fail '生存レーンで全体停止しない'
ok '実行中レーンで worktree / 監視 / scratch を保全'
# 外部の操作で worktree が消えた状態を再現し、退避した生存記録で止まることを確認する。
git -C "$repo" worktree remove --force "$wt"
rc=0; cleanup || rc=$?
[[ "$rc" == 7 && -d "$d" ]] || fail 'worktree 消失後の再実行で scratch が消えた'
ok '第2段階でも退避した生存記録で停止'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
rc=0; cleanup || rc=$?
[[ "$rc" == 8 && -d "$d" ]] || fail 'worktree が無いのに古い記録だけで削除した'
grep -qF "$d" "$T/out" || fail '保全した scratch を知らせない'
ok 'worktree 消失後は古い記録の終了だけで削除を許可しない（保全して終了コード 8）'

# 旧形式・開始時刻の欠落・ps 障害は終了済みとして削除しない。
for field in pid child_pid; do
  new_case "legacy-$field"
  sleep 600 & sleeper=$!
  mkdir -p "$wt/logs"
  printf '%s=%s\n' "$field" "$sleeper" > "$wt/logs/live.pid"
  print 'EXIT:0' > "$wt/logs/live.done"
  rc=0; cleanup || rc=$?
  [[ "$rc" == 7 && -d "$wt" && -d "$d" ]] && kill -0 "$sleeper" || fail "開始時刻なし: $field"
  kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
  ok "開始時刻なしの $field は終了記録があっても保全"
done

new_case generation
sleep 600 & sleeper=$!
started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$sleeper" | sed 's/^ *//; s/ *$//')"
mkdir -p "$wt/logs"
printf 'pid=%s\nlstart=%s\n' "$sleeper" "$started" > "$wt/logs/live.pid"
rc=0; cleanup || rc=$?
[[ "$rc" == 7 ]] || fail '旧世代の記録保存に失敗'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true
sleep 600 & sleeper=$!
started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$sleeper" | sed 's/^ *//; s/ *$//')"
printf 'pid=%s\nlstart=%s\n' "$sleeper" "$started" > "$wt/logs/live.pid"
git -C "$repo" worktree remove --force "$wt"
rc=0; cleanup || rc=$?
[[ "$rc" == 8 && -d "$d" ]] && kill -0 "$sleeper" || fail '旧世代の記録で新世代の scratch を消した'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
ok '古い記録と新しいレーンの世代取り違えを拒否'

new_case missing_unknown
# 初回の後片付け前に監視情報ごと消えた場合、旧 scratch は停止済みと判断しない。
git -C "$repo" worktree remove --force "$wt"
rc=0; cleanup || rc=$?
[[ "$rc" == 8 && -d "$d" ]] || fail '記録の無い旧 scratch を削除した'
ok '初回から worktree/生存情報が無い scratch は保全'

new_case guards
# 生存情報の控え: 記録したプロセスが終了済みのものだけ、後片付けの完了時に消す。生存中・書き込み直後は残す。
groot="$LANES_SCRATCH_ROOT/.cleanup-guards"; mkdir -p "$groot/dead" "$groot/live" "$groot/fresh"
sleep 600 & sleeper=$!
started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$sleeper" | sed 's/^ *//; s/ *$//')"
printf 'pid=%s\nlstart=%s\n' "$sleeper" "$started" > "$groot/live/a.pid"
printf 'pid=99999999\nlstart=Thu Jan  1 00:00:00 2026\n' > "$groot/dead/a.pid"
cp -p "$groot/dead/a.pid" "$groot/fresh/a.pid"
touch -t 202601010000 "$groot/dead/a.pid" "$groot/live/a.pid"
cleanup || fail "控えがあると後片付けが完了しない: $(cat "$T/out")"
[[ ! -e "$groot/dead" && -f "$groot/live/a.pid" && -f "$groot/fresh/a.pid" ]] || fail '控えの後片付けが不正'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
ok '終了済みの生存情報の控えだけを片付ける'

new_case child
sleep 600 & sleeper=$!
started="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$sleeper" | sed 's/^ *//; s/ *$//')"
mkdir -p "$wt/logs"
printf 'pid=99999999\nchild_pid=%s\nchild_lstart=%s\n' "$sleeper" "$started" > "$wt/logs/live.pid"
print 'EXIT:0' > "$wt/logs/live.done"
rc=0; cleanup || rc=$?
[[ "$rc" == 7 && -d "$wt" ]] || fail 'done のある生存子を見落とした'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
ok '終了印があっても生存子で停止'

new_case ignored
mkdir -p "$wt/local-data"; print 手動メモ > "$wt/local-data/manual-notes.txt"
rc=0; cleanup || rc=$?
[[ "$rc" == 4 && -f "$wt/local-data/manual-notes.txt" && -d "$d" ]] || fail '除外ファイルが消えた'
ok '未知の除外ファイルを保全'
rm "$wt/local-data/manual-notes.txt"
print 改行メモ > "$wt/local-data/"$'line\nbreak.txt'
rc=0; cleanup || rc=$?
[[ "$rc" == 4 ]] || fail '改行入り除外パスを見落とした'
ok '改行を含むパスも停止対象'
rm -rf "$wt/local-data"
mkdir -p "$wt/node_modules"; print generated > "$wt/node_modules/cache"
cleanup || fail '既知の生成物を消せない'
[[ ! -d "$wt" ]] || fail 'worktree が残った'
ok '許可した生成物だけ削除'

# 後片付けは、フォルダ名が .lane の label（ずらしたときは label-<数>）と合う scratch だけ消す
new_case label-match
d2="$LANES_SCRATCH_ROOT/label-match/lane-2"; mkdir -p "$d2"; printf 'worktree=%s\nlabel=lane\n' "$wt" > "$d2/.lane"
d3="$LANES_SCRATCH_ROOT/label-match/docs"; mkdir -p "$d3"; printf 'worktree=%s\nlabel=lane\n' "$wt" > "$d3/.lane"; print 手動 > "$d3/keep.txt"
d4="$LANES_SCRATCH_ROOT/label-match/nolabel"; mkdir -p "$d4"; printf 'worktree=%s\n' "$wt" > "$d4/.lane"
rc=0; cleanup || rc=$?
[[ "$rc" == 0 && ! -d "$d" && ! -d "$d2" ]] || fail "label の合う scratch（lane・lane-2）を消さない（rc=$rc）"
[[ -f "$d3/keep.txt" && -d "$d4" ]] || fail '.lane の label とフォルダ名が合わない scratch を消した'
ok '後片付けは .lane の label とフォルダ名が合う scratch だけ消す'

# .lane の無い既存のフォルダ（LANES_SCRATCH_ROOT を広い場所にしたときの同名のフォルダ）は scratch として使わずにずらす
new_case scratch-shift
sp() { (cd "$T" && LANES_DIR="$T/lanes" zsh -fc 'set -euo pipefail; source "$LANES_DIR/_common.sh"; lanes_scratch_path "$1" "$2"' _ "$1" "$2"); }
sroot="$LANES_SCRATCH_ROOT/$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir | xargs dirname | xargs basename)"
mkdir -p "$sroot/docs"; print 本物の文書 > "$sroot/docs/readme.txt"
got="$(sp "$wt" docs)"
[[ "$got" == "$sroot/docs-2" ]] || fail ".lane の無い既存フォルダを scratch に使った: $got"
print -r -- x > "$sroot/notes"; got="$(sp "$wt" notes)"
[[ "$got" == "$sroot/notes-2" ]] || fail "既存のファイルと同名の scratch を選んだ: $got"
mkdir -p "$sroot/mine"; printf 'worktree=%s\nlabel=mine\n' "${wt:A}" > "$sroot/mine/.lane"; got="$(sp "$wt" mine)"
[[ "$got" == "$sroot/mine" ]] || fail "自分の .lane があるフォルダを使い直さない: $got"
mkdir -p "$sroot/other"; printf 'worktree=/Users/you/else\nlabel=other\n' > "$sroot/other/.lane"; got="$(sp "$wt" other)"
[[ "$got" == "$sroot/other-2" ]] || fail "別 worktree の scratch をずらさない: $got"
[[ -f "$sroot/docs/readme.txt" && ! -e "$sroot/docs/.lane" ]] || fail '既存フォルダの中身を変えた'
ok '.lane の無い既存のもの・別 worktree の scratch は使わずに -2 へずらし、自分の scratch は使い直す'

# モノレポの各パッケージ配下の依存（apps/web/node_modules/ 等）も生成物として扱う。
# 除外されていない（.gitignore に無い）同名ディレクトリや、パッケージ配下の任意の除外物は従来どおり止める。
new_case nested_generated
mkdir -p "$wt/apps/web/node_modules/.bin"; print generated > "$wt/apps/web/node_modules/.bin/tool"
mkdir -p "$wt/apps/web/local-data"; print keep > "$wt/apps/web/local-data/notes"
rc=0; cleanup || rc=$?
[[ "$rc" == 4 && -d "$wt" ]] && grep -q 'apps/web/local-data/notes' "$T/out" && ! grep -q 'node_modules' "$T/out" || fail 'パッケージ配下の依存を止めた／任意の除外物を見落とした'
rm -rf "$wt/apps/web/local-data"
cleanup || fail 'パッケージ配下の依存があると後片付けできない'
[[ ! -d "$wt" ]] || fail 'worktree が残った'
ok 'パッケージ配下の node_modules も生成物として削除し、任意の除外物では止める'

# 確認コマンド（chk-run.sh）のビルドが残した ignore 済みの生成物（dist/ build/ out/）は、残骸と同じく退避して後片付けを続ける。
# 生成物の定義は _common.sh の LANES_GENERATED_DIRS / LANES_GENERATED_SUFFIXES の 1 か所で、chk-run.sh と同じものを使う。
# 依存・キャッシュ（*.tsbuildinfo など）は今までどおり退避せずに消す。symlink は辿らずリンクのまま退避する
new_case generated_dist
mkdir -p "$repo/.git/info"; print -- 'dist/\nbuild/\nout/\n*.tsbuildinfo' >> "$repo/.git/info/exclude"
gen_outside="$T/generated-outside.txt"; print -r -- '外の中身' > "$gen_outside"
mkdir -p "$wt/dist/assets" "$wt/build" "$wt/out" "$wt/logs"
print built > "$wt/dist/gen-index.js"; print asset > "$wt/dist/assets/gen-a.css"; ln -s "$gen_outside" "$wt/dist/gen-link.js"
print b > "$wt/build/gen-b.js"; print o > "$wt/out/gen-o.html"
print info > "$wt/tsconfig.tsbuildinfo"; print log > "$wt/logs/gen-x.log"
rc=0; zsh "$T/lanes/cleanup-after-merge.sh" "$wt" > "$T/out" 2>&1 || rc=$?
[[ "$rc" == 0 && -f "$wt/dist/gen-index.js" ]] && grep -q 'ignore 済み残骸 1 件 + ignore 済みの生成物 5 件を退避' "$T/out" \
  || fail "dry-run が ignore 済みの生成物を退避対象に数えない（rc=$rc）"
rc=0; cleanup || rc=$?
[[ "$rc" == 0 && ! -d "$wt" ]] || fail "ignore 済みの生成物（dist/ など）で後片付けが止まった（rc=$rc）"
for f in dist/gen-index.js dist/assets/gen-a.css build/gen-b.js out/gen-o.html logs/gen-x.log; do
  [[ -n "$(print -l "$LANES_ARCHIVE_ROOT"/**/$f(N.))" ]] || fail "生成物・残骸を退避していない: $f"
done
link="$(print -l "$LANES_ARCHIVE_ROOT"/**/dist/gen-link.js(N))"
[[ -n "$link" && -L "$link" && "$(< "$gen_outside")" == '外の中身' ]] || fail '生成物の中の symlink をリンクのまま退避していない'
[[ -z "$(print -l "$LANES_ARCHIVE_ROOT"/**/tsconfig.tsbuildinfo(N))" ]] || fail '依存・キャッシュ（*.tsbuildinfo）まで退避した'
ok 'ignore 済みの生成物（dist/ build/ out/）は残骸と同じく退避して、後片付けを続ける'

# 無視されていない dist/ の未追跡ファイルは、作業中かもしれないので今までどおり止まる（生成物として扱うのは ignore 済みだけ）
new_case generated_untracked
mkdir -p "$wt/dist"; print wip > "$wt/dist/wip.js"
rc=0; cleanup || rc=$?
[[ "$rc" == 4 && -f "$wt/dist/wip.js" ]] && grep -q 'dist/wip.js' "$T/out" || fail "無視されていない dist/ の未追跡ファイルで止まらない（rc=$rc）"
ok '無視されていない dist/ の未追跡ファイルでは、今までどおり止まる'

# 生成物があっても、知らない除外ファイルがあれば止まる（止める理由に出すのは知らない物だけ）
new_case generated_with_unknown
mkdir -p "$repo/.git/info"; print -- 'dist/' >> "$repo/.git/info/exclude"
mkdir -p "$wt/dist" "$wt/local-data"; print built > "$wt/dist/x.js"; print 手動メモ > "$wt/local-data/notes.txt"
rc=0; cleanup || rc=$?
[[ "$rc" == 4 && -f "$wt/dist/x.js" && -f "$wt/local-data/notes.txt" ]] && grep -q 'local-data/notes.txt' "$T/out" && ! grep -q 'dist/x.js' "$T/out" \
  || fail "生成物と知らない除外ファイルが混ざったときの止まり方が違う（rc=$rc）"
ok '生成物があっても、知らない除外ファイルがあれば止まる（生成物は止める理由に数えない）'

# 生成物の定義は chk-run.sh と同じく作業ツリー直下のフォルダだけ。パッケージ配下の dist/ は定義の外なので、今までどおり止まる
new_case generated_nested_dist
mkdir -p "$repo/.git/info"; print -- 'dist/' >> "$repo/.git/info/exclude"
mkdir -p "$wt/apps/web/dist"; print built > "$wt/apps/web/dist/x.js"
rc=0; cleanup || rc=$?
[[ "$rc" == 4 && -f "$wt/apps/web/dist/x.js" ]] && grep -q 'apps/web/dist/x.js' "$T/out" || fail "パッケージ配下の dist/ を生成物として扱った（rc=$rc）"
ok 'パッケージ配下の dist/（作業ツリー直下でない）は生成物の定義の外で、今までどおり止まる'

# 本体 checkout の生成物は退避も削除もしない（残骸だけ退避して消す）
new_case generated_main
mkdir -p "$repo/.git/info"; print -- 'dist/' >> "$repo/.git/info/exclude"
mkdir -p "$repo/dist" "$repo/logs"; print built > "$repo/dist/gen-main.js"; print log > "$repo/logs/gen-main.log"
rc=0; zsh "$T/lanes/cleanup-after-merge.sh" "$repo" --apply > "$T/out" 2>&1 || rc=$?
[[ "$rc" == 0 && -f "$repo/dist/gen-main.js" && ! -e "$repo/logs/gen-main.log" ]] || fail "本体 checkout の生成物を消した・残骸を消していない（rc=$rc）"
grep -q 'ignore 済みの生成物 1 件は触らない' "$T/out" || fail '本体 checkout の生成物を触らない旨を出さない'
[[ -z "$(print -l "$LANES_ARCHIVE_ROOT"/**/dist/gen-main.js(N))" && -n "$(print -l "$LANES_ARCHIVE_ROOT"/**/logs/gen-main.log(N.))" ]] \
  || fail '本体 checkout の生成物を退避した・残骸を退避していない'
ok '本体 checkout の生成物は退避も削除もしない（残骸だけ退避して消す）'

new_case pg_identity
sleep 600 & sleeper=$!
mkdir -p "$d/pg"
printf '%s\n%s\n1\n' "$sleeper" "$d/pg" > "$d/pg/postmaster.pid"
rc=0; cleanup || rc=$?
[[ "$rc" == 7 && -d "$wt" && -d "$d" ]] && kill -0 "$sleeper" || fail 'PID 再利用で別処理を停止/削除した'
ok 'PostgreSQL と照合できない PID を停止しない'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
cleanup || fail '古い停止済み PID を片付けられない'
ok '死亡済み PID は片付け可能'

new_case pg_hidden
sleep 600 & sleeper=$!
mkdir -p "$d/.pg"
printf '%s\n%s\n1\n' "$sleeper" "$d/.pg" > "$d/.pg/postmaster.pid"
rc=0; cleanup || rc=$?
[[ "$rc" == 7 && -d "$wt" && -d "$d/.pg" ]] && kill -0 "$sleeper" || fail '隠し PG を見落とした'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""
ok '隠しディレクトリの DB も停止確認の対象'

new_case pg_forged
# postgres という実行名だけ一致してもデータ領域/開始時刻/所有者で拒否する。
sleep 600 & sleeper=$!
export PG_TEST_PID="$sleeper" PG_TEST_DATA="$d/pg" PG_TEST_START="$(date +%s)" PG_TEST_MODE=data
export REAL_PS="$(command -v ps)" REAL_LSOF="$(command -v lsof)"
cat > "$T/bin/ps" <<'MOCK'
#!/bin/zsh -f
if [[ "$*" == *"-p $PG_TEST_PID"* ]]; then
  case "$2" in
    uid=) if [[ "$PG_TEST_MODE" == owner ]]; then print 98765; else id -u; fi ;;
    comm=) print postgres ;;
    lstart=) if [[ "$PG_TEST_MODE" == time ]]; then print 'Mon Jan 01 00:00:00 2001'; else LC_ALL=C TZ=UTC date -r "$PG_TEST_START" '+%a %b %d %H:%M:%S %Y'; fi ;;
    *) exec "$REAL_PS" "$@" ;;
  esac
else exec "$REAL_PS" "$@"; fi
MOCK
cat > "$T/bin/lsof" <<'MOCK'
#!/bin/zsh -f
if [[ "$PG_TEST_MODE" == data ]]; then print n/wrong-data; else print -r -- "n$PG_TEST_DATA"; fi
MOCK
cat > "$T/bin/pg_ctl" <<'MOCK'
#!/bin/zsh -f
print invoked >> "$TEST_PG_CALLS"
exit 1
MOCK
chmod +x "$T/bin/"*
export TEST_PG_CALLS="$T/pg-calls"
mkdir -p "$d/pg"; printf '%s\n%s\n%s\n' "$sleeper" "$d/pg" "$PG_TEST_START" > "$d/pg/postmaster.pid"
for PG_TEST_MODE in data time owner; do
  export PG_TEST_MODE
  rc=0; PATH="$T/bin:$PATH" cleanup || rc=$?
  [[ "$rc" == 7 && ! -e "$TEST_PG_CALLS" && -d "$wt" ]] && kill -0 "$sleeper" || fail "PG 実体照合: $PG_TEST_MODE"
  ok "PG 実体照合: $PG_TEST_MODE 不一致で停止/削除を拒否"
done
PG_TEST_MODE=match; export PG_TEST_MODE
rc=0; PATH="$T/bin:$PATH" cleanup || rc=$?
[[ "$rc" == 7 && -f "$TEST_PG_CALLS" && -d "$d" ]] && kill -0 "$sleeper" || fail 'pg_ctl 失敗後に直接 TERM した'
ok 'pg_ctl 失敗後は直接停止せず全体停止'
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true; sleeper=""

new_case remote_race
export REAL_GIT="$(command -v git)" RACE_ORIGIN="$case_root/origin.git"
git -C "$repo" checkout -qb extra; print extra > "$repo/extra"; git -C "$repo" add extra; git -C "$repo" commit -qm 'test: 未マージの追加'
export RACE_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin extra; git -C "$repo" checkout -q develop
cat > "$T/bin/git" <<'MOCK'
#!/bin/zsh -f
if [[ "$*" == *'push --force-with-lease='* ]]; then
  "$REAL_GIT" --git-dir="$RACE_ORIGIN" update-ref refs/heads/feature "$RACE_SHA"
fi
exec "$REAL_GIT" "$@"
MOCK
chmod +x "$T/bin/git"
rc=0; PATH="$T/bin:$PATH" cleanup || rc=$?
[[ "$rc" == 7 && "$(git --git-dir="$RACE_ORIGIN" rev-parse refs/heads/feature)" == "$RACE_SHA" ]] || fail '照会後の更新を削除した'
ok 'リモート削除の先端一致条件で競合を拒否'
new_case orphan_race
git -C "$repo" worktree remove "$wt"
git -C "$repo" branch orphan feature
git -C "$repo" checkout -qb extra; print extra > "$repo/extra"; git -C "$repo" add extra; git -C "$repo" commit -qm 'test: 未マージの追加'
export RACE_SHA="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q develop
cat > "$T/bin/git" <<'MOCK'
#!/bin/zsh -f
if [[ "$*" == *'update-ref -d refs/heads/orphan '* ]]; then
  "$REAL_GIT" -C "$2" update-ref refs/heads/orphan "$RACE_SHA"
fi
exec "$REAL_GIT" "$@"
MOCK
chmod +x "$T/bin/git"
rc=0; PATH="$T/bin:$PATH" zsh "$T/lanes/cleanup-merged-worktrees.sh" "$repo" --apply > "$T/out" 2>&1 || rc=$?
[[ "$rc" != 0 && "$(git -C "$repo" rev-parse refs/heads/orphan)" == "$RACE_SHA" ]] || fail '孤立した枝の更新を削除/成功扱いした'
ok '一括後片付けでも未マージの更新を保全し失敗を返す'
# 退避してよい残骸の名前: キットが作る名前（ログ・指示書・レビュー出力・パッチ）は退避して片付ける。
# キットが作らない名前（以前の運用の名残を含む）は「知らない物」として止まる（消さない側に倒れる）。
for extra in TRACKER-NOTE.md .bot-note.txt bot-review-1.out; do
  new_case "residue-${extra//[^a-zA-Z0-9]/-}"
  print -r -- x > "$wt/$extra"
  rc=0; cleanup || rc=$?
  [[ "$rc" == 4 && -d "$wt" && -f "$wt/$extra" ]] || fail "キットが作らない名前 $extra で止まらない（rc=$rc）"
  grep -qF -- "$extra" "$T/out" || fail "止めた理由に $extra を出さない"
  ok "キットが作らない名前 $extra は退避せず後片付けを止める"
done
new_case residue-kit
mkdir -p "$wt/logs" "$wt/prompts"
for f in logs/x.log prompts/p.md run-x.sh x.log IMPLEMENTATION_DONE review-1.md a.prompt.md a.patch .claude-task-a.md .check-a.sh .launch-a.sh .ci-fix-a.md .login-a.md; do
  print -r -- x > "$wt/$f"
done
rc=0; cleanup || rc=$?
[[ "$rc" == 0 && ! -d "$wt" ]] || fail "キットが作る残骸だけなのに片付けない（rc=$rc）"
[[ -n "$(print -l "$LANES_ARCHIVE_ROOT"/**/review-1.md(N))" && -n "$(print -l "$LANES_ARCHIVE_ROOT"/**/.launch-a.sh(DN))" ]] || fail "キットが作る残骸を退避しない"
ok "キットが作る残骸（ログ・指示書・レビュー出力・パッチ）は退避して片付ける"
# 同じ日・同じ枝の後片付けを繰り返しても、前回退避した symlink を辿って外のファイルを書き換えない
# （1 回目: logs/x.log が外向きの symlink → リンクのまま退避。2 回目: 同じ名前の普通のファイル → 退避先は新しいフォルダ）
outside="$T/archive-outside.txt"; print -r -- '外の元の中身' > "$outside"
new_case redo-1; mkdir -p "$wt/logs"; ln -s "$outside" "$wt/logs/x.log"
rc=0; cleanup || rc=$?; (( rc == 0 )) || fail "1 回目の後片付けが失敗（rc=$rc）"
new_case redo-2; mkdir -p "$wt/logs"; print -r -- '2 回目の中身' > "$wt/logs/x.log"
rc=0; cleanup || rc=$?; (( rc == 0 )) || fail "2 回目の後片付けが失敗（rc=$rc）"
[[ "$(< "$outside")" == '外の元の中身' ]] || fail '2 回目の退避が、前回退避した symlink を辿って外のファイルを書き換えた'
[[ -n "$(grep -l '2 回目の中身' "$LANES_ARCHIVE_ROOT"/**/logs/x.log(N.) 2>/dev/null)" ]] || fail '2 回目の残骸が退避されていない'
ok "同じ日の後片付けを繰り返しても、前回退避した symlink を辿らない（退避先は新しいフォルダ）"
# 統合先の枝は設定キー LANES_BASE_BRANCH で変えられる。既定（develop）のままだと別名の枝へのマージを確かめられず止まる。
case_root="$T/base-branch"; repo="$case_root/repo"; wt="$case_root/wt"
git init -q --bare "$case_root/origin.git"
git init -q -b trunk "$repo"; lanes_test_assert_repo "$repo"
git -C "$repo" config user.name you; git -C "$repo" config user.email you@example.com
print -- 'logs/' > "$repo/.gitignore"
print initial > "$repo/a"; git -C "$repo" add .; git -C "$repo" commit -qm 'test: 初期化'
git -C "$repo" checkout -qb feature
print feature > "$repo/a"; git -C "$repo" commit -qam 'test: 変更'
git -C "$repo" checkout -q trunk; git -C "$repo" merge -q --ff-only feature
git -C "$repo" remote add origin "$case_root/origin.git"; git -C "$repo" push -q origin trunk feature
git -C "$repo" worktree add -q "$wt" feature
cd "$T"
rc=0; zsh "$T/lanes/cleanup-after-merge.sh" "$wt" --apply > "$T/out" 2>&1 || rc=$?
[[ "$rc" != 0 && -d "$wt" ]] || fail '統合先の枝が無いのに worktree を消した'
ok '既定の統合先（develop）が無ければ消さずに止まる'
rc=0; LANES_BASE_BRANCH='bad..name' zsh "$T/lanes/cleanup-after-merge.sh" "$wt" > "$T/out" 2>&1 || rc=$?
[[ "$rc" == 2 && -d "$wt" ]] || fail '不正な LANES_BASE_BRANCH を通した'
ok '枝名として不正な LANES_BASE_BRANCH は exit 2'
rc=0; LANES_BASE_BRANCH=trunk zsh "$T/lanes/cleanup-after-merge.sh" "$wt" --apply > "$T/out" 2>&1 || rc=$?
[[ "$rc" == 0 && ! -d "$wt" ]] || fail 'LANES_BASE_BRANCH=trunk でマージ済みの worktree を片付けない'
git -C "$repo" show-ref -q --verify refs/heads/trunk || fail '統合先の枝 trunk を消した'
git -C "$repo" show-ref -q --verify refs/heads/feature && fail 'マージ済みのローカル枝が残った'
git -C "$case_root/origin.git" show-ref -q --verify refs/heads/trunk || fail 'リモートの統合先の枝を消した'
ok 'LANES_BASE_BRANCH の枝を基準に片付け、その枝は永久枝として残す'

print -- "PASS: $count 件"
