#!/bin/zsh -f
# 実装レーン監視ルーチン用の 1 回分チェック（既定は外部書き込みなし。既読状態はローカル保存）。使い方:
#   lanes-monitor.sh [--no-append] [--reset] [--allow-redeploy]
# ${LANES_RUNS_ROOT:-~/dev/_runs} 配下の logs/*.pid を持つ作業場所を自動発見（_ 始まり・隠し領域を除外）。
# 接続先が判明した GitHub リポジトリだけ PR を照会する（gh が無い・未ログインなら黙って飛ばす）。
# --allow-redeploy は LANES_VERCEL_PROJECT / LANES_VERCEL_SCOPE を設定したときだけ意味がある（空なら「無効」と出す）。
# 発見した .pid/.done と open PR を見て、
# 前回からの変化だけを短く出す。1 行目は WAKE: <理由> か QUIET。新規終了と要対応は省略せず全件出す。
# 状態: ${LANES_RUNS_ROOT}/.lanes-monitor-state.json（既読の .done・前回の PR 一覧・STALLED/DEAD の初回時刻）
# 履歴: ${LANES_RUNS_ROOT}/lanes-monitor-now.txt に 1 行追記（--no-append で抑止）
# 終了コード: 通常 0（判定は 1 行目）。使い方/環境エラーは 2
[ -n "${ZSH_VERSION:-}" ] || exec zsh -f "$0" "$@"
set -euo pipefail
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
append=1; reset=0; allow_redeploy=0
while (( $# )); do
  case "$1" in
    --no-append) append=0; shift ;;
    --reset) reset=1; shift ;;
    --allow-redeploy) allow_redeploy=1; shift ;;
    *) lanes_die "使い方: lanes-monitor.sh [--no-append] [--reset] [--allow-redeploy]" ;;
  esac
done
export LANES_STATUS="$LANES_DIR/lanes-status.sh" LM_APPEND=$append LM_RESET=$reset LM_ALLOW_REDEPLOY=$allow_redeploy
exec python3 "$LANES_DIR/lanes_monitor.py"
