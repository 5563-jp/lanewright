#!/bin/zsh -f
# selftest.sh の見張りのテスト。テストが本物のリポ（ここではキットのコピー）を書き換えたら selftest.sh が赤になることを確かめる。
# キットをコピーした一時リポに、わざと漏らす偽テストを置き、そのコピーの selftest.sh を --test で 1 本ずつ回す。
#   - 何もしない偽テスト → 緑（exit 0）
#   - キットへ commit する偽テスト → 赤（exit 1・HEAD が変わった）
#   - GIT_DIR・GIT_WORK_TREE を付けて一時ディレクトリで git init する偽テスト（実際に起きた漏れ方。core.worktree が書かれる）→ 赤（exit 1・設定ファイルが変わった）
#   - キットに未保存の変更を残す偽テスト → 赤（exit 1）
#   - 既にある未保存の変更（追跡・未追跡）を、同じ「M」「??」のまま中身だけ上書きする偽テスト → 赤（中身の指紋）
#   - 索引だけ変える（変更検知の省略の印）・同じ commit のまま枝を切り替える・枝やタグを作る・stash する・
#     worktree を足す・info/exclude や hooks を書く・無視対象の logs/ に書く偽テスト → それぞれ赤
#   - info/attributes・objects/info/alternates・hooks の下のフォルダに書く・リモート追跡の ref を作る・リモートへ push する・
#     他の worktree で checkout 中の枝を進める偽テスト → それぞれ赤
#   - テストへ渡す環境の GIT_ALLOW_PROTOCOL が file であること。TMPDIR がキットの中なら exit 2
#   - テストから見える gh が偽物で、GitHub の認証関連の環境変数が外れていること
#   - 出力に「LANES_PARTIAL: <理由>」を出した緑のテストは、表で「緑(一部)」になり、理由が表の下に出ること
#   - LANES_PRIVATE_DENYLIST（固有名の検査の禁止語ファイル）は、渡したときだけ絶対パスでテストへ届き、ほかの LANES_* は届かないこと
#   - LANES_TEST_SOCKET_ROOT（一時 PostgreSQL のソケットの逃がし先）は、渡せばそのまま、渡さなければ selftest の一時領域の中の
#     浅い場所がテストへ届くこと。無いフォルダ・キットの中なら exit 2
#   - 呼び出し元に GIT_ALLOW_PROTOCOL=lanes-no-transport（レビュー・QA のランチャが付ける通信の禁止）が残っていても、
#     隔離したテストの中では一時リポ間の file の push が通ること（ssh・https は許さないまま）
# 本物のキットのリポには触らない（コピーにだけ書く）。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h:h}/lanes/tests/_git-isolate.sh"; lanes_test_git_isolate
# 呼び出し元（selftest に禁止語ファイルを渡した場合など）の値を持ち込まない。必要な所では明示して渡す
unset LANES_PRIVATE_DENYLIST LANES_TEST_SOCKET_ROOT
KIT="${0:A:h:h}"
base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$base" && -d "$base" ]] || { print -u2 -- 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${base%/}/sg.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }
command -v rsync >/dev/null 2>&1 || fail "rsync が無い"

# キットのコピー（.git・ログは持ち込まない）を一時リポにする
copy="$T/kit"
rsync -a --exclude .git --exclude logs --exclude .lanes --exclude __pycache__ "$KIT/" "$copy/"
git init -q -b main "$copy"; lanes_test_assert_repo "$copy"
git -C "$copy" add -A
git -C "$copy" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: コピーの初期状態'

fake() {   # <名前> <中身>: コピーの tests/ に偽テストを置いて commit する（未保存の変更として数えないため）
  print -r -- $'#!/bin/zsh -f\nset -euo pipefail\nKIT="${0:A:h:h}"\n'"$2" > "$copy/tests/$1"
  git -C "$copy" add "tests/$1"
  git -C "$copy" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm "test: 偽テスト $1"
}
fake test-zz-clean.sh 'exit 0'
fake test-zz-leak-commit.sh 'git -C "$KIT" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit --allow-empty -qm "test: 初期化"'
fake test-zz-leak-gitdir.sh 'd="$(mktemp -d)"; GIT_DIR="$KIT/.git" GIT_WORK_TREE="$d" git init -q "$d" >/dev/null 2>&1 || true'
fake test-zz-leak-dirty.sh 'print -r -- leak > "$KIT/leak.txt"'

run_guard() {   # <期待 rc> <偽テスト>
  local want="$1" name="$2" rc=0
  zsh -f "$copy/selftest.sh" --profile claude-only --test "tests/$name" > "$T/$name.out" 2>&1 || rc=$?
  (( rc == want )) || { cat "$T/$name.out" >&2; fail "$name で selftest.sh が exit $want にならない（$rc）"; }
  OUT="$(< "$T/$name.out")"
}
run_guard 0 test-zz-clean.sh
[[ "$OUT" == *"キットのリポ: 変化なし"* ]] || fail "何もしない偽テストで「変化なし」が出ない"
pass "何もしない偽テストは緑（キットのリポは変化なし）"

head_before="$(git -C "$copy" rev-parse HEAD)"
run_guard 1 test-zz-leak-commit.sh
[[ "$OUT" == *"キットのリポが変わった"*"head"* && "$OUT" == *"作業枝に commit ができた"* ]] || fail "commit の漏れを赤にしない"
[[ "$(git -C "$copy" rev-parse HEAD)" != "$head_before" ]] || fail "偽テストが commit できていない（テストの前提が崩れている）"
pass "キットへ commit する偽テストで selftest.sh が赤になる"
git -C "$copy" reset -q --soft "$head_before"

run_guard 1 test-zz-leak-gitdir.sh
[[ "$OUT" == *"キットのリポが変わった"*"config"* ]] || fail "GIT_DIR 経由の設定の漏れを赤にしない"
git -C "$copy" config --get core.worktree >/dev/null || fail "偽テストが設定を書けていない（テストの前提が崩れている）"
[[ "$OUT" != *"$(git -C "$copy" config --get core.worktree)"* ]] || fail "設定の値をそのまま表示した"
pass "GIT_DIR を付けた git init の漏れで selftest.sh が赤になる（設定の値は表示しない）"
git -C "$copy" config --unset core.worktree

run_guard 1 test-zz-leak-dirty.sh
[[ "$OUT" == *"キットのリポが変わった"*"status"* ]] || fail "未保存の変更の漏れを赤にしない"
pass "キットに未保存の変更を残す偽テストで selftest.sh が赤になる"

# ---- 見張りの範囲を広げた分（1 種類ずつ、偽テストで赤になることを確かめる） ----
G='-c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false'
# 既にある未保存の変更（追跡ファイルの M）を、同じ M のまま中身だけ上書きする
fake test-zz-overwrite-tracked.sh 'print -r -- other > "$KIT/README.md"'
fake test-zz-overwrite-untracked.sh 'print -r -- other > "$KIT/scratch-note.txt"'
fake test-zz-index.sh 'git -C "$KIT" update-index --assume-unchanged LICENSE'
fake test-zz-switch.sh 'git -C "$KIT" checkout -q -b zz-other'
fake test-zz-branch.sh 'git -C "$KIT" branch zz-branch'
fake test-zz-tag.sh 'git -C "$KIT" tag zz-tag'
fake test-zz-stash.sh 'print -r -- x >> "$KIT/LICENSE"; git -C "$KIT" '"$G"' stash -q'
fake test-zz-worktree.sh 'git -C "$KIT" worktree add -q --detach "$(mktemp -d)/w"'
fake test-zz-exclude.sh 'print -r -- zz >> "$KIT/.git/info/exclude"'
fake test-zz-hook.sh 'print -r -- "#!/bin/sh" > "$KIT/.git/hooks/post-checkout"; chmod +x "$KIT/.git/hooks/post-checkout"'
fake test-zz-logs.sh 'mkdir -p "$KIT/logs"; print -r -- x > "$KIT/logs/leak.log"'

expect_red() {   # <偽テスト> <赤の種類> <説明>
  run_guard 1 "$1"
  [[ "$OUT" == *"キットのリポが変わった"*"$2"* ]] || { print -r -- "$OUT" >&2; fail "$3 を赤にしない（$2）"; }
  pass "$3で selftest.sh が赤になる（$2）"
}

print -r -- pre >> "$copy/README.md"
print -r -- pre > "$copy/scratch-note.txt"
expect_red test-zz-overwrite-tracked.sh content "既にある未保存の変更（追跡ファイル）の中身だけの上書き"
[[ "$(git -C "$copy" status --porcelain README.md)" == " M README.md" ]] || fail "前提が崩れている（README.md の状態）"
expect_red test-zz-overwrite-untracked.sh content "既にある未追跡ファイルの中身だけの上書き"
git -C "$copy" checkout -q -- README.md; rm -f "$copy/scratch-note.txt"

expect_red test-zz-index.sh index "変更検知の省略の印（索引だけの変更）"
git -C "$copy" update-index --no-assume-unchanged LICENSE

expect_red test-zz-switch.sh symref "同じ commit のままの枝の切り替え"
git -C "$copy" checkout -q main; git -C "$copy" branch -q -D zz-other

expect_red test-zz-branch.sh refs "枝を作る"
git -C "$copy" branch -q -D zz-branch
expect_red test-zz-tag.sh refs "タグを作る"
git -C "$copy" tag -d zz-tag >/dev/null

expect_red test-zz-stash.sh stash "stash"
git -C "$copy" stash drop -q

expect_red test-zz-worktree.sh worktrees "worktree を足す"
git -C "$copy" worktree list --porcelain | sed -n 's/^worktree //p' | while read -r w; do
  [[ "${w:A}" == "${copy:A}" ]] || git -C "$copy" worktree remove --force "$w"
done

cp "$copy/.git/info/exclude" "$T/exclude.bak"
expect_red test-zz-exclude.sh hooks "info/exclude への追記"
cp "$T/exclude.bak" "$copy/.git/info/exclude"
expect_red test-zz-hook.sh hooks "hooks を置く"
rm -f "$copy/.git/hooks/post-checkout"

expect_red test-zz-logs.sh status "無視対象の logs/ への書き込み"
rm -rf "$copy/logs"

# ---- 前後比較で見えなかった所（info/attributes・alternates・hooks の下のフォルダ・リモート追跡・他の worktree の枝・push）----
fake test-zz-attributes.sh 'print -r -- "* -text" >> "$KIT/.git/info/attributes"'
fake test-zz-alternates.sh 'd="$(mktemp -d)"; git init -q --bare "$d/o.git"; print -r -- "$d/o.git/objects" >> "$KIT/.git/objects/info/alternates"'
fake test-zz-hooksub.sh 'mkdir -p "$KIT/.git/hooks/sub"; print -r -- "#!/bin/sh" > "$KIT/.git/hooks/sub/x"'
fake test-zz-remote-ref.sh 'git -C "$KIT" update-ref refs/remotes/origin/zz HEAD'
fake test-zz-push.sh 'git -C "$KIT" push -q origin HEAD:refs/heads/zz-pushed'
fake test-zz-other-wt.sh 'git -C "'"$T"'/owt" '"$G"' commit --allow-empty -qm "test: 他の worktree の枝を進める"'

expect_red test-zz-attributes.sh hooks "info/attributes への追記"
rm -f "$copy/.git/info/attributes"
expect_red test-zz-alternates.sh hooks "objects/info/alternates への追記"
rm -f "$copy/.git/objects/info/alternates"
expect_red test-zz-hooksub.sh hooks "hooks の下のフォルダにファイルを置く"
rm -rf "$copy/.git/hooks/sub"
expect_red test-zz-remote-ref.sh refs "リモート追跡の ref を作る"
git -C "$copy" update-ref -d refs/remotes/origin/zz
# リモートの名前を使った push は、リモート追跡の ref が動くので赤になる（file のリモートなので通信は通る）
git init -q --bare "$T/remote.git"
git -C "$copy" remote add origin "$T/remote.git"
git -C "$copy" push -q origin main
expect_red test-zz-push.sh refs "リモートへの push"
[[ -n "$(git -C "$T/remote.git" for-each-ref refs/heads/zz-pushed)" ]] || fail "偽テストが push できていない（テストの前提が崩れている）"
git -C "$copy" remote remove origin
# 他の worktree で checkout 中の枝を動かしても赤になる（前は並行作業と区別できないので見ていなかった）
git -C "$copy" worktree add -q -b zz-wt "$T/owt"
expect_red test-zz-other-wt.sh refs "他の worktree で checkout 中の枝を進める"
git -C "$copy" worktree remove --force "$T/owt"; git -C "$copy" branch -q -D zz-wt

# テストへ渡す環境で git の通信を file だけにする（呼び出し元に値が無くても、テストが自分で置き直さなくても）
fake test-zz-proto.sh '[[ "${GIT_ALLOW_PROTOCOL:-}" == file ]]'
rc=0; env -u GIT_ALLOW_PROTOCOL zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-proto.sh > "$T/proto.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/proto.out" >&2; fail "テストへ GIT_ALLOW_PROTOCOL=file が渡らない"; }
pass "テストへ渡す環境で git の通信を file だけにする"

# TMPDIR がキットの中にあると、作業フォルダがキットの中にできるので使い方の誤り（exit 2）にする
mkdir -p "$copy/tmp-in-kit"
rc=0; TMPDIR="$copy/tmp-in-kit" zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-clean.sh > "$T/tmpin.out" 2>&1 || rc=$?
(( rc == 2 )) && grep -q 'TMPDIR がキットの中にある' "$T/tmpin.out" && [[ -z "$(ls -A "$copy/tmp-in-kit")" ]] \
  || { cat "$T/tmpin.out" >&2; fail "TMPDIR がキットの中にあっても止まらない（rc=$rc）"; }
rmdir "$copy/tmp-in-kit"
pass "TMPDIR がキットの中にあれば何も作らずに exit 2"

# テストから見える gh は selftest の偽物で（未ログインの終了コード 4）、GitHub の認証関連の環境変数は外れている
fake test-zz-gh.sh 'rc=0; gh auth status >/dev/null 2>&1 || rc=$?; [[ $rc == 4 && -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_HOST:-}" ]]'
rc=0; GH_TOKEN=dummy GITHUB_TOKEN=dummy GH_HOST=github.example.com zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-gh.sh > "$T/gh.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/gh.out" >&2; fail "テストに本物の gh か GitHub の認証の環境変数が届いた"; }
pass "テストには偽の gh だけが見え、GitHub の認証関連の環境変数は届かない"

# レビュー・QA のランチャの中から selftest を回したとき（GIT_ALLOW_PROTOCOL=lanes-no-transport が残る）でも、
# 隔離したテストの中では一時リポ間の file の push が通り、https は許されないまま
fake test-zz-file-push.sh 'source "$KIT/lanes/tests/_git-isolate.sh"; lanes_test_git_isolate
[[ "$GIT_ALLOW_PROTOCOL" == file ]] || { print -u2 -- "GIT_ALLOW_PROTOCOL が file でない"; exit 1; }
d="$(mktemp -d "${TMPDIR%/}/fp.XXXXXX")"
git init -q --bare "$d/r.git"; git init -q -b main "$d/w"; lanes_test_assert_repo "$d/w"
git -C "$d/w" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit --allow-empty -qm "test: 初期化"
git -C "$d/w" push -q "$d/r.git" HEAD:refs/heads/x
git clone -q "$d/r.git" "$d/c"
if git -C "$d/w" push -q https://example.com/owner/repo.git HEAD:refs/heads/x 2>"$d/err"; then exit 1; fi
grep -q "not allowed" "$d/err"'
rc=0; GIT_ALLOW_PROTOCOL=lanes-no-transport zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-file-push.sh > "$T/fp.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/fp.out" >&2; fail "GIT_ALLOW_PROTOCOL=lanes-no-transport が残ると、隔離したテストで一時リポ間の push が通らない"; }
pass "通信の禁止が残った呼び出し元からでも、隔離したテストでは file の push だけが通る（https は拒否のまま）"

# 一部だけ確かめた緑は「緑(一部)」と出し、理由を表の下に並べる
fake test-zz-partial.sh 'print -r -- "LANES_PARTIAL: 試しの理由"; exit 0'
run_guard 0 test-zz-partial.sh
[[ "$OUT" == *"| tests/test-zz-partial.sh | 緑(一部) |"* && "$OUT" == *"緑(一部) の内訳:"*"試しの理由"* && "$OUT" == *"うち一部 1"* ]] \
  || { print -r -- "$OUT" >&2; fail "一部だけの緑を表で区別しない"; }
run_guard 0 test-zz-clean.sh
[[ "$OUT" == *"| tests/test-zz-clean.sh | 緑 |"* && "$OUT" != *"緑(一部) の内訳"* ]] || fail "普通の緑まで「一部」と出した"
pass "一部だけ確かめた緑は表で「緑(一部)」と出し、理由を並べる"

# 構成に左右されないテストは最初の構成で 1 回だけ回して流用し、「# selftest: 構成ごと」の印のあるテストだけ構成ごとに回す
fake test-zz-each.sh $'# selftest: 構成ごと\nprint -r -- "$LANES_TOOLS" >> '"${(q)T}"'/each.log'
fake test-zz-once.sh 'print -r -- "$LANES_TOOLS" >> '"${(q)T}"'/once.log'
rc=0; zsh -f "$copy/selftest.sh" --profile all --test tests/test-zz-each.sh --test tests/test-zz-once.sh > "$T/reuse.out" 2>&1 || rc=$?
OUT="$(< "$T/reuse.out")"
(( rc == 0 )) && [[ "$(wc -l < "$T/each.log" | tr -d ' ')" == 4 && "$(wc -l < "$T/once.log" | tr -d ' ')" == 1 ]] \
  && [[ "$OUT" == *"| tests/test-zz-once.sh | 緑 | ＝緑 | ＝緑 | ＝緑 |"* && "$OUT" == *"| tests/test-zz-each.sh | 緑 | 緑 | 緑 | 緑 |"* && "$OUT" == *"流用 3"* ]] \
  || { print -r -- "$OUT" >&2; fail "構成に左右されないテストの流用・構成ごとのテストの繰り返しが違う（$rc）"; }
rc=0; zsh -f "$copy/selftest.sh" --profile all --every-profile --test tests/test-zz-once.sh > "$T/every.out" 2>&1 || rc=$?
(( rc == 0 )) && [[ "$(wc -l < "$T/once.log" | tr -d ' ')" == 5 ]] && grep -q '流用 0' "$T/every.out" \
  || { cat "$T/every.out" >&2; fail "--every-profile で全部のテストを構成ごとに回さない（$rc）"; }
pass "構成に左右されないテストは 1 回だけ回して流用し、印のあるテストと --every-profile では構成ごとに回す"
# CLI まわりの利用者の環境変数（前置きの省略・Gemini の待ち時間・chk-run のキャッシュの場所など）はテストに持ち込まない
fake test-zz-drop.sh '[[ -z "${CHK_CACHE:-}${CLAUDE_NO_PREAMBLE:-}${GEMINI_NO_PREAMBLE:-}${GEMINI_IDLE_GRACE:-}${CODEX_HOME_X:-}" && "$CLAUDE_BIN" == */stubs/claude ]]'
rc=0; CHK_CACHE=/nonexistent CLAUDE_NO_PREAMBLE=1 GEMINI_NO_PREAMBLE=1 GEMINI_IDLE_GRACE=1 CODEX_HOME_X=1 CLAUDE_BIN=/nonexistent \
  zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-drop.sh > "$T/drop.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/drop.out" >&2; fail "CHK_* / CLAUDE_* / GEMINI_* / CODEX_* の環境変数がテストへ届いた（$rc）"; }
pass "CHK_* / CLAUDE_* / CODEX_* / GEMINI_* の利用者の環境変数はテストに持ち込まない"

# 禁止語ファイルは渡したときだけ（絶対パスで）テストに届く。ほかの LANES_* は届かない
print -r -- 'not-a-real-word' > "$T/deny.txt"
fake test-zz-deny.sh '[[ "$LANES_PRIVATE_DENYLIST" == /* && -f "$LANES_PRIVATE_DENYLIST" && -z "${LANES_OTHER_X:-}" ]]'
fake test-zz-nodeny.sh '[[ -z "${LANES_PRIVATE_DENYLIST:-}" ]]'
rc=0; ( cd "$T" && LANES_PRIVATE_DENYLIST=deny.txt LANES_OTHER_X=1 zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-deny.sh ) > "$T/deny.out" 2>&1 || rc=$?
(( rc == 0 )) && grep -q '禁止語ファイル: あり' "$T/deny.out" || { cat "$T/deny.out" >&2; fail "禁止語ファイルがテストへ届かない"; }
rc=0; zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-nodeny.sh > "$T/nodeny.out" 2>&1 || rc=$?
(( rc == 0 )) && grep -q '禁止語ファイル: なし' "$T/nodeny.out" || { cat "$T/nodeny.out" >&2; fail "禁止語ファイル無しの扱いが違う"; }
rc=0; LANES_PRIVATE_DENYLIST="$T/no-such-deny.txt" zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-clean.sh > "$T/baddeny.out" 2>&1 || rc=$?
(( rc == 2 )) || fail "無い禁止語ファイルを渡しても使い方の誤り（exit 2）にならない（$rc）"
pass "禁止語ファイルは渡したときだけ絶対パスでテストに届き、無いファイルは使い方の誤りになる"
# ソケットの逃がし先は、渡せばそのまま、渡さなければ selftest の一時領域の中の浅い既存フォルダ（$work 直下）がテストへ届く（/tmp ではない）
mkdir -p "$T/sock"
fake test-zz-sock.sh '[[ "$LANES_TEST_SOCKET_ROOT" == '"${(q)T}"'/sock ]]'
fake test-zz-sock-default.sh '[[ -d "$LANES_TEST_SOCKET_ROOT" && "$LANES_TEST_SOCKET_ROOT" == "${TMPDIR%/1/t/}" && "$LANES_TEST_SOCKET_ROOT" != /tmp/* ]]'
rc=0; LANES_TEST_SOCKET_ROOT="$T/sock" zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-sock.sh > "$T/sock.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/sock.out" >&2; fail "渡した LANES_TEST_SOCKET_ROOT がテストへ届かない（$rc）"; }
rc=0; zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-sock-default.sh > "$T/sockdef.out" 2>&1 || rc=$?
(( rc == 0 )) || { cat "$T/sockdef.out" >&2; fail "渡さないとき selftest の一時領域の浅い場所がテストへ届かない（$rc）"; }
rc=0; LANES_TEST_SOCKET_ROOT="$T/no-such-sock" zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-clean.sh > "$T/badsock.out" 2>&1 || rc=$?
(( rc == 2 )) || { cat "$T/badsock.out" >&2; fail "無い LANES_TEST_SOCKET_ROOT で exit 2 にならない（$rc）"; }
mkdir -p "$copy/sock-in-kit"
rc=0; LANES_TEST_SOCKET_ROOT="$copy/sock-in-kit" zsh -f "$copy/selftest.sh" --profile claude-only --test tests/test-zz-clean.sh > "$T/kitsock.out" 2>&1 || rc=$?
rmdir "$copy/sock-in-kit"
(( rc == 2 )) && grep -q 'LANES_TEST_SOCKET_ROOT がキットの中にある' "$T/kitsock.out" || { cat "$T/kitsock.out" >&2; fail "キットの中の LANES_TEST_SOCKET_ROOT で exit 2 にならない（$rc）"; }
pass "ソケットの逃がし先は渡せばそのまま・渡さなければ一時領域の浅い場所が届き、無い・キットの中なら exit 2"
# 固有名の検査そのもの: 禁止語ファイルを渡すと汎用のパターンで拾えない語も拾い、渡さないとその旨を出す
mkdir -p "$T/np"; print -r -- 'このキットは acme-widgets 向け' > "$T/np/a.md"
print -r -- $'# 注記の行\nacme-widgets' > "$T/deny2.txt"
rc=0; out="$(zsh -f "$KIT/tests/test-no-private.sh" "$T/np" 2>&1)" || rc=$?
(( rc == 0 )) && [[ "$out" == *"汎用のパターンだけ"* ]] || fail "禁止語ファイル無しで汎用のパターンだけと出さない（$rc）"
rc=0; out="$(LANES_PRIVATE_DENYLIST="$T/deny2.txt" zsh -f "$KIT/tests/test-no-private.sh" "$T/np" 2>&1)" || rc=$?
(( rc == 1 )) && [[ "$out" == *"a.md:1: [禁止語]"* && "$out" != *"acme-widgets"* ]] || { print -r -- "$out" >&2; fail "禁止語ファイルの語を拾わない・語をそのまま出した（$rc）"; }
pass "固有名の検査は禁止語ファイルの語も拾い（語そのものは出さない）、無いときはその旨を出す"

# 片付けたあとは、何もしない偽テストがまた緑（見張りが前の状態を引きずらない）
run_guard 0 test-zz-clean.sh
[[ "$OUT" == *"キットのリポ: 変化なし"* ]] || fail "片付けたあとの何もしない偽テストで「変化なし」が出ない"
pass "片付けたあとは何もしない偽テストが緑"

print -r -- "PASS: $count 件 / EXIT:0"
