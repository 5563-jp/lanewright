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
# 再利用の記録（logs/.<系列>.review-state）の扱い（このランチャだけの単純な方式）:
#   子（agy）を起動する直前に、その系列の記録を「確認中」（IN_PROGRESS）に書き換える（rvd_mark_in_progress。前回の未解決指摘の
#   本文を読み切ってから書き換える）。確定するのは agy が 0 で終わり、VERDICT が CLEAN か NEEDS_FIX で、読み取り専用の監査を通り、
#   公開ログ（<label>.last.md と <label>.log）が書けたときだけ。確定の順番は、書く先（.done・証跡・ログ・後回し票・記録）の確認 →
#   ログの末尾 → 再利用の記録（rvd_save_state）→ 証跡（<label>.evidence.md）→ 後回し票（該当時）→ 終了記録（.done を読み戻して確かめる）。
#   合格の証跡と標準出力の表示は全部が書けてから出す。途中で失敗したら確定した分（再利用の記録・後回し票）を戻し、証跡・ログの末尾を
#   失敗（VERDICT: NONE・EXIT:3）で書き直す（合格の表示を残さない）。後回し票は確定まで scratch の写しに足すだけ（失格の回は公開しない）。
#   agy の失敗・見張りの停止・中断・強制終了・書き込みの試みや作業ツリーの変更（EXIT:4）・記録の書き込みの失敗では確定しない
#   （IN_PROGRESS のまま残る）。次の起動は前回の記録を使わない（古い CLEAN で省略・delta にしない。rvd_prev_record）。
#   前回が NEEDS_FIX だったときの未解決指摘だけは、IN_PROGRESS の記録に持ち越して次の起動へ引き継ぐ（rvd_carried_record）。
#   終了記録（.done）の書き先がフォルダなどで書けないと分かっていれば、記録に触る前に止める（EXIT:2）。
# 親（このランチャ）は起動の最初に / へ移る（子の agy だけを worktree で起動する）。親の python は作業場所のモジュールを読まない。
# dry-run も logs/ とプロンプトの書き先を確かめ、symlink を辿らずに書く。
# 同じ道具でレビューしない: この worktree の logs/ に Gemini 実装（run-gemini.sh）の記録が 1 本でもあれば起動しない（exit 2）。
#   Codex か Claude のレビュー（run-review.sh --engine codex|claude）を使う。どうしても回すときだけ --allow-same-engine（証跡に残る）
# 読み取り専用の強制:
#   agy は --mode plan（書き込む前に計画を出して止まるモード）＋ --sandbox（端末サンドボックス）＋ --settings（起動単位の設定）で起動する。
#   設定の拒否は _common.sh の lanes_gemini_review_settings（MCP・ファイルの書き込み・URL・commit や push などのコマンド。外から緩められない）。
#   --dangerously-skip-permissions・accept-edits・auto は使わない。ANTIGRAVITY_HEADLESS=true・stdin は /dev/null・--add-dir は scratch だけ。
#   Mac の端末サンドボックス（sandbox-exec）を有効にできない・agy --help に --sandbox / --settings / --mode（plan）が無いなら起動しない。
#   専用の linked worktree だけで起動する（_common.sh の lanes_require_linked_worktree。本体 checkout では起動しない）。
#   子の環境: TMPDIR / LANES_SCRATCH = scratch、GIT_OPTIONAL_LOCKS=0、GIT_PAGER=cat、GIT_CONFIG_GLOBAL = scratch の最小 gitconfig、git の通信は止める。
#   子の前後で作業ツリー（rvd_snapshot）・指示と条件（review_context）・git の管理フォルダ（rvd_git_guard。設定・hooks・タグ・stash）・
#   git の制御ファイル（lanes_git_ctl_fingerprint。git を呼ぶ前に比べる）を比べ、変わっていたら NEEDS_FIX（EXIT:4）。
#   stream-json の step_update に書き込み系のツールの呼び出しが 1 件でもあれば NEEDS_FIX（EXIT:4。証跡に件数）。
#   先頭の init が無い・JSON の欠損・不正・result の重複・終端でない result・status が SUCCESS でない は VERDICT: NONE。
#   限界: 子は同じ利用者の権限で動くので、閉じ込めをすり抜けて logs/ の記録を書き換える細工までは防がない（ほかのレビュー役と同じ前提）。
# VERDICT の読み取り: 共通の判定（_common.sh の lanes_parse_review。最後の行の VERDICT）で NONE のときだけ、コード・引用・表・番号付きの
#   行を除いた本文の独立した行の VERDICT（NEEDS_FIX があればそれ、無ければ最後のもの）を最後の行に置き直して、同じ判定にもう一度かける
#   （レビュー不能の文言・閉じていないコード・必須検証の不足・P0〜P2 の規則はそのまま効く）。
# 見張り: run-gemini.sh と同じ（gemini-agy.zsh）。出力が GEMINI_REVIEW_NOOUTPUT_SEC 秒（既定 600）止まったら EXIT:8、
#   idle（裏の作業待ち）のまま子が無ければ EXIT:3、全体の上限は --print-timeout（GEMINI_REVIEW_PRINT_TIMEOUT、既定 45m）。
# モデルと effort: GEMINI_REVIEW_MODEL / GEMINI_REVIEW_EFFORT（既定は空 = 付けない。実装用の GEMINI_MODEL / GEMINI_EFFORT とは別）
# 出力: <worktree>/logs/<label>.log（本文と証跡）/ <label>.last.md（最後の応答の本文だけ）/ <label>.json（生の stream-json。進行中も増える）
#       / <label>.stderr.log / <label>.prompt.md（渡した全文。dry-run は <label>.dry-run.prompt.md）/ <label>.evidence.md（PR 貼り付け用）
#       / <label>.pid（起動時）/ <label>.done（終了時）/ .<系列>.review-state（再利用の記録）/ <系列>.followups.md（round 3 以降の後回し票）
# 最終行は必ず VERDICT: CLEAN | NEEDS_FIX | NONE。終了コード: agy の rc（非 0 ならそのまま。見張りの停止は idle 3 / 無出力 8）、
#   書き込みの試み・作業ツリーや git の変更は 4（agy の rc より優先。agy の rc は証跡に別に書く）、rc 0 で VERDICT が取れない・記録を
#   書けないなら 3、引数・前提の誤りは 2。実行中に logs/ そのものを差し替えられたら 5（記録を書かずに止める）
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
# 親（このランチャ）は、引数のパスを絶対パスに決めた直後に / へ移る。対象の worktree の中から呼ばれても、親が動かす python
# （_common.sh・review-dedup.zsh の判定や記録）が作業場所の中の同じ名前のモジュール（json.py など）を読まないようにする。
# 子（agy）だけを worktree で起動する（gemini-agy.zsh の run_agy_once）。以後の git は必ず -C "$wt" で呼ぶ。
# 今の場所からの相対パスで書いた設定（LANES_CONF・パスで書いた GEMINI_BIN）は、移る前に絶対パスに直す（PATH で探す名前だけの値はそのまま）
[[ -z "${LANES_CONF:-}" || "$LANES_CONF" == /* ]] || LANES_CONF="${LANES_CONF:a}"
[[ -z "${GEMINI_BIN:-}" || "$GEMINI_BIN" == /* || "$GEMINI_BIN" != */* ]] || GEMINI_BIN="${GEMINI_BIN:a}"
builtin cd -q /
# ここから排他を取るまでの誤り（--mode・--round・--base の値など）は、取れれば今回の .done に残す（前回の DONE を残したまま止まらない）
lanes_early_target "$wt" "$label" "$dry"
lanes_require_label "$label"
lanes_require_worktree "$wt"
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
# 必須検証の使い回しの問い合わせ。指紋に環境変数が入るので、scratch や git の通信止めを export する前に、
# 親が chk-run.sh を回したのと同じ環境で呼ぶ。ランチャの記録（logs/ の直下の .pid・ログ・起動ログなど）は指紋に入らない
rvd_checks_query "$LANES_DIR" "$wt"
[[ "$RVD_CHECKS_REUSE" == yes ]] && LANES_REVIEW_CHECKS_REUSED=1 || LANES_REVIEW_CHECKS_REUSED=0
checks_key="$(rvd_checks_key)"

logdir="$wt/logs"
log="$logdir/$label.log"; json="$logdir/$label.json"; err="$logdir/$label.stderr.log"; body_log="$logdir/$label.last.md"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
# 系列の記録（再利用の記録・後回し票）は label では名前が決まらないので、ランチャの記録の台帳へ名前で載せる
series="$(rvd_series "$label")"
# 親の chk-run の記録を使えないときは、子を起動せずに止める（LANES_REVIEW_REQUIRE_CHECKS=1 のとき。run-claude-review.sh と同じ位置）
if rvd_checks_block "$allow_missing"; then lanes_die "$RVD_CHECKS_BLOCK"; fi
# 同じ道具でレビューしない。この worktree に Gemini 実装の記録があれば、排他を取る前に止める（今回の失敗 EXIT:2 として .done に残す）
same_engine_line=""
if lanes_has_impl_lane "$logdir" gemini; then
  if (( allow_same )); then
    same_engine_line="- 同じ道具のレビュー: この worktree に Gemini 実装の記録がある（logs/$REPLY）のに --allow-same-engine で起動した（実装と同じ思い込みを見落としやすい）"
    print -u2 -- "注意: この worktree に Gemini 実装の記録がある（logs/$REPLY）。--allow-same-engine が付いているので Gemini でレビューする（証跡に残す）"
  else
    lanes_die "この worktree には Gemini 実装の記録がある（logs/$REPLY）。実装と同じ道具（Gemini）でレビューすると同じ思い込みを見落としやすいので起動しない。Codex か Claude のレビューを使う（run-review.sh --engine codex / --engine claude）。どうしても Gemini で回すなら --allow-same-engine を付ける（証跡に残る）"
  fi
fi
if (( ! dry )); then
  # label の排他に加えて、同じ logs/ のレビュー共通の排他（--review-lock。Codex・Claude のレビューと共通の logs/.review.lock）を取る。
  # 別の label・別のエンジンのレビューが実行中なら、その記録・再利用の記録には触らずに止める（exit 2）
  lanes_mark_start "$logdir" "$label" gemini-review "$wt" --review-lock "file:.$series.review-state" "file:$series.followups.md"
  # 終了記録（.done）の書き込み先を、記録に触る前に確かめる。lanes_mark_start の回転が退避するのは普通のファイルと symlink だけなので、
  # 同じ名前のフォルダなどが残っていると、最後の .done だけを書けない（終了記録の無い実行を、次の起動が再利用し得る）。ここで止める
  [[ ! -e "$LANES_DONEFILE" && ! -L "$LANES_DONEFILE" ]] \
    || lanes_die "終了記録の書き込み先（${LANES_DONEFILE:t}）がフォルダなどになっていて書けない → 起動しない。中身を確かめてから消す: $LANES_DONEFILE"
fi
lanes_require_tool gemini run-gemini-review.sh
# 入口（run-review.sh）から来たときの起動前点検は、Gemini レビューの点検（agy のオプション・サンドボックス）も含めて回す
lanes_entry_preflight --review-engine gemini
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
# 前のレビューが途中で終わった（IN_PROGRESS のまま）なら前回の記録は使わない。ただしその前の NEEDS_FIX の未解決指摘は引き継ぐ
carried=0
if [[ -z "$record" ]]; then
  record="$(rvd_carried_record "$logdir" "$series")"
  if [[ -n "$record" ]]; then carried=1; prev_v='VERDICT: NEEDS_FIX'; prev_head=""; fi
fi
requested_mode="$mode"
policy=early; (( round >= 3 )) && policy=followups
# 再利用の条件（指示・起点・設定・検証の設定・必須検証の使い回し・レビュー役）。変わったら同じ HEAD でも省略しない（review-dedup.zsh の rvd_context）
review_context() { rvd_context "$LANES_DIR" "$prompt" "$review_base" "$requested_mode" "$policy" "$GEMINI_REVIEW_MODEL" "$GEMINI_REVIEW_EFFORT" "$wt" "$checks_key" gemini; }
context="$(review_context)"
tree="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
decided="$(rvd_decide_mode "$wt" "$prev_head" "$prev_v" "$context" "$(rvd_record_get "$record" context)" "$tree" "$(rvd_record_get "$record" tree)")"
skip_same=0
case "$mode:$decided" in
  auto:delta|delta:delta) mode=delta; base="$prev_head" ;;
  *:same) mode=full; (( force )) || skip_same=1 ;;
  *) mode=full ;;   # 明示の delta も、前回の記録が使えなければ（初回・前回 NEEDS_FIX・条件変更・未保存変更・前回が途中で終わった）全体を見る
esac
# 記録の公開（証跡・後回し票）。<公開先>、中身は標準入力。公開先と同じフォルダの一時ファイルに書き切ってから名前を付け替える
# （mv。書きかけ・欠けた中身を公開先に残さない）。公開先が symlink・フォルダ・普通のファイルでない物なら書かない（辿らない・中へ入れない）。
# 0 = 公開できた。子（agy）の起動前か、子と孫の回収が済んだ後だけで使う
publish_to() {
  local dst="$1" tmp="${1:h}/.${1:t}.tmp.$$"
  [[ ! -L "$dst" && ( ! -e "$dst" || -f "$dst" ) ]] || return 1
  rm -f -- "$tmp" 2>/dev/null || true
  if [[ ! -e "$tmp" && ! -L "$tmp" ]] && cat > "$tmp" && mv -f -- "$tmp" "$dst"; then return 0; fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}
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
  # 証跡は変数に作ってから 1 回で書く。証跡・ログのどちらかを書けなければ、前回の結果を使ったことにしない（EXIT:3・VERDICT: NONE）
  ev_text="$(
    print -- "## Gemini レビュー証跡（$label）"
    print -- "- $prev_v"
    print -- "- 対象: $(lanes_git_summary "$wt")"
    print -- "- レビューエンジン: gemini"
    print -- "- モード: skip-same-head（前回 round と同じ head ${prev_head:0:12}。レビューしていない）/ round=$round"
    rvd_checks_evidence skip
    [[ -z "$same_engine_line" ]] || print -r -- "$same_engine_line"
    print -- "- 実行: $(lanes_now) / 約 0 分 / EXIT:0"
    print -- "- HEAD: ${prev_head:0:12} → ${prev_head:0:12} / 作業ツリー差分行 0"
  )" || ev_text=""
  if [[ -n "$ev_text" ]] && print -r -- "$ev_text" | publish_to "$evidence" \
      && print -r -- "$ev_text"$'\n'"EXIT:0"$'\n'"$prev_v" > "$log"; then
    print -r -- "$ev_text"
    lanes_mark_done 0 "$prev_v" "skip-same-head round=$round"
    exit 0
  fi
  print -u2 -- "→ 記録を書けなかった（証跡 ${evidence:t}・ログ ${log:t}）。前回の結果を使ったことにしない。logs/ の権限・空きを確かめて回し直す"
  lanes_mark_done 3 "VERDICT: NONE" "skip-same-head round=$round / 記録を書けない"
  exit 3
fi
if (( dry )); then
  final="$logdir/$label.dry-run.prompt.md"
else
  for f in "$log" "$json" "$err" "$evidence" "$final" "$body_log"; do lanes_rotate_log "$f"; done
fi
mkdir -p "$logdir"
if (( dry )); then
  # dry-run は lanes_mark_start（logs/ の symlink・中の symlink の検査）を通らないので、書く前に同じことを確かめる。
  # logs/ が symlink なら書かない。<label>.dry-run.prompt.md が symlink なら、辿らずにその名前を外してから新しく作る（フォルダなら止める）
  [[ -d "$logdir" && ! -L "$logdir" ]] || lanes_die "logs/ が本物のフォルダではない（symlink など）→ dry-run でも書かない: $logdir"
  lanes_fresh_file "$final"
  lanes_records_claim "$logdir" "label:$label"   # dry-run が書く <label>.dry-run.prompt.md も、書く前にランチャの記録の台帳へ載せる
fi
# レーン専用の作業場所（TMPDIR / LANES_SCRATCH）。agy に書かせてよいのはここだけ（--add-dir）。マージ後 cleanup が消す
if (( dry )); then scratch="$(lanes_scratch_path "$wt" "$label")"; else lanes_scratch_prepare "$wt" "$label" gemini-review; scratch="$LANES_SCRATCH"; fi
# 親は起動の最初に / へ移っているので、子へ渡す場所（--add-dir・TMPDIR・GIT_CONFIG_GLOBAL）は絶対パスでなければならない
[[ "$scratch" == /* ]] || lanes_die "scratch の置き場所が絶対パスでない: $scratch（LANES_SCRATCH_ROOT を絶対パスで書く）"

lanes_check_gemini_subscription
# agy も絶対パスで起動する（親は / へ移り、子は worktree で起動するので、相対パスのままだと別の場所を指す。symlink はたどらない）
[[ "$GEMINI_BIN" == /* ]] || GEMINI_BIN="${GEMINI_BIN:a}"
# --sandbox が無効になる環境では走らせない。対象は Mac の端末サンドボックス（run-gemini.sh と同じ確認）
[[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] || lanes_die "端末サンドボックスを強制できない環境 → 起動禁止"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny file-write*)' /usr/bin/true 2>/dev/null \
  || lanes_die "端末サンドボックスを有効にできない → 起動禁止"
gem_help="$(ANTIGRAVITY_HEADLESS=true "$GEMINI_BIN" --help < /dev/null 2>&1)" || lanes_die "agy --help の確認に失敗"
# オプション名は単語として照合する（*--mode* だと --model の行にも当たる。lanes-doctor.sh と同じ _common.sh の関数）
for option in --sandbox --settings --mode; do
  lanes_help_has_option "$gem_help" "$option" || lanes_die "agy が $option に未対応 → 起動禁止（読み取り専用を強制できない）"
done
# plan は --mode の行の中に単語としてあること（help の別の場所の語・--model の説明の語では通さない）
lanes_agy_help_mode_has_plan "$gem_help" || lanes_die "agy の --mode に plan が無い → 起動禁止（読み取り専用を強制できない）"
unset gem_help

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
# 登録済みの linked worktree に限る。管理領域（.git 本体・hooks・設定）が作業場所・scratch の外にあることも確かめる（run-gemini.sh と同じ）
lanes_require_linked_worktree "$wt"
gitdir="$LANES_WT_GITDIR"; gitcommon="$LANES_WT_GITCOMMON"
for gd in "$gitdir" "$gitcommon"; do
  [[ "$gd/" != "$wt/"* && "$gd/" != "${scratch:A}/"* ]] || lanes_die "Git 管理領域が worktree / scratch の中にある → 起動禁止: $gd"
done
template="$LANES_DIR/templates/claude-review-$mode.md"
[[ -s "$template" ]] || lanes_die "テンプレが無い: $template"
focus="$LANES_DIR/templates/codex-review-focus.md"
[[ -s "$focus" ]] || lanes_die "テンプレが無い: $focus"
delta_note=""
[[ "$mode" == "delta" ]] && delta_note="$(rvd_delta_note "$wt" "$base" "$round")"

# テンプレ（Claude レビュー用を流用し、役名だけ Gemini に読み替え）+ 置き場所 + 閉じ込めの説明 + 案件固有の指示 + ランチャの追記
# （delta の説明・前回の未解決指摘・受け入れ済みの限界・必須検証のきまり）+ 出し方（Codex レビューと同じ codex-review-focus.md）を結合して残す
LANES_ACCEPTED_NOTE="$(rvd_accepted_note "$wt")" python3 -I - "$template" "$prompt" "$final" "$wt" "$branch" "$head" "$base" "$mode" "$(lanes_now)" \
    "$(rvd_checks_rule)" "$delta_note" "$unresolved_note" "$(lanes_scratch_rule "$scratch")" "$focus" <<'PY' || lanes_die "結合済みプロンプト（${final:t}）を書けない（同じ名前の物が置かれている・logs/ を書けない）"
import os, sys, pathlib
tpl, case, out, wt, branch, head, base, mode, date, checks_rule, delta_note, unresolved, scratch_rule, focus = sys.argv[1:15]
# 役名だけ Gemini に読み替える。実際のパス・枝名（{{WORKTREE}} など）を埋め込む前に置き換える（パス・枝名の中の文字は変えない）
t = pathlib.Path(tpl).read_text(encoding="utf-8").replace("Claude", "Gemini")
for k, v in {"WORKTREE": wt, "BRANCH": branch, "HEAD": head, "BASE": base, "MODE": mode, "DATE": date}.items():
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
# 書き先は回転か lanes_fresh_file で空けてある。logs/ を symlink を辿らずに開き、その中に新しいファイルとして作る
# （同じ名前の物が置き直されていたら・symlink なら書かずに失敗する。O_EXCL・O_NOFOLLOW）
d = os.open(os.path.dirname(out), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    fd = os.open(os.path.basename(out), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=d)
finally:
    os.close(d)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

# 起動単位の設定（拒否の固定の一覧。_common.sh の lanes_gemini_review_settings。利用者の設定ファイルは変えない）
gem_settings="$(lanes_gemini_review_settings)" || lanes_die "Gemini レビューの設定を作れない"
# 環境変数の effort が設定ファイルと違う値で勝っていたら知らせる（渡す値は変えない）
lanes_effort_override_note GEMINI_REVIEW_EFFORT
cmd=("$GEMINI_BIN")
if [[ -n "$GEMINI_REVIEW_MODEL" ]]; then cmd+=(--model "$GEMINI_REVIEW_MODEL"); fi
if [[ -n "$GEMINI_REVIEW_EFFORT" ]]; then cmd+=(--effort "$GEMINI_REVIEW_EFFORT"); fi
cmd+=(--mode plan --sandbox --settings "$gem_settings"
     --output-format stream-json --print-timeout "$print_timeout" --add-dir "$scratch")
if (( dry )); then
  print -- "[dry-run] series=$series round=$round mode=$mode base=$base prev_head=${prev_head:0:12}（判定 $decided）/ 必須検証の使い回し: $RVD_CHECKS_REUSE"
  (( ! carried )) || print -- "[dry-run] 前回のレビューは途中で終わった（IN_PROGRESS）。その前の NEEDS_FIX の未解決指摘を引き継いで full で回す"
  print -- "[dry-run] scratch: $scratch"
  print -- "[dry-run] （子だけ cd ${(q)wt}）ANTIGRAVITY_HEADLESS=true TMPDIR=${(q)scratch}/ LANES_SCRATCH=${(q)scratch} GIT_DIR=${(q)gitdir} GIT_WORK_TREE=${(q)wt} GIT_CONFIG_GLOBAL=${(q)scratch}/gitconfig GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat GIT_ALLOW_PROTOCOL=lanes-no-transport lanes_start_child_in ${(q)wt} python3 -I gemini-stream-tee.py -- ${(q)cmd[@]} -p \"\$(<${(q)final})\" < /dev/null > ${(q)json} 2> ${(q)err}"
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

# 親は対象の worktree へ移らない（起動の最初に / へ移ってある。子だけを worktree で起動する。gemini-agy.zsh の run_agy_once が
# lanes_start_child_in で起動する）。git は必ず -C "$wt" で呼ぶ
snapshot_before="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
[[ "$snapshot_before" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "起動準備中に内容・指示が変化した。再実行する"
guard_before="$(rvd_git_guard "$wt")" || lanes_die "レビュー前の git 管理フォルダの確認に失敗"
# git の制御ファイル（worktree の .git・gitdir の commondir / gitdir / config・共通の config・hooks）の前後比較（Codex レビューと同じ）。
# 子の後は git を 1 回も呼ぶ前に指紋だけで比べる
git_fp_before="$(lanes_git_ctl_fingerprint "$wt" "$gitdir" "$gitcommon")" || lanes_die "起動前の git 制御ファイルの確認に失敗"
# 子を起動する直前に、この系列の記録を確認中（IN_PROGRESS）にする。ここから先で確定（rvd_save_state）まで進めずに終わったら、
# 次の起動は前回の記録（古い CLEAN を含む）を使わない。前回 NEEDS_FIX の未解決指摘だけは持ち越す
rvd_mark_in_progress "$logdir" "$series" "$round" "$label" "$record" "$prev_v" \
  || lanes_die "再利用の記録（logs/.$series.review-state）を確認中にできない（記録を読めない・書けない、または前回の未解決指摘の本文を読めない）。記録は変えていない"
started="$(lanes_now)"; t0=$(date +%s)

# レビューの子から push（と fetch）をできなくする（読み取り専用の役。git の通信は要らない）
lanes_block_git_transport
# agy は監督役（作業場所は worktree）の下で、受け取り役（gemini-stream-tee.py）を挟んで起動する。見張りは Gemini 実装と同じ
GEM_TAG="[run-gemini-review]"
source "$LANES_DIR/gemini-agy.zsh"
run_agy_once "$json" "$err"
LANES_CHILD=""   # 以後の trap で（pid 再利用した）別プロセスを kill しない
agy_rc=$GEM_RC   # agy（受け取り役）の終了コード。書き込みの試み・作業ツリーの変更で EXIT:4 にしたときも、証跡にはこの値を別に残す
rc=$GEM_RC
stop_line="なし"
if (( GEM_NOOUT )); then rc=8; stop_line="出力 ${noout_sec} 秒なしで停止"
elif (( GEM_IDLE_KILLED )); then rc=3; stop_line="idle（裏の作業待ち）で強制停止。正常完了ではない"
fi
# git を 1 回も呼ぶ前に、制御ファイルが変わっていないかを見る（記録は IN_PROGRESS のまま残す）
git_fp_after="$(lanes_git_ctl_fingerprint "$wt" "$gitdir" "$gitcommon" 2>/dev/null)" || git_fp_after=ERROR
if [[ "$git_fp_after" != "$git_fp_before" ]]; then
  print -- "[run-gemini-review] $(lanes_now) git の制御ファイル（.git・commondir・gitdir・config・config.worktree・hooks）が変わった → git を実行せず停止" >> "$log"
  print -u2 -- "→ Gemini レビューの実行中に git の制御ファイルが変わった。git を実行せず停止（EXIT:4）。$wt/.git と $gitdir・$gitcommon の中身を手で確かめてから直す"
  print -- "EXIT:4" >> "$log"
  lanes_mark_done 4 "VERDICT: NEEDS_FIX" "git の制御ファイルの変更を検出（git 未実行）"
  exit 4
fi
elapsed=$(( ($(date +%s) - t0) / 60 ))

# stream-json を厳密に読み、最後の result（status=SUCCESS の response）だけを本文にする（logs/<label>.last.md と logs/<label>.log）。
# 同時に、書き込み系のツール呼び出し（run-gemini.sh の監査と同じ判定: ツール名に write / replace / edit / delete / move / rename /
# create / append / copy / patch を含む tool の step_update）を数える。読み取り専用のレビューでは 1 件でも不合格。
# 開始から記録できたことも確かめる: 1 行目が init のイベントでない・init が 2 回ある記録は不備。
# 出力（標準出力）: status= / writes= / write_tools= / asks= / turns= / invalid= / invalid_kinds=。終了コード: 0 = 本文あり /
# 4 = JSON の欠損・不正・init の欠落・result の重複・終端でない / 5 = status が SUCCESS でない（本文は書かない＝VERDICT を拾わない）/
# 6 = 公開ログ（last.md・.log）を書けない
conv_rc=0
audit_out="$(python3 -I - "$json" "$body_log" "$log" <<'PY'
import json, sys
src, body_out, log_out = sys.argv[1:4]
WRITE_HINT = ("write", "replace", "edit", "delete", "move", "rename", "create", "append", "copy", "patch")
status, body, error, turns, asks = "NONE", "", "", 0, 0
writes, write_tools, invalid = set(), set(), []
results, last_event, events, inits, first_init = 0, None, 0, 0, False
try:
    with open(src, "rb") as f:
        raw = f.read()
    # 行の区切りは \n だけ（str.splitlines は本文の中の U+2028 などでも割ってしまい、正しい JSON を不正な行にする）
    lines = raw.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
except OSError:
    lines = None; invalid.append("ログを読み取れない")
if lines is not None and not lines:
    invalid.append("ログが空")
for index, part in enumerate(lines or []):
    # 文字コード（UTF-8）は 1 行ずつ読む。途中で切れた行（末尾の文字が欠けたなど）はその行だけを不備に数え、
    # その前後の行で見つけた書き込みの記録は捨てない（書き込みの試みがあれば EXIT:4 を優先する）
    try:
        line = part.decode("utf-8")
    except UnicodeDecodeError:
        invalid.append("文字コードの不正行"); continue
    try:
        d = json.loads(line)
    except (ValueError, TypeError):
        invalid.append("JSON の不正行"); continue
    if not isinstance(d, dict) or not isinstance(d.get("event"), str):
        invalid.append("イベントの形式が不正"); continue
    events += 1
    last_event = d["event"]
    if d["event"] == "init":
        inits += 1
        first_init = first_init or index == 0
        continue
    if d["event"] == "result":
        r = d.get("result")
        if not isinstance(r, dict) or r.get("status") not in ("SUCCESS", "ERROR"):
            invalid.append("結果の形式が不正"); continue
        if any(not isinstance(r.get(k, ""), str) for k in ("response", "error")):
            invalid.append("結果本文の形式が不正"); continue
        if type(r.get("num_turns", 0)) is not int or r.get("num_turns", 0) < 0 or not isinstance(r.get("usage", {}), dict):
            invalid.append("結果集計の形式が不正"); continue
        results += 1
        status = r["status"]; body = r.get("response", "") or ""; error = r.get("error", "") or ""; turns = r.get("num_turns", 0)
        continue
    if d["event"] != "step_update":
        continue
    su = d.get("step_update")
    if not isinstance(su, dict) or not isinstance(su.get("step_type"), str):
        invalid.append("作業記録の形式が不正"); continue
    name = su.get("tool_name") or ""
    if not isinstance(name, str) or (su["step_type"] == "tool" and not name.strip()):
        invalid.append("ツール名の形式が不正"); continue
    if name.startswith("ask_"):
        asks += 1
    if su["step_type"] == "tool" and any(h in name.lower() for h in WRITE_HINT):
        # 同じ呼び出しの経過の記録（何度も届く step_update）は 1 件に数える。手がかりが無ければ中身で区別する
        key = next((str(su[k]) for k in ("step_index", "step_id", "id", "tool_call_id") if k in su), None)
        writes.add(key if key is not None else name + "\0" + json.dumps(su.get("tool_info"), sort_keys=True, ensure_ascii=False))
        write_tools.add(name)
if results > 1 or (results == 1 and last_event != "result"):
    invalid.append("結果が重複、または終端ではない")
if results == 0 and lines:
    invalid.append("終了結果が欠損")
if lines and not first_init:
    invalid.append("開始の記録（先頭の init）が無い")
if inits > 1:
    invalid.append("開始の記録（init）が重複")
ok = not invalid and status == "SUCCESS" and bool(body.strip())
# 見張りの行（run_agy_once が子の実行中に書いたもの）は残して、本文の前に置く
try:
    with open(log_out, encoding="utf-8", errors="replace") as f:
        watch = f.read().rstrip()
except OSError:
    watch = ""
one = " ".join(str(error).split())[:300]
meta = (f"[meta] status={status} turns={turns} events={events} inits={inits} writes={len(writes)} asks={asks} audit_errors={len(invalid)}"
        + (f" error={one}" if one else "") + "\n")
written = True
try:
    # 子と孫の回収と logs/ の確かめ（lanes_logdir_check）が済んだ後なので、名前のまま書いてよい
    with open(body_out, "w", encoding="utf-8") as f:
        f.write(body if ok else "")
    with open(log_out, "w", encoding="utf-8") as f:
        f.write(meta + (watch + "\n" if watch else "")
                + ("" if ok else "[meta] 正常な result（status=SUCCESS の本文）が無い・JSON が不正なので VERDICT は採用しない\n")
                + "\n" + (body if ok else ""))
except OSError:
    written = False
print(f"status={status}")
print(f"writes={len(writes)}")
print("write_tools=" + ",".join(sorted(write_tools))[:200])
print(f"asks={asks}")
print(f"turns={turns}")
print(f"invalid={len(invalid)}")
print("invalid_kinds=" + "・".join(dict.fromkeys(invalid))[:200])
print(f"written={int(written)}")
sys.exit(6 if not written else 0 if ok else (5 if not invalid and results == 1 else 4))
PY
)" || conv_rc=$?
audit_get() { local line; for line in "${(@f)audit_out}"; do [[ "$line" == "$1="* ]] && { print -r -- "${line#*=}"; return 0; }; done; print -r -- ""; }
gstatus="$(audit_get status)"; [[ -n "$gstatus" ]] || gstatus=NONE
writes_n="$(audit_get writes)"; [[ "$writes_n" == <-> ]] || writes_n=0
write_tools="$(audit_get write_tools)"; asks_n="$(audit_get asks)"; [[ "$asks_n" == <-> ]] || asks_n=0
invalid_n="$(audit_get invalid)"; [[ "$invalid_n" == <-> ]] || invalid_n=0; invalid_kinds="$(audit_get invalid_kinds)"
# 監査そのものが動かなかった（python の失敗など）ときも、成功扱いにしない
[[ -n "$audit_out" ]] || { conv_rc=4; invalid_n=1; invalid_kinds="監査を実行できない"; }
# 記録の書き込みの失敗（公開ログ・後回し票・証跡）。1 つでもあれば記録を確定しない（IN_PROGRESS のまま）
typeset -a write_failed; write_failed=()
[[ "$(audit_get written)" != 0 ]] || write_failed+=("公開ログ（${body_log:t}・${log:t}）")
# 必須検証の仕組みの有無をランチャ側で見て判定へ渡す（仕組みがあるのに「該当なし（未導入）」・NA と書いた項目は未実施と同じ扱い）
checks_present="$(lanes_checks_present "$wt")" || checks_present=""
export LANES_CHECKS_PRESENT="$checks_present"
# 判定・指摘数・必須検証・解消宣言は、最後の応答の本文（last.md）だけを読む（見張りの行や JSON の途中を拾わない）
verdict_note=""
if (( conv_rc != 0 )); then
  verdict="VERDICT: NONE"
else
  verdict="$(lanes_extract_verdict "$body_log")"
fi
# 本文の途中にある独立した行の VERDICT（最後の行の後ろに補足が続いた応答など）。共通の判定が NONE のときだけ見る。
# コード・引用・表・字下げ・番号付きの行は除く（共通の判定と同じ扱い）。NEEDS_FIX が 1 つでもあればそれ、無ければ最後のもの。
# 見つけた判定を本文の最後の行に置いた写しを、共通の判定にもう一度かける（レビュー不能の文言・閉じていないコード・必須検証の不足・
# P0〜P2 の規則はそのまま効く）。写しは scratch に置く（子と孫の回収が済んだ後）
if (( conv_rc == 0 && rc == 0 )) && [[ "$verdict" == 'VERDICT: NONE' ]]; then
  inline="$(python3 -I - "$body_log" <<'PY'
import re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        raw = f.read()
except (OSError, UnicodeError):
    sys.exit(0)
found, fence, width = [], None, 0
for line in raw.splitlines():
    stripped = line.strip()
    marker = re.match(r"^(`{3,}|~{3,})(.*)$", stripped)
    if marker:
        token, suffix = marker.groups()
        if fence is None:
            fence, width = token[0], len(token)
        elif token[0] == fence and len(token) >= width and not suffix.strip():
            fence = None
        continue
    if fence is not None or line.startswith(("    ", "\t")) or stripped.startswith((">", "|")):
        continue
    candidate = re.sub(r"^[-*+]\s+", "", stripped)
    for wrapper in ("**", "`"):
        if candidate.startswith(wrapper) and candidate.endswith(wrapper):
            candidate = candidate[len(wrapper):-len(wrapper)].strip()
    m = re.fullmatch(r"VERDICT:\s*(CLEAN|NEEDS_FIX|PASS)", candidate)
    if m:
        found.append("CLEAN" if m[1] == "PASS" else m[1])
if found:
    print("VERDICT: " + ("NEEDS_FIX" if "NEEDS_FIX" in found else found[-1]))
PY
)" || inline=""
  if [[ "$inline" == 'VERDICT: CLEAN' || "$inline" == 'VERDICT: NEEDS_FIX' ]]; then
    inline_copy="$(mktemp "${LANES_SCRATCH%/}/verdict-inline.XXXXXX")" || inline_copy=""
    # 写しは本文を読み切れたときだけ使う（cat の失敗を最後の print の成功で隠さない。本文の無い写しで判定を作らない）
    if [[ -n "$inline_copy" ]] && { cat -- "$body_log" && print -r -- "" && print -r -- "$inline"; } > "$inline_copy"; then
      again="$(lanes_extract_verdict "$inline_copy")"
      if [[ "$again" == 'VERDICT: CLEAN' || "$again" == 'VERDICT: NEEDS_FIX' ]]; then
        verdict="$again"; verdict_note="本文の途中の独立した行の VERDICT を採用（${inline#VERDICT: }）"
      fi
    fi
    [[ -z "$inline_copy" ]] || rm -f -- "$inline_copy"
  fi
fi
[[ "$verdict" == "VERDICT: PASS" ]] && verdict="VERDICT: CLEAN"
(( rc == 0 )) || verdict="VERDICT: NONE"   # agy が非 0 で終わった・見張りで止めた本文の VERDICT は採用しない
# レビュー後の HEAD。読めない（枝の参照が消えた・壊れた など）ときは止めずに、作業ツリーや git の変更として扱う（下の dirty。EXIT:4）
head_after_full="$(git -C "$wt" rev-parse --verify -q HEAD 2>/dev/null)" || head_after_full=""
head_after="${head_after_full:0:12}"; [[ -n "$head_after" ]] || head_after="（読めない）"
# P0/P1 と明示 CLEAN の矛盾は必ず不合格
typeset -A sev; for k in P0 P1 P2 P3; do sev[$k]=$(lanes_count_findings "$body_log" $k); done
sevsum="P0:${sev[P0]} P1:${sev[P1]} P2:${sev[P2]} P3:${sev[P3]}"
[[ "$verdict" == 'VERDICT: NONE' ]] || (( rc != 0 || sev[P0] + sev[P1] == 0 )) || verdict="VERDICT: NEEDS_FIX"
gate="$(rvd_gate "$round" "$verdict" "${sev[P0]}" "${sev[P1]}")"
raw_verdict="$verdict"; followups=""
# 後回し票（<系列>.followups.md）は、下の読み取り専用の監査（書き込みの試み・作業ツリーや git の変更）を通り、記録を確定するときだけ
# 公開する。それまでは scratch の写し（公開中の票の中身から始める）に足しておく（失格の回の指摘を票に残さない・再実行で重ねない）
fu_pub="$logdir/$series.followups.md"; fu_stage=""; fu_old=""; fu_published=0
stage_followups() {   # 写しを用意する（1 回だけ）。0 = 用意できた
  [[ -z "$fu_stage" ]] || return 0
  local s o=""
  s="$(mktemp "${LANES_SCRATCH%/}/followups.XXXXXX")" || return 1
  if [[ -e "$fu_pub" || -L "$fu_pub" ]]; then
    # 公開中の票が普通のファイルでなければ失敗にする。公開の後で確定に失敗したら戻せるよう、元の中身も別に写す
    if ! { [[ -f "$fu_pub" && ! -L "$fu_pub" ]] && o="$(mktemp "${LANES_SCRATCH%/}/followups-old.XXXXXX")" \
        && cat -- "$fu_pub" > "$s" && cat -- "$fu_pub" > "$o"; }; then
      rm -f -- "$s" ${o:+"$o"}; return 1
    fi
  fi
  fu_stage="$s"; fu_old="$o"
}
# round 3 以降の P2/P3 は、元から CLEAN（P3 だけ）でも残件を必ず後回し票に保存する（run-claude-review.sh と同じ）
if (( round >= 3 && sev[P2] + sev[P3] > 0 )) && [[ "$verdict" != 'VERDICT: NONE' ]]; then
  followups="$fu_pub"
  if ! { stage_followups && rvd_write_followups "$body_log" "$fu_stage" "$round" "$head_after" "$label"; }; then
    rc=3; verdict="VERDICT: NONE"; gate=FIX
    write_failed+=("後回し票（${fu_pub:t}）")
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
  # 前回の軽微な指摘も保存対象。今回の本文から省かれていても取りこぼさない。
  # ただし前回分を後回し票へ移して通すのは、今回の判定が CLEAN のとき（今回の指摘が無い、または今回の要修正の理由が全部 P2/P3 で、
  # 上で後回し票に移して CLEAN にした）だけ。今回の本文が NEEDS_FIX のまま（重大度を読み取れない今回の要修正の理由がある）なら、
  # 前回分だけを移しても今回の理由が残るので通さない（NEEDS_FIX のまま）
  defer_previous=0
  if (( round >= 3 && rc == 0 && sev[P0] + sev[P1] == 0 )) && [[ "$verdict" == 'VERDICT: CLEAN' && "$checks" == COMPLETE ]]; then
    defer_previous=1
  fi
  previous_rc=0
  if (( defer_previous )) && ! stage_followups; then
    previous_rc=2
  else
    rvd_previous_followups "$record" "$fu_stage" "$round" "$head_after" "$label" "$defer_previous" || previous_rc=$?
  fi
  if (( previous_rc == 0 && defer_previous )); then
    pending_note=""; verdict="VERDICT: CLEAN"; gate=MERGE_WITH_FOLLOWUP
    followups="$fu_pub"
  elif (( previous_rc == 2 )); then
    rc=3; verdict="VERDICT: NONE"; gate=FIX
    (( ! defer_previous )) || write_failed+=("後回し票（${fu_pub:t}）")
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
dirty=0
if [[ -z "$head_after_full" || "$snapshot_after" == ERROR || "$snapshot_before" != "$snapshot_after" || "$conditions_after" != "$context" \
    || "$guard_after" == ERROR || "$guard_before" != "$guard_after" ]] || (( writes_n > 0 )); then
  dirty=1; verdict="VERDICT: NEEDS_FIX"
  [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  # 書き込みの試み・変更は、agy 自身の失敗（非 0 の終了・見張りの停止）より優先して EXIT:4 にする（呼び出し元が CLI の障害と
  # 監査の違反を区別できるように）。agy の終了コードは証跡の「読み取り専用の確認」の行に別に残す
  rc=4
  (( writes_n == 0 )) || print -u2 -- "→ Gemini レビューが書き込み系のツールを ${writes_n} 件呼んだ（${write_tools:-名前不明}）。読み取り専用のレビューとして不合格（NEEDS_FIX）にする"
  [[ -n "$head_after_full" ]] || print -u2 -- "→ レビューの後に HEAD を読めない（枝の参照が消えた・壊れた など）。git の変更として不合格（NEEDS_FIX）にする。git -C $wt status で確かめる"
fi
(( rc != 0 )) || [[ "$verdict" == 'VERDICT: CLEAN' || "$verdict" == 'VERDICT: NEEDS_FIX' ]] || rc=3
# 周回の上限を超えて CLEAN にならなければ ESCALATE（人に返す）。続けるなら人が直して LANES_REVIEW_MAX_ROUNDS を上げる
gate="$(rvd_escalate "$round" "$verdict" "$gate")"

# 証跡の本文（PR に貼る）。<判定> <EXIT> [記録を確定できなかった理由]。変数に作ってから 1 回で書く（途中の失敗で欠けた証跡を出さない）
evidence_text() {
  print -- "## Gemini レビュー証跡（$label）"
  print -- "- $1"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- レビューエンジン: gemini"
  print -- "- モード: $mode / base=$base / round=$round"
  lanes_model_effort_evidence gemini-review
  print -- "- 指摘: $sevsum / GATE: $gate"
  [[ "$gate" != ESCALATE ]] || print -- "- 周回の上限（LANES_REVIEW_MAX_ROUNDS=${LANES_REVIEW_MAX_ROUNDS:-5}）を超えた → ここで止めて人に判断を返す（続ける＝直して上限を上げる / 締める＝残りを .lanes/accepted-limitations.md か後回し票へ）"
  print -- "- 必須検証の成功確認: $checks（仕組みがあると見た項目: ${checks_present:-なし}。その項目の「該当なし（未導入）」・NA は受け付けない）"
  rvd_checks_evidence
  [[ -z "$followups" ]] || print -- "- 元の判定: $raw_verdict / P2/P3 の保存先: $followups${fu_skip_note:-}"
  (( ! carried )) || print -- "- 前回: 途中で終わったレビュー（IN_PROGRESS）の記録から、その前の NEEDS_FIX の未解決指摘を引き継いだ（full）"
  [[ -z "$verdict_note" ]] || print -r -- "- VERDICT の読み取り: $verdict_note"
  print -- "- 読み取り専用の確認: 書き込みの試み ${writes_n} 件${write_tools:+（$write_tools）}（1 件でもあれば不合格）/ 承認・質問ツール ${asks_n} 回 / agy: $gstatus・終了コード $agy_rc / JSON の不備 ${invalid_n} 件${invalid_kinds:+（$invalid_kinds）} / 見張り: $stop_line"
  [[ -z "$same_engine_line" ]] || print -r -- "$same_engine_line"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分 / EXIT:$2"
  [[ -z "${3:-}" ]] || print -r -- "- 記録の確定: できなかった（$3）。再利用の記録は確定していない（次の起動は前回の結果を使わずに回す）"
  print -- "- HEAD: $head → $head_after / 内容・履歴・条件の変更検出 $dirty（0=なし、1=あり）"
  print -- "- ログ: $log（本文）/ $body_log（最後の応答）/ $json（生）/ $final（渡した全文）"
  print -- "- 作業場所（scratch）: $scratch（${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"
}
# 終了記録（.done）を今回の値で書けたか（普通のファイルで、1 行目が EXIT:<n>・2 行目が判定）。lanes_mark_done は書けなくても止まらない
done_written() {
  local f="${LANES_DONEFILE:-}" first="" second=""
  [[ -n "$f" && -f "$f" && ! -L "$f" ]] || return 1
  { IFS= read -r first && IFS= read -r second; } < "$f" || return 1
  [[ "$first" == "EXIT:$1" && "$second" == "$2" ]]
}

# ---- 記録の確定 ----
# 確定するのは、agy が 0 で終わり、VERDICT が CLEAN か NEEDS_FIX で、ここまでの記録（公開ログ・後回し票の写し）が全部書けたときだけ。
# 順番: 書く先の確認 → ログの末尾（確定見込みの判定）→ 再利用の記録（rvd_save_state）→ 証跡 → 後回し票 → 終了記録（.done。読み戻して確かめる）
# 合格の証跡と標準出力の表示は、全部が書けてから出す。途中で失敗したら、確定した分（再利用の記録・後回し票）を元に戻し、
# 証跡を失敗（VERDICT: NONE・EXIT:3 と理由）で書き直し、ログの末尾にも失敗の判定を足す（合格の表示を残さない）
statef="$(rvd_state_file "$logdir" "$series")"
final_rc=$rc; done_verdict="$verdict"; done_note="gemini rc=$rc agy_rc=$agy_rc gate=$gate $sevsum"
fail_reason=""; tail_written=0; state_saved=0; done_lost=0; inprog_copy=""; ev_text=""
finalize=0
(( rc == 0 )) && [[ "$verdict" == 'VERDICT: CLEAN' || "$verdict" == 'VERDICT: NEEDS_FIX' ]] && finalize=1
if (( finalize )); then
  # 書く先が symlink・フォルダなどになっていないか（子が実行中に置いた物も含む）。終了記録（.done）は開始時に退避してあるので、
  # 何かがあれば実行中に置かれた物（書けないか、今回の結果でない）。1 つでもあれば確定しない
  [[ ! -e "$LANES_DONEFILE" && ! -L "$LANES_DONEFILE" ]] || write_failed+=("終了記録（${LANES_DONEFILE:t}。実行中に置かれた物がある）")
  for f in "$evidence" "$log" "$statef" ${fu_stage:+"$fu_pub"}; do
    [[ ! -L "$f" && ( ! -e "$f" || -f "$f" ) ]] || write_failed+=("${f:t}（symlink・フォルダなどになっている）")
  done
fi
if (( ${#write_failed} )); then
  fail_reason="記録を書けない: ${(j:・:)write_failed}"
elif (( finalize )); then
  ev_text="$(evidence_text "$verdict" "$rc")" || ev_text=""
  if [[ -z "$ev_text" ]]; then
    fail_reason="記録を書けない: 証跡（${evidence:t}）を作れない"
  elif ! print -r -- $'\n'"----"$'\n'"$ev_text"$'\n'"finished: $(lanes_now)"$'\n'"EXIT:$rc"$'\n'"$verdict" >> "$log"; then
    fail_reason="記録を書けない: ログの末尾（${log:t}）"
  else
    tail_written=1
    # 確定に失敗したら戻せるよう、確認中（IN_PROGRESS）の記録を先に写しておく
    if ! { inprog_copy="$(mktemp "${LANES_SCRATCH%/}/review-state.XXXXXX")" && cat -- "$statef" > "$inprog_copy"; }; then
      fail_reason="記録を確定できない: 確認中の再利用の記録（${statef:t}）を写せない"
    elif ! rvd_save_state "$logdir" "$series" "$round" "$head_after_full" "$verdict" "$gate" "$label" "$context" "$snapshot_after" "$review_base" "$log" "$pending_note" "$blocking_previous"; then
      fail_reason="記録を確定できない: 再利用の記録（${statef:t}）"
    else
      state_saved=1
      if ! print -r -- "$ev_text" | publish_to "$evidence"; then
        fail_reason="記録を書けない: 証跡（${evidence:t}）"
      elif [[ -n "$fu_stage" ]] && ! publish_to "$fu_pub" < "$fu_stage"; then
        fail_reason="記録を書けない: 後回し票（${fu_pub:t}）"
      else
        [[ -z "$fu_stage" ]] || fu_published=1
        lanes_mark_done "$final_rc" "$done_verdict" "$done_note" || true
        if done_written "$final_rc" "$done_verdict"; then
          print -r -- "$ev_text"
          exit $final_rc
        fi
        # 終了記録を書けなかった（.done は書き直せない）。ここまでの確定を戻し、終了記録の無い実行を次の起動が再利用しないようにする
        done_lost=1; fail_reason="記録を書けない: 終了記録（${LANES_DONEFILE:t}）"
      fi
    fi
  fi
fi
if [[ -n "$fail_reason" ]]; then
  print -u2 -- "→ $fail_reason。再利用の記録は確定しない（次の起動は前回の結果を使わずに回す）。logs/ の権限・空きを確かめて回し直す"
  (( final_rc != 0 )) || final_rc=3
  done_verdict="VERDICT: NONE"; done_note+=" / $fail_reason"
  # 確定まで進めた分を元に戻す。再利用の記録は確認中へ（戻せなければ消す＝次の起動は前回の記録を使わない）、後回し票は公開前の中身へ
  if (( state_saved )) && ! rvd_state_write "$statef" < "$inprog_copy" 2>/dev/null; then
    if rm -f -- "$statef" 2>/dev/null; then
      print -u2 -- "→ 再利用の記録（${statef:t}）を確認中へ戻せないので消した（次の起動は前回の記録を使わずに full で回す。前回の未解決指摘は引き継がれない）"
    else
      print -u2 -- "→ 再利用の記録（${statef:t}）を確認中へ戻せない・消せない。次の起動の前に手で消す: $statef"
    fi
  fi
  if (( fu_published )); then
    if [[ -n "$fu_old" ]]; then publish_to "$fu_pub" < "$fu_old"; else rm -f -- "$fu_pub"; fi \
      || print -u2 -- "→ 後回し票（${fu_pub:t}）を公開前の中身へ戻せない。今回の round（$round）の分を手で消す: $fu_pub"
  fi
fi
(( final_rc != 0 )) || [[ "$done_verdict" == 'VERDICT: CLEAN' || "$done_verdict" == 'VERDICT: NEEDS_FIX' ]] || final_rc=3   # 完走したのに VERDICT が無い
# ここまで来たときは後回し票を公開していない（確定しなかった・公開した分は戻した）。証跡の保存先の行にその旨を付ける
fu_skip_note="（確定しなかったので保存していない）"
ev_text="$(evidence_text "$done_verdict" "$final_rc" "$fail_reason")" \
  || ev_text="## Gemini レビュー証跡（$label）"$'\n'"- $done_verdict"$'\n'"- 実行: $started 開始 / EXIT:$final_rc${fail_reason:+ / 記録の確定: できなかった（$fail_reason）}"
print -r -- "$ev_text" | publish_to "$evidence" || print -u2 -- "→ 証跡（${evidence:t}）を書けない"
if (( tail_written )); then
  # 先に書いた確定見込みの判定は採用しない（ログの最後の行を今回の結果にする）
  tail_text="[run-gemini-review] $(lanes_now) 記録の確定に失敗（$fail_reason）→ 上の判定は採用しない"$'\n'"EXIT:$final_rc"$'\n'"$done_verdict"
else
  tail_text=$'\n'"----"$'\n'"$ev_text"$'\n'"finished: $(lanes_now)"$'\n'"EXIT:$final_rc"$'\n'"$done_verdict"
fi
print -r -- "$tail_text" >> "$log" || print -u2 -- "→ ログの末尾（${log:t}）を書けない"
print -r -- "$ev_text"
(( done_lost )) || lanes_mark_done "$final_rc" "$done_verdict" "$done_note" || true
exit $final_rc
