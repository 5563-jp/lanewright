#!/bin/zsh -f
# 実装の入口。構成（LANES_TOOLS）の実装役に合うランチャへ振り分ける薄い入口。
# 使い方: run-impl.sh <worktree> <prompt.md> [label] [--engine claude|gemini] [--dry-run]
#                     [gemini 用: --verify "<検証コマンド>" --allow-path <相対パス> ... [--no-push]]
#   --engine claude（省略時）: run-claude.sh へ渡す（gemini 用のオプションは付けられない）
#   --engine gemini         : run-gemini.sh へ渡す（構成に gemini が無ければ exit 2）
# 起動前に lanes-doctor.sh --quiet を通す（足りないものがあれば一覧を出して exit 2）。点検は振り分け先が label の排他を取った後に
# 行うので、失敗は今回の .done（EXIT:2 → lanes-status.sh で FAILED）に残る（前回の成功の .done を残したまま止まらない）。
# 終了コードは振り分け先のランチャのまま。この入口自身の誤り（引数・構成・点検）は exit 2。
# 入口自身の誤り（不明なオプションを含む）も、label の排他を取れれば今回の .done（EXIT:2）に残す（_common.sh の lanes_early_target）。
# label は指示書の直後に置く（不明なオプションの後ろの語は、そのオプションの値として読み捨てる）。
set -euo pipefail
LANES_DIR="${0:A:h}"
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
source "$LANES_DIR/_common.sh"
die() { lanes_die "$@"; }
usage="使い方: run-impl.sh <worktree> <prompt.md> [label] [--engine claude|gemini] [--dry-run] [gemini 用: --verify \"<cmd>\" --allow-path <相対パス> ... --no-push]"
(( $# >= 2 )) || die "$usage"
engine=""; gemini_only=""
typeset -a pass positional
pass=(); positional=()
early_dry=0
while (( $# )); do
  case "$1" in
    --engine) (( $# >= 2 )) || { lanes_defer_die "--engine に値が無い"; shift; continue; }; [[ -z "$engine" ]] || lanes_defer_die "--engine が 2 回"; engine="$2"; shift 2 ;;
    --verify|--allow-path) (( $# >= 2 )) || { lanes_defer_die "$1 に値が無い"; shift; continue; }; gemini_only="$1"; pass+=("$1" "$2"); shift 2 ;;
    --no-push) gemini_only="$1"; pass+=("$1"); shift ;;
    --dry-run) early_dry=1; pass+=("$1"); shift ;;
    --*)
      # 不明なオプションは入口で止める（今回の .done に EXIT:2 を残す）。値を取るつもりの書き方（--mode full）でも、
      # 値の full を label と取り違えないよう、worktree と指示書が揃った後の次の語は、そのオプションの値として読み捨てる
      lanes_defer_die "不明なオプション: $1 / $usage"
      # （--name=value の形は値が同じ語にあるので、次の語は読み捨てない）
      if (( ${#positional} >= 2 )); then lanes_unknown_opt_width "$@"; shift "$REPLY"; else shift; fi ;;
    *) positional+=("$1"); pass+=("$1"); shift ;;
  esac
done
engine="${engine:-claude}"
# 振り分け先と同じ規則で worktree と label を決め（label 省略時はプロンプトのファイル名）、ここから先の誤りを今回の .done に残す
if (( ${#positional} >= 2 )); then
  early_label="${positional[3]:-}"; [[ -n "$early_label" ]] || early_label="${${positional[2]:A}:t:r}"
  lanes_early_target "${positional[1]:A}" "$early_label" "$early_dry"
fi
[[ -z "${LANES_DEFERRED_ERROR:-}" ]] || die "$LANES_DEFERRED_ERROR"
[[ "$engine" == claude || "$engine" == gemini ]] || die "--engine は claude か gemini（渡されたのは '$engine'）"

source "$LANES_DIR/lanes-roles.sh"
lanes_roles_resolve || die "$LANES_ROLES_ERROR"
if [[ "$engine" == gemini ]] && ! lanes_roles_has_tool gemini; then
  die "この構成（$LANES_PROFILE / LANES_TOOLS=\"$LANES_TOOLS_NORMALIZED\"）に gemini が無いので --engine gemini は使えない。--engine を外して Claude で実装する"
fi
if [[ "$engine" == claude && -n "$gemini_only" ]]; then
  die "$gemini_only は gemini 用のオプション。Claude で実装するなら外す（Gemini で実装するなら --engine gemini）"
fi
# 起動前点検は振り分け先が排他・終了記録（.pid / .done）を取った後に行う（失敗を今回の FAILED として残すため）
export LANES_ENTRY_PREFLIGHT=1

case "$engine" in
  claude) exec zsh -f "$LANES_DIR/run-claude.sh" "${pass[@]}" ;;
  gemini) exec zsh -f "$LANES_DIR/run-gemini.sh" "${pass[@]}" ;;
esac
