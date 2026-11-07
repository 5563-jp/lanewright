#!/bin/zsh -f
# キットの導入スクリプト。キットの置き場所は動かさず、そのまま使う。
# 使い方: ./install.sh [--dry-run] [--uninstall]
#   --dry-run   何も書き換えず、やる予定のことだけ表示する
#   --uninstall このスクリプトが作った symlink（シンボリックリンク＝別の場所を指す目印のファイル）だけを消す。設定ファイルは残す。
#               このスクリプトが作ったスキル置き場（~/.<道具>/skills）は、空になったときだけ消す
# やること:
#   1. <キット>/skills/<名前>/（SKILL.md があるもの）を、各道具のスキル置き場へ symlink で作る。
#      対象は親ディレクトリが既にある道具だけ（入っていない道具の置き場は作らない）:
#        ~/.claude/skills  ~/.codex/skills  ~/.gemini/antigravity-cli/skills  ~/.cursor/skills
#      同名が既にあるとき: このキットの skills を指す symlink、または前回の導入記録にあって行き先が消えた symlink なら張り替える。
#      それ以外（実ファイル・実ディレクトリ・他所を指す symlink）は触らずに警告する。
#   2. <キット>/lanes.conf.example を設定の場所へ、まだ無いときだけコピーする。
#      設定の場所: ${LANES_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf}
#   3. 作った symlink を導入記録（設定ファイルと同じフォルダの installed-links.txt）に残す（--uninstall で使う）。
#      1 行 1 リンクで「リンクの絶対パス<TAB>作ったときの行き先」。導入記録そのものが symlink・他人の持ち物のときは書かない。
#      スキル置き場のフォルダをこのスクリプトが作ったときは、同じフォルダの installed-dirs.txt に 1 行 1 フォルダで残す
#      （--uninstall で、空のときだけ消すため。元からあったフォルダは記録しないので消さない）。
#   4. 次の手順（設定の編集・lanes-doctor.sh・selftest.sh）を表示する。
# 書き込むのは $HOME の下だけ。設定の場所が $HOME の外を指すとき・導入記録と同じパスのときは止まる。
# キットの skills を指すかは、symlink の行き先を正規化（相対パス・「..」を解き、在れば実体のパス）してから判定する。
# 終了コード: 0 = 完了（警告があっても 0）/ 2 = 使い方の誤り・前提エラー
[ -n "${ZSH_VERSION:-}" ] || exec zsh -f "$0" "$@"
set -euo pipefail
setopt null_glob

kit="${0:A:h}"
dry=0
mode=install
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 -- "error: 知らない引数: $a（--dry-run / --uninstall のみ）"; exit 2 ;;
  esac
done

[[ -n "${HOME:-}" && -d "$HOME" ]] || { print -u2 -- "error: HOME が無い"; exit 2; }
home="${HOME:A}"

conf="${LANES_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf}"
conf="${conf:a}"
conf_dir="${conf:h}"
manifest="$conf_dir/installed-links.txt"
dirs_record="$conf_dir/installed-dirs.txt"
# 設定ファイルが導入記録と同じ場所だと、設定が導入記録として書き換え・削除されてしまう。書き込みの前に止める
# （名前が同じ場合に加え、設定ファイルが導入記録を指す symlink などで実体が同じ場合も止める）
# （macOS の既定のファイルシステムは大文字・小文字を区別しないので、名前は小文字にそろえて比べる）
same_file() { [[ "${(L)1}" == "${(L)2}" ]] || { [[ -e "$1" && -e "$2" && "$1" -ef "$2" ]]; }; }
if same_file "$conf" "$manifest" || same_file "$conf" "$dirs_record"; then
  print -u2 -- "error: 設定ファイルの場所が導入記録と同じ: $conf（installed-links.txt / installed-dirs.txt 以外の名前にする）"
  exit 2
fi

# $HOME の下かどうか（symlink を解いた実体で比べる。まだ無いパスは在る所まで遡って解く）
under_home() {
  local p="$1" rest=""
  while [[ ! -e "$p" && "$p" != "/" ]]; do rest="/${p:t}$rest"; p="${p:h}"; done
  p="${p:A}$rest"
  [[ "$p" == "$home" || "$p" == "$home/"* ]]
}
under_home "$conf_dir" || { print -u2 -- "error: 設定の場所が HOME の外: $conf_dir（HOME の下だけに書く）"; exit 2; }

warns=0
warn() { print -u2 -- "警告: $*"; warns=$(( warns + 1 )); }
say() { if (( dry )); then print -- "[予定] $*"; else print -- "$*"; fi; }

# 道具ごとのスキル置き場（親ディレクトリが在るものだけ使う）
tool_dirs=(
  "$HOME/.claude/skills"
  "$HOME/.codex/skills"
  "$HOME/.gemini/antigravity-cli/skills"
  "$HOME/.cursor/skills"
)

# 導入記録が安全に読み書きできるか（symlink でなく、自分の持ち物の普通のファイル。無いのは可）
manifest_ok() {
  [[ -L "$manifest" ]] && return 1
  [[ ! -e "$manifest" ]] && return 0
  [[ -f "$manifest" && -O "$manifest" ]]
}
manifest_usable=1
manifest_ok || manifest_usable=0
# 作ったフォルダの記録も同じ条件で読み書きする
dirs_ok() {
  [[ -L "$dirs_record" ]] && return 1
  [[ ! -e "$dirs_record" ]] && return 0
  [[ -f "$dirs_record" && -O "$dirs_record" ]]
}
dirs_usable=1
dirs_ok || dirs_usable=0
typeset -a made_dirs=()
if (( dirs_usable )) && [[ -f "$dirs_record" ]]; then
  for line in "${(@f)$(<"$dirs_record")}"; do
    [[ -n "$line" ]] && made_dirs+=("$line")
  done
fi
# 記録してよいフォルダか（道具のスキル置き場のどれかと同じパスだけ。記録を書き換えられても他のフォルダは消さない）
is_tool_dir() { (( ${tool_dirs[(Ie)$1]} )); }

# 導入記録の読み込み（1 行 1 リンク。「リンク<TAB>行き先」。古い形式の行はリンクだけで行き先が空）
typeset -a recorded=()
typeset -A rec_target=()
if (( manifest_usable )) && [[ -f "$manifest" ]]; then
  for line in "${(@f)$(<"$manifest")}"; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *$'\t'* ]]; then
      l="${line%%$'\t'*}"; rec_target[$l]="${line#*$'\t'}"
    else
      l="$line"; rec_target[$l]=""
    fi
    recorded+=("$l")
  done
fi

# 存在しない部分を含むパスを、先頭から 1 段ずつ実体で解く（途中の symlink は行き先へ置き換え、「..」は解いた実体の親へ上がる）。
# 文字の上だけで「..」を消すと、途中に外を指す symlink があるときに行き先を取り違える
# （例: skills/bridge -> <外>/child のとき skills/bridge/../x の実体は <外>/x であって skills/x ではない）
resolve_path() {
  local -a rest=(${(s:/:)1}) parts
  local cur="" c t hops=0
  while (( ${#rest} )); do
    c="${rest[1]}"; rest=("${(@)rest[2,-1]}")
    case "$c" in
      ''|.) continue ;;
      ..) cur="${cur%/*}"; continue ;;
    esac
    if [[ -L "$cur/$c" ]]; then
      hops=$(( hops + 1 )); (( hops <= 40 )) || return 1   # 循環するリンクは解けないので失敗にする
      t="$(readlink "$cur/$c")" || return 1
      [[ "$t" == /* ]] && cur=""
      parts=(${(s:/:)t}); rest=("${parts[@]}" "${rest[@]}")
    else
      cur="$cur/$c"
    fi
  done
  print -r -- "${cur:-/}"
}
# symlink の行き先を正規化する（相対の行き先はリンクの置き場から解き、「..」を解決する。在れば実体のパスにする）
link_dest() {
  local l="$1" t
  t="$(readlink "$l")" || return 1
  [[ "$t" == /* ]] || t="${l:h}/$t"
  if [[ -e "$t" ]]; then
    # 「..」も実体のフォルダ構成で辿る（途中に symlink があっても文字の上の前後関係で解かない）
    if [[ -d "$t" ]]; then
      ( setopt chase_dots chase_links; cd -q -- "$t" 2>/dev/null && print -r -- "$PWD" ) || return 1
    else
      ( setopt chase_dots chase_links; cd -q -- "${t:h}" 2>/dev/null && print -r -- "$PWD/${t:t}" ) || return 1
    fi
  else
    # 行き先が無くても、在る部分までの途中の symlink は実体で解いてから比べる
    resolve_path "$t"
  fi
}
kit_skills="${kit:A}/skills"
# このキットの skills/<名前> を指す symlink か（行き先を正規化してから比べる。skills/../.. のような外への行き先は含めない）
points_to_kit() {
  local d
  d="$(link_dest "$1")" || return 1
  [[ "$d" == "$kit_skills/"* && "${d#$kit_skills/}" != */* && -n "${d#$kit_skills/}" ]]
}
# 前回の導入記録にあり、記録した行き先（作ったときの行き先）を今も指している symlink か
# （キットを動かした後でも張り替え・削除できるように。利用者が別の場所へ向け直したものは、行き先が無くても触らない。
#  行き先を記録していない古い形式の行は、自分のものと確かめられないので触らない）
is_recorded() {
  local l="$1" t
  (( ${recorded[(Ie)$l]} )) || return 1
  [[ -n "${rec_target[$l]:-}" ]] || return 1
  [[ -L "$l" ]] || return 1
  t="$(readlink "$l")" || return 1
  [[ "$t" == "${rec_target[$l]}" ]]
}

typeset -a now_links=()
typeset -A now_target=()

if [[ "$mode" == install ]]; then
  typeset -a skills=()
  for d in "$kit"/skills/*(/N); do
    if [[ -f "$d/SKILL.md" ]]; then skills+=("${d:t}"); else warn "SKILL.md が無いので飛ばす: skills/${d:t}"; fi
  done
  (( ${#skills} )) || print -- "skills/ にスキルが無い（スキルの symlink は作らない）"

  for td in "${tool_dirs[@]}"; do
    if [[ ! -d "${td:h}" ]]; then
      print -- "飛ばす: ${td:h} が無い（その道具は入っていないとみなす）"
      continue
    fi
    under_home "$td" || { warn "HOME の外を指すので飛ばす: $td"; continue; }
    (( ${#skills} )) || continue
    # 置き場そのものが行き先の無い symlink・フォルダでないもの: 中にリンクを作れないので、警告してその道具だけ飛ばす
    if [[ -L "$td" && ! -d "$td" ]]; then
      warn "スキル置き場が行き先の無い symlink（かフォルダでないもの）なので飛ばす: $td -> $(readlink "$td")"
      continue
    fi
    if [[ -e "$td" && ! -d "$td" ]]; then
      warn "スキル置き場の場所にフォルダでないものがあるので飛ばす: $td"
      continue
    fi
    if [[ ! -d "$td" && ! -L "$td" ]]; then
      say "作成: $td"
      (( dry )) || mkdir -p "$td"
      made_dirs+=("$td")
    fi
    for s in "${skills[@]}"; do
      link="$td/$s"; target="$kit/skills/$s"
      if [[ -L "$link" ]]; then
        if [[ "$(readlink "$link")" == "$target" ]]; then
          print -- "済み: $link"
          now_links+=("$link"); now_target[$link]="$target"; continue
        fi
        if points_to_kit "$link" || is_recorded "$link"; then
          say "張り替え: $link -> $target"
          if (( ! dry )); then rm -f "$link"; ln -s "$target" "$link"; fi
          now_links+=("$link"); now_target[$link]="$target"; continue
        fi
        warn "他所を指す symlink があるので触らない: $link -> $(readlink "$link")"
        continue
      fi
      if [[ -e "$link" ]]; then
        warn "同名の実ファイル・実ディレクトリがあるので触らない: $link"
        continue
      fi
      say "作成: $link -> $target"
      (( dry )) || ln -s "$target" "$link"
      now_links+=("$link"); now_target[$link]="$target"
    done
  done

  # 設定ファイルのひな形
  if [[ -L "$conf" && ! -e "$conf" ]]; then
    # 行き先の無い symlink: cp がリンク先に書いてしまうので触らない
    warn "設定ファイルの場所に行き先の無い symlink があるので触らない: $conf -> $(readlink "$conf")"
  elif [[ -e "$conf" || -L "$conf" ]]; then
    print -- "設定ファイルは既にある（上書きしない）: $conf"
  elif [[ -f "$kit/lanes.conf.example" ]]; then
    say "コピー: lanes.conf.example -> $conf"
    if (( ! dry )); then mkdir -p "$conf_dir"; cp "$kit/lanes.conf.example" "$conf"; chmod 600 "$conf"; fi
  else
    warn "lanes.conf.example が無いので設定ファイルは作らない"
  fi

  # 導入記録（前回分のうち、まだ自分のリンクとして残っているものも行き先ごと引き継ぐ）
  (( manifest_usable )) || warn "導入記録が symlink か自分の持ち物でないので読み書きしない: $manifest（--uninstall はこのキットを指すリンクだけ消せる）"
  if (( ! dry )); then
    typeset -a keep=()
    for l in "${recorded[@]}"; do
      (( ${now_links[(Ie)$l]} )) && continue
      if is_recorded "$l"; then
        keep+=("$l"); now_target[$l]="${rec_target[$l]}"
      elif [[ -L "$l" ]] && points_to_kit "$l"; then
        # 古い形式の行でも、このキットを指しているものは今の行き先で記録し直す
        keep+=("$l"); now_target[$l]="$(readlink "$l")"
      fi
    done
    typeset -a all=("${(@u)now_links[@]}" "${(@u)keep[@]}")
    if (( ! manifest_usable )); then
      :
    elif (( ${#all} )); then
      mkdir -p "$conf_dir"
      # 一時ファイルに書いてから置き換える（既存の名前がリンクでも、リンク先へは書かない）
      tmp="$(mktemp "$conf_dir/.installed-links.XXXXXX")"
      for l in "${all[@]}"; do print -r -- "$l"$'\t'"${now_target[$l]}"; done >| "$tmp"
      if manifest_ok; then mv -f "$tmp" "$manifest"
      else rm -f "$tmp"; warn "導入記録が書き込み中に symlink などへ変わったので書かない: $manifest"; fi
    elif [[ -f "$manifest" ]]; then
      rm -f "$manifest"
    fi
    # 作ったスキル置き場の記録（今も実ディレクトリとして在るものだけ残す）
    typeset -a dkeep=()
    for dd in "${(@u)made_dirs[@]}"; do
      is_tool_dir "$dd" && [[ -d "$dd" && ! -L "$dd" ]] && dkeep+=("$dd")
    done
    if (( ! dirs_usable )); then
      warn "作ったフォルダの記録が symlink か自分の持ち物でないので読み書きしない: $dirs_record（--uninstall で空の置き場は消えない）"
    elif (( ${#dkeep} )); then
      mkdir -p "$conf_dir"
      tmp="$(mktemp "$conf_dir/.installed-dirs.XXXXXX")"
      print -rl -- "${dkeep[@]}" >| "$tmp"
      if dirs_ok; then mv -f "$tmp" "$dirs_record"
      else rm -f "$tmp"; warn "作ったフォルダの記録が書き込み中に symlink などへ変わったので書かない: $dirs_record"; fi
    elif [[ -f "$dirs_record" ]]; then
      rm -f "$dirs_record"
    fi
  fi

  print -- ""
  print -- "次の手順:"
  print -- "  1. 設定を編集する: $conf（使う道具 LANES_TOOLS・司令塔 LANES_COMMANDER・統合先 LANES_BASE_BRANCH など。説明は docs/config.md）"
  print -- "  2. 起動前点検: zsh $kit/lanes/lanes-doctor.sh（足りないものがあれば一覧を出して exit 2）"
  print -- "     役割の割り振りの確認: zsh $kit/lanes/lanes-roles.sh --print"
  print -- "  3. 自己テスト: zsh $kit/selftest.sh（既定は 4 構成すべて。1 構成なら --profile claude-codex など）"
  print -- "  （任意）PATH に足す: ~/.zshrc に export PATH=\"$kit/lanes:\$PATH\""
else
  # アンインストール: このキットを指す symlink と、導入記録にある symlink だけ消す
  typeset -a cands=("${recorded[@]}")
  for td in "${tool_dirs[@]}"; do
    for l in "$td"/*(@N); do cands+=("$l"); done
  done
  removed=0
  for l in "${(@u)cands[@]}"; do
    [[ -L "$l" ]] || continue
    if points_to_kit "$l" || is_recorded "$l"; then
      # 置き場（リンクの親フォルダ）の実体が HOME の外なら消さない（置き場を外へ移してリンクで戻した場合など）
      if ! under_home "${l:h}"; then
        warn "置き場の実体が HOME の外なので消さない: $l"
        continue
      fi
      say "削除: $l"
      (( dry )) || rm -f "$l"
      removed=$(( removed + 1 ))
    fi
  done
  if (( ! manifest_usable )); then
    warn "導入記録が symlink か自分の持ち物でないので読まず、消さない: $manifest"
  elif (( ! dry )) && [[ -f "$manifest" ]]; then
    rm -f "$manifest"
  fi
  # このスクリプトが作ったスキル置き場は、空のときだけ消す（中に利用者のものがあれば残す）
  typeset -a dleft=()
  if (( ! dirs_usable )); then
    warn "作ったフォルダの記録が symlink か自分の持ち物でないので読まず、消さない: $dirs_record"
  else
    for dd in "${(@u)made_dirs[@]}"; do
      if ! is_tool_dir "$dd" || [[ -L "$dd" || ! -d "$dd" ]]; then continue; fi
      if ! under_home "$dd"; then warn "置き場の実体が HOME の外なので消さない: $dd"; continue; fi
      if (( dry )); then
        # 予定の表示では、消す予定の symlink だけが入っているなら空になるとみなす
        typeset -a rest=()
        for e in "$dd"/*(DN); do
          if [[ -L "$e" ]] && { points_to_kit "$e" || is_recorded "$e"; }; then continue; fi
          rest+=("$e")
        done
        if (( ${#rest} )); then print -- "残す（中に他のものがある）: $dd"; else say "削除（このスクリプトが作った空のフォルダ）: $dd"; fi
        continue
      fi
      if [[ -z "$(print -l "$dd"/*(DN))" ]]; then
        say "削除（このスクリプトが作った空のフォルダ）: $dd"
        rmdir -- "$dd" 2>/dev/null || { warn "消せなかった: $dd"; dleft+=("$dd"); }
      else
        print -- "残す（中に他のものがある）: $dd"
        dleft+=("$dd")
      fi
    done
    if (( ! dry )); then
      if (( ${#dleft} )); then
        tmp="$(mktemp "$conf_dir/.installed-dirs.XXXXXX")"
        print -rl -- "${dleft[@]}" >| "$tmp"
        if dirs_ok; then mv -f "$tmp" "$dirs_record"; else rm -f "$tmp"; fi
      elif [[ -f "$dirs_record" ]]; then
        rm -f "$dirs_record"
      fi
    fi
  fi
  if (( dry )); then
    print -- "symlink を ${removed} 件消す予定。設定ファイルは残す: $conf"
  else
    print -- "symlink を ${removed} 件消した。設定ファイルは残す: $conf"
  fi
fi

(( warns )) && print -u2 -- "警告 ${warns} 件（上を参照）"
exit 0
