#!/bin/zsh -f
# レビューの入口。構成（LANES_TOOLS）のレビュー役に合うランチャへ振り分ける薄い入口。
# 使い方: run-review.sh <worktree> <prompt.md> [label] [--engine codex|claude|gemini] [--mode auto|full|delta] [--base <sha|branch>] [--round N]
#                       [--force] [--allow-missing-checks] [--allow-same-engine] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
#   レビュー役 codex（① full / ② claude-codex）: run-codex-review.sh へそのまま渡す
#   レビュー役 claude（③ claude-gemini / ④ claude-only）: run-claude-review.sh へそのまま渡す
#   --engine で選ぶ（run-impl.sh の --engine と同じ流儀）。優先順は --engine ＞ LANES_REVIEW_ENGINE（設定。既定は空）＞ 構成のレビュー役。
#     codex  : run-codex-review.sh（構成に codex が無ければ exit 2）
#     claude : run-claude-review.sh（claude はどの構成にもある）
#     gemini : run-gemini-review.sh（構成に gemini が無ければ exit 2。明示したときだけ使う。Gemini で実装した worktree には使わない）
#   --allow-same-engine は gemini 用（Gemini で実装した worktree をあえて Gemini でレビューするときだけ）
#   どれも review-dedup.zsh の同じ仕組み（--mode auto の full / delta / 同じ head の結果の再利用、--round と round 3 以降の
#   P2/P3 の後回し、--force、--base は commit に解決できるもの）と、親の chk-run.sh の記録による必須検証の使い回しを持つ
# 起動前に lanes-doctor.sh --quiet を通す（足りないものがあれば一覧を出して exit 2）。点検は振り分け先が label の排他を取った後に
# 行うので、失敗は今回の .done（EXIT:2 → lanes-status.sh で FAILED）に残る（前回の成功の .done を残したまま止まらない）。
# 点検は、ここで決めたレビュー役を前提に回す（LANES_REVIEW_ENGINE に入れて振り分け先へ渡し、振り分け先の lanes_entry_preflight が
# lanes-doctor.sh --review-engine に渡す。設定ファイルが別の値で固定していても、実際に振り分けたレビュー役で点検する）。
# 終了コードは振り分け先のランチャのまま。この入口自身の誤り（引数・構成・点検・知らない --engine の値）は exit 2。
# 入口自身の誤りも、label の排他を取れれば今回の .done（EXIT:2）に残す（_common.sh の lanes_early_target）。
set -euo pipefail
LANES_DIR="${0:A:h}"
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
source "$LANES_DIR/_common.sh"
die() { lanes_die "$@"; }
usage="使い方: run-review.sh <worktree> <prompt.md> [label] [--engine codex|claude|gemini] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--allow-missing-checks] [--allow-same-engine] [--dry-run]"
(( $# >= 2 )) || die "$usage"
wt="$1"; prompt="$2"; shift 2
label=""; mode=""; base=""; round=""; force=0; dry=0; allow_missing=0; allow_same=0; engine=""; engine_given=0
while (( $# )); do
  case "$1" in
    --engine) (( $# >= 2 )) || { lanes_defer_die "--engine に値が無い"; shift; continue; }; (( ! engine_given )) || lanes_defer_die "--engine が 2 回"; engine="$2"; engine_given=1; shift 2 ;;
    --mode) (( $# >= 2 )) || { lanes_defer_die "--mode に値が無い"; shift; continue; }; mode="$2"; shift 2 ;;
    --base) (( $# >= 2 )) || { lanes_defer_die "--base に値が無い"; shift; continue; }; base="$2"; shift 2 ;;
    --round) (( $# >= 2 )) || { lanes_defer_die "--round に値が無い"; shift; continue; }; round="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --allow-missing-checks) allow_missing=1; shift ;;
    --allow-same-engine) allow_same=1; shift ;;
    --dry-run) dry=1; shift ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || die "label が 2 回: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
# 振り分け先と同じ規則で label を決め、ここから先の誤りを（排他を取れれば）今回の .done に残す
lanes_early_target "${wt:A}" "${label:-${${prompt:A}:t:r}}" "$dry"
[[ -z "$mode" || "$mode" == auto || "$mode" == full || "$mode" == delta ]] || die "--mode は auto|full|delta（渡されたのは '$mode'）"
# --engine の値（空文字の指定も誤り）。設定（LANES_REVIEW_ENGINE）の値は lanes.env が確かめ済み（誤りは設定の誤りとして上で止まる）
if (( engine_given )); then
  [[ "$engine" == codex || "$engine" == claude || "$engine" == gemini ]] || die "--engine は codex か claude か gemini（渡されたのは '$engine'）"
fi

source "$LANES_DIR/lanes-roles.sh"
lanes_roles_resolve || die "$LANES_ROLES_ERROR"
# 優先順: --engine ＞ LANES_REVIEW_ENGINE ＞ 構成のレビュー役
engine_from="構成のレビュー役"
if (( engine_given )); then engine_from="--engine"
elif [[ -n "${LANES_REVIEW_ENGINE:-}" ]]; then engine="$LANES_REVIEW_ENGINE"; engine_from="LANES_REVIEW_ENGINE"
else engine="$LANES_ROLE_REVIEW"
fi
if [[ "$engine" != claude ]] && ! lanes_roles_has_tool "$engine"; then
  die "この構成（$LANES_PROFILE / LANES_TOOLS=\"$LANES_TOOLS_NORMALIZED\"）に $engine が無いので、レビュー役に $engine（$engine_from）は使えない。構成に $engine を足すか、$engine_from の指定を外して構成のレビュー役（$LANES_ROLE_REVIEW）で回す"
fi
if [[ "$engine" != gemini ]] && (( allow_same )); then
  die "--allow-same-engine は Gemini レビュー（--engine gemini）用のオプション。$engine でレビューするなら外す"
fi

typeset -a args
args=("$wt" "$prompt")
[[ -n "$label" ]] && args+=("$label")
[[ -n "$mode" ]] && args+=(--mode "$mode")
[[ -n "$base" ]] && args+=(--base "$base")
[[ -n "$round" ]] && args+=(--round "$round")
(( force )) && args+=(--force)
(( allow_missing )) && args+=(--allow-missing-checks)
(( allow_same )) && args+=(--allow-same-engine)
(( dry )) && args+=(--dry-run)
case "$engine" in
  codex) target=run-codex-review.sh ;;
  claude) target=run-claude-review.sh ;;
  gemini) target=run-gemini-review.sh ;;
esac
# 起動前点検は振り分け先が排他・終了記録（.pid / .done）を取った後に行う（失敗を今回の FAILED として残すため）
export LANES_ENTRY_PREFLIGHT=1
# 点検（振り分け先の lanes_entry_preflight → lanes-doctor.sh --review-engine）が、ここで決めたレビュー役を前提にするよう渡す
# （設定が LANES_REVIEW_ENGINE=gemini でも、--engine codex / claude で選んだ起動を、使わない Gemini の点検で止めない）。
# chk-run.sh は LANES_REVIEW_ENGINE を外してから指紋を取るので、必須検証の記録の使い回しには影響しない
export LANES_REVIEW_ENGINE="$engine"
# _common.sh が外した API キーなどは、振り分け先が親の環境のまま chk-run.sh --query を呼べるよう元に戻して渡す
# （振り分け先も _common.sh で外すので、CLI の子には届かない）
lanes_restore_caller_auth_env
exec zsh -f "$LANES_DIR/$target" "${args[@]}"
