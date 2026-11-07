#!/bin/zsh -f
# 5 分監視と定期の生存確認（既定 10 分ごと。LANES_CHECK_INTERVAL_MIN）の入口。判定・時刻制限・排他は標準ライブラリの本体へ渡す。
# lanes-watch.sh [--until-wake] [--interval 秒] [--max-hours 時間] / lanes-watch.sh --check
# LANES_RUNS_ROOT / LANES_WATCH_MONITOR / LANES_WATCH_HEARTBEAT で使い捨て環境へ差し替え可能。
[ -n "${ZSH_VERSION:-}" ] || exec zsh -f "$0" "$@"
set -euo pipefail
# 設定ファイルの LANES_RUNS_ROOT などを Python 側へ渡す（lanes.env が LANES_* を export する）
source "${0:A:h}/lanes.env"
command -v python3 >/dev/null 2>&1 || { print -u2 -- 'ERROR: python3 が PATH に無い'; exit 2; }
# 司令塔が Claude のセッション（LANES_COMMANDER=claude）なら、終わらない常駐ではなく --until-wake で回すのが既定の形。
# 常駐で起動されたら案内だけ出す（止めない。標準エラーなので、1 行目の WAKE: / QUIET の読み取りには混ざらない）
if [[ "${LANES_COMMANDER:-}" == claude && " $* " != *" --until-wake "* && " $* " != *" --check "* && " $* " != *" -h "* && " $* " != *" --help "* ]]; then
  print -u2 -- '注意: 司令塔が Claude（LANES_COMMANDER=claude）のときは、lanes-watch.sh --until-wake をバックグラウンドで回し、WAKE: で起きて次工程をつなぐのが既定の形（終わらない常駐は外の Bot 向け。docs/commander-claude.md）'
fi
exec python3 -B "${0:A:h}/lanes_watch.py" "$@"
