#!/bin/bash
# chk-run.sh / prepare-screen-qa.sh / vercel_autoredeploy.py の自己テスト
# 実行: bash lanes/tests/test-chk-run.sh
set -u
[ -n "${ZSH_VERSION:-}" ] && setopt NO_BG_NICE SH_WORD_SPLIT 2>/dev/null || true
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

caller_pwd=$(pwd -P) || exit 1
L=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
repo_top=$(cd "$L/../.." && pwd -P) || exit 1

# 確認コマンドの例として本物の npm（Node.js に付属）で package.json の scripts を回す。無ければ理由を出して止める
# （黙って対象外にしない。自己テストの前提として README の「前提」に Node.js・npm を書いてある）
command -v npm >/dev/null 2>&1 || { echo "ERROR: このテストは npm を使う（PATH に無い）。Node.js（npm 付き）を入れてから再実行する" >&2; exit 1; }
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || { echo "HOME が無効: ${HOME:-}" >&2; exit 1; }
if [ -n "${LANES_SCRATCH:-}" ] && [ ! -d "$LANES_SCRATCH" ]; then
  echo "LANES_SCRATCH が存在しない: $LANES_SCRATCH" >&2; exit 1
fi
if [ -n "${TMPDIR:-}" ] && [ ! -d "$TMPDIR" ]; then
  echo "TMPDIR が存在しない: $TMPDIR" >&2; exit 1
fi

base_tmp="${TEST_CHK_RUN_ROOT:-${LANES_SCRATCH:-${TMPDIR:-/tmp}}}"
base_tmp="${base_tmp%/}"
[ -n "$base_tmp" ] && [ -d "$base_tmp" ] || { echo "一時領域の親ディレクトリが無い: $base_tmp" >&2; exit 1; }
real_base=$(cd "$base_tmp" && pwd -P) || { echo "一時領域の親を解決できない: $base_tmp" >&2; exit 1; }
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "$(cd "$(dirname "$0")" && pwd -P)/_git-isolate.sh"; lanes_test_git_isolate "$real_base"

root=$(TMPDIR="$real_base" mktemp -d "$real_base/test-chk-run.XXXXXX") || { echo "一時領域の作成に失敗" >&2; exit 1; }
real_root=$(cd "$root" && pwd -P) || { echo "一時領域の解決に失敗: $root" >&2; exit 1; }
case "$real_root" in
  "$real_base"/test-chk-run.*) ;;
  *) echo "一時領域のパスが想定外: $real_root" >&2; exit 1 ;;
esac

cleanup() {
  cd / 2>/dev/null || true
  case "${real_root:-}" in
    "$real_base"/test-chk-run.*) rm -rf "$real_root" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT

mkdir -p "$real_root/r" "$real_root/out" || { echo "作業ディレクトリの作成に失敗: $real_root" >&2; exit 1; }
cd "$real_root/r" || { echo "作業ディレクトリへの移動に失敗: $real_root/r" >&2; exit 1; }
real_r=$(pwd -P) || exit 1
case "$real_r" in
  "$real_root"/r) ;;
  *) echo "現在のディレクトリが一時領域内ではない: $real_r" >&2; exit 1 ;;
esac
if [ "$real_r" = "$caller_pwd" ] || [ "$real_r" = "$L" ] || [ "$real_r" = "$repo_top" ]; then
  echo "作業先が呼び出し元または本体リポジトリと同一: $real_r" >&2
  exit 1
fi

export PYTHONPYCACHEPREFIX="$real_root/pycache"
git init -q || exit 1
lanes_test_assert_repo .
git config user.email t@t || exit 1
git config user.name t || exit 1
cat > package.json <<'J'
{"name":"t","private":true,"scripts":{"typecheck":"echo tc","test":"echo 3 件 OK","build":"echo build","smoke:iphone":"echo SMOKE_OK"}}
J
mkdir -p src docs; echo x > src/a.ts; echo d > docs/a.md; git add -A; git commit -qm c1 || exit 1
# 確認コマンドは設定キー LANES_CHECK_CMD で渡す（対象リポに .lanes/check.sh があればそちらが優先）
unset LANES_CHECK_CMD
export CHK_CACHE="$real_root/passed.tsv"
# npm がネットワークに触らないようにする（更新のお知らせの確認を止め、オフラインで動かす）
export npm_config_update_notifier=false npm_config_offline=true
export LANES_CHECK_CMD='npm run typecheck && npm test && npm run build && npm run smoke:iphone'
run() { bash "$L/chk-run.sh" "$real_root/r" 49999 "$real_root/out" "$@"; }
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
ng() { fail=$((fail+1)); echo "FAIL $1"; }
has() { if grep -qE "$3" <<< "$2"; then ok "$1"; else ng "$1（'$3' が無い）"; printf '%s\n' "$2" | sed 's/^/     /'; fi; }
hasnt() { if grep -qE "$3" <<< "$2"; then ng "$1（'$3' がある）"; else ok "$1"; fi; }

o=$(run); rc=$?;     has  "初回は全部回す"            "$o" '^check=0（'; has "初回を記録" "$o" '^recorded=.*full'; [ $rc = 0 ] && ok "初回 exit 0" || ng "初回 exit $rc"
hasnt "記録したときは「通ったが記録しない」の行を出さない" "$o" '^record=no'
o=$(run);            has  "同じ tree は飛ばす"        "$o" '^skip=same-tree'; has "check 行は残す" "$o" '^check=0 SKIP\(same-tree\)'
o=$(run --force);    has  "--force は回す"            "$o" '^check=0（'
echo d2 >> docs/a.md; mkdir -p src/tests; echo t > src/tests/x.test.ts; git add -A; git commit -qm docs
o=$(run);            has  "docs・テストだけは tc・test" "$o" '^check=0（'; has "docs・テスト差分でも build を回す" "$o" '^check=0（'; has "smoke も回す" "$o" '^check=0（'
o=$(run);            has  "その tree も次は飛ばす"    "$o" '^skip=same-tree'
echo y >> src/a.ts; git commit -qam code
o=$(run);            has  "コード変更は全部"          "$o" '^check=0（'; has "smoke も回す" "$o" '^check=0（'
echo z >> src/a.ts
o=$(run);            hasnt "未 commit の変更があると飛ばさない" "$o" 'skip='; hasnt "未 commit は記録しない" "$o" '^recorded='
# 通ったのに記録しないときは、黙らずに理由を出す（次も省かない・レビューが親の記録を使い回せない理由が分かるように）
has  "未 commit で記録しない理由を出す" "$o" '^record=no reason=uncommitted（.*未 commit の変更か未追跡のファイルがある: src/a\.ts）$'
git checkout -q -- src/a.ts
git checkout -q -b release HEAD; git commit -q --allow-empty -m rel
o=$(run);            has  "release 枝（tree 同じ）は飛ばす" "$o" '^skip=same-tree'

# ---- 問い合わせ（--query）: 回さずに、記録を使い回せるかだけ答える。何も実行・作成しない ----
q() { bash "$L/chk-run.sh" "$real_root/r" --query "$@"; }
qmark="$real_root/qmark"
saved_cmd=$LANES_CHECK_CMD
export LANES_CHECK_CMD="touch $qmark"
o=$(run);            has  "問い合わせの準備: 記録する" "$o" '^recorded='
rm -f "$qmark"; out_before=$(ls -la "$real_root/out"); lines_before=$(wc -l < "$CHK_CACHE")
o=$(q); rc=$?
has  "問い合わせ: 記録ありで yes"        "$o" '^reuse=yes$'
has  "問い合わせ: 記録の head を出す"    "$o" '^head=[0-9a-f]{12}$'
has  "問い合わせ: 記録の日時を出す"      "$o" '^recorded=.+'
has  "問い合わせ: 確認コマンドの種類"    "$o" '^check=LANES_CHECK_CMD$'
[ $rc = 0 ] && ok "問い合わせ: yes は exit 0" || ng "問い合わせ: yes なのに exit $rc"
[ ! -e "$qmark" ] && ok "問い合わせ: 確認コマンドを実行しない" || ng "問い合わせ: 確認コマンドを実行した"
[ "$(wc -l < "$CHK_CACHE")" = "$lines_before" ] && ok "問い合わせ: 記録を書かない" || ng "問い合わせ: 記録を書いた"
[ "$(ls -la "$real_root/out")" = "$out_before" ] && ok "問い合わせ: 出力先を書き換えない" || ng "問い合わせ: 出力先を書き換えた"
o=$(LANES_ENTRY_PREFLIGHT=1 LANES_REVIEW_REUSE_CHECKS=1 q); has "問い合わせ: 入口・ランチャの制御の値は指紋に入れない" "$o" '^reuse=yes$'
has  "問い合わせ: 照合した入力の指紋を出す" "$o" '^fp=.+'
# 指紋から外す制御の値は、確認コマンドにも届かない（届くと、値で結果を変えられるのに「同じ」と扱ってしまう）
o=$(LANES_REVIEW_REUSE_CHECKS=1 LANES_ENTRY_PREFLIGHT=1 LANES_CHECK_CMD='test -z "${LANES_REVIEW_REUSE_CHECKS:-}${LANES_ENTRY_PREFLIGHT:-}"' run --force); rc=$?
[ $rc = 0 ] && ok "制御の値（LANES_REVIEW_REUSE_CHECKS・LANES_ENTRY_PREFLIGHT）は確認コマンドに渡さない" || ng "制御の値が確認コマンドに届いた（exit $rc）"
o=$(LANES_CHECK_CMD="touch $qmark.b" q); rc=$?
has  "問い合わせ: 確認コマンドの変更で no" "$o" '^reuse=no reason=input-changed$'; [ $rc = 1 ] && ok "問い合わせ: no は exit 1" || ng "問い合わせ: no なのに exit $rc"
o=$(EXTRA_FOR_TEST=1 q); has "問い合わせ: 環境変数の違いで no" "$o" '^reuse=no reason=input-changed$'
echo w >> docs/a.md
o=$(q);              has  "問い合わせ: 未 commit の変更で no" "$o" '^reuse=no reason=uncommitted$'
git commit -qam q2
o=$(q);              has  "問い合わせ: tree が違えば no" "$o" '^reuse=no reason=no-record$'
[ ! -e "$qmark" ] && ok "問い合わせ: no のときも実行しない" || ng "問い合わせ: no のときに確認コマンドを実行した"
o=$(CHK_CACHE="$real_root/nocache/sub/passed.tsv" q)
has  "問い合わせ: 記録が無ければ no" "$o" '^reuse=no reason=no-record$'
[ ! -e "$real_root/nocache" ] && ok "問い合わせ: 記録のフォルダを作らない" || ng "問い合わせ: 記録のフォルダを作った"
printf '%s\tx\tfull\tx\tx\tx\n' "$(git rev-parse 'HEAD^{tree}')" > "$real_root/old.tsv"
o=$(CHK_CACHE="$real_root/old.tsv" q); has "問い合わせ: 旧形式（port・outdir の無い）記録は使わない" "$o" '^reuse=no reason=no-record$'
o=$(LANES_CONF="$real_root/none.conf" LANES_CHECK_CMD='' q); has "問い合わせ: 確認コマンドが無ければ no" "$o" '^reuse=no reason=no-check$'
q extra >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "問い合わせ: 余計な引数は exit 2" || ng "問い合わせ: 余計な引数で exit $rc"
bash "$L/chk-run.sh" "$real_root/no-such-wt" --query >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "問い合わせ: worktree が無ければ exit 2" || ng "問い合わせ: worktree が無いのに exit $rc"
bash "$L/chk-run.sh" "$real_root/r" --query --force >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "問い合わせ: --force と組み合わせたら exit 2" || ng "問い合わせ: --force と組み合わせて exit $rc"
export LANES_CHECK_CMD="$saved_cmd"

# ---- 追加テスト 1: test-chk-run.sh の作成・移動失敗時に呼び出し元を汚さない ----
guard_dir="$real_root/caller-repo"
mkdir -p "$guard_dir"
(
  cd "$guard_dir" || exit 1
  git init -q && lanes_test_assert_repo . && git config user.email c@c && git config user.name c
  echo '{"name":"caller-original"}' > package.json
  git add package.json && git commit -qm init
)
before_head=$(git -C "$guard_dir" rev-parse HEAD)
before_pkg=$(cat "$guard_dir/package.json")
(
  cd "$guard_dir" && TEST_CHK_RUN_ROOT="$real_root/no-such-parent/sub" bash "$L/tests/test-chk-run.sh" >/dev/null 2>&1
)
guard_rc=$?
after_head=$(git -C "$guard_dir" rev-parse HEAD)
after_pkg=$(cat "$guard_dir/package.json")
if [ $guard_rc != 0 ] && [ "$before_head" = "$after_head" ] && [ "$before_pkg" = "$after_pkg" ]; then
  ok "作成・移動失敗時は即終了し呼び出し元を変更しない"
else
  ng "作成・移動失敗時の保護失敗 (rc=$guard_rc head=$before_head->$after_head pkg=$after_pkg)"
fi

# ---- 追加テスト 2: chk-run.sh 検証失敗時の終了コード伝播と Git 失敗伝播 ----
cat > package.json <<'J'
{"name":"t","private":true,"scripts":{"typecheck":"exit 7","test":"echo 3 件 OK","build":"echo build","smoke:iphone":"echo SMOKE_OK"}}
J
git commit -qam "tc fail"
o=$(run); rc=$?
has "確認失敗時は check=7 を出力" "$o" '^check=7（'
hasnt "tc 失敗時は recorded しない" "$o" '^recorded='
hasnt "tc 失敗時は「通ったが記録しない」の行を出さない" "$o" '^record=no'
[ $rc != 0 ] && ok "tc 失敗時は非 0 終了 (rc=$rc)" || ng "tc 失敗なのに exit 0"

o=$(run --merge non-existent-ref-xyz 2>&1); rc=$?
[ $rc != 0 ] && ok "--merge 失敗時は非 0 終了" || ng "--merge 失敗なのに exit 0"

# package.json を正常に戻し新しい変更を入れて記録を確認
cat > package.json <<'J'
{"name":"t","private":true,"scripts":{"typecheck":"echo tc","test":"echo 3 件 OK","build":"echo build","smoke:iphone":"echo SMOKE_OK"}}
J
echo recovered >> src/a.ts
git commit -qam "restore pkg"
o=$(run); has "復旧後は再度記録" "$o" '^recorded=.*full'
# 監督役が起動ごとに振る識別子や端末の接続 ID だけが違うなら、同じ入力として省略する。
o=$(LANES_PROCESS_TOKEN="run-$$-a" TERM_SESSION_ID="session-$$" run)
has "監督用の識別子が変わっても same-tree 省略する" "$o" '^skip=same-tree'

# ---- 追加テスト 3: 環境変数・導入済み依存・未追跡ファイルの変化で省略しない ----
o=$(EXTRA_VERIFY_ENV="changed-value" run)
hasnt "環境変数が変わったら same-tree 省略しない" "$o" '^skip=same-tree'

mkdir -p node_modules/fake-dep
echo "v1" > node_modules/fake-dep/index.js
o=$(run)
hasnt "node_modules が増えたら same-tree 省略しない" "$o" '^skip=same-tree'
rm -rf node_modules

echo "untracked" > src/untracked.ts
o=$(run)
hasnt "未追跡ファイルがあれば same-tree 省略しない" "$o" '^skip=same-tree'
hasnt "未追跡ファイルがあれば記録しない" "$o" '^recorded='
has  "未追跡ファイルで記録しない理由を出す" "$o" '^record=no reason=uncommitted（.*未 commit の変更か未追跡のファイルがある: src/untracked\.ts）$'
rm -f src/untracked.ts

# ---- 追加テスト 4: 確認コマンドの失敗・裏で立てたプロセスの回収・ポートの受け渡し ----
o=$(LANES_CHECK_CMD="false" run --force); rc=$?
has "確認コマンド失敗時は check=1" "$o" '^check=1（'
hasnt "確認コマンド失敗時は記録しない" "$o" '^recorded='
[ $rc != 0 ] && ok "確認コマンド失敗時は非 0 終了" || ng "確認コマンド失敗なのに exit 0"

# 秒数に自分の pid（$$）を混ぜて一意にする。並行して回る別のテスト（clone を並べた selftest など）の sleep を数えない
bg_secs="21.0$$7"
o=$(LANES_CHECK_CMD="(sleep $bg_secs &) ; npm run build" run --force); rc=$?
has "裏でプロセスを立てても確認コマンドの結果を返す" "$o" '^check=0（'
sleep 0.5; left=$(pgrep -f "^sleep ${bg_secs//./\\.}\$" 2>/dev/null | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok "確認コマンドが裏で立てたプロセスを監督役が回収する" || ng "確認コマンドの孫が残った（${left} 件）"

o=$(LANES_CHECK_CMD='test "$LANES_CHECK_PORT" = 49999 && test -d "$LANES_CHECK_OUTDIR"' run --force); rc=$?
has "確認コマンドへ LANES_CHECK_PORT と LANES_CHECK_OUTDIR を渡す" "$o" '^check=0（'

# 出力先も再利用の条件に入る: 出力先 A でだけ通る確認を記録したあと、出力先 B では記録を流用せずに回す
mkdir -p "$real_root/out-b"
outdir_cmd='case "$LANES_CHECK_OUTDIR" in */out) exit 0 ;; *) exit 6 ;; esac'
o=$(LANES_CHECK_CMD="$outdir_cmd" run --force); has "出力先 A でだけ通る確認を記録" "$o" '^recorded=.*full'
o=$(LANES_CHECK_CMD="$outdir_cmd" run); has "同じ出力先 A なら飛ばす" "$o" '^skip=same-tree'
o=$(LANES_CHECK_CMD="$outdir_cmd" bash "$L/chk-run.sh" "$real_root/r" 49999 "$real_root/out-b"); rc=$?
hasnt "出力先を変えたら記録を流用しない" "$o" '^skip=same-tree'
has "出力先 B では回して失敗する" "$o" '^check=6（'
[ $rc != 0 ] && ok "出力先 B の失敗は非 0 終了" || ng "出力先 B で失敗なのに exit 0"
# 同じ出力先を別の書き方（末尾の / や ..）で渡しても、正規化して同じものとして扱う
o=$(LANES_CHECK_CMD="$outdir_cmd" bash "$L/chk-run.sh" "$real_root/r" 49999 "$real_root/out-b/../out/"); has "出力先は正規化して比べる" "$o" '^skip=same-tree'

# 設定が無ければ何も回さず exit 2 で設定方法を出す
o=$(LANES_CHECK_CMD='' run 2>&1); rc=$?
[ $rc = 2 ] && ok "確認コマンド未設定なら exit 2" || ng "確認コマンド未設定で exit $rc"
has "未設定時は設定方法を出す" "$o" 'LANES_CHECK_CMD'
has "未設定時は .lanes/check.sh の置き方も出す" "$o" '\.lanes/check\.sh'
hasnt "未設定時は確認を回さない" "$o" '^check='

# .lanes/check.sh があれば LANES_CHECK_CMD より優先する（無視対象に置けば未 commit 扱いにならない）
printf '.lanes/\n' >> .git/info/exclude
mkdir -p .lanes
printf 'echo FROM_REPO_CHECK\nexit 5\n' > .lanes/check.sh
o=$(LANES_CHECK_CMD="true" run --force); rc=$?
has ".lanes/check.sh を優先して回す" "$o" '^check=5（\.lanes/check\.sh）'
grep -q FROM_REPO_CHECK "$real_root/out/check.log" && ok ".lanes/check.sh の出力を check.log に残す" || ng ".lanes/check.sh の出力が check.log に無い"
rm -rf .lanes

# ---- 追加テスト 5: ビルドが読む Markdown を壊したときにビルドを省略しない ----
cat > package.json <<'J'
{"name":"t","private":true,"scripts":{"typecheck":"echo tc","test":"echo 3 件 OK","build":"grep -q GOOD_MD docs/a.md && echo build","smoke:iphone":"echo SMOKE_OK"}}
J
echo "GOOD_MD" > docs/a.md
git add -A && git commit -qm "build reads docs/a.md"
o=$(run); has "Markdown 参照ビルド初回成功" "$o" '^recorded=.*full'
echo "BROKEN_MD" > docs/a.md
git commit -qam "break docs/a.md"
o=$(run); rc=$?
hasnt "ビルドが読む Markdown 変更時は build を省略しない" "$o" '^check=0 SKIP'
has "壊れた Markdown で check=1" "$o" '^check=1（'
[ $rc != 0 ] && ok "壊れた Markdown で非 0 終了" || ng "壊れた Markdown なのに exit 0"

# ---- 追加テスト 5b: node_modules 内の実行ファイルの実行権限変更で省略しない ----
echo "node_modules/" > .gitignore
mkdir -p node_modules/.bin
cat > node_modules/.bin/fake-builder <<'SH'
#!/bin/sh
echo build
SH
chmod +x node_modules/.bin/fake-builder
cat > package.json <<'J'
{"name":"t","private":true,"scripts":{"typecheck":"echo tc","test":"echo 3 件 OK","build":"./node_modules/.bin/fake-builder","smoke:iphone":"echo SMOKE_OK"}}
J
echo "GOOD_MD" > docs/a.md
git add .gitignore package.json docs/a.md && git commit -qm "use fake-builder in node_modules"
o=$(run); rc=$?
has "fake-builder 初回成功を記録" "$o" '^recorded=.*full'
o=$(run)
has "fake-builder 権限同一なら same-tree 省略" "$o" '^skip=same-tree'
chmod -x node_modules/.bin/fake-builder
o=$(run); rc=$?
hasnt "fake-builder の chmod -x 後は same-tree 省略しない" "$o" '^skip=same-tree'
has "fake-builder の chmod -x 後は check=126" "$o" '^check=126（'
[ $rc != 0 ] && ok "fake-builder の chmod -x 後は非 0 終了" || ng "fake-builder の chmod -x 後なのに exit 0"
rm -rf node_modules

# ---- 追加テスト 5c: 本物の npm の形（node_modules/.bin/* が作業ツリー内へのシンボリックリンク）----
mkdir -p node_modules/fake-builder/bin node_modules/.bin
cat > node_modules/fake-builder/bin/cli.js <<'SH'
#!/bin/sh
echo build
SH
chmod +x node_modules/fake-builder/bin/cli.js
ln -s ../fake-builder/bin/cli.js node_modules/.bin/fake-builder
echo "GOOD_MD_5C" > docs/a.md
git commit -qam "5c: npm 形の .bin リンク"
o=$(run)
has "作業ツリー内を指す .bin リンクでも成功を記録する" "$o" '^recorded=.*full'
o=$(run)
has "作業ツリー内リンクの記録を同じ tree で使い回す" "$o" '^skip=same-tree'
qo=$(q 2>/dev/null)
has "作業ツリー内リンクの記録を問い合わせで使い回せる" "$qo" '^reuse=yes'
printf '#!/bin/sh\necho build changed\n' > node_modules/fake-builder/bin/cli.js
o=$(run)
hasnt "リンク先の中身が変わったら省略しない" "$o" '^skip=same-tree'
# 作業ツリーの外を指すリンクは今までどおり記録しない
outside_dir="$real_root/outside-5c"; mkdir -p "$outside_dir"
printf '#!/bin/sh\necho build\n' > "$outside_dir/cli.sh"; chmod +x "$outside_dir/cli.sh"
rm node_modules/.bin/fake-builder; ln -s "$outside_dir/cli.sh" node_modules/.bin/fake-builder
o=$(run --force)
has "外を指すリンクでも確認自体は通る" "$o" '^check=0（'
hasnt "作業ツリーの外を指すリンクは記録しない" "$o" '^recorded='
has  "外を指すリンクで記録しない理由を出す" "$o" '^record=no reason=unresolvable（.*作業ツリーの外（か \.git の中）を指すリンク: node_modules/\.bin/fake-builder'
qo=$(q 2>/dev/null)
has "外を指すリンクがあれば問い合わせは reuse=no" "$qo" '^reuse=no'
# 行き先の無いリンクも記録しない
rm node_modules/.bin/fake-builder; ln -s ../fake-builder/bin/cli.js node_modules/.bin/fake-builder
ln -s ../nowhere/missing node_modules/.bin/dangling
o=$(run --force)
has "行き先の無いリンクでも確認自体は通る" "$o" '^check=0（'
hasnt "行き先の無いリンクがあれば記録しない" "$o" '^recorded='
has  "行き先の無いリンクで記録しない理由を出す" "$o" '^record=no reason=unresolvable（.*行き先の無いリンク: node_modules/\.bin/dangling'
rm node_modules/.bin/dangling
# 中を指すディレクトリリンク（npm workspaces / pnpm の形）は記録して使い回す
mkdir -p packages/pkg; echo "PKG_V1" > packages/pkg/index.js
echo "packages/" >> .git/info/exclude
ln -s ../packages/pkg node_modules/pkg
o=$(run --force)
has "中を指すディレクトリリンクで記録する" "$o" '^recorded=.*full'
o=$(run)
has "中を指すディレクトリリンクで使い回す" "$o" '^skip=same-tree'
echo "PKG_V2" > packages/pkg/index.js
o=$(run)
hasnt "ディレクトリリンク先の中身が変わったら省略しない" "$o" '^skip=same-tree'
# その奥に外を指すリンクがあれば記録しない
ln -s "$outside_dir/cli.sh" packages/pkg/outside
o=$(run --force)
has "奥に外リンクがあっても確認自体は通る" "$o" '^check=0（'
hasnt "ディレクトリリンクの奥に外へのリンクがあれば記録しない" "$o" '^recorded='
rm packages/pkg/outside
# .git の中を指すリンク（大文字違いも）は記録しない
ln -s ../../.git/HEAD node_modules/.bin/githead
o=$(run --force)
has ".git の中を指すリンクでも確認自体は通る" "$o" '^check=0（'
hasnt ".git の中を指すリンクは記録しない" "$o" '^recorded='
rm node_modules/.bin/githead
if [ -e .GIT ]; then
  ln -s ../../.GIT/HEAD node_modules/.bin/githead
  o=$(run --force)
  has "大文字違いの .GIT を指すリンクでも確認自体は通る" "$o" '^check=0（'
  hasnt "大文字違いの .GIT を指すリンクも記録しない" "$o" '^recorded='
  rm node_modules/.bin/githead
fi
rm -rf node_modules packages "$outside_dir"

# ---- 追加テスト 6: prepare-screen-qa.sh の URL 認証情報秘匿・IPv6 角括弧保持・ラベル検証 ----
qa_repo="$real_root/qa-repo"
mkdir -p "$qa_repo"
(
  cd "$qa_repo" || exit 1
  git init -q && lanes_test_assert_repo . && git config user.email q@q && git config user.name q
  echo q > a.txt && git add a.txt && git commit -qm init
  git remote add origin "https://user_placeholder:token_placeholder_123@example.com/org/unknown-repo.git?secret_param=999"
)
qa_err=$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" valid-label --url "https://preview.example.com" 2>&1 >/dev/null)
hasnt "未知 origin 警告に認証情報を出さない" "$qa_err" 'token_placeholder_123|user_placeholder|secret_param'
has "未知 origin 警告に接続先名だけ出す" "$qa_err" 'example\.com/org/unknown-repo'

qa_v6_out=$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" ipv6-label --url "http://[::1]:4173/check" 2>/dev/null)
has "IPv6 ポート付き URL の角括弧を保持する" "$qa_v6_out" '^preview=http://\[::1\]:4173/check$'
has "IPv6 URL が meta にも角括弧付きで書かれる" "$(cat "$qa_repo/logs/ipv6-label.meta.txt")" '^preview=http://\[::1\]:4173/check$'

qa_v6_noport=$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" ipv6-noport --url "http://user_placeholder:token_placeholder_123@[2001:db8::1]/check?secret_param=1#frag" 2>/dev/null)
has "IPv6 ポートなし URL でも角括弧を保持し認証情報とクエリを除去する" "$qa_v6_noport" '^preview=http://\[2001:db8::1\]/check$'

git -C "$qa_repo" remote set-url origin "git@[::1]:org/unknown-repo.git"
qa_v6_origin_err=$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" ipv6-origin --url "http://[::1]:4173/check" 2>&1 >/dev/null)
has "SCP 形式の IPv6 origin でも角括弧付き接続先名を出す" "$qa_v6_origin_err" '\[::1\]/org/unknown-repo'

zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" "../escaped" --url "https://preview.example.com" >/dev/null 2>&1
qa_bad_rc=$?
if [ $qa_bad_rc != 0 ] && [ ! -e "$qa_repo/escaped.prompt.md" ]; then
  ok "prepare-screen-qa.sh は ../ ラベルを拒否し logs/ 外に書かない"
else
  ng "prepare-screen-qa.sh が不正ラベルを通した (rc=$qa_bad_rc)"
fi

# ---- 追加テスト 7: vercel_autoredeploy.py の再々デプロイ防止・途中失敗時の履歴保持・排他制御 ----
py_out=$(python3 - "$L" "$real_root" <<'PY'
import fcntl, os, sys, time
lanes_dir, root = sys.argv[1:3]
sys.path.insert(0, lanes_dir)
import vercel_autoredeploy as va

# 7z: LANES_VERCEL_PROJECT が空なら何もせず「無効」と出す（vercel を呼ばない）
va.PROJECT = ""
va._vc = lambda *a, **k: (_ for _ in ()).throw(AssertionError("無効なのに vercel を呼んだ"))
z_lines, z_wakes = va.run()
assert z_wakes == [] and len(z_lines) == 1 and "無効" in z_lines[0], f"disabled: {z_lines}"
va.PROJECT = "my-app"
va.SCOPE = "my-team"

va.STATE = os.path.join(root, "vercel-state.json")
now_ms = int(time.time() * 1000)

# 7a: 再デプロイ先が同じ Git information retrieval failed で ERROR になっても再々デプロイしない
redeploy_calls = []
deps_step1 = [
    {"url": "my-app-orig1-my-team.example.vercel.app", "state": "ERROR", "createdAt": now_ms - 60000, "target": "preview", "meta": {"githubCommitRef": "feat/x", "githubCommitSha": "1111111"}},
]
deps_step2 = [
    {"url": "my-app-retry1-my-team.example.vercel.app", "state": "ERROR", "createdAt": now_ms - 30000, "target": "preview", "meta": {"githubCommitRef": "feat/x", "githubCommitSha": "1111111"}},
    {"url": "my-app-orig1-my-team.example.vercel.app", "state": "ERROR", "createdAt": now_ms - 60000, "target": "preview", "meta": {"githubCommitRef": "feat/x", "githubCommitSha": "1111111"}},
]
current_deps = deps_step1
va._list = lambda: current_deps
va._inspect = lambda url: {"target": "preview", "status": "Error", "reason": va.GIT_FAIL}
def fake_vc(args, timeout=40):
    if args and args[0] == "redeploy":
        redeploy_calls.append(args[1])
        return 0, f"https://my-app-retry{len(redeploy_calls)}-my-team.example.vercel.app\n", ""
    return 0, "", ""
va._vc = fake_vc

lines1, wakes1 = va.run()
current_deps = deps_step2
lines2, wakes2 = va.run()
assert redeploy_calls == ["my-app-orig1-my-team.example.vercel.app"], f"unexpected redeploy_calls: {redeploy_calls}"

# 7b: 1件目の再デプロイ成功後に2件目の _inspect が例外で失敗しても、次回1件目を再実行しない
va.STATE = os.path.join(root, "vercel-state-2.json")
redeploy_calls.clear()
current_deps = [
    {"url": "my-app-d1-my-team.example.vercel.app", "state": "ERROR", "createdAt": now_ms - 50000, "target": "preview", "meta": {"githubCommitRef": "feat/a", "githubCommitSha": "2222222"}},
    {"url": "my-app-d2-my-team.example.vercel.app", "state": "ERROR", "createdAt": now_ms - 40000, "target": "preview", "meta": {"githubCommitRef": "feat/b", "githubCommitSha": "3333333"}},
]
def flaky_inspect(url):
    if "d2" in url:
        raise RuntimeError("inspect failed on d2")
    return {"target": "preview", "status": "Error", "reason": va.GIT_FAIL}
va._inspect = flaky_inspect
va.run()
assert redeploy_calls == ["my-app-d1-my-team.example.vercel.app"], f"step1 calls: {redeploy_calls}"
# 次回は d2 も正常応答になったとする -> d1 は再実行されず d2 だけ実行されること
va._inspect = lambda url: {"target": "preview", "status": "Error", "reason": va.GIT_FAIL}
va.run()
assert redeploy_calls == ["my-app-d1-my-team.example.vercel.app", "my-app-d2-my-team.example.vercel.app"], f"step2 calls: {redeploy_calls}"

# 7c: ロック保持中は同時実行を排除する
va.STATE = os.path.join(root, "vercel-state-3.json")
redeploy_calls.clear()
lock_fh = open(va.STATE + ".lock", "a+", encoding="utf-8")
fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
lines_locked, wakes_locked = va.run()
fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
lock_fh.close()
assert redeploy_calls == [] and lines_locked == [], f"should skip when locked: {redeploy_calls}"
# 7d: 再デプロイ先 URL は「プロジェクト名-識別子-スコープ」の形を優先して拾う（元の URL は選ばない）
picked = va._extract_redeploy_url("src https://my-app-orig1-my-team.example.vercel.app\nnew https://other-x.example.vercel.app", "my-app-orig1-my-team.example.vercel.app")
assert picked == "other-x.example.vercel.app", f"fallback pick: {picked}"
print("PY_TESTS_OK")
PY
)
has "vercel_autoredeploy.py の自己テスト成功" "$py_out" '^PY_TESTS_OK$'

sleep 1; left=$(pgrep -f "sleep 21.37" 2>/dev/null | wc -l | tr -d ' ')
echo "（確認コマンドが裏で立てた sleep の残り: ${left}）"
echo "---- $pass passed, $fail failed"
[ $fail = 0 ]
