#!/bin/zsh -f
# レビューの入口。構成（LANES_TOOLS）のレビュー役に合うランチャへ振り分ける薄い入口。
# 使い方: run-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
#   レビュー役 codex（① full / ② claude-codex）: run-codex-review.sh へそのまま渡す
#   レビュー役 claude（③ claude-gemini / ④ claude-only）: run-claude-review.sh へそのまま渡す
#   どちらも review-dedup.zsh の同じ仕組み（--mode auto の full / delta / 同じ head の結果の再利用、--round と round 3 以降の
#   P2/P3 の後回し、--force、--base は commit に解決できるもの）と、親の chk-run.sh の記録による必須検証の使い回しを持つ
# 起動前に lanes-doctor.sh --quiet を通す（足りないものがあれば一覧を出して exit 2）。点検は振り分け先が label の排他を取った後に
# 行うので、失敗は今回の .done（EXIT:2 → lanes-status.sh で FAILED）に残る（前回の成功の .done を残したまま止まらない）。
# 終了コードは振り分け先のランチャのまま。この入口自身の誤り（引数・構成・点検）は exit 2。
# 入口自身の誤りも、label の排他を取れれば今回の .done（EXIT:2）に残す（_common.sh の lanes_early_target）。
set -euo pipefail
LANES_DIR="${0:A:h}"
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
source "$LANES_DIR/_common.sh"
die() { lanes_die "$@"; }
usage="使い方: run-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]"
(( $# >= 2 )) || die "$usage"
wt="$1"; prompt="$2"; shift 2
label=""; mode=""; base=""; round=""; force=0; dry=0
while (( $# )); do
  case "$1" in
    --mode) (( $# >= 2 )) || { lanes_defer_die "--mode に値が無い"; shift; continue; }; mode="$2"; shift 2 ;;
    --base) (( $# >= 2 )) || { lanes_defer_die "--base に値が無い"; shift; continue; }; base="$2"; shift 2 ;;
    --round) (( $# >= 2 )) || { lanes_defer_die "--round に値が無い"; shift; continue; }; round="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --dry-run) dry=1; shift ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || die "label が 2 回: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
# 振り分け先と同じ規則で label を決め、ここから先の誤りを（排他を取れれば）今回の .done に残す
lanes_early_target "${wt:A}" "${label:-${${prompt:A}:t:r}}" "$dry"
[[ -z "$mode" || "$mode" == auto || "$mode" == full || "$mode" == delta ]] || die "--mode は auto|full|delta（渡されたのは '$mode'）"

source "$LANES_DIR/lanes-roles.sh"
lanes_roles_resolve || die "$LANES_ROLES_ERROR"

typeset -a args
args=("$wt" "$prompt")
[[ -n "$label" ]] && args+=("$label")
[[ -n "$mode" ]] && args+=(--mode "$mode")
[[ -n "$base" ]] && args+=(--base "$base")
[[ -n "$round" ]] && args+=(--round "$round")
(( force )) && args+=(--force)
(( dry )) && args+=(--dry-run)
if [[ "$LANES_ROLE_REVIEW" == codex ]]; then target=run-codex-review.sh; else target=run-claude-review.sh; fi
# 起動前点検は振り分け先が排他・終了記録（.pid / .done）を取った後に行う（失敗を今回の FAILED として残すため）
export LANES_ENTRY_PREFLIGHT=1
# _common.sh が外した API キーなどは、振り分け先が親の環境のまま chk-run.sh --query を呼べるよう元に戻して渡す
# （振り分け先も _common.sh で外すので、CLI の子には届かない）
lanes_restore_caller_auth_env
exec zsh -f "$LANES_DIR/$target" "${args[@]}"
