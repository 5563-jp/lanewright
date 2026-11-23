#!/bin/zsh -f
# レビューの入口。構成（LANES_TOOLS）とレビュー役の決まりに合うランチャへ振り分ける薄い入口。
# 使い方: run-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force]
#                       [--allow-missing-checks] [--engine codex|gemini|claude] [--impl-engine claude|gemini|codex] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
#   振り分け先: codex → run-codex-review.sh / claude → run-claude-review.sh / gemini → run-gemini-review.sh
#   どれも review-dedup.zsh の同じ仕組み（--mode auto の full / delta / 同じ head の結果の再利用、--round と round 3 以降の
#   P2/P3 の後回し、--force、--base は commit に解決できるもの）と、親の chk-run.sh の記録による必須検証の使い回しを持つ
# レビュー役の決め方（上から順に、最初に当てはまるもの）:
#   1. --engine の明示。構成に無い道具・知らない名前は exit 2
#   2. 同じ系列（label の末尾 -r<N> を外した名前）の前回のレビュー役（logs/.<系列>.review-state か、その系列の証跡の見出し）。
#      r2 以降も同じ役で続ける（同じ head の結果の再利用と delta が効く。割合の数え方は進めない）。今の構成に無い役は使わない
#   3. LANES_REVIEW_GEMINI_PCT（0〜100。既定 0）の割合で Gemini（構成に gemini があるときだけ）。100 なら毎回 Gemini。
#      1〜99 は ${XDG_STATE_HOME:-~/.local/state}/lanewright/review-split.state に誤差を積み上げて決める
#      （acc に割合を足し、100 以上になったら 100 を引いて Gemini。50 なら既定の役・Gemini・既定の役・Gemini … の順）
#   4. 構成の既定のレビュー役（LANES_ROLE_REVIEW: codex（① full / ② claude-codex）か claude（③ claude-gemini / ④ claude-only））
# 同じ道具でのレビューの禁止: Gemini で実装したものは Gemini でレビューしない。--engine gemini なら exit 2、2・3 では Gemini を選ばない
#   （系列の前回が Gemini でも、構成の既定の役へ逃がす）。Gemini で実装したかは、--impl-engine gemini か、logs/ の .pid に
#   Gemini の実装レーン（lane=gemini）が 1 つでもあるかで見る（どちらかに当たれば Gemini で実装したとみなす。迷ったら Gemini に回さない側）。
#   それ以外の組み合わせ（Claude の実装を Claude でレビューする ③④ など）は今までどおり
# --dry-run は割合の記録（review-split.state）を進めない（次に選ぶ役を見せるだけ）。選んだ役と理由は標準エラーに 1 行出す
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
usage="使い方: run-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--allow-missing-checks] [--engine codex|gemini|claude] [--impl-engine claude|gemini|codex] [--dry-run]"
(( $# >= 2 )) || die "$usage"
wt="$1"; prompt="$2"; shift 2
label=""; mode=""; base=""; round=""; force=0; dry=0; allow_missing=0; engine=""; impl_engine=""
while (( $# )); do
  case "$1" in
    --mode) (( $# >= 2 )) || { lanes_defer_die "--mode に値が無い"; shift; continue; }; mode="$2"; shift 2 ;;
    --base) (( $# >= 2 )) || { lanes_defer_die "--base に値が無い"; shift; continue; }; base="$2"; shift 2 ;;
    --round) (( $# >= 2 )) || { lanes_defer_die "--round に値が無い"; shift; continue; }; round="$2"; shift 2 ;;
    --engine) (( $# >= 2 )) || { lanes_defer_die "--engine に値が無い"; shift; continue; }; [[ -z "$engine" ]] || lanes_defer_die "--engine が 2 回"; engine="$2"; shift 2 ;;
    --impl-engine) (( $# >= 2 )) || { lanes_defer_die "--impl-engine に値が無い"; shift; continue; }; [[ -z "$impl_engine" ]] || lanes_defer_die "--impl-engine が 2 回"; impl_engine="$2"; shift 2 ;;
    --force) force=1; shift ;;
    --allow-missing-checks) allow_missing=1; shift ;;
    --dry-run) dry=1; shift ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || die "label が 2 回: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
# 振り分け先と同じ規則で label を決め、ここから先の誤りを（排他を取れれば）今回の .done に残す
eff_label="${label:-${${prompt:A}:t:r}}"
lanes_early_target "${wt:A}" "$eff_label" "$dry"
lanes_require_label "$eff_label"   # 系列の記録を読む前に形を確かめる（logs/ の外を読まない）
[[ -z "$mode" || "$mode" == auto || "$mode" == full || "$mode" == delta ]] || die "--mode は auto|full|delta（渡されたのは '$mode'）"
[[ -z "$engine" || "$engine" == codex || "$engine" == gemini || "$engine" == claude ]] || die "--engine は codex|gemini|claude（渡されたのは '$engine'）"
[[ -z "$impl_engine" || "$impl_engine" == claude || "$impl_engine" == gemini || "$impl_engine" == codex ]] \
  || die "--impl-engine は claude|gemini|codex（渡されたのは '$impl_engine'）"

source "$LANES_DIR/lanes-roles.sh"
lanes_roles_resolve || die "$LANES_ROLES_ERROR"
if [[ -n "$engine" ]] && ! lanes_roles_has_tool "$engine"; then
  die "この構成（$LANES_PROFILE / LANES_TOOLS=\"$LANES_TOOLS_NORMALIZED\"）に $engine が無いので --engine $engine は使えない。--engine を外すと構成の既定のレビュー役（$LANES_ROLE_REVIEW）で回す"
fi
source "$LANES_DIR/review-dedup.zsh"

# Gemini で実装したか（--impl-engine gemini か、logs/ の .pid に lane=gemini の実装レーンが 1 つでもある。
# run-gemini-review.sh も同じ判定 review-dedup.zsh の rvd_impl_gemini を使い、直接呼ばれても自分では拒否する）
impl_gemini=0
rvd_impl_gemini "${wt:A}/logs" "$impl_engine" && impl_gemini=1

# 割合の振り分け。<割合 1〜99> <dry-run なら 1> → 標準出力に gemini か default。
# 記録を読めない・書けない・排他を取れないときは default（構成の既定の役。今までどおりのレビュー）に倒し、理由を標準エラーに出す
review_split() {
  local pct="$1" dry="$2" dir="${XDG_STATE_HOME:-$HOME/.local/state}/lanewright" acc=0 v="" next pick fd=""
  local state="$dir/review-split.state" lock="$dir/review-split.lock" tmp
  if (( ! dry )); then
    zmodload zsh/system 2>/dev/null \
      && ( umask 077; mkdir -p -- "$dir" && : >> "$lock" ) 2>/dev/null \
      && zsystem flock -t 10 -f fd "$lock" 2>/dev/null \
      || { print -u2 -- "注意: 割合の振り分けの記録（$state）の排他を取れない。今回は構成の既定のレビュー役で回す"; print -r -- default; return 0; }
  fi
  if [[ -f "$state" && ! -L "$state" ]]; then v="$(sed -n 's/^acc=//p' "$state" 2>/dev/null)" || v=""; v="${v%%$'\n'*}"; fi
  if [[ "$v" == <-> && ${#v} -le 3 ]] && (( v < 100 )); then acc=$v; fi
  next=$(( acc + pct ))
  if (( next >= 100 )); then pick=gemini; next=$(( next - 100 )); else pick=default; fi
  if (( ! dry )); then
    tmp="$state.tmp.$$"
    if ! { print -r -- "acc=$next" > "$tmp" && mv -f -- "$tmp" "$state"; } 2>/dev/null; then
      rm -f -- "$tmp" 2>/dev/null || true
      print -u2 -- "注意: 割合の振り分けの記録（$state）を書けない。今回は構成の既定のレビュー役で回す"
      pick=default
    fi
    zsystem flock -u "$fd" 2>/dev/null || true
  fi
  print -r -- "$pick"
}

pick=""; why=""; note=""
if [[ -n "$engine" ]]; then
  if [[ "$engine" == gemini ]] && (( impl_gemini )); then
    die "Gemini で実装したもの（--impl-engine gemini か logs/ の .pid の lane=gemini）は Gemini でレビューしない（同じ道具のレビューは独立性が無い）。--engine を外すか codex / claude を指定する"
  fi
  pick="$engine"; why="--engine の指定"
fi
if [[ -z "$pick" ]]; then
  series="$(rvd_series "$eff_label")"
  prev="$(rvd_prev_reviewer "${wt:A}/logs" "$series")"
  if [[ -z "$prev" ]]; then
    :
  elif ! lanes_roles_has_tool "$prev"; then
    note="同じ系列（$series）の前回の役 $prev は今の構成に無い"
  elif [[ "$prev" == gemini ]] && (( impl_gemini )); then
    note="同じ系列（$series）の前回は Gemini だが、Gemini で実装したものなので Gemini では続けない"
  else
    pick="$prev"; why="同じ系列（$series）の前回のレビュー役を続ける"
  fi
fi
if [[ -z "$pick" ]]; then
  pct="${LANES_REVIEW_GEMINI_PCT:-0}"
  # lanes.env が確かめ済みだが、計算に入れる直前にも数字だけかを見る（lanes.env を差し替えた環境でも値の中身を実行しない）
  [[ "$pct" == <-> && ${#pct} -le 3 ]] || pct=0
  (( pct <= 100 )) || pct=0
  why="構成の既定"
  if (( pct > 0 )) && lanes_roles_has_tool gemini; then
    if (( impl_gemini )); then
      why="Gemini で実装したものなので、割合の振り分け（LANES_REVIEW_GEMINI_PCT=$pct）から外して構成の既定"
    elif (( pct >= 100 )); then
      pick=gemini; why="LANES_REVIEW_GEMINI_PCT=100"
    elif [[ "$(review_split "$pct" "$dry")" == gemini ]]; then
      pick=gemini; why="LANES_REVIEW_GEMINI_PCT=$pct の割合で Gemini"
    else
      why="LANES_REVIEW_GEMINI_PCT=$pct の割合で構成の既定"
    fi
  fi
  [[ -n "$pick" ]] || pick="$LANES_ROLE_REVIEW"
fi
case "$pick" in
  codex) target=run-codex-review.sh ;;
  gemini) target=run-gemini-review.sh ;;
  *) target=run-claude-review.sh ;;
esac
# 子シェルの中で出す（閉じた stderr へ print -u2 すると、そのシェルごと止まるため。出せなくても振り分けは止めない）
( print -u2 -- "レビュー役: $pick（$why${note:+。$note}）→ $target" ) || true

typeset -a args
args=("$wt" "$prompt")
[[ -n "$label" ]] && args+=("$label")
[[ -n "$mode" ]] && args+=(--mode "$mode")
[[ -n "$base" ]] && args+=(--base "$base")
[[ -n "$round" ]] && args+=(--round "$round")
(( force )) && args+=(--force)
(( allow_missing )) && args+=(--allow-missing-checks)
(( dry )) && args+=(--dry-run)
# 起動前点検は振り分け先が排他・終了記録（.pid / .done）を取った後に行う（失敗を今回の FAILED として残すため）
export LANES_ENTRY_PREFLIGHT=1
# _common.sh が外した API キーなどは、振り分け先が親の環境のまま chk-run.sh --query を呼べるよう元に戻して渡す
# （振り分け先も _common.sh で外すので、CLI の子には届かない）
lanes_restore_caller_auth_env
exec zsh -f "$LANES_DIR/$target" "${args[@]}"
