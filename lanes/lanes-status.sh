#!/bin/zsh -f
# レーンの生死を 1 行で返す（Claude 実装 / レビュー / Gemini / QA 共通。.pid の lane= で種類が分かる）。使い方:
#   lanes-status.sh <worktree> [label] [--tail N]
#   label 省略で logs/ 配下の全 label（<label>.pid / <label>.done があるもの）。--tail N で DONE 以外は最終出力ファイルの末尾 N 行も出す
# 状態:
#   RUNNING  pid 生存、最終出力から LANES_STALL_MINUTES 分以内
#   STALLED  pid 生存、最終出力から LANES_STALL_MINUTES 分超（許可待ち / MCP 固まり / cap 待ちの疑い。子の CPU 時間も併記）
#   DONE     .done あり EXIT:0
#   FAILED   .done あり EXIT≠0（ランチャが失敗を記録した: 前提チェック失敗・VERDICT 無し・CLI エラー・シグナル等）
#   DEAD     pid 消滅で .done 無し（kill -9 / Mac 再起動 / 起動元シェル終了で trap も走れず）
#   NONE     .pid も .done も無い（この label は起動していない、または旧ランチャのログ）
# 終了コード: DONE=0 RUNNING=10 STALLED=11 DEAD=12 FAILED=13 NONE=14（複数 label は最も重いもの）。使い方エラーは 2
# bash / sh で呼ばれても zsh で再実行する（bash だと ${0:A:h} が "A: unbound variable" で落ちる）
[ -n "${ZSH_VERSION:-}" ] || exec zsh -f "$0" "$@"
set -euo pipefail
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
zmodload -F zsh/stat b:zstat   # mtime を PATH 非依存で取る（GNU stat が先にあると stat -f が壊れる）

usage="使い方: lanes-status.sh <worktree> [label] [--tail N]"
wt="${1:-}"; [[ -n "$wt" ]] || lanes_die "$usage"
shift
label=""; tailn=0
while (( $# )); do
  case "$1" in
    --tail) (( $# >= 2 )) || lanes_die "--tail に値が無い"; tailn="$2"; shift 2 ;;
    --*) lanes_die "不明なオプション: $1 / $usage" ;;
    *) label="$1"; shift ;;
  esac
done
[[ "$tailn" == <-> ]] || lanes_die "--tail は整数"
[[ -z "$label" ]] || lanes_require_label "$label"
[[ "$LANES_STALL_MINUTES" == <-> ]] || lanes_die "LANES_STALL_MINUTES は整数（今: '$LANES_STALL_MINUTES'）"
lanes_require_worktree "$wt"; wt="${wt:A}"
logdir="$wt/logs"
now=$(date +%s)
stall_sec=$(( LANES_STALL_MINUTES * 60 ))

typeset -a labels
if [[ -n "$label" ]]; then
  labels=("$label")
else
  [[ -d "$logdir" ]] || { print -- "NONE     （logs/ が無い: $logdir）"; exit 14; }
  labels=("${(@f)$(ls "$logdir" 2>/dev/null | grep -E '\.(pid|done)$' | grep -vE '\.prev-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.(pid|done)$' | sed -E 's/\.(pid|done)$//' | sort -u || true)}")
  labels=("${(@)labels:#}")
  (( ${#labels} )) || { print -- "NONE     （.pid / .done が無い: $logdir）"; exit 14; }
fi

mtime() { local m; m="$(zstat +mtime "$1" 2>/dev/null || true)"; [[ "$m" == <-> ]] && print -- "$m" || print 0; }
ago() {  # 秒 → 「N秒前 / N分前 / N時間M分前」。負数なら不明
  local s="$1"
  if (( s < 0 )); then print "不明"
  elif (( s < 60 )); then print "${s}秒前"
  elif (( s < 3600 )); then print "$(( s / 60 ))分前"
  else print "$(( s / 3600 ))時間$(( (s % 3600) / 60 ))分前"; fi
}
field() { [[ -f "$1" ]] || return 0; sed -n "s/^$2=//p" "$1" | head -1; }   # ファイル無しでも落ちない（set -e）
child_cpu() {  # $1=pidfile $2=非空なら kill 案内を付ける（FAILED / DEAD だけ。RUNNING / STALLED の子は健全なので案内しない）
  # 子（codex / claude / agy）の生死と CPU 時間。「動いているが無出力」と「固まっている」の区別材料。同一性は lstart で見る
  local c; c="$(field "$1" child_pid)"
  [[ "$c" == <-> ]] || return 0   # 未記録（前提チェック失敗など子がいないのが正常）は何も出さない
  local identity; identity="$(lanes_process_state "$c" "$(field "$1" child_lstart)")"
  if [[ "$identity" == unknown ]]; then
    print -- "子 pid=$c 同一性不明（停止・削除・再起動を保留）"
  elif [[ "$identity" == alive ]]; then
    local t; t="$(ps -o time= -p "$c" 2>/dev/null | sed 's/^ *//' || true)"
    print -- "子 pid=$c 生存 CPU ${t:-?}${2:+（kill $c してから再起動）}"
  else
    print -- "子 pid=$c 消滅（または別プロセス）"
  fi
}
addf() { [[ -n "$2" ]] && print -- "$1  $2" || print -- "$1"; }   # 空の断片で二重スペースを作らない

worst=0
for lb in "${labels[@]}"; do
  pidfile="$logdir/$lb.pid"; donefile="$logdir/$lb.done"; log="$logdir/$lb.log"; evidence="$logdir/$lb.evidence.md"
  # 最終出力 = この label の出力ファイルの最新 mtime（Claude のレーンは .log が終了後にしか無く、進行中は .json が増える）
  last=0; lastf=""
  for f in "$log" "$logdir/$lb.json" "$logdir/$lb.stderr.log" "$logdir/$lb.last.md" "$logdir/$lb.completion.json" "$evidence"; do
    [[ -f "$f" ]] || continue
    m=$(mtime "$f"); (( m > last )) && { last=$m; lastf="$f"; }
  done
  pid=""; started=""; started_epoch=0
  if [[ -f "$pidfile" ]]; then
    pid="$(field "$pidfile" pid)"; started="$(field "$pidfile" started)"
    started_epoch="$(field "$pidfile" started_epoch)"; [[ "$started_epoch" == <-> ]] || started_epoch=0
  fi
  state=""; code=0; detail=""
  if [[ -f "$donefile" ]]; then
    rc="$(sed -n 's/^EXIT://p' "$donefile" | head -1)"; [[ -n "$rc" ]] || rc="?"
    verdict="$(grep -m1 '^VERDICT:' "$donefile" || print 'VERDICT: ?')"
    finished="$(field "$donefile" finished)"; elapsed="$(field "$donefile" elapsed_min)"; note="$(field "$donefile" note)"
    dm=$(mtime "$donefile"); since=$(( dm > 0 ? now - dm : -1 ))
    if [[ "$rc" == "0" ]]; then state="DONE"; code=0; else state="FAILED"; code=13; fi
    detail="EXIT:$rc  $verdict  終了 ${finished:-?}（$(ago $since)）  経過 ${elapsed:-?}分"
    [[ -n "$note" ]] && detail+="  ($note)"
    if [[ "$state" == "FAILED" ]]; then detail="$(addf "$detail" "$(child_cpu "$pidfile" 1)")"; fi   # 子が生きていれば孤児（kill が要る）
    if [[ -f "$evidence" ]]; then detail+="  証跡: $evidence"; else detail+="  証跡なし。出力: ${lastf:-無し}"; fi
  elif [[ -n "$pid" ]]; then
    identity="$(lanes_process_state "$pid" "$(field "$pidfile" lstart)")"
    alive=0; [[ "$identity" == alive ]] && alive=1
    el=$(( started_epoch > 0 ? (now - started_epoch) / 60 : -1 ))
    if [[ "$identity" == unknown ]]; then
      state="FAILED"; code=13
      detail="pid=$pid 同一性不明（停止・削除・再起動を保留）。出力: ${lastf:-まだ無し}"
    elif (( alive )); then
      if (( last > 0 )); then age=$(( now - last )); elif (( started_epoch > 0 )); then age=$(( now - started_epoch )); else age=-1; fi
      if (( age > stall_sec )); then
        state="STALLED"; code=11
        detail="$(addf "pid=$pid  経過 ${el}分  最終出力 $(ago $age)（閾値 ${LANES_STALL_MINUTES}分）" "$(child_cpu "$pidfile")")  → 末尾を見る。許可待ち / MCP / cap の疑い。原因が分かれば kill $pid（ランチャ）して再起動。出力: ${lastf:-まだ無し}"
      else
        state="RUNNING"; code=10
        detail="$(addf "pid=$pid  開始 ${started:-?}  経過 ${el}分  最終出力 $(ago $age)" "$(child_cpu "$pidfile")")  出力: ${lastf:-まだ無し}"
      fi
    else
      state="DEAD"; code=12
      detail="$(addf "pid=$pid 消滅・.done 無し  開始 ${started:-?}  最終出力 $(ago $(( last > 0 ? now - last : -1 )))" "$(child_cpu "$pidfile" 1)")  → 起動元シェル終了 / kill -9 / 再起動の疑い。出力: ${lastf:-無し}"
    fi
  else
    state="NONE"; code=14
    if [[ -f "$log" ]]; then detail="(.pid / .done 無し。旧ランチャのログ)  ログ: $log"
    else detail="(この label の記録が無い: $logdir/$lb.*)"; fi
  fi
  printf '%-8s %s  %s\n' "$state" "$lb" "$detail"
  if (( tailn > 0 )) && [[ "$state" != "DONE" ]]; then
    tailf="$lastf"
    [[ "$state" == "FAILED" && -s "$logdir/$lb.stderr.log" ]] && tailf="$logdir/$lb.stderr.log"   # 失敗の原因は stderr に出る
    if [[ -n "$tailf" ]]; then
      print -- "  --- 最終出力 ${tailn} 行: $tailf"
      tail -n "$tailn" "$tailf" | cut -c1-300 | sed 's/^/  | /'
    else
      print -- "  --- 出力ファイルがまだ無い: $logdir/$lb.*"
    fi
  fi
  (( code > worst )) && worst=$code
done
exit $worst
