#!/bin/zsh -f
# install.sh のテスト。一時 HOME（mktemp -d）と、install.sh をコピーした偽のキットで確かめる。
# 使い方: zsh tests/test-install.sh
# 確かめること: 道具の置き場の有無の組み合わせ / 二重実行 / 既存の実ファイル・他所の symlink を壊さない /
#   --dry-run で何も変わらない / --uninstall は自分の symlink だけ消して設定を残す / キットを動かした後の張り替え /
#   skills/ が空でも動く / 設定ファイルを上書きしない / HOME の外への書き込みを拒む /
#   導入記録・設定ファイルの symlink を辿って書かない / 置き場が HOME の外へ移ったら消さない /
#   導入記録の元の行き先と一致するリンクだけ張り替え・削除する（古い形式の記録は安全側） /
#   自分が作ったスキル置き場だけを、空のときだけ --uninstall で消す（元からあった置き場・中身のある置き場は残す）
#   設定ファイルが導入記録と同じパスなら書く前に止まる / skills/../.. のように外へ出る行き先はキットの物にしない /
#   行き先が無くても途中の symlink を実体で解いてから判定する
[ -n "${ZSH_VERSION:-}" ] || exec zsh -f "$0" "$@"
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h:h}/lanes/tests/_git-isolate.sh"; lanes_test_git_isolate
src="${0:A:h:h}/install.sh"
[[ -f "$src" ]] || { print -u2 -- "error: install.sh が無い: $src"; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
pass=0
ok() { pass=$(( pass + 1 )); print -- "ok   $1"; }
ng() { fails=$(( fails + 1 )); print -- "NG   $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else ng "$name"; fi; }

# 偽のキットを作る（skills: 引数の名前ごとに SKILL.md 入りのフォルダ）
mkkit() {
  local k="$1"; shift
  mkdir -p "$k/skills"
  cp "$src" "$k/install.sh"
  print -- 'LANES_TOOLS="${LANES_TOOLS:-claude}"' > "$k/lanes.conf.example"
  local s
  for s in "$@"; do mkdir -p "$k/skills/$s"; print -- "# $s" > "$k/skills/$s/SKILL.md"; done
}
# 一時 HOME を作る（引数は作っておく道具の親ディレクトリ）
mkhome() {
  local h="$1"; shift
  mkdir -p "$h"
  local d
  for d in "$@"; do mkdir -p "$h/$d"; done
}
# install.sh を一時 HOME で動かす（設定の場所の環境変数は外す）
run() {
  local h="$1" k="$2"; shift 2
  env -u LANES_CONF -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$h" zsh -f "$k/install.sh" "$@"
}
# HOME の中身の写し（パス・種類・symlink の行き先・ファイルの中身のハッシュ・権限）
snap() {
  local h="$1" p
  find "$h" -print | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -L "$p" ]]; then print -r -- "L $p -> $(readlink "$p")"
    elif [[ -d "$p" ]]; then print -r -- "D $p"
    else print -r -- "F $p $(stat -f %Lp "$p") $(md5 -q "$p")"; fi
  done
}

conf_rel=".config/lanewright/lanes.conf"

# 1. 道具の置き場が 1 つも無い: symlink は作らず、設定ファイルだけコピー
H="$work/h1"; K="$work/kit1"; mkkit "$K" alpha beta; mkhome "$H"
out="$(run "$H" "$K" 2>&1)"; rc=$?
check "1: 道具なしでも成功" test "$rc" -eq 0
check "1: 置き場を作らない" test ! -e "$H/.claude"
check "1: 設定ファイルをコピー" test -f "$H/$conf_rel"
check "1: 設定ファイルは 600" test "$(stat -f %Lp "$H/$conf_rel")" = 600
check "1: 次の手順を表示" grep -q 'lanes-doctor.sh' <<<"$out"

# 2. claude と codex だけある: その 2 つにだけ作る。SKILL.md の無いフォルダは飛ばす
H="$work/h2"; K="$work/kit2"; mkkit "$K" alpha beta; mkdir -p "$K/skills/nodoc"; mkhome "$H" .claude .codex
run "$H" "$K" >/dev/null 2>&1
check "2: claude に alpha" test "$(readlink "$H/.claude/skills/alpha")" = "${K:A}/skills/alpha"
check "2: claude に beta" test -L "$H/.claude/skills/beta"
check "2: codex に alpha" test "$(readlink "$H/.codex/skills/alpha")" = "${K:A}/skills/alpha"
check "2: SKILL.md の無いものは作らない" test ! -e "$H/.claude/skills/nodoc"
check "2: gemini の置き場を作らない" test ! -e "$H/.gemini"
check "2: cursor の置き場を作らない" test ! -e "$H/.cursor"
check "2: 導入記録に 4 件" test "$(wc -l < "$H/.config/lanewright/installed-links.txt" | tr -d ' ')" = 4

# 3. 二重実行: 何も変わらない
before="$(snap "$H")"
run "$H" "$K" >/dev/null 2>&1; rc=$?
check "3: 二重実行も成功" test "$rc" -eq 0
check "3: 二重実行で状態が同じ" test "$before" = "$(snap "$H")"

# 4. gemini（antigravity）と cursor の置き場も使う
H="$work/h4"; K="$work/kit4"; mkkit "$K" alpha; mkhome "$H" .gemini/antigravity-cli .cursor
run "$H" "$K" >/dev/null 2>&1
check "4: antigravity に作る" test -L "$H/.gemini/antigravity-cli/skills/alpha"
check "4: cursor に作る" test -L "$H/.cursor/skills/alpha"
check "4: ~/.gemini/skills には作らない" test ! -e "$H/.gemini/skills"

# 5. 既存の実ディレクトリ・実ファイル・他所の symlink は触らず警告。設定ファイルは上書きしない
H="$work/h5"; K="$work/kit5"; mkkit "$K" alpha beta gamma; mkhome "$H" .claude/skills
mkdir -p "$H/.claude/skills/alpha"; print -- mine > "$H/.claude/skills/alpha/SKILL.md"
print -- file > "$H/.claude/skills/beta"
mkdir -p "$H/other/gamma"; ln -s "$H/other/gamma" "$H/.claude/skills/gamma"
mkdir -p "$H/.config/lanewright"; print -- 'MY=1' > "$H/$conf_rel"
before="$(snap "$H")"
out="$(run "$H" "$K" 2>&1)"; rc=$?
check "5: 衝突があっても成功" test "$rc" -eq 0
check "5: 状態が同じ（何も壊さない）" test "$before" = "$(snap "$H" | grep -v 'installed-links.txt')"
check "5: 警告を出す" grep -q '警告' <<<"$out"
check "5: 設定ファイルを上書きしない" test "$(cat "$H/$conf_rel")" = 'MY=1'

# 6. --dry-run: 何も変わらない（置き場あり・設定なしの状態から）
H="$work/h6"; K="$work/kit6"; mkkit "$K" alpha; mkhome "$H" .claude .codex
before="$(snap "$H")"
out="$(run "$H" "$K" --dry-run 2>&1)"; rc=$?
check "6: dry-run 成功" test "$rc" -eq 0
check "6: dry-run で何も変わらない" test "$before" = "$(snap "$H")"
check "6: dry-run で予定を表示" grep -q '\[予定\] 作成' <<<"$out"

# 7. --uninstall: 自分の symlink だけ消し、他所の symlink・実ファイル・設定を残す。--dry-run 付きは何も消さない
H="$work/h7"; K="$work/kit7"; mkkit "$K" alpha beta; mkhome "$H" .claude .codex
run "$H" "$K" >/dev/null 2>&1
mkdir -p "$H/other/x"; ln -s "$H/other/x" "$H/.claude/skills/foreign"
print -- keep > "$H/.claude/skills/realfile"
before="$(snap "$H")"
run "$H" "$K" --uninstall --dry-run >/dev/null 2>&1
check "7: uninstall --dry-run で何も変わらない" test "$before" = "$(snap "$H")"
run "$H" "$K" --uninstall >/dev/null 2>&1; rc=$?
check "7: uninstall 成功" test "$rc" -eq 0
check "7: 自分の symlink を消す（claude）" test ! -L "$H/.claude/skills/alpha"
check "7: 自分の symlink を消す（codex）" test ! -L "$H/.codex/skills/beta"
check "7: 他所の symlink は残す" test -L "$H/.claude/skills/foreign"
check "7: 実ファイルは残す" test -f "$H/.claude/skills/realfile"
check "7: 設定ファイルは残す" test -f "$H/$conf_rel"
check "7: 導入記録は消す" test ! -e "$H/.config/lanewright/installed-links.txt"

# 8. キットを動かした後: 導入記録にある古いリンクを新しい場所へ張り替える。その後の uninstall でも消える
H="$work/h8"; K="$work/kit8a"; mkkit "$K" alpha; mkhome "$H" .claude
run "$H" "$K" >/dev/null 2>&1
K2="$work/kit8b"; mv "$K" "$K2"
run "$H" "$K2" >/dev/null 2>&1
check "8: 動かしたキットへ張り替え" test "$(readlink "$H/.claude/skills/alpha")" = "${K2:A}/skills/alpha"
mv "$K2" "$work/kit8c"
run "$H" "$work/kit8c" --uninstall >/dev/null 2>&1
check "8: 記録にあるリンクは行き先が変わっても消せる" test ! -L "$H/.claude/skills/alpha"

# 8b. 導入記録にあっても、利用者が実在する別の場所へ向け直したリンクは触らない
H="$work/h8b"; K="$work/kit8b2"; mkkit "$K" alpha; mkhome "$H" .claude
run "$H" "$K" >/dev/null 2>&1
mkdir -p "$H/mine/skills/alpha"; rm "$H/.claude/skills/alpha"; ln -s "$H/mine/skills/alpha" "$H/.claude/skills/alpha"
K3="$work/kit8b3"; mv "$K" "$K3"
run "$H" "$K3" >/dev/null 2>&1
check "8b: 向け直したリンクは張り替えない" test "$(readlink "$H/.claude/skills/alpha")" = "$H/mine/skills/alpha"
run "$H" "$K3" --uninstall >/dev/null 2>&1
check "8b: 向け直したリンクは uninstall でも消さない" test -L "$H/.claude/skills/alpha"

# 9. skills/ が空・無い: 成功して設定ファイルだけ
H="$work/h9"; K="$work/kit9"; mkkit "$K"; mkhome "$H" .claude
run "$H" "$K" >/dev/null 2>&1; rc=$?
check "9: skills が空でも成功" test "$rc" -eq 0
check "9: 空なら置き場を作らない" test ! -e "$H/.claude/skills"
rm -rf "$K/skills"
run "$H" "$K" >/dev/null 2>&1; rc=$?
check "9: skills が無くても成功" test "$rc" -eq 0

# 10. 設定の場所が HOME の外なら止まる・知らない引数は exit 2
H="$work/h10"; K="$work/kit10"; mkkit "$K" alpha; mkhome "$H" .claude
rc=0; env HOME="$H" LANES_CONF="$work/outside/lanes.conf" zsh -f "$K/install.sh" >/dev/null 2>&1 || rc=$?
check "10: HOME の外の設定は exit 2" test "$rc" -eq 2
check "10: HOME の外に書かない" test ! -e "$work/outside"
check "10: 止まったときは symlink も作らない" test ! -e "$H/.claude/skills"
rc=0; run "$H" "$K" --bogus >/dev/null 2>&1 || rc=$?
check "10: 知らない引数は exit 2" test "$rc" -eq 2

# 11. XDG_CONFIG_HOME を尊重する
H="$work/h11"; K="$work/kit11"; mkkit "$K"; mkhome "$H"
env -u LANES_CONF HOME="$H" XDG_CONFIG_HOME="$H/xdg" zsh -f "$K/install.sh" >/dev/null 2>&1
check "11: XDG_CONFIG_HOME の下に設定" test -f "$H/xdg/lanewright/lanes.conf"

# 12. 導入記録が HOME の外のファイルを指す symlink なら、リンク先を書き換えない（終了コードは 0 で警告）
H="$work/h12"; K="$work/kit12"; mkkit "$K" alpha; mkhome "$H" .claude
mkdir -p "$work/out12" "$H/.config/lanewright"; print -- 'victim' > "$work/out12/victim.txt"
ln -s "$work/out12/victim.txt" "$H/.config/lanewright/installed-links.txt"
out="$(run "$H" "$K" 2>&1)"; rc=$?
check "12: 成功する" test "$rc" -eq 0
check "12: リンク先のファイルを書き換えない" test "$(cat "$work/out12/victim.txt")" = victim
check "12: 導入記録のリンクはそのまま" test "$(readlink "$H/.config/lanewright/installed-links.txt")" = "$work/out12/victim.txt"
check "12: 警告を出す" grep -q '導入記録が symlink' <<<"$out"
run "$H" "$K" --uninstall >/dev/null 2>&1
check "12: uninstall でもリンク先を壊さない" test "$(cat "$work/out12/victim.txt")" = victim
check "12: uninstall でも導入記録のリンクを消さない" test -L "$H/.config/lanewright/installed-links.txt"
check "12: キットを指すリンクは uninstall で消える" test ! -L "$H/.claude/skills/alpha"

# 13. 設定ファイルの場所が行き先の無い symlink なら、リンク先に設定を作らない
H="$work/h13"; K="$work/kit13"; mkkit "$K"; mkhome "$H"
mkdir -p "$work/out13" "$H/.config/lanewright"
ln -s "$work/out13/lanes.conf" "$H/$conf_rel"
out="$(run "$H" "$K" 2>&1)"; rc=$?
check "13: 成功する" test "$rc" -eq 0
check "13: リンク先に設定を作らない" test ! -e "$work/out13/lanes.conf"
check "13: リンクはそのまま" test "$(readlink "$H/$conf_rel")" = "$work/out13/lanes.conf"
check "13: 警告を出す" grep -q '行き先の無い symlink' <<<"$out"

# 14. 導入後に置き場を HOME の外へ移してリンクで戻した: uninstall は外側のリンクを消さない
H="$work/h14"; K="$work/kit14"; mkkit "$K" alpha; mkhome "$H" .claude
run "$H" "$K" >/dev/null 2>&1
mkdir -p "$work/out14"; mv "$H/.claude/skills" "$work/out14/skills"; ln -s "$work/out14/skills" "$H/.claude/skills"
out="$(run "$H" "$K" --uninstall 2>&1)"; rc=$?
check "14: uninstall 成功" test "$rc" -eq 0
check "14: HOME の外のリンクを消さない" test -L "$work/out14/skills/alpha"
check "14: 警告を出す" grep -q 'HOME の外なので消さない' <<<"$out"

# 15. 利用者がまだ無い別の「…/skills/<同名>」へ向け直したリンクは、キットを動かした後も張り替え・削除しない
H="$work/h15"; K="$work/kit15a"; mkkit "$K" alpha; mkhome "$H" .claude
run "$H" "$K" >/dev/null 2>&1
check "15: 導入記録に元の行き先を残す" grep -qF "$H/.claude/skills/alpha"$'\t'"${K:A}/skills/alpha" "$H/.config/lanewright/installed-links.txt"
rm "$H/.claude/skills/alpha"; ln -s "$H/later/skills/alpha" "$H/.claude/skills/alpha"
K2="$work/kit15b"; mv "$K" "$K2"
run "$H" "$K2" >/dev/null 2>&1
check "15: 向け直したリンクは張り替えない" test "$(readlink "$H/.claude/skills/alpha")" = "$H/later/skills/alpha"
run "$H" "$K2" --uninstall >/dev/null 2>&1
check "15: 向け直したリンクは uninstall でも消さない" test -L "$H/.claude/skills/alpha"

# 16. 古い形式（リンクだけ・行き先なし）の導入記録: キットを指さないリンクは触らず、キットを指すリンクは消す
H="$work/h16"; K="$work/kit16"; mkkit "$K" alpha; mkhome "$H" .claude/skills .config/lanewright
ln -s "$work/gone16/skills/alpha" "$H/.claude/skills/alpha"
ln -s "${K:A}/skills/beta" "$H/.claude/skills/beta"
print -rl -- "$H/.claude/skills/alpha" "$H/.claude/skills/beta" > "$H/.config/lanewright/installed-links.txt"
run "$H" "$K" >/dev/null 2>&1
check "16: 古い形式の他所リンクは張り替えない" test "$(readlink "$H/.claude/skills/alpha")" = "$work/gone16/skills/alpha"
check "16: キットを指すリンクは行き先付きで記録し直す" grep -qF "$H/.claude/skills/beta"$'\t'"${K:A}/skills/beta" "$H/.config/lanewright/installed-links.txt"
run "$H" "$K" --uninstall >/dev/null 2>&1
check "16: 古い形式の他所リンクは uninstall でも消さない" test -L "$H/.claude/skills/alpha"
check "16: キットを指すリンクは消す" test ! -L "$H/.claude/skills/beta"

# 17. 自分が作ったスキル置き場（~/.<道具>/skills）は、--uninstall で空のときだけ消す
H="$work/h17"; K="$work/kit17"; mkkit "$K" alpha; mkhome "$H" .claude .codex/skills
run "$H" "$K" >/dev/null 2>&1
rec="$H/.config/lanewright/installed-dirs.txt"
check "17: 作った置き場を記録する" grep -qxF "$H/.claude/skills" "$rec"
check "17: 元からあった置き場は記録しない" test -z "$(grep -xF "$H/.codex/skills" "$rec" || true)"
run "$H" "$K" >/dev/null 2>&1
check "17: 二重実行でも作った置き場の記録を引き継ぐ" grep -qxF "$H/.claude/skills" "$rec"
before="$(snap "$H")"
out="$(run "$H" "$K" --uninstall --dry-run 2>&1)"
check "17: dry-run は消す予定だけ出す" test "$(snap "$H")" = "$before"
check "17: dry-run に空の置き場を消す予定が出る" eval '[[ "$out" == *"削除（このスクリプトが作った空のフォルダ）: $H/.claude/skills"* ]]'
run "$H" "$K" --uninstall >/dev/null 2>&1
check "17: 作った空の置き場は uninstall で消す" test ! -e "$H/.claude/skills"
check "17: 道具の親フォルダは残す" test -d "$H/.claude"
check "17: 元からあった置き場は空でも残す" test -d "$H/.codex/skills"
check "17: 置き場を消したら記録も消す" test ! -e "$rec"
# 中に利用者のものがあれば残し、記録も残す（あとで空にしてから uninstall すれば消える）
run "$H" "$K" >/dev/null 2>&1
mkdir -p "$H/.claude/skills/mine"
out="$(run "$H" "$K" --uninstall 2>&1)"
check "17: 中身のある置き場は残す" test -d "$H/.claude/skills/mine"
check "17: 残した理由を出す" eval '[[ "$out" == *"残す（中に他のものがある）: $H/.claude/skills"* ]]'
check "17: 残した置き場の記録は残す" grep -qxF "$H/.claude/skills" "$rec"
rmdir "$H/.claude/skills/mine"
run "$H" "$K" --uninstall >/dev/null 2>&1
check "17: 空にしてからの uninstall で消す" test ! -e "$H/.claude/skills"
# 記録が道具の置き場以外のフォルダを指していても消さない（記録の書き換えに備える）
mkdir -p "$H/.config/lanewright" "$H/empty-other"
print -r -- "$H/empty-other" > "$rec"
run "$H" "$K" --uninstall >/dev/null 2>&1
check "17: 道具の置き場以外のフォルダは記録にあっても消さない" test -d "$H/empty-other"
# 記録ファイルが symlink なら読まず、置き場も消さない
H="$work/h17b"; K="$work/kit17b"; mkkit "$K" alpha; mkhome "$H" .claude
run "$H" "$K" >/dev/null 2>&1
mv "$H/.config/lanewright/installed-dirs.txt" "$work/dirs17b.txt"
ln -s "$work/dirs17b.txt" "$H/.config/lanewright/installed-dirs.txt"
out="$(run "$H" "$K" --uninstall 2>&1)"
check "17: 記録が symlink なら置き場を消さない" test -d "$H/.claude/skills"
check "17: 記録が symlink なら警告する" eval '[[ "$out" == *"作ったフォルダの記録が symlink"* ]]'

# 18. スキル置き場が行き先の無い symlink・フォルダでないもの: 落ちずに警告して、ほかの道具と設定のコピーは続ける
H="$work/h18"; K="$work/kit18"; mkkit "$K" alpha; mkhome "$H" .claude .codex .cursor
ln -s "$work/no-such-skills" "$H/.claude/skills"
print -r -- x > "$H/.cursor/skills"
out="$(run "$H" "$K" 2>&1)"; rc=$?
check "18: 行き先の無い置き場があっても成功" test "$rc" -eq 0
check "18: 行き先の無い置き場を警告する" eval '[[ "$out" == *"スキル置き場が行き先の無い symlink"*"$H/.claude/skills"* ]]'
check "18: フォルダでない置き場を警告する" eval '[[ "$out" == *"フォルダでないものがあるので飛ばす: $H/.cursor/skills"* ]]'
check "18: 行き先の無い symlink を書き換えない" test "$(readlink "$H/.claude/skills")" = "$work/no-such-skills"
check "18: リンク先を作らない" test ! -e "$work/no-such-skills"
check "18: フォルダでない置き場を書き換えない" test "$(< "$H/.cursor/skills")" = x
check "18: ほかの道具には作る" test "$(readlink "$H/.codex/skills/alpha")" = "${K:A}/skills/alpha"
check "18: 設定ファイルはコピーする" test -f "$H/$conf_rel"
check "18: 導入記録は残す" grep -qF "$H/.codex/skills/alpha" "$H/.config/lanewright/installed-links.txt"
out="$(run "$H" "$K" --uninstall 2>&1)"; rc=$?
check "18: uninstall も落ちない" test "$rc" -eq 0
check "18: uninstall でほかの道具のリンクを消す" test ! -e "$H/.codex/skills/alpha"
check "18: uninstall で行き先の無い置き場を消さない" test -L "$H/.claude/skills"

# 19. 設定ファイルの場所が導入記録と同じ名前なら、書き込みの前に exit 2（既存の設定を消さない）
for name in installed-links.txt installed-dirs.txt; do
  H="$work/h19-$name"; K="$work/kit19-$name"; mkkit "$K" alpha; mkhome "$H" .claude
  mkdir -p "$H/cfg"; print -- 'LANES_TOOLS="claude"' > "$H/cfg/$name"
  before="$(snap "$H")"
  rc=0; out="$(env -u XDG_CONFIG_HOME HOME="$H" LANES_CONF="$H/cfg/$name" zsh -f "$K/install.sh" 2>&1)" || rc=$?
  check "19: 設定が $name と同じなら install は exit 2" test "$rc" -eq 2
  check "19: $name の理由を出す" eval '[[ "$out" == *"導入記録と同じ"* ]]'
  rc=0; env -u XDG_CONFIG_HOME HOME="$H" LANES_CONF="$H/cfg/$name" zsh -f "$K/install.sh" --uninstall >/dev/null 2>&1 || rc=$?
  check "19: 設定が $name と同じなら uninstall も exit 2" test "$rc" -eq 2
  check "19: $name の衝突で何も書き換えない（設定も残る）" test "$(snap "$H")" = "$before"
done
# 大文字・小文字だけ違う名前（macOS の既定のファイルシステムでは同じファイル）も止める
H="$work/h19c"; K="$work/kit19c"; mkkit "$K" alpha; mkhome "$H" .claude
rc=0; env -u XDG_CONFIG_HOME HOME="$H" LANES_CONF="$H/cfg/Installed-Links.TXT" zsh -f "$K/install.sh" >/dev/null 2>&1 || rc=$?
check "19: 大文字・小文字だけ違う名前でも exit 2" test "$rc" -eq 2
check "19: 大文字・小文字の衝突で何も作らない" test ! -e "$H/cfg"
# 設定ファイルが導入記録を指す symlink（実体が同じ）でも止める
H="$work/h19b"; K="$work/kit19b"; mkkit "$K" alpha; mkhome "$H" .claude
mkdir -p "$H/cfg"; print -- x > "$H/cfg/installed-links.txt"; ln -s installed-links.txt "$H/cfg/lanes.conf"
rc=0; env -u XDG_CONFIG_HOME HOME="$H" LANES_CONF="$H/cfg/lanes.conf" zsh -f "$K/install.sh" >/dev/null 2>&1 || rc=$?
check "19: 設定が導入記録を指す symlink なら exit 2" test "$rc" -eq 2
check "19: 導入記録の実体を書き換えない" test "$(< "$H/cfg/installed-links.txt")" = x

# 20. 未記録のリンクの行き先は正規化してから判定する。skills/../../<外> はキットの物にしない（張り替え・削除しない）
H="$work/h20"; K="$work/kit20"; mkkit "$K" alpha; mkhome "$H" .claude
mkdir -p "$H/.claude/skills" "$work/foreign-skill"
ln -s "${K:A}/skills/../../foreign-skill" "$H/.claude/skills/alpha"
ln -s "${K:A}/skills/../../foreign-skill" "$H/.claude/skills/other"
out="$(run "$H" "$K" 2>&1)"
check "20: 外へ出る行き先は張り替えない" test "$(readlink "$H/.claude/skills/alpha")" = "${K:A}/skills/../../foreign-skill"
check "20: 外へ出る行き先は警告する" eval '[[ "$out" == *"他所を指す symlink"*"$H/.claude/skills/alpha"* ]]'
run "$H" "$K" --uninstall >/dev/null 2>&1
check "20: uninstall でも外へ出る行き先のリンクを消さない" test -L "$H/.claude/skills/other"
# 相対の行き先・途中に「.」があっても、キットの skills/<名前> を指すものは自分の物として張り替える
H="$work/h20b"; K="$work/kit20b"; mkkit "$K" alpha beta; mkhome "$H" .claude
mkdir -p "$H/.claude/skills"; ln -s "${K:A}/skills/./beta" "$H/.claude/skills/alpha"
run "$H" "$K" >/dev/null 2>&1
check "20: 正規化してキット内を指すリンクは張り替える" test "$(readlink "$H/.claude/skills/alpha")" = "${K:A}/skills/alpha"

# 21. 行き先が無いリンクでも、途中の symlink を実体で解いてから判定する
#     （skills/bridge -> <外>/child のとき skills/bridge/../lanes の実体は <外>/lanes。キットの物にしない・消さない）
H="$work/h21"; K="$work/kit21"; mkkit "$K" alpha; mkhome "$H" .claude
mkdir -p "$H/.claude/skills" "$work/outside21/child"
ln -s "$work/outside21/child" "$K/skills/bridge"
ln -s "${K:A}/skills/bridge/../lanes" "$H/.claude/skills/lanes"
run "$H" "$K" --uninstall >/dev/null 2>&1
check "21: 途中の symlink で外へ出る、行き先の無いリンクを uninstall で消さない" test -L "$H/.claude/skills/lanes"
out="$(run "$H" "$K" 2>&1)"
check "21: install でも張り替えない" test "$(readlink "$H/.claude/skills/lanes")" = "${K:A}/skills/bridge/../lanes"
# 途中に symlink が無ければ、行き先が無くてもキットの skills/<名前> を指すものは自分の物（消してよい）
H="$work/h21b"; K="$work/kit21b"; mkkit "$K" alpha; mkhome "$H" .claude
mkdir -p "$H/.claude/skills"; ln -s "${K:A}/skills/./gone" "$H/.claude/skills/gone"
run "$H" "$K" --uninstall >/dev/null 2>&1
check "21: 途中に symlink の無い、キット内の行き先の無いリンクは uninstall で消す" test ! -L "$H/.claude/skills/gone"

print -- "INSTALL TEST: ok=$pass NG=$fails"
(( fails == 0 ))
