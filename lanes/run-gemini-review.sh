#!/bin/zsh -f
# レビューランチャ（Gemini / Antigravity CLI agy・読み取り専用）。明示したときだけ使うレビュー役（既定のレビュー役は構成で決まる codex / claude）。
# 振り分けの入口は run-review.sh（--engine gemini か LANES_REVIEW_ENGINE=gemini）。構成（LANES_TOOLS）に gemini が無ければ起動しない（exit 2）。使い方:
#   run-gemini-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force]
#                        [--allow-missing-checks] [--allow-same-engine] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# レビューの周回の仕組みは run-claude-review.sh と同じ（review-dedup.zsh。順番も条件も同じ）:
#   既定は --mode auto。初回は full。前回 CLEAN・条件一致・未保存変更なしなら前回の HEAD からの delta、同じ HEAD なら前回の結果を使う（--force で回す）。
#   前回 NEEDS_FIX なら full に戻して未解決指摘を引き継ぐ。round は --round か label 末尾 -r<N>。round 3 以降の P2/P3 は必須検証の成功確認が
#   ある場合だけ後回し票を保存して CLEAN へ進める。周回の上限（LANES_REVIEW_MAX_ROUNDS）を超えて CLEAN にならなければ GATE: ESCALATE。
#   必須検証の使い回し（親の chk-run.sh の記録）・LANES_REVIEW_REQUIRE_CHECKS=1 の起動前の停止・--allow-missing-checks も同じ。
# 同じ道具でレビューしない: この worktree の logs/ に Gemini 実装（run-gemini.sh）の記録が 1 本でもあれば起動しない（exit 2）。
#   Codex か Claude のレビュー（run-review.sh --engine codex|claude）を使う。どうしても回すときだけ --allow-same-engine（証跡に残る）
# 読み取り専用の強制（ここが一番大事）:
#   agy は --mode plan（書き込む前に計画を出して止まるモード）＋ --sandbox（端末サンドボックス）＋ --settings（起動単位の設定）で起動する。
#   設定の拒否は _common.sh の lanes_gemini_review_settings（MCP・ファイルの書き込み・URL・commit や push などのコマンド。外から緩められない）。
#   --dangerously-skip-permissions・accept-edits・auto は使わない。ANTIGRAVITY_HEADLESS=true・stdin は /dev/null・--add-dir は scratch だけ。
#   Mac の端末サンドボックス（sandbox-exec）を有効にできない・agy --help に --sandbox / --settings / --mode（plan）が無いなら起動しない。
#   agy（GEMINI_BIN）は点検の前に絶対パスへ直し、点検と起動で同じ実行ファイルを使う（_common.sh の lanes_resolve_bin）。
#   専用の linked worktree だけで起動する（_common.sh の lanes_require_linked_worktree。本体 checkout・管理領域を外に置いた本体・
#   submodule では起動しない。run-gemini.sh と同じ確認）。呼び出し元の GIT_DIR などは _common.sh を読んだ時点で外し、git から見た
#   最上位がこの worktree であることも確かめる。
#   親（このランチャ）は対象の worktree へ cd しない（子だけを worktree で起動する）。親の python3 は -I（作業場所・PYTHON* の環境変数を
#   見ない）で動かし、レビュー対象の同名のモジュールを読まない。
#   子の環境: TMPDIR / LANES_SCRATCH = scratch、GIT_OPTIONAL_LOCKS=0、GIT_PAGER=cat、GIT_CONFIG_GLOBAL = scratch の最小 gitconfig、git の通信は止める。
#   子の前後で作業ツリー・指示と条件・git の管理フォルダ（設定・hooks・タグ・stash）・git の制御ファイル（git を呼ぶ前に比べる）・
#   再利用の記録・「使い回し禁止」の印（logs/ の中と外を置き場所ごとに）を比べ、変わっていたら NEEDS_FIX（EXIT:4）。
#   stream-json の書き込み系のツール呼び出し（run-gemini.sh の監査と同じ判定）が 1 件でもあれば NEEDS_FIX（EXIT:4。証跡に件数）。
#   監査と最後の応答は、親の受け取り役（gemini-stream-tee.py）がパイプで直接受け取った親専用の写しを読む（子が書ける logs/<label>.json は
#   判定の正本にしない。回収後に親専用の写しで置き換える）。先頭の init が無い・JSON の欠損・不正・result の重複・終端でない result は VERDICT: NONE。
#   書き込みの試み・改ざん（EXIT:4）で不合格にしたら、見つけた直後（証跡を書く前）に、その系列の前回の CLEAN を失効させる
#   （次の通常の起動で同じ HEAD の省略・delta に使わない）。監査は親専用の写しをバイト列のまま 1 行ずつ反復して読む（全体を読み込まない。
#   末尾の文字切れなどの不正行は監査の不備として数え、それまでに数えた書き込みの試みは失わない）。監査は 2 段: 数える段で書き込みの試みを
#   確定して前回の CLEAN を失効させてから、本文（last.md）と表示用のログ（log）を書く段に進む（書く段の失敗で件数を失わない）。
#   親の chk-run の記録を使い回したときは、子の後にも同じ環境で確認コマンドの入力を照合し直す（review-dedup.zsh の rvd_checks_recheck。
#   レビュー中に未追跡の logs/input.json などが変わっていたら NEEDS_FIX・EXIT:4）。
# 同じ worktree のレビューは 1 本ずつ（review-dedup.zsh の rvd_review_lock。logs/ と logs/ の外の固定の場所の 2 つに排他。並行すると、
#   後から終わった方が先に終わった方の再利用の記録を巻き戻す）。排他を取って前回の後始末をしてから、親の chk-run の記録を問い合わせる。
#   子の起動前に logs/ の外へ「確認中」の印（覚えた再利用の記録と「使い回し禁止」の印の有無）を置き、子の後の確認と、今回の判定の保存
#   （または違反のときの前回の CLEAN の失効）が済んでから消す。途中で終わったら次のレビューが印を見つけて、記録を子の前の中身に戻し、
#   その系列の前回の CLEAN を再利用しない（rvd_inflight_recover。「使い回し禁止」の印を置けなければ起動しない）。
#   同じ head の前回の結果を返すとき（skip-same-head）も、使い回した親の chk-run の記録の入力を照合し直す（変わっていたら返さない）。
# 見張り: run-gemini.sh と同じ（gemini-agy.zsh）。出力が GEMINI_REVIEW_NOOUTPUT_SEC 秒（既定 600）止まったら EXIT:8、
#   idle（裏の作業待ち）のまま子が無ければ EXIT:3、全体の上限は --print-timeout（GEMINI_REVIEW_PRINT_TIMEOUT、既定 45m）。
# モデルと effort: GEMINI_REVIEW_MODEL / GEMINI_REVIEW_EFFORT（既定は空 = 付けない。実装用の GEMINI_MODEL / GEMINI_EFFORT とは別）
# 出力: <worktree>/logs/<label>.log（本文と証跡）/ <label>.last.md（最後の応答の本文だけ）/ <label>.json（生の stream-json。進行中も増える）
#       / <label>.stderr.log / <label>.prompt.md（渡した全文。dry-run は <label>.dry-run.prompt.md）/ <label>.evidence.md（PR 貼り付け用）
#       / <label>.pid（起動時）/ <label>.done（終了時）/ .<系列>.review-state（再利用の記録）/ <系列>.followups.md（round 3 以降の後回し票）
# 最終行は必ず VERDICT: CLEAN | NEEDS_FIX | NONE。終了コード: agy の rc（非 0 ならそのまま。見張りの停止は idle 3 / 無出力 8）、
#   改ざん・書き込みの試みは 4（agy の rc より優先。agy の rc は証跡の「読み取り専用の確認」の行に別に書く）、rc 0 で VERDICT が取れなければ 3、
#   引数・前提の誤りは 2。実行中に logs/ そのものを差し替えられたら 5（記録を書かずに止め、logs/ の外に「使い回し禁止」の印を置く）
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
source "$LANES_DIR/review-dedup.zsh"

usage="使い方: run-gemini-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--allow-missing-checks] [--allow-same-engine] [--dry-run]"
wt="${1:-}"; prompt="${2:-}"
[[ -n "$wt" && -n "$prompt" ]] || lanes_die "$usage"
shift 2
label=""; mode="auto"; base=""; dry=0; round=0; force=0; allow_missing=0; allow_same=0
while (( $# )); do
  case "$1" in
    --mode) (( $# >= 2 )) || { lanes_defer_die "--mode に値が無い"; shift; continue; }; mode="$2"; shift 2 ;;
    --base) (( $# >= 2 )) || { lanes_defer_die "--base に値が無い"; shift; continue; }; base="$2"; shift 2 ;;
    --round) (( $# >= 2 )) || { lanes_defer_die "--round に値が無い"; shift; continue; }; round="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --force) force=1; shift ;;
    --allow-missing-checks) allow_missing=1; shift ;;
    --allow-same-engine) allow_same=1; shift ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || lanes_die "label が 2 回指定されている: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
wt="${wt:A}"; prompt="${prompt:A}"
[[ -n "$label" ]] || label="${prompt:t:r}"
# ここから排他を取るまでの誤り（--mode・--round・--base の値など）は、取れれば今回の .done に残す（前回の DONE を残したまま止まらない）
lanes_early_target "$wt" "$label" "$dry"
lanes_require_label "$label"
lanes_require_worktree "$wt"
# 呼び出し元の git の場所の環境変数（GIT_DIR など）は _common.sh を読んだ時点で外してある。git から見た最上位がこの worktree か確かめる
lanes_require_toplevel "$wt"
[[ "$mode" == "auto" || "$mode" == "full" || "$mode" == "delta" ]] || lanes_die "--mode は auto|full|delta（渡されたのは '$mode'）"
[[ "$round" == <-> && ${#round} -le 6 ]] || lanes_die "--round は 0〜999999 の整数"
# 比較起点はレビュー開始前に commit へ固定し、再利用判定にも含める。統合先の枝が無い repo（main だけの運用など）では --base を案内して止める
if [[ -n "$base" ]]; then
  base="$(git -C "$wt" rev-parse --verify --end-of-options "$base^{commit}" 2>/dev/null)" || lanes_die "--base を commit として解決できない: $base"
else
  base="$(git -C "$wt" rev-parse --verify --end-of-options "origin/${LANES_BASE_BRANCH:-develop}^{commit}" 2>/dev/null)" \
    || lanes_die "比較起点 origin/${LANES_BASE_BRANCH:-develop} が無い。その枝の無い repo では --base <sha|branch> を指定する（統合先は LANES_BASE_BRANCH で変えられる）"
fi
review_base="$base"

logdir="$wt/logs"
log="$logdir/$label.log"; json="$logdir/$label.json"; err="$logdir/$label.stderr.log"; body_log="$logdir/$label.last.md"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
# 系列の記録（再利用の記録・後回し票・「使い回し禁止」の印）は label では名前が決まらないので、ランチャの記録の台帳へ名前で載せる
series="$(rvd_series "$label")"
(( dry )) || lanes_mark_start "$logdir" "$label" gemini-review "$wt" "file:.$series.review-state" "file:$series.followups.md" "file:.review-reuse-blocked"
if (( ! dry )); then
  # 同じ worktree のレビューは 1 本ずつ。前回の記録を読む所から最後の保存まで、排他をかける（logs/ と logs/ の外の固定の場所。終了まで持つ）
  rvd_review_lock_or_die "$logdir" "$LANES_LOGDIR_ID"
  # 前のレビューが子の後の確認の前に終わっていたら（「確認中」の印が残っている）、記録を子の前に戻し、その系列の CLEAN を失効させる。
  # 「使い回し禁止」の印を置けなければ、ここで止める（rvd_inflight_recover_or_die）
  rvd_inflight_recover_or_die "$logdir"
fi
# 必須検証の使い回しの問い合わせ（排他を取り、前回の記録を戻した後。前回の子が残した台帳に無い記録が入力の変化に見えて、
# 復旧の前に止まらないように）。指紋に環境変数が入るので、scratch や git の通信止めを export する前に、親が chk-run.sh を回したのと
# 同じ環境で呼ぶ（ここまでに export・unset したものは無い）。ランチャの記録（logs/ の直下の .pid・ログ・起動ログなど）は指紋に入らない
rvd_checks_query "$LANES_DIR" "$wt"
[[ "$RVD_CHECKS_REUSE" == yes ]] && LANES_REVIEW_CHECKS_REUSED=1 || LANES_REVIEW_CHECKS_REUSED=0
checks_key="$(rvd_checks_key)"
# 親の chk-run の記録を使えないときは、子を起動せずに止める（LANES_REVIEW_REQUIRE_CHECKS=1 のとき。理由と直し方を .done の note に残す）
if rvd_checks_block "$allow_missing"; then lanes_die_noted "$RVD_CHECKS_BLOCK"; fi
# 同じ道具でレビューしない。この worktree に Gemini 実装の記録があれば止める（今回の失敗 EXIT:2 として、理由を .done の note に残す）
# 記録を読めない（確かめられない）ときも「記録なし」と取り違えず、--allow-same-engine が無ければ止める
same_engine_line=""; same_rc=0
lanes_impl_lane_recorded "$logdir" gemini || same_rc=$?
if (( same_rc == 0 )); then
  if (( allow_same )); then
    same_engine_line="- 同じ道具のレビュー: この worktree に Gemini 実装の記録がある（logs/$REPLY）のに --allow-same-engine で起動した（実装と同じ思い込みを見落としやすい）"
    print -u2 -- "注意: この worktree に Gemini 実装の記録がある（logs/$REPLY）。--allow-same-engine が付いているので Gemini でレビューする（証跡に残す）"
  else
    lanes_die_noted "この worktree には Gemini 実装の記録がある（logs/$REPLY）。実装と同じ道具（Gemini）でレビューすると同じ思い込みを見落としやすいので起動しない。Codex か Claude のレビューを使う（run-review.sh --engine codex / --engine claude）。どうしても Gemini で回すなら --allow-same-engine を付ける（証跡に残る）"
  fi
elif (( same_rc != 1 )); then
  if (( allow_same )); then
    same_engine_line="- 同じ道具のレビュー: この worktree の Gemini 実装の記録を確かめられない（$REPLY）のに --allow-same-engine で起動した"
    print -u2 -- "注意: この worktree の Gemini 実装の記録を確かめられない（$REPLY）。--allow-same-engine が付いているので Gemini でレビューする（証跡に残す）"
  else
    lanes_die_noted "この worktree の Gemini 実装の記録を確かめられない（$REPLY）。実装と同じ道具（Gemini）でのレビューにならないと確かめられないので起動しない。logs/ の .pid・証跡を読めるように直すか、Codex か Claude のレビューを使う（run-review.sh --engine codex / --engine claude）。どうしても Gemini で回すなら --allow-same-engine を付ける（証跡に残る）"
  fi
fi
lanes_require_tool gemini run-gemini-review.sh
# 入口（run-review.sh）から来たときの起動前点検は、Gemini レビューの点検（agy の有無・サンドボックス）も含めて回す
# （点検は設定ファイルを読み直すので、レビュー役は環境変数ではなく引数で渡す）
lanes_entry_preflight gemini
lanes_require_prompt "$prompt"
# 見張りの設定（Gemini 実装と同じ考え方。idle の猶予と確認の間隔は実装と同じキー）
print_timeout="${GEMINI_REVIEW_PRINT_TIMEOUT:-45m}"
idle_grace="${GEMINI_IDLE_GRACE:-60}"; resume_grace="${GEMINI_IDLE_RESUME_GRACE:-300}"; noout_sec="${GEMINI_REVIEW_NOOUTPUT_SEC:-600}"; poll="${GEMINI_POLL_SEC:-5}"
[[ "$idle_grace" == <-> && "$resume_grace" == <-> && "$noout_sec" == <-> && "$poll" == <-> ]] \
  || lanes_die "GEMINI_IDLE_GRACE / GEMINI_IDLE_RESUME_GRACE / GEMINI_REVIEW_NOOUTPUT_SEC / GEMINI_POLL_SEC は整数秒"
(( poll >= 1 && noout_sec >= 1 )) || lanes_die "GEMINI_POLL_SEC と GEMINI_REVIEW_NOOUTPUT_SEC は 1 以上"
[[ "$print_timeout" =~ '^[0-9]+(ms|s|m|h)?$' ]] || lanes_die "GEMINI_REVIEW_PRINT_TIMEOUT の形が不正（例: 45m）"
round="$(rvd_round "$logdir" "$series" "$label" "$round")"
[[ "$round" == <-> && ${#round} -le 6 ]] || lanes_die "round が不正"
record="$(rvd_prev_record "$logdir" "$series" "$round")"
prev_head="$(rvd_record_get "$record" head)"
prev_v="$(rvd_record_get "$record" verdict)"
requested_mode="$mode"
policy=early; (( round >= 3 )) && policy=followups
# 再利用の条件（指示・起点・設定・検証の設定・必須検証の使い回し・レビュー役）。変わったら同じ HEAD でも省略しない（review-dedup.zsh の rvd_context）
review_context() { rvd_context "$LANES_DIR" "$prompt" "$review_base" "$requested_mode" "$policy" "$GEMINI_REVIEW_MODEL" "$GEMINI_REVIEW_EFFORT" "$wt" "$checks_key" gemini; }
context="$(review_context)"
tree="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
decided="$(rvd_decide_mode "$wt" "$prev_head" "$prev_v" "$context" "$(rvd_record_get "$record" context)" "$tree" "$(rvd_record_get "$record" tree)")"
# 前のレビューで再利用の記録を戻しきれなかった印があれば、どの系列でも前回の記録を使わない（毎回 full。--mode delta も full にする）。
# この起動の後始末で印を置いたとき（RVD_RECOVER_BLOCKED=1）も同じ（印をあとで消されても、この起動の判定は変えない）
if rvd_reuse_blocked "$logdir" || (( ${RVD_RECOVER_BLOCKED:-0} )); then
  decided=full
  print -u2 -- "注意: logs/.review-reuse-blocked がある（前のレビューで再利用の記録を戻しきれなかった）。前回の記録を使わず full でレビューする。logs/.*.review-state を確かめてから印を消す"
elif (( dry )) && rvd_inflight_present "$logdir"; then
  # dry-run は排他を取らず後始末もしない。途中で終わったレビューの印があるうちは、前回の記録を使う前提で見せない
  decided=full
  print -u2 -- "注意: 前のレビューが子の後の確認の前に終わった印がある（次の本番の起動が後始末する）。dry-run は前回の記録を使わない full として見せる"
fi
skip_same=0
case "$mode:$decided" in
  auto:delta|delta:delta) mode=delta; base="$prev_head" ;;
  *:same) mode=full; (( force )) || skip_same=1 ;;
  *) mode=full ;;   # 明示の delta も、前回の記録が使えなければ（初回・前回 NEEDS_FIX・条件変更・未保存変更）全体を見る
esac
unresolved_note=""
if [[ "$prev_v" == 'VERDICT: NEEDS_FIX' ]]; then
  # 未解決のある系列では明示 delta も全体へ戻す。
  mode=full; base="$review_base"; skip_same=0
  [[ -n "$(rvd_record_get "$record" report)" ]] || lanes_die "前回の未解決指摘本文が無い。復元してから再レビューする"
  unresolved_note="$(rvd_unresolved_note "$record" "$round")"
fi

if (( skip_same )); then
  if (( dry )); then
    print -- "[dry-run] series=$series round=$round prev_head=${prev_head:0:12} → 同じ head をもう一度レビューしない（前回 $prev_v を使う。回すなら --force）"
    exit 0
  fi
  for f in "$log" "$json" "$err" "$evidence" "$body_log"; do lanes_rotate_log "$f"; done
  [[ "$(rvd_snapshot "$wt")" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "省略判定中に内容・指示が変化した。再実行する"
  # 使い回した親の chk-run の記録の入力（未追跡の logs/input.json・依存・環境変数など。rvd_snapshot は未追跡の logs/ を見ない）も、
  # 前回の合格を返す直前に照合し直す（問い合わせの後に変わっていたら、古い合格を返さない）
  skip_checks_rc=0; rvd_checks_recheck "$LANES_DIR" "$wt" || skip_checks_rc=$?
  (( skip_checks_rc == 0 )) || lanes_die "省略判定中に、使い回した親の chk-run の記録の入力（確認コマンドが読むファイル・依存・環境変数など）が変わった（または照合し直せない）。前回の結果は返さない。chk-run.sh を通し直してから再実行する"
  {
    print -- "## Gemini レビュー証跡（$label）"
    print -- "- $prev_v"
    print -- "- 対象: $(lanes_git_summary "$wt")"
    print -- "- レビューエンジン: gemini"
    print -- "- モード: skip-same-head（前回 round と同じ head ${prev_head:0:12}。レビューしていない）/ round=$round"
    rvd_checks_evidence skip
    [[ -z "$same_engine_line" ]] || print -r -- "$same_engine_line"
    print -- "- 実行: $(lanes_now) / 約 0 分 / EXIT:0"
    print -- "- HEAD: ${prev_head:0:12} → ${prev_head:0:12} / 作業ツリー差分行 0"
  } > "$evidence"
  { cat "$evidence"; print -- "EXIT:0"; print -- "$prev_v"; } > "$log"
  cat "$evidence"
  lanes_mark_done 0 "$prev_v" "skip-same-head round=$round"
  exit 0
fi
if (( dry )); then
  # dry-run は lanes_mark_start を通らないので、書く前に logs/ と書き込み先を確かめ、台帳へ載せる（載せられなければ書かずに止める）
  final="$logdir/$label.dry-run.prompt.md"
  lanes_dry_run_target "$wt" "$logdir" "$label" "$final"
else
  for f in "$log" "$json" "$err" "$evidence" "$final" "$body_log"; do lanes_rotate_log "$f"; done
fi
# レーン専用の作業場所（TMPDIR / LANES_SCRATCH）。agy に書かせてよいのはここだけ（--add-dir）。マージ後 cleanup が消す
if (( dry )); then scratch="$(lanes_scratch_path "$wt" "$label")"; else lanes_scratch_prepare "$wt" "$label" gemini-review; scratch="$LANES_SCRATCH"; fi
scratch_rule="$(lanes_scratch_rule "$scratch")"

# agy の場所はここで絶対パスに確定する（lanes_resolve_bin。下の --help の点検と、子の作業場所で起動する cmd に同じ値を使う）
lanes_check_gemini_subscription
[[ "$GEMINI_BIN" == /* ]] || lanes_die "agy の場所を絶対パスで確かめられない: $GEMINI_BIN"
# --sandbox が無効になる環境では走らせない。対象は Mac の端末サンドボックス（run-gemini.sh と同じ確認）
[[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] || lanes_die "端末サンドボックスを強制できない環境 → 起動禁止"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny file-write*)' /usr/bin/true 2>/dev/null \
  || lanes_die "端末サンドボックスを有効にできない → 起動禁止"
gem_help="$(ANTIGRAVITY_HEADLESS=true "$GEMINI_BIN" --help < /dev/null 2>&1)" || lanes_die "agy --help の確認に失敗"
# オプション名は単語として照合する（*--mode* だと --model の行にも当たる。_common.sh の lanes_help_has_option。lanes-doctor.sh と同じ）
for option in --sandbox --settings --mode; do
  lanes_help_has_option "$gem_help" "$option" || lanes_die "agy が $option に未対応 → 起動禁止（読み取り専用を強制できない）"
done
# plan は --mode の行の中に単語としてあること（help の別の場所の語・--model の説明の語では通さない）
lanes_agy_help_mode_has_plan "$gem_help" || lanes_die "agy の --mode に plan が無い → 起動禁止（読み取り専用を強制できない）"
unset gem_help

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
# 登録済みの linked worktree に限る（.git が普通のファイルというだけでは通さない。_common.sh の lanes_require_linked_worktree。run-gemini.sh と同じ）。
# 管理領域（.git 本体・hooks・設定）が作業場所・scratch の外にあることも確かめる
lanes_require_linked_worktree "$wt"
gitdir="$LANES_WT_GITDIR"; gitcommon="$LANES_WT_GITCOMMON"
for gd in "$gitdir" "$gitcommon"; do
  [[ "${gd:A}/" != "${wt:A}/"* && "${gd:A}/" != "${scratch:A}/"* ]] || lanes_die "Git 管理領域が worktree / scratch の中にある → 起動禁止: $gd"
done
template="$LANES_DIR/templates/claude-review-$mode.md"
[[ -s "$template" ]] || lanes_die "テンプレが無い: $template"
focus="$LANES_DIR/templates/codex-review-focus.md"
[[ -s "$focus" ]] || lanes_die "テンプレが無い: $focus"
delta_note=""
[[ "$mode" == "delta" ]] && delta_note="$(rvd_delta_note "$wt" "$base" "$round")"

# テンプレ（役名を Gemini に読み替え。Codex レビューと同じ流用）+ 置き場所 + 閉じ込めの説明 + 案件固有の指示 + ランチャの追記
# （delta の説明・前回の未解決指摘・受け入れ済みの限界・必須検証のきまり）+ 出し方（Codex レビューと同じ codex-review-focus.md）を結合して残す
LANES_ACCEPTED_NOTE="$(rvd_accepted_note "$wt")" python3 -I - "$template" "$prompt" "$final" "$wt" "$branch" "$head" "$base" "$mode" "$(lanes_now)" \
    "$(rvd_checks_rule)" "$delta_note" "$unresolved_note" "$scratch" "$scratch_rule" "$focus" <<'PY'
import os, sys, pathlib
tpl, case, out, wt, branch, head, base, mode, date, checks_rule, delta_note, unresolved, scratch, scratch_rule, focus = sys.argv[1:16]
t = pathlib.Path(tpl).read_text(encoding="utf-8")
# 役名だけ Gemini に読み替える（Claude レビュー用のテンプレを流用）。実際のパス・枝名（{{WORKTREE}} など）を埋め込む前に、テンプレの文だけを
# 置き換える（後から全文を置き換えると、Claude を含むパス・枝名まで存在しない Gemini の名前に変わる）
t = t.replace("Claude", "Gemini")
for k, v in {"WORKTREE": wt, "BRANCH": branch, "HEAD": head, "BASE": base, "MODE": mode, "DATE": date, "SCRATCH": scratch}.items():
    t = t.replace("{{" + k + "}}", v)
jail = ("# このレビューの閉じ込め（ランチャが強制している）\n"
        "- 書き込みはできない（plan モード・端末サンドボックス・ファイルの書き込みの拒否）。ファイルの作成・編集・削除・移動・名前の変更を試さない。"
        "計画やメモのファイルも作らない（書き込み系のツールを 1 回でも呼ぶと、ランチャがこのレビューを不合格にする）。結果は最後の応答の本文にだけ書く。\n"
        "- MCP・URL の読み込みは使えない。git の通信（fetch・push）も止めてある。読むのはこの worktree のファイルと git の履歴だけ。")
c = pathlib.Path(case).read_text(encoding="utf-8")
extra = [p.rstrip() for p in (delta_note, unresolved, os.environ.get("LANES_ACCEPTED_NOTE", "")) if p.strip()]
rule = checks_rule.rstrip()
extra.append(rule if rule.startswith("#") else "# 必須検証の成功行\n- " + rule)
f = pathlib.Path(focus).read_text(encoding="utf-8").rstrip()
text = (t.rstrip() + "\n\n" + scratch_rule.rstrip() + "\n\n" + jail
        + "\n\n---\n\n# 案件固有の指示（司令塔が記入）\n\n" + c.rstrip()
        + "\n\n---\n\n" + "\n\n".join(extra) + "\n\n" + f
        + "\n\n最終行は次のいずれか1行だけ:\nVERDICT: CLEAN\nVERDICT: NEEDS_FIX\n")
# logs/ を symlink を辿らずに開き、その中で一時ファイルに書いてから名前を付け替える（既存の名前が symlink・ハードリンクでも先を書き換えない）
d, name = os.path.split(out)
dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
tmp = f".{name}.{os.getpid()}.{os.urandom(6).hex()}.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=dfd)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
except BaseException:
    try:
        os.unlink(tmp, dir_fd=dfd)
    except OSError:
        pass
    raise
PY

# 起動単位の設定（拒否の固定の一覧。_common.sh の lanes_gemini_review_settings。利用者の設定ファイルは変えない）
gem_settings="$(lanes_gemini_review_settings)" || lanes_die "Gemini レビューの設定を作れない"
# 環境変数の effort が設定ファイルと違う値で勝っていたら知らせる（渡す値は変えない）
lanes_effort_override_note GEMINI_REVIEW_EFFORT
cmd=("$GEMINI_BIN")   # 点検（--help）したのと同じ絶対パス
if [[ -n "$GEMINI_REVIEW_MODEL" ]]; then cmd+=(--model "$GEMINI_REVIEW_MODEL"); fi
if [[ -n "$GEMINI_REVIEW_EFFORT" ]]; then cmd+=(--effort "$GEMINI_REVIEW_EFFORT"); fi
cmd+=(--mode plan --sandbox --settings "$gem_settings"
     --output-format stream-json --print-timeout "$print_timeout" --add-dir "$scratch")
if (( dry )); then
  print -- "[dry-run] series=$series round=$round mode=$mode base=$base prev_head=${prev_head:0:12}（判定 $decided）/ 必須検証の使い回し: $RVD_CHECKS_REUSE"
  print -- "[dry-run] scratch: $scratch"
  print -- "[dry-run] （子だけ cd ${(q)wt}）ANTIGRAVITY_HEADLESS=true TMPDIR=${(q)scratch}/ LANES_SCRATCH=${(q)scratch} GIT_DIR=${(q)gitdir} GIT_WORK_TREE=${(q)wt} GIT_CONFIG_GLOBAL=${(q)scratch}/gitconfig GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat GIT_ALLOW_PROTOCOL=lanes-no-transport lanes_start_child_in ${(q)wt} ${(q)LANES_PYTHON3} -I gemini-stream-tee.py ${(q)logdir} ${(q)json:t} -- ${(q)cmd[@]} -p \"\$(<${(q)final})\" < /dev/null >（親専用の写し）2> ${(q)err}"
  print -- "[dry-run] 見張り: idle（root agent idle）の後 子が無く json が ${idle_grace} 秒動かなければ異常終了（EXIT:3）/ 出力 ${noout_sec} 秒なしで EXIT:8 / --print-timeout $print_timeout / 確認間隔 ${poll} 秒"
  [[ -z "$same_engine_line" ]] || print -r -- "[dry-run] ${same_engine_line#- }"
  print -- "[dry-run] 結合済みプロンプト: $final"
  exit 0
fi

# サンドボックス内の git 用の最小 gitconfig（秘密は入れない）。レビューは commit しないので名前とメールは取れるときだけ書く
gname="$(git -C "$wt" config user.name || true)"; gmail="$(git -C "$wt" config user.email || true)"
lanes_fresh_file "$scratch/gitconfig"
{
  if [[ -n "$gname" && -n "$gmail" ]]; then print -- "[user]"; print -- "\tname = $gname"; print -- "\temail = $gmail"; fi
  print -- "[core]"; print -- "\tpager = cat"; print -- "[safe]"; print -- "\tdirectory = *"
} > "$scratch/gitconfig"

# 親は対象の worktree へ移らない（親が回す python3・git が、レビュー対象の中の同名のモジュールや設定に引きずられないように）。
# 子（agy）の作業場所だけを worktree にする（gemini-agy.zsh の run_agy_once が lanes_start_child_in で起動する）。
# 以後の git は必ず -C "$wt" で呼ぶ（/ では git のリポジトリにならないので、付け忘れても別のリポジトリを読まずに失敗する）
cd /
snapshot_before="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
[[ "$snapshot_before" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "起動準備中に内容・指示が変化した。再実行する"
guard_before="$(rvd_git_guard "$wt")" || lanes_die "レビュー前の git 管理フォルダの確認に失敗"
# git の制御ファイル（worktree の .git・gitdir の commondir / gitdir / config・共通の config・hooks）の前後比較（Codex レビューと同じ）。
# 子の後は git を 1 回も呼ぶ前に指紋だけで比べる（偽の gitdir・core.fsmonitor などを、ランチャがサンドボックスの外で動かさない）
git_fp_before="$(lanes_git_ctl_fingerprint "$wt" "$gitdir" "$gitcommon")" || lanes_die "起動前の git 制御ファイルの確認に失敗"
# 再利用の記録（logs/ にある全部の系列の .review-state）を覚える（子の後で比べて戻す。Codex・Claude レビューと同じ）
states_before="$(rvd_states_snapshot "$logdir")" || lanes_die "レビュー前の再利用の記録の確認に失敗"
# 「使い回し禁止」の印は、置き場所（logs/ の中と外）ごとに有無を覚える（子の後で比べる。片方だけの削除・新設も見つける）。
# 外の印のパスは logs/ の実パスから決まるので、子が logs/ を差し替える前のここで求めておく
block_files=("${(@f)$(rvd_block_files "$logdir")}")
(( ${#block_files} == 2 )) || lanes_die "「使い回し禁止」の印の置き場所を決められない"
blocked_before="$(rvd_block_state "${block_files[1]}" "${block_files[2]}")"
# 子の実行中に logs/ そのものを差し替えられたら（lanes_logdir_check が記録を書かずに EXIT:5 で止める）、止める前に logs/ の外へ
# 「使い回し禁止」の印を置く（差し替えた先に偽の再利用の記録を置かれても、次のレビューが前回の結果を使わない）
lanes_logdir_tamper_hook() {
  rvd_place_outer_marker "${block_files[2]}" \
    || ( print -u2 -- "→ 「使い回し禁止」の印（${block_files[2]}）を置けない。次のレビューは --mode full --force で回す" ) || true
}
# 書き込みの試み・改ざんを見つけたら、ほかの何より先に呼ぶ（証跡の書き込みや標準出力への表示で set -e が発動しても、前回の CLEAN を残さない）。
# この系列の前回の CLEAN を失効させる。失効させられなければ「使い回し禁止」の印を置く。2 回目以降は何もしない（review-dedup.zsh の
# rvd_invalidate_on_violation。どちらもできなければ「確認中」の印を残す＝次のレビューが後始末する）
invalidate_on_violation() { rvd_invalidate_on_violation "$logdir" "$series" "$1" "$label" || true; }
# 子の起動前に「確認中」の印（覚えた再利用の記録と「使い回し禁止」の印の有無）を logs/ の外へ置く。消すのは最後（rvd_inflight_finish）:
# 子の後の確認に加えて、今回の判定の保存（rc 0 のとき）か、前回の CLEAN の失効（違反のとき）が済んでから。途中で終わったら、
# 次のレビューが印を見つけて後始末する（review-dedup.zsh の rvd_inflight_recover）
print -r -- "$states_before" | rvd_inflight_begin "$logdir" "$series" "$label" "$LANES_LOGDIR_ID" "$blocked_before" \
  || lanes_die "途中で終わったときの後始末の印（$(rvd_inflight_file "$logdir")）を置けない → 起動しない。${XDG_STATE_HOME:-~/.local/state}/lanewright/ の権限を確かめる"
started="$(lanes_now)"; t0=$(date +%s)

# レビューの子から push（と fetch）をできなくする（読み取り専用の役。git の通信は要らない）
lanes_block_git_transport
# agy は監督役（lanes_start_child_in。作業場所は worktree）の下で、受け取り役（gemini-stream-tee.py）を挟んで起動する。
# 見張りは Gemini 実装と同じ（gemini-agy.zsh の run_agy_once）。
# 見張りの行は子の起動前に開いた番号（fd）で logs/<label>.log へ書く（子が logs/ を差し替えても外へは書かない）
GEM_TAG="[run-gemini-review]"
source "$LANES_DIR/gemini-agy.zsh"
run_agy_once "$json" "$err"
LANES_CHILD=""   # 以後の trap で（pid 再利用した）別プロセスを kill しない
agy_rc=$GEM_RC   # agy（受け取り役）の終了コード。書き込みの試み・改ざんで EXIT:4 にしたときも、証跡にはこの値を別に残す
rc=$GEM_RC
stop_line="なし"
if (( GEM_NOOUT )); then rc=8; stop_line="出力 ${noout_sec} 秒なしで停止"
elif (( GEM_IDLE_KILLED )); then rc=3; stop_line="idle（裏の作業待ち）で強制停止。正常完了ではない"
fi
# 再利用の記録が子の実行中に変わっていたら、まず元の中身に戻す（以後どこで終わっても偽の記録を残さない）
state_tampered=0
states_rc=0; print -r -- "$states_before" | rvd_states_restore "$logdir" || states_rc=$?
# 印が子の実行中に変わっていたら（どちらかの置き場所の削除・新設）、改ざんとして扱う。印は両方に置いて使い回し禁止のままにする
blocked_after="$(rvd_block_state "${block_files[1]}" "${block_files[2]}")"
marker_tampered=0
[[ "$blocked_after" == "$blocked_before" ]] || marker_tampered=1
if (( marker_tampered )) && (( states_rc == 0 )); then states_rc=1; fi
if (( states_rc != 0 )); then
  state_tampered=1
  # 違反を見つけたら、表示より先にこの系列の前回の CLEAN の失効と、「使い回し禁止」の印（戻しきれない・印が変わった）を済ませる
  # （以後どこで終わっても古い合格を残さない）
  invalidate_on_violation 4
  if (( states_rc == 2 || marker_tampered )) && ! rvd_mark_blocked "$logdir" 2>/dev/null; then
    # 戻しきれない別の系列の記録・消された印を守る物が無いので、「確認中」の印を残す（次のレビューが記録を戻し直し、印を置き直す）
    RVD_VIOLATION_SETTLED=0
    ( print -u2 -- "→ 「使い回し禁止」の印を置けない。「確認中」の印を残す（次のレビューが後始末する）。logs/ と ${XDG_STATE_HOME:-~/.local/state}/lanewright/ の権限を確かめる。次のレビューは --mode full --force で回す" ) || true
  fi
  (( ! marker_tampered )) || print -u2 -- "→ Gemini レビューの実行中に「使い回し禁止」の印が変わった（前: $blocked_before / 後: $blocked_after。inner=logs/ の中、outer=外）。両方に置いて（使い回し禁止のまま）不合格（NEEDS_FIX）にする"
  if (( states_rc == 1 )); then
    print -u2 -- "→ Gemini レビューの実行中に再利用の記録（logs/.*.review-state）が増えた・変わった。子の前の状態に戻して不合格（NEEDS_FIX）にする"
  else
    print -u2 -- "→ Gemini レビューの実行中の再利用の記録（logs/.*.review-state）を確かめられない・戻せない。不合格（NEEDS_FIX）にする。中身を手で確かめる"
  fi
fi
# git を 1 回も呼ぶ前に、制御ファイルが変わっていないかを見る（Codex レビュー・run-gemini.sh と同じやり方）
git_fp_after="$(lanes_git_ctl_fingerprint "$wt" "$gitdir" "$gitcommon" 2>/dev/null)" || git_fp_after=ERROR
if [[ "$git_fp_after" != "$git_fp_before" ]]; then
  # 最初にこの系列の前回の CLEAN を失効させる（次の通常の起動で古い合格を返さない。ログへの書き込みで止まっても残さない）
  invalidate_on_violation 4
  { print -- "[run-gemini-review] $(lanes_now) git の制御ファイル（.git・commondir・gitdir・config・config.worktree・hooks）が変わった → git を実行せず停止"
    print -- "EXIT:4"; } >> "$log" 2>/dev/null || true
  ( print -u2 -- "→ Gemini レビューの実行中に git の制御ファイルが変わった。git を実行せず停止（EXIT:4）。$wt/.git と $gitdir・$gitcommon の中身を手で確かめてから直す" ) || true
  # 失効（か「使い回し禁止」の印）が済んでから「確認中」の印を消す（どちらもできなければ残す）
  rvd_inflight_finish "$logdir"
  lanes_mark_done 4 "VERDICT: NEEDS_FIX" "git の制御ファイルの変更を検出（git 未実行）"
  exit 4
fi
elapsed=$(( ($(date +%s) - t0) / 60 ))

# stream-json を厳密に読み、最後の result（status=SUCCESS の response）だけを本文にする（logs/<label>.last.md と logs/<label>.log）。
# 読むのは親専用の写し（受け取り役がパイプで直接受け取ったもの。番号 3 で渡す）。子が書ける logs/<label>.json は読まない。
# 同時に、書き込み系のツール呼び出し（run-gemini.sh の監査と同じ判定: ツール名に write / replace / edit / delete / move / rename /
# create / append / copy / patch を含む tool の step_update）を数える。読み取り専用のレビューでは 1 件でも不合格。
# 開始から記録できたことも確かめる: 1 行目が init のイベントでない（先頭の欠落・result だけ残った）・init が 2 回ある記録は不備。
# 写しはバイト列のまま 1 行ずつ反復して読み、行ごとに UTF-8 として解釈する（全体を一度に読み込んで複製しない。長い実行でコマンドの出力が
# 膨らんでも、メモリは 1 行分と最後の応答の本文だけ。末尾の文字切れなどの不正行は監査の不備として数え、その前後の正常な行の
# 書き込みの試みは失わない）。
# 承認・質問ツール（ask_*）と書き込みの試みは、同じ呼び出しの経過の記録（何度も届く step_update）を 1 件に数える。
# 2 段に分ける（同じ写しを 2 回読む。子と孫は回収済みで、写しの名前は子の起動前に消してあるので、2 回とも同じ中身）:
#   audit   … 数えるだけ（ファイルは書かない）。出力（標準出力）: status= / writes= / write_tools= / asks= / turns= / invalid= / invalid_kinds=。
#             終了コード: 0 = 本文あり / 4 = JSON の欠損・不正・init の欠落・result の重複・終端でない / 5 = status が SUCCESS でない
#   publish … 本文（last.md）と表示用のログ（log）を書く。0 = 書けた / 1 = 書けない
# ランチャは audit の件数で違反を確定し、前回の CLEAN を失効させてから publish する（公開用のファイルの書き込みに失敗しても、
# 書き込みの試みの件数を失わない・失効より後回しにしない）
gem_audit_py="$(cat <<'PY'
import json, os, sys
mode, body_out, log_out = sys.argv[1:4]
WRITE_HINT = ("write", "replace", "edit", "delete", "move", "rename", "create", "append", "copy", "patch")
status, body, error, turns = "NONE", "", "", 0
writes, write_tools, asks, invalid = set(), set(), set(), []
results, last_event, events, inits, first_init, nlines = 0, None, 0, 0, False, 0
def call_key(su, name):
    # 同じ呼び出しの経過の記録は 1 件に数える。手がかり（呼び出しの番号・識別子）が無ければ中身で区別する
    key = next((str(su[k]) for k in ("step_index", "step_id", "id", "tool_call_id") if k in su), None)
    return key if key is not None else name + "\0" + json.dumps(su.get("tool_info"), sort_keys=True, ensure_ascii=False)
def one_line(index, raw_line):
    global status, body, error, turns, results, last_event, events, inits, first_init
    try:
        line = raw_line.decode("utf-8")
    except UnicodeError:
        invalid.append("文字コードの不正行（末尾の文字切れなど）"); return
    try:
        d = json.loads(line)
    except (ValueError, TypeError):
        invalid.append("JSON の不正行"); return
    if not isinstance(d, dict) or not isinstance(d.get("event"), str):
        invalid.append("イベントの形式が不正"); return
    events += 1
    last_event = d["event"]
    if d["event"] == "init":
        inits += 1
        first_init = first_init or index == 0
        return
    if d["event"] == "result":
        r = d.get("result")
        if not isinstance(r, dict) or r.get("status") not in ("SUCCESS", "ERROR"):
            invalid.append("結果の形式が不正"); return
        if any(not isinstance(r.get(k, ""), str) for k in ("response", "error")):
            invalid.append("結果本文の形式が不正"); return
        if type(r.get("num_turns", 0)) is not int or r.get("num_turns", 0) < 0 or not isinstance(r.get("usage", {}), dict):
            invalid.append("結果集計の形式が不正"); return
        results += 1
        status = r["status"]; body = r.get("response", "") or ""; error = r.get("error", "") or ""; turns = r.get("num_turns", 0)
        return
    if d["event"] != "step_update":
        return
    su = d.get("step_update")
    if not isinstance(su, dict) or not isinstance(su.get("step_type"), str):
        invalid.append("作業記録の形式が不正"); return
    name = su.get("tool_name") or ""
    if not isinstance(name, str) or (su["step_type"] == "tool" and not name.strip()):
        invalid.append("ツール名の形式が不正"); return
    if name.startswith("ask_"):
        asks.add(call_key(su, name))
    if su["step_type"] == "tool" and any(h in name.lower() for h in WRITE_HINT):
        writes.add(call_key(su, name))
        write_tools.add(name)
try:
    os.lseek(3, 0, os.SEEK_SET)
    with os.fdopen(3, "rb", closefd=False) as f:
        # 1 行ずつ反復する（全体を読み込まない）。改行で区切った各行の最後の改行だけを外す（最後の改行の後ろの空は行に数えない）
        for raw_line in f:
            one_line(nlines, raw_line[:-1] if raw_line.endswith(b"\n") else raw_line)
            nlines += 1
except OSError:
    invalid.append("ログを読み取れない")
if not nlines and "ログを読み取れない" not in invalid:
    invalid.append("ログが空")
if results > 1 or (results == 1 and last_event != "result"):
    invalid.append("結果が重複、または終端ではない")
if results == 0 and nlines:
    invalid.append("終了結果が欠損")
if nlines and not first_init:
    invalid.append("開始の記録（先頭の init）が無い")
if inits > 1:
    invalid.append("開始の記録（init）が重複")
ok = not invalid and status == "SUCCESS" and bool(body.strip())
if mode == "audit":
    print(f"status={status}")
    print(f"writes={len(writes)}")
    print("write_tools=" + ",".join(sorted(write_tools))[:200])
    print(f"asks={len(asks)}")
    print(f"turns={turns}")
    print(f"invalid={len(invalid)}")
    print("invalid_kinds=" + "・".join(dict.fromkeys(invalid))[:200])
    sys.exit(0 if ok else (5 if not invalid and results == 1 else 4))
def new_file(path):
    # 既存の物（symlink・ハードリンク）は辿らず、必ず新しい普通のファイルとして作る（子の回収後に呼ぶ）
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666), "w", encoding="utf-8")
try:
    # 見張りの行（run_agy_once が子の実行中に書いたもの）は残して、本文の前に置く
    try:
        with open(log_out, encoding="utf-8", errors="replace") as f:
            watch = f.read().rstrip()
    except OSError:
        watch = ""
    one = " ".join(str(error).split())[:300]
    meta = (f"[meta] status={status} turns={turns} events={events} inits={inits} writes={len(writes)} asks={len(asks)} audit_errors={len(invalid)}"
            + (f" error={one}" if one else "") + "\n")
    with new_file(body_out) as f:
        f.write(body if ok else "")
    with new_file(log_out) as f:
        f.write(meta + (watch + "\n" if watch else "")
                + ("" if ok else "[meta] 正常な result（status=SUCCESS の本文）が無い・JSON が不正なので VERDICT は採用しない\n")
                + "\n" + (body if ok else ""))
except OSError:
    sys.exit(1)
PY
)"
conv_rc=0
audit_out="$(gem_stream_read "$GEM_STREAM_FD" python3 -I -c "$gem_audit_py" audit "$body_log" "$log")" || conv_rc=$?
audit_get() { local line; for line in "${(@f)audit_out}"; do [[ "$line" == "$1="* ]] && { print -r -- "${line#*=}"; return 0; }; done; print -r -- ""; }
gstatus="$(audit_get status)"; [[ -n "$gstatus" ]] || gstatus=NONE
writes_n="$(audit_get writes)"; [[ "$writes_n" == <-> ]] || writes_n=0
write_tools="$(audit_get write_tools)"; asks_n="$(audit_get asks)"; [[ "$asks_n" == <-> ]] || asks_n=0
invalid_n="$(audit_get invalid)"; [[ "$invalid_n" == <-> ]] || invalid_n=0; invalid_kinds="$(audit_get invalid_kinds)"
# 監査そのものが動かなかった（python の失敗など）ときも、成功扱いにしない。書き込みの試みがあったかどうか分からないので、
# この系列の前回の CLEAN も再利用しない（失効させる。終了コードは EXIT:4 にはしない＝改ざんの証拠ではない）
if [[ "$(audit_get writes)" != <-> ]]; then
  conv_rc=4; invalid_n=$(( invalid_n + 1 )); invalid_kinds="${invalid_kinds:+$invalid_kinds・}監査を実行できない"
  invalidate_on_violation 3
fi
# 書き込みの試み・公開ログの改ざんは、公開用のファイル（last.md・log）を書く前に確定し、この系列の前回の CLEAN を失効させる
(( writes_n == 0 && ! GEM_PUBLIC_TAMPERED )) || invalidate_on_violation 4
# 本文と表示用のログを書く（失敗しても、上で数えた書き込みの試みと失効はそのまま。判定は VERDICT: NONE）
publish_rc=0; gem_stream_read "$GEM_STREAM_FD" python3 -I -c "$gem_audit_py" publish "$body_log" "$log" || publish_rc=$?
if (( publish_rc != 0 )); then
  conv_rc=4; invalid_n=$(( invalid_n + 1 )); invalid_kinds="${invalid_kinds:+$invalid_kinds・}本文・ログ（$body_log:t・$log:t）を書けない"
fi
# 必須検証の仕組みの有無をランチャ側で見て判定へ渡す（仕組みがあるのに「該当なし（未導入）」・NA と書いた項目は未実施と同じ扱い）
checks_present="$(lanes_checks_present "$wt")" || checks_present=""
export LANES_CHECKS_PRESENT="$checks_present"
# 判定・指摘数・必須検証・解消宣言は、最後の応答の本文（last.md）だけを読む（見張りの行や JSON の途中を拾わない）
if (( conv_rc != 0 )); then
  verdict="VERDICT: NONE"
else
  verdict="$(lanes_extract_verdict "$body_log")"
fi
[[ "$verdict" == "VERDICT: PASS" ]] && verdict="VERDICT: CLEAN"
(( rc == 0 )) || verdict="VERDICT: NONE"   # agy が非 0 で終わった・見張りで止めた本文の VERDICT は採用しない
head_after="$(git -C "$wt" rev-parse --short=12 HEAD)"
# P0/P1 と明示 CLEAN の矛盾は必ず不合格
typeset -A sev; for k in P0 P1 P2 P3; do sev[$k]=$(lanes_count_findings "$body_log" $k); done
sevsum="P0:${sev[P0]} P1:${sev[P1]} P2:${sev[P2]} P3:${sev[P3]}"
[[ "$verdict" == 'VERDICT: NONE' ]] || (( rc != 0 || sev[P0] + sev[P1] == 0 )) || verdict="VERDICT: NEEDS_FIX"
gate="$(rvd_gate "$round" "$verdict" "${sev[P0]}" "${sev[P1]}")"
raw_verdict="$verdict"; followups=""
# round 3 以降の P2/P3 は、元から CLEAN（P3 だけ）でも残件を必ず後回し票に保存する（run-claude-review.sh と同じ）
if (( round >= 3 && sev[P2] + sev[P3] > 0 )) && [[ "$verdict" != 'VERDICT: NONE' ]]; then
  followups="$logdir/$series.followups.md"
  if ! rvd_write_followups "$body_log" "$followups" "$round" "$head_after" "$label"; then
    rc=3; verdict="VERDICT: NONE"; gate=FIX
  fi
fi
# 指摘があっても、必須検証の成功（または親の記録の使い回し）が確かめられなければ昇格させない
checks="$(lanes_parse_review "$body_log" checks)"
if [[ "$gate" == MERGE_WITH_FOLLOWUP && "$checks" == COMPLETE ]] && (( rc == 0 && sev[P2] + sev[P3] > 0 )); then
  verdict="VERDICT: CLEAN"
elif [[ "$gate" == MERGE_WITH_FOLLOWUP ]]; then
  gate=FIX
fi
# P3 が明示 CLEAN と併記されても、同じ成功確認を迂回させない
if (( round >= 3 && sev[P2] + sev[P3] > 0 )) && [[ "$verdict" == 'VERDICT: CLEAN' && "$checks" != COMPLETE ]]; then
  verdict="VERDICT: NEEDS_FIX"; gate=FIX
fi
# 解消宣言は判定と同じ解析器で読む。コード例・引用・表の中の書式例では未解決指摘を解除しない
resolved="$(lanes_parse_review "$body_log" resolved)" || resolved=NO
pending_note="$unresolved_note"; blocking_previous=0
[[ "$resolved" != YES ]] || pending_note=""
if [[ -n "$unresolved_note" && "$resolved" != YES ]]; then
  # 前回の軽微な指摘も保存対象。今回の本文から省かれていても取りこぼさない
  defer_previous=0
  if (( round >= 3 && rc == 0 && sev[P0] + sev[P1] == 0 )) && [[ ( "$verdict" == 'VERDICT: CLEAN' || "$verdict" == 'VERDICT: NEEDS_FIX' ) && "$checks" == COMPLETE ]]; then
    defer_previous=1
  fi
  previous_rc=0
  rvd_previous_followups "$record" "$logdir/$series.followups.md" "$round" "$head_after" "$label" "$defer_previous" || previous_rc=$?
  if (( previous_rc == 0 && defer_previous )); then
    pending_note=""; verdict="VERDICT: CLEAN"; gate=MERGE_WITH_FOLLOWUP
    followups="$logdir/$series.followups.md"
  elif (( previous_rc == 2 )); then
    rc=3; verdict="VERDICT: NONE"; gate=FIX
  else
    (( previous_rc != 1 )) || blocking_previous=1
    [[ "$verdict" == 'VERDICT: NONE' ]] || verdict="VERDICT: NEEDS_FIX"
    [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  fi
fi
# 状態表示が同じでも、既に変更済みのファイルの上書きや commit を検出する。書き込み系のツールを呼んだ（試みた）ことも同じく不合格
snapshot_after="$(rvd_snapshot "$wt")" || snapshot_after=ERROR
conditions_after="$(review_context)" || conditions_after=ERROR
guard_after="$(rvd_git_guard "$wt")" || guard_after=ERROR
# 親の chk-run の記録を使い回したときは、確認コマンドの入力（未追跡の logs/input.json・依存・環境変数など）がレビュー中に変わって
# いないかを、問い合わせたときと同じ環境で照合し直す（rvd_snapshot は未追跡の logs/ を見ないので、ここで見る）。
# 作業ツリーの中身が変わっていたら（それだけで下の違反になる）、照合し直さない（子が置いた物の近くで、照合のための道具を親が動かさない）
checks_after_rc=0
if [[ "$snapshot_after" != ERROR && "$snapshot_before" == "$snapshot_after" ]]; then
  rvd_checks_recheck "$LANES_DIR" "$wt" || checks_after_rc=$?
fi
dirty=0
if [[ "$snapshot_after" == ERROR || "$snapshot_before" != "$snapshot_after" || "$conditions_after" != "$context" \
    || "$guard_after" == ERROR || "$guard_before" != "$guard_after" ]] || (( state_tampered || writes_n > 0 || GEM_PUBLIC_TAMPERED || checks_after_rc != 0 )); then
  # 違反を見つけたら、証跡や表示より先にこの系列の前回の CLEAN を失効させる
  invalidate_on_violation 4
  dirty=1; verdict="VERDICT: NEEDS_FIX"
  [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  # 書き込みの試み・改ざんは、agy 自身の失敗（非 0 の終了・見張りの停止）より優先して EXIT:4 にする（呼び出し元が CLI の障害と
  # 監査の違反を区別できるように）。agy の終了コードは証跡の「読み取り専用の確認」の行に別に残す
  rc=4
  (( writes_n == 0 )) || print -u2 -- "→ Gemini レビューが書き込み系のツールを ${writes_n} 件呼んだ（${write_tools:-名前不明}）。読み取り専用のレビューとして不合格（NEEDS_FIX）にする"
  (( ! GEM_PUBLIC_TAMPERED )) || print -u2 -- "→ Gemini レビューの実行中に logs/$json:t（公開用の stream-json）が消された・書き換えられた。判定は受け取った中身で行い、改ざんとして不合格（NEEDS_FIX）にする"
  (( checks_after_rc != 1 )) || print -u2 -- "→ Gemini レビューの実行中に、使い回した親の chk-run の記録の入力（確認コマンドが読むファイル・依存・環境変数など）が変わった。不合格（NEEDS_FIX）にする"
  (( checks_after_rc != 2 )) || print -u2 -- "→ 使い回した親の chk-run の記録の入力を、レビューの後に照合し直せない（chk-run.sh --query-input の失敗）。不合格（NEEDS_FIX）にする"
fi
(( rc != 0 )) || [[ "$verdict" == 'VERDICT: CLEAN' || "$verdict" == 'VERDICT: NEEDS_FIX' ]] || rc=3
# 周回の上限を超えて CLEAN にならなければ ESCALATE（人に返す）。続けるなら人が直して LANES_REVIEW_MAX_ROUNDS を上げる
gate="$(rvd_escalate "$round" "$verdict" "$gate")"
publish_note=""
if (( GEM_PUBLIC_TAMPERED )); then publish_note+=" / 公開用の json（$json:t）が実行中に消された・書き換えられた（改ざん。不合格）"; fi
if (( GEM_PUBLISH_FAILED )); then publish_note+=" / 公開用の json（$json:t）を受け取った中身で置き換えられず消した"; fi
if (( checks_after_rc == 1 )); then publish_note+=" / 使い回した親の chk-run の記録の入力がレビュー中に変わった（不合格）"
elif (( checks_after_rc == 2 )); then publish_note+=" / 使い回した親の chk-run の記録の入力を照合し直せない（不合格）"; fi

{
  print -- "## Gemini レビュー証跡（$label）"
  print -- "- $verdict"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- レビューエンジン: gemini"
  print -- "- モード: $mode / base=$base / round=$round"
  lanes_model_effort_evidence gemini-review
  print -- "- 指摘: $sevsum / GATE: $gate"
  [[ "$gate" != ESCALATE ]] || print -- "- 周回の上限（LANES_REVIEW_MAX_ROUNDS=${LANES_REVIEW_MAX_ROUNDS:-5}）を超えた → ここで止めて人に判断を返す（続ける＝直して上限を上げる / 締める＝残りを .lanes/accepted-limitations.md か後回し票へ）"
  print -- "- 必須検証の成功確認: $checks（仕組みがあると見た項目: ${checks_present:-なし}。その項目の「該当なし（未導入）」・NA は受け付けない）"
  rvd_checks_evidence
  [[ -n "$followups" ]] && print -- "- 元の判定: $raw_verdict / P2/P3 の保存先: $followups"
  print -- "- 読み取り専用の確認: 書き込みの試み ${writes_n} 件${write_tools:+（$write_tools）}（1 件でもあれば不合格）/ 承認・質問ツール ${asks_n} 回 / agy: $gstatus・終了コード $agy_rc / JSON の不備 ${invalid_n} 件${invalid_kinds:+（$invalid_kinds）} / 見張り: $stop_line$publish_note"
  [[ -z "$same_engine_line" ]] || print -r -- "$same_engine_line"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分 / EXIT:$rc"
  print -- "- HEAD: $head → $head_after / 内容・履歴・条件の変更検出 $dirty（0=なし、1=あり）"
  print -- "- ログ: $log（本文）/ $body_log（最後の応答）/ $json（生）/ $final（渡した全文）"
  print -- "- 作業場所（scratch）: $scratch（${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"
} > "$evidence"

{ print -- ""; print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; print -- "$verdict"; } >> "$log"
cat "$evidence"
final_rc=$rc
# 次回へ引き継ぐ本文（未解決指摘の解析・次の指示書）は、親が受信した最後の応答の本文（last.md）だけにする。
# logs/<label>.log は表示用（見張りの行・証跡を含み、子の実行中に公開ログから読み戻した行もある）なので正本にしない
(( rc == 0 )) && rvd_save_state "$logdir" "$series" "$round" "$(git -C "$wt" rev-parse HEAD)" "$verdict" "$gate" "$label" "$context" "$snapshot_after" "$review_base" "$body_log" "$pending_note" "$blocking_previous"
(( rc == 0 )) && [[ "$verdict" != "VERDICT: CLEAN" && "$verdict" != "VERDICT: NEEDS_FIX" ]] && final_rc=3   # 完走したのに VERDICT が無い
# 書き込みの試み・改ざん（EXIT:4）の失効は、見つけた直後（invalidate_on_violation）に済ませてある。
# 「確認中」の印は、今回の判定の保存（rc 0）か前回の CLEAN の失効（違反）が済んだここで消す（保存の前に消すと、証跡の書き込みなどで
# 止まったとき系列に前回の CLEAN だけが残り、次回が後始末も確認もせずにその合格を返す）
rvd_inflight_finish "$logdir"
exec {GEM_STREAM_FD}<&- 2>/dev/null || true
lanes_mark_done "$final_rc" "$verdict" "gemini rc=$rc agy_rc=$agy_rc gate=$gate $sevsum"
exit $final_rc
