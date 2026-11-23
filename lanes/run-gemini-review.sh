#!/bin/zsh -f
# レビューランチャ（Gemini / Antigravity CLI agy・読み取り専用）。構成（LANES_TOOLS）に gemini があるときに使える、もう 1 つのレビュー役。
# 振り分けの入口は run-review.sh（--engine gemini か LANES_REVIEW_GEMINI_PCT の割合。Gemini で実装したものは Gemini でレビューしない）。使い方:
#   run-gemini-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--allow-missing-checks] [--impl-engine claude|gemini|codex] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# 同じ確認を繰り返さない仕組み（--mode auto の full / delta / 同じ head の結果の再利用、--round と round 3 以降の P2/P3 の後回し、
#   --force、--base）と、親の chk-run.sh の記録による必須検証の使い回し（LANES_REVIEW_REUSE_CHECKS / LANES_REVIEW_REQUIRE_CHECKS と
#   --allow-missing-checks）は run-claude-review.sh / run-codex-review.sh と同じ（review-dedup.zsh）。
# 同じ道具でのレビューの禁止: Gemini で実装したもの（--impl-engine gemini か、logs/ の .pid に lane=gemini）は、直接呼ばれても
#   前回の結果の再利用・子の起動より前に止める（exit 2。判定は入口の run-review.sh と同じ review-dedup.zsh の rvd_impl_gemini）
# 読み取り専用の担保:
#   - agy に --sandbox（端末サンドボックス）・--settings（起動ごとの設定）・--mode plan を必ず付け、ANTIGRAVITY_HEADLESS=true で起動する
#   - 設定の permissions.deny で MCP・ファイルを書く道具・サブエージェント・ブラウザ・外部からの取得・予約を拒否する
#     （固定の一覧は下の gem_settings。GEMINI_REVIEW_DENY で足せるが、外せない。渡す一覧は再利用の条件にも入る）
#   - stream-json の作業記録を監査し、禁止の道具・質問の道具（ask_*）が 1 件でもあれば不合格（EXIT:4・VERDICT: NEEDS_FIX）
#   - 子の前後で作業ツリー・git の管理フォルダ・再利用の記録を比べ、変わっていれば不合格（EXIT:4）。
#     git の制御ファイル（.git・config・hooks など）が変わったら、git を 1 回も呼ばずに止める（EXIT:4）
#   - 本体 checkout（.git がフォルダ）では起動しない（専用の linked worktree が前提。run-gemini.sh と同じ）
#   - 子の git は通信（push・fetch）を止め（GIT_ALLOW_PROTOCOL）、任意のロックを取らない（GIT_OPTIONAL_LOCKS=0）。
#     管理フォルダは作業場所（cwd）から見つける（GIT_DIR / GIT_WORK_TREE は渡さない。scratch に写したコピーの中ではそのコピーを見る）
#   - 子（agy と端末のコマンド）が書けるのは、作業ツリー（前後の比較で不合格）と scratch の work/（--add-dir・LANES_SCRATCH・TMPDIR）だけ。
#     実行の記録の原本（scratch の record/）・子の git 用の gitconfig・設定の写しは scratch の直下に置き、子から書けない。
#     監査と判定は原本で行い、子の終了後にだけ logs/ へ写す（写せなければ合格を保存しない。EXIT:3・VERDICT: NONE）
#   - 子の git は最小の設定で動くので、commit の作者の照合は親が元の有効な設定で行い、一致・不一致の数だけを指示書に入れる
# 判定: agy は時間切れ（--print-timeout）や失敗でも終了コード 0 で {"event":"result","result":{"status":"ERROR",...}} を出すことがある。
#   result がちょうど 1 つで最後のイベント・status が SUCCESS・response が空でない文字列のときだけ、本文の最終行の VERDICT を読む。
#   それ以外（ERROR・空の応答・result が無い・JSON の破損）は VERDICT: NONE（EXIT:3）。エラーの本文からは VERDICT を拾わない。
#   CLEAN を保存するのは、必須検証の成功行（CHECKS:）か親の chk-run の記録の使い回しで成功を確かめたときだけ（無ければ NEEDS_FIX）
# 見張り（run-gemini.sh と同じ）: json / stderr が GEMINI_NOOUTPUT_SEC（既定 600）秒止まれば EXIT:8。idle のまま子が無ければ EXIT:3。
#   全体の上限は agy の --print-timeout（GEMINI_REVIEW_PRINT_TIMEOUT、無ければ GEMINI_PRINT_TIMEOUT、既定 75m。単位なしは秒）。
#   作業ツリーが変わっていない一時エラー（503 / UNAVAILABLE / interrupted）だけ 1 回やり直す（1 回目は <label>.try1.json / .try1.stderr.log）。
#   やり直しには、初回の開始から数えた残り時間だけを --print-timeout で渡す（残りが全体の 1 割未満ならやり直さない）
# 出力: <worktree>/logs/<label>.log（見張りの記録と本文）/ <label>.json（生。stream-json）/ <label>.stderr.log（この 3 つと try1 は record/ の原本の写し）
#       / <label>.prompt.md（実際に渡した全文。dry-run は <label>.dry-run.prompt.md）/ <label>.evidence.md（PR 貼り付け用）
#       / <label>.pid（起動時）/ <label>.done（終了時）/ .<系列>.review-state / <系列>.followups.md
#       scratch の直下には gemini-settings.json（渡した設定の写し）・子の git 用の gitconfig・record/（記録の原本）を置き、子が書ける work/ と分ける
# 最終行は必ず VERDICT: CLEAN | NEEDS_FIX | NONE。終了コード: 0 / 2=引数・前提 / 3=agy の異常・判定なし / 4=監査・変更の検出
#   / 5=logs/ の差し替え / 8=無出力で停止 / それ以外の非 0 = agy の終了コード
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
source "$LANES_DIR/review-dedup.zsh"
# git は作業場所から管理フォルダを見つける（呼び出し元の GIT_DIR などを使わない。子にも渡さない。外すものは chk-run.sh と同じ）
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

usage="使い方: run-gemini-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--allow-missing-checks] [--impl-engine claude|gemini|codex] [--dry-run]"
wt="${1:-}"; prompt="${2:-}"
[[ -n "$wt" && -n "$prompt" ]] || lanes_die "$usage"
shift 2
label=""; mode="auto"; base=""; dry=0; round=0; force=0; allow_missing=0; impl_engine=""
while (( $# )); do
  case "$1" in
    --mode) (( $# >= 2 )) || { lanes_defer_die "--mode に値が無い"; shift; continue; }; mode="$2"; shift 2 ;;
    --base) (( $# >= 2 )) || { lanes_defer_die "--base に値が無い"; shift; continue; }; base="$2"; shift 2 ;;
    --round) (( $# >= 2 )) || { lanes_defer_die "--round に値が無い"; shift; continue; }; round="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --force) force=1; shift ;;
    --allow-missing-checks) allow_missing=1; shift ;;
    --impl-engine) (( $# >= 2 )) || { lanes_defer_die "--impl-engine に値が無い"; shift; continue; }; [[ -z "$impl_engine" ]] || lanes_defer_die "--impl-engine が 2 回"; impl_engine="$2"; shift 2 ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || lanes_die "label が 2 回指定されている: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
wt="${wt:A}"; prompt="${prompt:A}"
[[ -n "$label" ]] || label="${prompt:t:r}"
# ここから排他を取るまでの誤り（--mode・--round・--base・見張りの設定の値など）は、取れれば今回の .done に残す
lanes_early_target "$wt" "$label" "$dry"
lanes_require_label "$label"
lanes_require_worktree "$wt"
[[ "$mode" == "auto" || "$mode" == "full" || "$mode" == "delta" ]] || lanes_die "--mode は auto|full|delta（渡されたのは '$mode'）"
[[ "$round" == <-> && ${#round} -le 6 ]] || lanes_die "--round は 0〜999999 の整数"
[[ -z "$impl_engine" || "$impl_engine" == claude || "$impl_engine" == gemini || "$impl_engine" == codex ]] \
  || lanes_die "--impl-engine は claude|gemini|codex（渡されたのは '$impl_engine'）"
# 比較起点はレビュー開始前に commit へ固定し、再利用判定にも含める。統合先の枝が無い repo（main だけの運用など）では --base を案内して止める
if [[ -n "$base" ]]; then
  base="$(git -C "$wt" rev-parse --verify --end-of-options "$base^{commit}" 2>/dev/null)" || lanes_die "--base を commit として解決できない: $base"
else
  base="$(git -C "$wt" rev-parse --verify --end-of-options "origin/${LANES_BASE_BRANCH:-develop}^{commit}" 2>/dev/null)" \
    || lanes_die "比較起点 origin/${LANES_BASE_BRANCH:-develop} が無い。その枝の無い repo では --base <sha|branch> を指定する（統合先は LANES_BASE_BRANCH で変えられる）"
fi
review_base="$base"
# 見張りの設定（run-gemini.sh と同じ名前。全体の上限だけ、レビュー用の GEMINI_REVIEW_PRINT_TIMEOUT で別に決められる）
print_timeout="${GEMINI_REVIEW_PRINT_TIMEOUT:-${GEMINI_PRINT_TIMEOUT:-75m}}"
idle_grace="${GEMINI_IDLE_GRACE:-60}"; resume_grace="${GEMINI_IDLE_RESUME_GRACE:-300}"; noout_sec="${GEMINI_NOOUTPUT_SEC:-600}"; poll="${GEMINI_POLL_SEC:-5}"
[[ "$idle_grace" == <-> && "$resume_grace" == <-> && "$noout_sec" == <-> && "$poll" == <-> ]] \
  && (( ${#idle_grace} <= 6 && ${#resume_grace} <= 6 && ${#noout_sec} <= 6 && ${#poll} <= 6 )) \
  || lanes_die "GEMINI_IDLE_GRACE / GEMINI_IDLE_RESUME_GRACE / GEMINI_NOOUTPUT_SEC / GEMINI_POLL_SEC は整数秒（6 桁まで）"
(( poll >= 1 )) || lanes_die "GEMINI_POLL_SEC は 1 以上"
[[ "$print_timeout" =~ '^[0-9]{1,7}(ms|s|m|h)?$' ]] || lanes_die "GEMINI_REVIEW_PRINT_TIMEOUT / GEMINI_PRINT_TIMEOUT の形が不正（例: 75m。数字は 7 桁まで）"
# 全体の上限を秒にする（自動のやり直しに、初回の開始からの残り時間だけを渡すため）。単位なしは秒として数える
case "$print_timeout" in
  *ms) pt_total=$(( (10#${print_timeout%ms} + 999) / 1000 )) ;;
  *h) pt_total=$(( 10#${print_timeout%h} * 3600 )) ;;
  *m) pt_total=$(( 10#${print_timeout%m} * 60 )) ;;
  *s) pt_total=$(( 10#${print_timeout%s} )) ;;
  *) pt_total=$(( 10#$print_timeout )) ;;
esac
(( pt_total >= 1 )) || lanes_die "GEMINI_REVIEW_PRINT_TIMEOUT / GEMINI_PRINT_TIMEOUT は 1 秒以上"
# 必須検証の使い回しの問い合わせ。指紋に環境変数が入るので、scratch や git の通信止めを export する前に、
# 親が chk-run.sh を回したのと同じ環境で呼ぶ。ランチャの記録（logs/ の直下の .pid・ログ・起動ログなど）は指紋に入らない
rvd_checks_query "$LANES_DIR" "$wt"
[[ "$RVD_CHECKS_REUSE" == yes ]] && LANES_REVIEW_CHECKS_REUSED=1 || LANES_REVIEW_CHECKS_REUSED=0
checks_key="$(rvd_checks_key)"

logdir="$wt/logs"
log="$logdir/$label.log"; json="$logdir/$label.json"; err="$logdir/$label.stderr.log"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
json1="$logdir/$label.try1.json"; err1="$logdir/$label.try1.stderr.log"
# 系列の記録（再利用の記録・後回し票・「使い回し禁止」の印）は label では名前が決まらないので、ランチャの記録の台帳へ名前で載せる
series="$(rvd_series "$label")"
# 親の chk-run の記録を使えないときは、子を起動せずに止める（LANES_REVIEW_REQUIRE_CHECKS=1 のとき。run-claude-review.sh と同じ）
if rvd_checks_block "$allow_missing"; then lanes_die "$RVD_CHECKS_BLOCK"; fi
(( dry )) || lanes_mark_start "$logdir" "$label" gemini-review "$wt" "file:.$series.review-state" "file:$series.followups.md" "file:.review-reuse-blocked"
lanes_require_tool gemini run-gemini-review.sh
# 同じ道具でのレビューの禁止（入口の run-review.sh と同じ判定 rvd_impl_gemini）。直接呼ばれても、前回の結果の再利用・子の起動より前に止める
# （再利用の記録・後回し票には触らない。今回の .done に EXIT:2 を残す）
if rvd_impl_gemini "$wt/logs" "$impl_engine"; then
  lanes_die "Gemini で実装したもの（--impl-engine gemini か logs/ の .pid の lane=gemini）は Gemini でレビューしない（同じ道具のレビューは独立性が無い）。run-review.sh で codex / claude に回す"
fi
lanes_entry_preflight
lanes_require_prompt "$prompt"
round="$(rvd_round "$logdir" "$series" "$label" "$round")"
[[ "$round" == <-> && ${#round} -le 6 ]] || lanes_die "round が不正"
record="$(rvd_prev_record "$logdir" "$series" "$round")"
prev_head="$(rvd_record_get "$record" head)"
prev_v="$(rvd_record_get "$record" verdict)"
requested_mode="$mode"
policy=early; (( round >= 3 )) && policy=followups
# 起動ごとの設定（agy の --settings）。再利用の条件に入れるので、再利用の判定より前に確定する。利用者の許可設定より deny が優先され、設定ファイルを変更しない。
# 拒否の固定の一覧 + GEMINI_REVIEW_DENY（カンマ区切り。空の項目は無視。制御文字・長すぎる項目は止める）
gem_settings="$("$LANES_PY" -I - "${GEMINI_REVIEW_DENY:-}" <<'PY'
import json, sys
BASE = ["mcp(*)", "write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit",
        "notebook_execution", "delete_knowledge", "generate_image", "invoke_subagent", "define_subagent", "manage_subagents",
        "browser_subagent", "open_browser_url", "read_url_content", "search_web", "schedule", "run_workflow"]
extra = []
for item in sys.argv[1].split(","):
    s = item.strip()
    if not s:
        continue
    if len(s) > 200 or any(ord(ch) < 32 or ord(ch) == 127 for ch in s):
        sys.exit(2)
    extra.append(s)
deny = list(dict.fromkeys(BASE + extra))
print(json.dumps({"permissions": {"deny": deny}, "allowNonWorkspaceAccess": False, "enableTerminalSandbox": True,
                  "modelProvider": "", "useG1Credits": False}, ensure_ascii=False, separators=(",", ":")))
PY
)" || lanes_die "GEMINI_REVIEW_DENY に使えない値がある（カンマ区切りの道具の名前だけ。改行などの制御文字・200 文字を超える項目は書けない）"
deny_n="$(print -r -- "$gem_settings" | "$LANES_PY" -I -c 'import json, sys; print(len(json.load(sys.stdin)["permissions"]["deny"]))')"
# 再利用の条件（指示・起点・設定・検証の設定・必須検証の使い回し・レビュー役・実際に渡す設定（拒否の一覧））。
# 変わったら同じ HEAD でも省略しない（review-dedup.zsh の rvd_context）
review_context() { rvd_context "$LANES_DIR" "$prompt" "$review_base" "$requested_mode" "$policy" "${GEMINI_MODEL:-}" "${GEMINI_EFFORT:-}" "$wt" "$checks_key" gemini "$gem_settings"; }
context="$(review_context)"
tree="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
decided="$(rvd_decide_mode "$wt" "$prev_head" "$prev_v" "$context" "$(rvd_record_get "$record" context)" "$tree" "$(rvd_record_get "$record" tree)")"
# 前のレビューで再利用の記録を戻しきれなかった印があれば、どの系列でも前回の記録を使わない（毎回 full。--mode delta も full にする）
if rvd_reuse_blocked "$logdir"; then
  decided=full
  print -u2 -- "注意: logs/.review-reuse-blocked がある（前のレビューで再利用の記録を戻しきれなかった）。前回の記録を使わず full でレビューする。logs/.*.review-state を確かめてから印を消す"
fi
skip_same=0
case "$mode:$decided" in
  auto:delta|delta:delta) mode=delta; base="$prev_head" ;;
  *:same) mode=full; (( force )) || skip_same=1 ;;
  *) mode=full ;;   # 明示の delta も、前回の記録が使えなければ（初回・条件変更・未保存変更）全体を見る。前回 NEEDS_FIX は下で決め直す
esac
unresolved_note=""
if [[ "$prev_v" == 'VERDICT: NEEDS_FIX' ]]; then
  # 未解決のある系列も、2 回目からは前回レビューした HEAD からの差分だけを見る（前回の指摘は全件引き継ぐ）。
  # 明示の --mode full・再利用の記録を戻しきれなかった印・旧記録・同じ HEAD・未保存変更・起点の変更のときは全体を見る。
  skip_same=0
  [[ -n "$(rvd_record_get "$record" report)" ]] || lanes_die "前回の未解決指摘本文が無い。復元してから再レビューする"
  if [[ "$requested_mode" != full ]] && ! rvd_reuse_blocked "$logdir" \
     && [[ "$(rvd_fix_mode "$wt" "$prev_head" "$tree" "$(rvd_record_get "$record" tree)" "$review_base" "$(rvd_record_get "$record" base)" gemini "$(rvd_record_reviewer "$record")")" == delta ]]; then
    mode=delta; base="$prev_head"
  else
    mode=full; base="$review_base"
  fi
  unresolved_note="$(rvd_unresolved_note "$record" "$round")"
fi

if (( skip_same )); then
  if (( dry )); then
    print -- "[dry-run] series=$series round=$round prev_head=${prev_head:0:12} → 同じ head をもう一度レビューしない（前回 $prev_v を使う。回すなら --force）"
    exit 0
  fi
  for f in "$log" "$json" "$err" "$evidence"; do lanes_rotate_log "$f"; done
  [[ "$(rvd_snapshot "$wt")" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "省略判定中に内容・指示が変化した。再実行する"
  {
    print -- "## Gemini レビュー証跡（$label）"
    print -- "- $prev_v"
    print -- "- 対象: $(lanes_git_summary "$wt")"
    print -- "- モード: skip-same-head（前回 round と同じ head ${prev_head:0:12}。レビューしていない）/ round=$round"
    rvd_checks_evidence skip
    print -- "- 実行: $(lanes_now) / 約 0 分 / EXIT:0"
    print -- "- HEAD: ${prev_head:0:12} → ${prev_head:0:12} / 作業ツリー差分行 0"
  } > "$evidence"
  { cat "$evidence"; print -- "EXIT:0"; print -- "$prev_v"; } > "$log"
  cat "$evidence"
  lanes_mark_done 0 "$prev_v" "skip-same-head round=$round"
  exit 0
fi
if (( dry )); then
  final="$logdir/$label.dry-run.prompt.md"
else
  for f in "$log" "$json" "$err" "$evidence" "$final" "$json1" "$err1"; do lanes_rotate_log "$f"; done
fi
mkdir -p "$logdir"
(( ! dry )) || lanes_records_claim "$logdir" "label:$label"   # dry-run が書く <label>.dry-run.prompt.md も、書く前にランチャの記録の台帳へ載せる
# レーン専用の作業場所（scratch）。マージ後 cleanup が消す。子に渡すのは中の work/ だけ（--add-dir・LANES_SCRATCH・TMPDIR）。
# 記録の原本の record/・gitconfig・設定の写しは scratch の直下に置き、子から書けないようにする
if (( dry )); then scratch="$(lanes_scratch_path "$wt" "$label")"; else lanes_scratch_prepare "$wt" "$label" gemini-review; scratch="$LANES_SCRATCH"; fi
work="$scratch/work"; rec="$scratch/record"
plog="$rec/$label.log"; pjson="$rec/$label.json"; perr="$rec/$label.stderr.log"; pjson1="$rec/$label.try1.json"; perr1="$rec/$label.try1.stderr.log"

lanes_check_gemini_subscription
# --sandbox が無効になる環境では走らせない。対象は Mac の端末サンドボックス（run-gemini.sh と同じ確かめ）
[[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] || lanes_die "端末サンドボックスを強制できない環境 → 起動禁止"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny file-write*)' /usr/bin/true 2>/dev/null \
  || lanes_die "端末サンドボックスを有効にできない → 起動禁止"
# 読み取り専用に要るオプション（サンドボックス・起動ごとの設定・plan モード）が無い agy では走らせない
# オプション名は語単位の完全一致で見る（--model だけのヘルプで --mode を通さない）
gem_help="$(ANTIGRAVITY_HEADLESS=true "$GEMINI_BIN" --help < /dev/null 2>&1)" || lanes_die "agy --help の確認に失敗"
typeset -a gem_opts; gem_opts=(${=${gem_help//[^A-Za-z0-9_-]/ }})
for option in --sandbox --settings --mode; do
  (( ${gem_opts[(Ie)$option]} )) || lanes_die "agy が $option に未対応 → 起動禁止（読み取り専用にできない）"
done
unset gem_help gem_opts

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir)" || lanes_die "git の管理フォルダを確かめられない: $wt"
gitcommon="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" || lanes_die "git の管理フォルダを確かめられない: $wt"
# サンドボックス内の agy が .git/hooks や設定を書き換えると、ランチャがサンドボックスの外で走らせる git から実行されうる。
# 管理領域が作業場所・scratch の外にある linked worktree に限る（run-gemini.sh と同じ）
gitlink="$wt/.git"
[[ -f "$gitlink" && ! -L "$gitlink" ]] || lanes_die "本体 checkout（.git がディレクトリ）またはリンクの .git では起動しない。git worktree add で専用 worktree を作ってから渡す"
for gd in "$gitdir" "$gitcommon"; do
  [[ "${gd:A}/" != "${wt:A}/"* && "${gd:A}/" != "${scratch:A}/"* ]] || lanes_die "Git 管理領域が worktree / scratch の中にある → 起動禁止: $gd"
done
# scratch が worktree の中にあると、子が記録の原本（record/）を書き換えられる
[[ "${scratch:A}/" != "${wt:A}/"* ]] || lanes_die "scratch が worktree の中にある → 起動禁止（記録の原本を子から守れない。LANES_SCRATCH_ROOT を worktree の外にする）: $scratch"

template="$LANES_DIR/templates/claude-review-$mode.md"
[[ -s "$template" ]] || lanes_die "テンプレが無い: $template"
focus="$LANES_DIR/templates/codex-review-focus.md"
[[ -s "$focus" ]] || lanes_die "レビューの出し方のテンプレが無い: $focus"
delta_note=""
[[ "$mode" == "delta" ]] && delta_note="$(rvd_delta_note "$wt" "$base" "$round" "$review_base")"
scratch_rule="$(lanes_scratch_rule "$work")"
# 子の git は最小の設定（GIT_CONFIG_GLOBAL）で動くので、利用者の共通設定にある作者名・メールは子から見えない。
# 親が元の有効な設定で、レビューの範囲（比較起点..HEAD）の commit の作者を照合し、一致・不一致の数だけを指示書に入れる（値は渡さない）
gem_author_note() {   # <比較起点> → 指示書に足す文
  local from="$1" name="" email="" out="" row n=0 bad=0
  name="$(git -C "$wt" config user.name 2>/dev/null)" || name=""
  email="$(git -C "$wt" config user.email 2>/dev/null)" || email=""
  print -r -- "# commit の作者の照合（ランチャが元の git の設定で確かめた結果）"
  print -r -- "- このレビューの中の git は最小の設定で動くので、git config user.name / user.email は空になる。作者の照合はこの結果を使う（値はここに書かない）。"
  if [[ -z "$name" || -z "$email" ]]; then
    print -r -- "- 対象リポの有効な git の設定に user.name か user.email が無く、ランチャは照合できなかった。照合できないことを指摘に書く。"
    return 0
  fi
  if ! out="$(git -C "$wt" log -z --format='%an%x1f%ae' "$from..HEAD" 2>/dev/null)"; then
    print -r -- "- commit の一覧を読めず、ランチャは照合できなかった。照合できないことを指摘に書く。"
    return 0
  fi
  for row in "${(@0)out}"; do
    [[ -n "$row" ]] || continue
    n=$(( n + 1 ))
    [[ "${row%%$'\x1f'*}" == "$name" && "${row#*$'\x1f'}" == "$email" ]] || bad=$(( bad + 1 ))
  done
  if (( n == 0 )); then
    print -r -- "- 範囲（${from:0:12}..HEAD）に commit が無い。"
  elif (( bad == 0 )); then
    print -r -- "- 範囲（${from:0:12}..HEAD）の commit ${n} 件の作者は、すべて対象リポの有効な git の設定（user.name / user.email）と一致した。"
  else
    print -r -- "- 範囲（${from:0:12}..HEAD）の commit ${n} 件のうち ${bad} 件の作者が、対象リポの有効な git の設定（user.name / user.email）と一致しない。git log --format='%h %an <%ae>' で該当の commit を確かめ、指摘に書く。"
  fi
}
author_note="$(gem_author_note "$base")"

# テンプレ（役名だけ Gemini に読み替え）+ 置き場所 + 読み取り専用の約束 + 案件固有の指示 + レビューの出し方（Codex と同じ観点）
# + ランチャの追記（delta の説明・前回の未解決指摘・受け入れ済みの限界・必須検証のきまり）を結合して、実際に渡した全文を残す
# 書き込みは logs/ を symlink を辿らずに開き、その中に新しいファイルを作ってから名前を置き換える（dry-run でも、既存の名前が
# リンクならその先を書き換えない）
LANES_ACCEPTED_NOTE="$(rvd_accepted_note "$wt")" "$LANES_PY" -I - "$template" "$prompt" "$final" "$wt" "$branch" "$head" "$base" "$mode" "$(lanes_now)" \
    "$work" "$scratch_rule" "$(rvd_checks_rule)" "$focus" "$delta_note" "$unresolved_note" "$author_note" <<'PY' || lanes_die "結合したプロンプトを書けない（logs/ が symlink・書けない など）: $final"
import os, sys, pathlib
(tpl, case, out, wt, branch, head, base, mode, date, scratch, rule, checks_rule, focus, delta_note, unresolved, author) = sys.argv[1:17]
t = pathlib.Path(tpl).read_text(encoding="utf-8")
for k, v in {"WORKTREE": wt, "BRANCH": branch, "HEAD": head, "BASE": base, "MODE": mode, "DATE": date, "SCRATCH": scratch}.items():
    t = t.replace("{{" + k + "}}", v)
# 役名だけ Gemini に読み替え（Claude レビュー用のテンプレを流用。run-codex-review.sh と同じやり方）
t = t.replace("Claude", "Gemini")
case_text = pathlib.Path(case).read_text(encoding="utf-8")
focus_text = pathlib.Path(focus).read_text(encoding="utf-8")
readonly = "\n".join([
    "# Gemini レビューの約束（ランチャが実行の記録で確かめる）",
    "- このレビューは読み取り専用（plan モード・端末サンドボックス）。ファイルを書く・置き換える・消す道具、MCP、サブエージェント、ブラウザ、Web の検索・取得、予約・ワークフローの道具は使わない。1 回でも使うと、本文に関係なく不合格になる。",
    "- 質問・承認の道具（名前が ask_ で始まるもの）は使わない（非対話なので答える人がいない。使うと不合格）。分からない点は前提を書いたうえで指摘に含める。",
    "- 端末のコマンドは読む・確かめるためだけに使う（git diff / git log / git show / 該当テスト 1 本など）。作業ツリーと git の管理フォルダを書き換えない（前後の比較で不合格になる）。一時ファイルは $LANES_SCRATCH の下だけに置く。",
])
extra = [p.rstrip() for p in (delta_note, unresolved, os.environ.get("LANES_ACCEPTED_NOTE", ""), author) if p.strip()]
crule = checks_rule.rstrip()
extra.append(crule if crule.startswith("#") else "# 必須検証の成功行\n- " + crule)
build = ("build はレビューでは回さない（統合先（LANES_BASE_BRANCH。今は " + (os.environ.get("LANES_BASE_BRANCH") or "develop")
         + "）に入れる直前の最終 head の chk-run と CI で 1 回だけ担保する）。")
body = (t.rstrip() + "\n\n" + rule.rstrip() + "\n\n" + readonly
        + "\n\n---\n\n# 案件固有の指示（司令塔が記入）\n\n" + case_text.rstrip()
        + "\n\n---\n\n" + focus_text.rstrip() + "\n\n" + "\n\n".join(extra) + "\n\n" + build
        + "\n\n最終行は次のいずれか 1 行だけ:\nVERDICT: CLEAN\nVERDICT: NEEDS_FIX\n")
d, name = os.path.split(out)
dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
tmp = f".{name}.{os.getpid()}.{os.urandom(6).hex()}.tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=dfd)
try:
    with os.fdopen(fd, "wb") as f:
        f.write(body.encode("utf-8"))
    os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
except BaseException:
    try:
        os.unlink(tmp, dir_fd=dfd)
    except OSError:
        pass
    raise
PY
# プロンプトは agy の引数で渡す（-p）。引数の長さの上限（macOS は環境変数と合わせて約 1MB）に当たる前に止める
prompt_bytes=$(wc -c < "$final" | tr -d ' ')
[[ "$prompt_bytes" == <-> ]] && (( prompt_bytes <= 800000 )) \
  || lanes_die "結合したプロンプトが大きすぎて agy の引数に渡せない（${prompt_bytes} bytes。前回の指摘本文が大きいなら --mode full --force でやり直す）: $final"

settings_copy="$scratch/gemini-settings.json"
if (( ! dry )); then lanes_fresh_file "$settings_copy"; print -r -- "$gem_settings" > "$settings_copy"; fi
# 環境変数の effort が設定ファイルと違う値で勝っていたら知らせる（渡す値は変えない）
lanes_effort_override_note GEMINI_EFFORT
cmd=("$GEMINI_BIN" --sandbox --settings "$gem_settings" --mode plan)
if [[ -n "$GEMINI_MODEL" ]]; then cmd+=(--model "$GEMINI_MODEL"); fi
if [[ -n "$GEMINI_EFFORT" ]]; then cmd+=(--effort "$GEMINI_EFFORT"); fi
cmd+=(--output-format stream-json)   # 続けて run_agy_once が --print-timeout（残り時間）・--add-dir（work/）・-p（指示書）を付ける
if (( dry )); then
  print -- "[dry-run] series=$series round=$round mode=$mode base=$base prev_head=${prev_head:0:12}（判定 $decided）/ 必須検証の使い回し: $RVD_CHECKS_REUSE"
  print -- "[dry-run] scratch: $scratch（子が書けるのは work/ だけ: TMPDIR / LANES_SCRATCH / --add-dir。記録の原本は record/）/ 拒否の一覧 ${deny_n} 件"
  print -- "[dry-run] cd ${(q)wt} && ANTIGRAVITY_HEADLESS=true LANES_SCRATCH=${(q)work} TMPDIR=${(q)work}/ GIT_CONFIG_GLOBAL=${(q)scratch}/gitconfig GIT_OPTIONAL_LOCKS=0 ${(q)cmd[@]} --print-timeout $print_timeout --add-dir ${(q)work} -p \"\$(<${(q)final})\" < /dev/null > ${(q)pjson} 2> ${(q)perr}"
  print -- "[dry-run] 見張り: idle（root agent idle）の後 子が無く json が ${idle_grace} 秒動かなければ止める / 出力 ${noout_sec} 秒なしで EXIT:8 / --print-timeout $print_timeout / 確認間隔 ${poll} 秒"
  print -- "[dry-run] 結合済みプロンプト: $final"
  exit 0
fi

# 子が書ける work/ は前回の中身を残してよいが、フォルダでない物（前の子が置いたリンクなど）なら作り直す。
# 記録の原本の record/ は毎回空から作る（前の子が中に置いた物を使わない）。どちらも子の起動前なので、消してから作れば安全
if [[ ! -d "$work" || -L "$work" ]]; then lanes_fresh_file "$work"; mkdir -- "$work" || lanes_die "scratch の work/ を作れない: $work"; fi
rm -rf -- "$rec" 2>/dev/null || true
mkdir -m 700 -- "$rec" 2>/dev/null || lanes_die "記録の原本の置き場所（scratch の record/）を作れない: $rec"
# サンドボックス内の git 用の最小 gitconfig（利用者の設定を読ませない。秘密は入れない）
lanes_fresh_file "$scratch/gitconfig"
{ print -- "[core]"; print -- "\tpager = cat"; print -- "[safe]"; print -- "\tdirectory = *"; } > "$scratch/gitconfig"

# ---- 子プロセスの記録と停止（run-gemini.sh と同じ）----
# 無出力の監視用に、監督役と agy の子孫を pid・pgid・lstart で数える。停止対象の同一性確認と回収は共通監督役が行う。
typeset -gA GEM_TRACK PSL PSPP PSPG
typeset -g GEM_PGID="" GEM_ROOT_LS=""
gem_ps_snapshot() {   # 全プロセスの ppid / pgid / lstart を 1 回の ps で取る（引数・環境は読まない）。呼び出し元のシェルで実行する
  local line psout
  local -a w
  psout="$(LC_ALL=C TZ=UTC ps -axo pid=,ppid=,pgid=,lstart= 2>/dev/null)" || return 1
  [[ -n "$psout" ]] || return 1
  PSL=(); PSPP=(); PSPG=()
  for line in ${(f)psout}; do
    w=(${=line})
    (( ${#w} >= 4 )) || continue
    [[ "$w[1]" == <-> && "$w[2]" == <-> && "$w[3]" == <-> ]] || continue
    PSPP[$w[1]]="$w[2]"; PSPG[$w[1]]="$w[3]"; PSL[$w[1]]="${(j: :)w[4,-1]}"
  done
  return 0
}
gem_track_tree() {   # 根（監督役）が起動時と同じプロセスのときだけ子孫を GEM_TRACK に足す。死んだ・別物になった記録は外す
  local root="${GEM_PGID:-}" p
  local -A kids
  local -a queue
  gem_ps_snapshot || return 0
  for p in ${(k)GEM_TRACK}; do
    if [[ "${PSL[$p]:-}" != "${GEM_TRACK[$p]}" ]]; then unset "GEM_TRACK[$p]"; fi
  done
  [[ -n "$root" && -n "$GEM_ROOT_LS" && "${PSL[$root]:-}" == "$GEM_ROOT_LS" ]] || return 0
  gem_adopt_group
  for p in ${(k)PSPP}; do kids[${PSPP[$p]}]="${kids[${PSPP[$p]}]:-} $p"; done
  queue=($root)
  while (( ${#queue} )); do
    p="${queue[1]}"; shift queue
    if [[ -n "${PSL[$p]:-}" && "$p" != "$$" ]]; then
      GEM_TRACK[$p]="${PSL[$p]}"
    fi
    queue+=(${=kids[$p]:-})
  done
  return 0
}
gem_adopt_group() {   # 監督役の集団の今のメンバーを記録する。根の同一性を確認した直後だけ呼ぶ
  local p
  [[ -n "${GEM_PGID:-}" && "$GEM_PGID" != "${PSPG[$$]:-y}" ]] || return 0
  for p in ${(k)PSPG}; do
    if [[ "${PSPG[$p]}" == "$GEM_PGID" && "$p" != "$$" && -n "${PSL[$p]:-}" ]]; then GEM_TRACK[$p]="${PSL[$p]}"; fi
  done
  return 0
}
mtime_of() { local m; m="$(stat -f %m "$1" 2>/dev/null)" || m=0; print -- "${m:-0}"; }
# 状態の確認（lanes-status.sh の最終出力）用の、logs/ の json・stderr の写し。原本に増えた分だけを、子の起動前に開いた番号（fd）へ足す。
# 子が logs/ の名前を差し替えても、開いた元のファイルに書くだけで外へは届かない。写しは見るためだけで、監査・判定には使わない
# （子の終了後に gem_publish が原本で置き換える）
zmodload zsh/system 2>/dev/null || true
gem_mirror() {
  while sysread -i "$GEM_JR" -o "$GEM_JM" -s 65536; do :; done
  while sysread -i "$GEM_ER" -o "$GEM_EM" -s 65536; do :; done
  return 0
}
idle_count() { local n; n="$(grep -c 'root agent idle' "$1" 2>/dev/null)" || n=0; print -- "${n:-0}"; }

# agy を 1 回走らせて見張る。<json> <stderr> <--print-timeout に渡す値>。結果: GEM_RC / GEM_IDLE_KILLED / GEM_NOOUT / GEM_SECS
# 出力の受け先（json・stderr）と見張りの記録（plog）は、子から書けない scratch の record/ にある（logs/ へは子の終了後に写す）。
# 子の書ける場所は work/（LANES_SCRATCH・TMPDIR・--add-dir）。git は作業場所（cwd）から管理フォルダを見つける（GIT_DIR は渡さない）
run_agy_once() {
  local j="$1" e="$2" to="$3" now last m idle_at=0 idle_seen=0 n ta grace=$idle_grace
  GEM_RC=0; GEM_IDLE_KILLED=0; GEM_NOOUT=0; ta=$(date +%s)
  lanes_logdir_check
  # 原本を作ってから、読む番号と logs/ の写しの番号を開く（子はまだいない。logs/ に symlink などが無いことは直前に確かめた）
  : > "$j"; : > "$e"
  lanes_fresh_file "$logdir/${j:t}"; lanes_fresh_file "$logdir/${e:t}"
  exec {GEM_JR}<"$j" {GEM_ER}<"$e" {GEM_JM}>"$logdir/${j:t}" {GEM_EM}>"$logdir/${e:t}"
  ANTIGRAVITY_HEADLESS=true LANES_SCRATCH="$work" TMPDIR="$work/" GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat \
    lanes_start_child "${cmd[@]}" --print-timeout "$to" --add-dir "$work" -p "$(<"$final")" < /dev/null > "$j" 2> "$e"
  GEM_PGID="$LANES_CHILD"; GEM_TRACK=()
  GEM_ROOT_LS="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$LANES_CHILD" 2>/dev/null)" || GEM_ROOT_LS=""
  GEM_ROOT_LS="${(j: :)${=GEM_ROOT_LS}}"
  last=$ta
  while kill -0 "$LANES_CHILD" 2>/dev/null; do
    sleep "$poll"
    kill -0 "$LANES_CHILD" 2>/dev/null || break
    gem_track_tree
    gem_mirror
    now=$(date +%s)
    m="$(mtime_of "$j")"; if (( m > last )); then last=$m; fi
    m="$(mtime_of "$e")"; if (( m > last )); then last=$m; fi
    n="$(idle_count "$e")"
    if (( n > idle_seen )); then
      idle_seen=$n; idle_at=$now; grace=$idle_grace
      print -- "[見張り] $(lanes_now) agy が idle（裏の作業待ち）。子の処理が無く、json が ${idle_grace} 秒動かなければ止める" >> "$plog"
    fi
    if (( idle_at > 0 )); then
      m="$(mtime_of "$j")"
      if (( m > idle_at )); then
        # json が動いた（裏の作業の出力か、agy が続きを始めた）→ 見張りは解除せず時計だけ戻す。動いた後の猶予は長め
        idle_at=$now; if (( grace < resume_grace )); then grace=$resume_grace; fi
      elif (( now - idle_at >= grace && ${#GEM_TRACK} <= 2 )); then
        # テスト等の子が動いている間は idle だけで止めない。全体の時間上限と無出力の見張りは維持
        GEM_IDLE_KILLED=1
        print -- "[見張り] $(lanes_now) idle のまま ${grace} 秒 → 止めた（EXIT:3）" >> "$plog"
        break
      fi
    fi
    if (( now - last >= noout_sec )); then
      GEM_NOOUT=1
      print -- "[見張り] $(lanes_now) json / stderr が ${noout_sec} 秒更新なし → 止めた（EXIT:8）" >> "$plog"
      break
    fi
  done
  # 回収を確かめられなければ（監督役が残る）ここで止まる（終了の処理が「子の回収未確認」として .done を書く。run-gemini.sh と同じ）
  if (( GEM_IDLE_KILLED || GEM_NOOUT )); then lanes_kill_child; fi
  wait "$LANES_CHILD" 2>/dev/null || GEM_RC=$?
  gem_mirror
  exec {GEM_JR}<&- {GEM_ER}<&- {GEM_JM}>&- {GEM_EM}>&-
  lanes_logdir_check
  # 監督役の終了は子孫の回収完了を意味する。終了後に集団番号を再利用しない
  LANES_CHILD=""; GEM_PGID=""
  GEM_SECS=$(( $(date +%s) - ta ))
  return 0
}

# 記録の原本（record/ の log・json・stderr・try1）を logs/ へ写す。子（と孫）の回収が済んでから呼ぶ。
# 写し先に前からある物（子が実行中に置いたファイル・フォルダなど）は消してから新しく作る。1 つでも写せなければ 1 を返す
gem_publish() {
  local name ok=0
  lanes_logdir_intact || return 1
  for name in "$label.log" "$label.json" "$label.stderr.log" "$label.try1.json" "$label.try1.stderr.log"; do
    [[ -f "$rec/$name" ]] || continue
    rm -f -- "$logdir/$name" 2>/dev/null || true
    if [[ -e "$logdir/$name" || -L "$logdir/$name" ]] || ! cp -- "$rec/$name" "$logdir/$name" 2>/dev/null; then
      print -u2 -- "→ 記録を logs/ へ写せない: $name（原本: $rec/$name）"
      ok=1
    fi
  done
  return $ok
}

# 子の後に毎回呼ぶ（git を 1 回も呼ぶ前）。
# 1. 再利用の記録（logs/.<series>.review-state）は worktree の中にあり、サンドボックスの子でも書ける。偽の CLEAN を書かれたまま
#    子が失敗すると記録が上書きされず、次の --mode auto が「同じ HEAD なので省略」で偽の CLEAN を使い得る。子の前の中身へ戻す
#    （run-claude-review.sh・run-codex-review.sh と同じ。1 = 変わっていたので戻した / 2 = 戻しきれなかった → states_rc に大きい方を残す）
# 2. git の制御ファイル（worktree の .git・gitdir の commondir など・共通の config・hooks）の指紋を比べ、変わっていたら git を呼ばずに止める
states_rc=0
gem_after_child() {
  local src=0 now
  print -r -- "$states_before" | rvd_states_restore "$logdir" || src=$?
  if (( blocked_before )) && ! rvd_reuse_blocked "$logdir"; then
    print -u2 -- "→ Gemini レビューの実行中に「使い回し禁止」の印が消された。置き直して不合格（NEEDS_FIX）にする"
    (( src != 0 )) || src=1
  fi
  if (( src == 2 )) || { (( blocked_before )) && ! rvd_reuse_blocked "$logdir"; }; then
    rvd_mark_blocked "$logdir" || print -u2 -- "→ 「使い回し禁止」の印を置けない。logs/ と ${XDG_STATE_HOME:-~/.local/state}/lanewright/ の権限を確かめる。次のレビューは --mode full --force で回す"
  fi
  if (( src > states_rc )); then states_rc=$src; fi
  now="$(lanes_git_ctl_fingerprint "$wt" "$gitdir" "$gitcommon" 2>/dev/null)" || now=ERROR
  [[ "$now" != "$git_fp_before" ]] || return 0
  {
    print -- "[見張り] $(lanes_now) git の制御ファイル（.git・commondir・gitdir・config・config.worktree・hooks）が変わった → git を実行せず停止"
    print -- "EXIT:4"
    print -- "VERDICT: NEEDS_FIX"
  } >> "$plog"
  gem_publish || true
  print -u2 -- "→ Gemini レビューの実行中に git の制御ファイルが変わった。git を実行せず停止（EXIT:4）。$wt/.git と $gitdir・$gitcommon の中身を手で確かめてから直す"
  lanes_mark_done 4 "VERDICT: NEEDS_FIX" "git の制御ファイルの変更を検出（git 未実行）"
  exit 4
}

# 実行の記録（stream-json）の監査と本文の取り出し。<check|write> <json>...（再実行したときは 1 回目と 2 回目の両方）
# 要約を AUDIT_OUT（key=value の行）に入れる。終了コード: 0 = 最後の結果が SUCCESS で本文あり / 3 = それ以外（ERROR・空・欠落・破損）
# write のときは、ログに本文を足す（本文が使えないときは理由だけ足し、エラーの本文は字下げしてコード扱いにする＝VERDICT を拾わせない）
gem_audit() {
  local m="$1" out="" rc=0; shift
  out="$("$LANES_PY" -I - "$plog" "$m" "$gem_settings" "$@" <<'PY'
import json, re, sys
log, mode, settings, *srcs = sys.argv[1:]
FORBIDDEN = {"write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit",
             "notebook_execution", "delete_knowledge", "generate_image", "call_mcp_tool", "invoke_subagent",
             "define_subagent", "manage_subagents", "browser_subagent", "open_browser_url", "read_url_content",
             "search_web", "schedule", "run_workflow"}
try:
    for d in json.loads(settings)["permissions"]["deny"]:
        if isinstance(d, str) and "(" not in d:
            FORBIDDEN.add(d.strip().lower())
except (ValueError, KeyError, TypeError):
    pass
# 名前から書き込みと分かる道具も、読み取り専用のレビューでは禁止として数える（迷ったら不合格の側）
WRITE_HINT = ("write", "replace", "edit", "delete", "move", "rename", "create", "append", "copy", "patch")
def forbidden(name):
    n = name.lower()
    return (n in FORBIDDEN or n.startswith(("browser_", "mcp")) or "_mcp" in n or any(h in n for h in WRITE_HINT))
def safe(name):
    return re.sub(r"[^A-Za-z0-9_.:*()-]", "?", name)[:60]
asks, events = 0, 0
violations, invalid = [], []
status, response, error, turns = "NONE", "", "", 0
for idx, src in enumerate(srcs):
    last_src = idx == len(srcs) - 1
    try:
        with open(src, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeError):
        invalid.append("記録を読めない"); continue
    if not lines:
        invalid.append("記録が空"); continue
    results, last_event = 0, None
    for line in lines:
        try:
            d = json.loads(line)
        except ValueError:
            invalid.append("JSON の不正行"); continue
        if not isinstance(d, dict) or not isinstance(d.get("event"), str):
            invalid.append("イベントの形式が不正"); continue
        events += 1
        last_event = d["event"]
        if d["event"] == "result":
            results += 1
            r = d.get("result")
            if not isinstance(r, dict) or not isinstance(r.get("status"), str):
                invalid.append("結果の形式が不正"); continue
            if last_src:
                status = r["status"]
                resp, er, t = r.get("response", ""), r.get("error", ""), r.get("num_turns", 0)
                if not isinstance(resp, str):
                    invalid.append("結果の本文の形式が不正"); resp = ""
                response, error = resp, (er if isinstance(er, str) else "")
                turns = t if type(t) is int else 0
            continue
        if d["event"] != "step_update":
            continue
        su = d.get("step_update")
        if not isinstance(su, dict) or not isinstance(su.get("step_type"), str):
            violations.append("作業記録の形式が不正"); continue
        if su["step_type"] != "tool":
            continue
        name = su.get("tool_name")
        if not isinstance(name, str) or not name.strip():
            violations.append("名前の無い道具"); continue
        if name.startswith("ask_"):
            asks += 1
        elif forbidden(name):
            violations.append(safe(name))
    if results > 1 or (results == 1 and last_event != "result"):
        invalid.append("結果が重複、または最後のイベントではない")
    if last_src and results == 0:
        invalid.append("終了の結果（result）が無い")
ok = not invalid and status == "SUCCESS" and response.strip() != ""
if mode == "write":
    meta = f"[meta] status={safe(status)} turns={turns} events={events} ask_tools={asks} forbidden_tools={len(violations)} invalid={len(invalid)}\n"
    with open(log, "a", encoding="utf-8") as f:
        f.write("----\n" + meta)
        if ok:
            f.write("\n" + response.rstrip() + "\n")
        else:
            why = "・".join(dict.fromkeys(invalid)) or (f"status={safe(status)}" if status != "SUCCESS" else "応答が空")
            f.write(f"[meta] agy が正常に終わっていない（{why}）ため VERDICT は採用しない\n")
            text = response if response.strip() else error
            if text.strip():
                f.write("\n" + "\n".join("    " + l for l in text.rstrip().splitlines()) + "\n")
print(f"status={safe(status)}")
print(f"asks={asks}")
print(f"violations={len(violations)}")
print("violation_names=" + ",".join(list(dict.fromkeys(violations))[:5]))
print(f"invalid={len(invalid)}")
print("invalid_reasons=" + "・".join(list(dict.fromkeys(invalid))[:3]))
print("error=" + " ".join(error.split())[:200])
sys.exit(0 if ok else 3)
PY
)" || rc=$?
  typeset -g AUDIT_OUT="$out"
  return $rc
}
audit_get() { local -a hit; hit=(${(M)${(f)AUDIT_OUT}:#$1=*}); print -r -- "${${hit[1]:-}#$1=}"; }

cd "$wt"
snapshot_before="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
[[ "$snapshot_before" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "起動準備中に内容・指示が変化した。再実行する"
# git の制御ファイルの指紋（子の後は git を呼ぶ前にこれだけで比べる）と、設定・hooks・タグ・stash の指紋（rvd_git_guard）
git_fp_before="$(lanes_git_ctl_fingerprint "$wt" "$gitdir" "$gitcommon")" || lanes_die "起動前の git 制御ファイルの確認に失敗"
guard_before="$(rvd_git_guard "$wt")" || lanes_die "レビュー前の git 管理フォルダの確認に失敗"
# 今の系列だけでなく、logs/ にある全部の系列の再利用の記録を覚える（別の系列の記録に偽の CLEAN を作られても戻す）
states_before="$(rvd_states_snapshot "$logdir")" || lanes_die "レビュー前の再利用の記録の確認に失敗"
# 「使い回し禁止」の印の有無も覚える（子が印を消したら改ざんとして扱う）
blocked_before=0; rvd_reuse_blocked "$logdir" && blocked_before=1
started="$(lanes_now)"; t0=$(date +%s)
# 見張りの記録の頭（原本の record/ に書く。本文は子の後に足す。ここには判定に紛れる語（VERDICT・指摘の印など）を書かない）
{ print -- "# Gemini の実行記録（$label）"; print -- "started: $started"; } > "$plog"

# レビューの子から push（と fetch）をできなくする（読み取り専用の役。git の通信は要らない）
lanes_block_git_transport
retried=0
run_agy_once "$pjson" "$perr" "$print_timeout"
gem_after_child
first_rc=0; gem_audit check "$pjson" || first_rc=$?
# 1 回だけの自動再実行: 見張りで止めていない・最後の結果が SUCCESS でない・監査に引っかかっていない・記録の形が正しい・
# 全体の上限の残り（初回の開始から数える）が 1 割以上ある・作業ツリーが変わっていない・一時的なエラー（503 / UNAVAILABLE / stream interrupted）
remaining=$(( pt_total - ($(date +%s) - t0) )); retry_to=""
if (( first_rc != 0 && ! GEM_IDLE_KILLED && ! GEM_NOOUT && remaining >= 1 && remaining * 10 >= pt_total )) && [[ "$(audit_get status)" != SUCCESS ]] \
   && [[ "$(audit_get asks)" == 0 && "$(audit_get violations)" == 0 && "$(audit_get invalid)" == 0 ]]; then
  snap_mid="$(rvd_snapshot "$wt")" || snap_mid=ERROR
  if [[ "$snap_mid" == "$snapshot_before" ]] \
     && { grep -q -E 'UNAVAILABLE|code 503|(^|[^0-9])503([^0-9]|$)|stream was interrupted|interrupted' "$perr" 2>/dev/null \
          || [[ "$(audit_get error)" =~ '(UNAVAILABLE|503|interrupted)' ]]; }; then
    retried=1; retry_to="${remaining}s"
    print -- "[見張り] $(lanes_now) agy が $(audit_get status)（一時的なエラー）・作業ツリーの変更なし → 残り ${retry_to} で 1 回だけやり直す（1 回目は ${json1:t} / ${err1:t}）" >> "$plog"
    mv -f "$pjson" "$pjson1"; mv -f "$perr" "$perr1"
    run_agy_once "$pjson" "$perr" "$retry_to"
    gem_after_child
  fi
fi
typeset -a audit_srcs; audit_srcs=("$pjson"); (( ! retried )) || audit_srcs=("$pjson1" "$pjson")
conv_rc=0; gem_audit write "${audit_srcs[@]}" || conv_rc=$?
lanes_logdir_check
gstatus="$(audit_get status)"; [[ -n "$gstatus" ]] || gstatus=NONE
asks_n="$(audit_get asks)"; viol_n="$(audit_get violations)"; invalid_n="$(audit_get invalid)"; viol_names="$(audit_get violation_names)"
audit_violation=0
if [[ "$asks_n" != <-> || "$viol_n" != <-> || "$invalid_n" != <-> ]]; then
  # 監査の要約を読めない（監査の処理そのものが落ちた）＝読み取り専用だったと確かめられない → 不合格の側
  audit_violation=1; asks_n="${asks_n:-?}"; viol_n="${viol_n:-?}"; invalid_n="${invalid_n:-?}"; viol_names="監査の結果を読めない"
  (( conv_rc != 0 )) || conv_rc=3
elif (( asks_n > 0 || viol_n > 0 )); then
  audit_violation=1
fi
state_tampered=0
if (( states_rc != 0 )); then
  state_tampered=1
  if (( states_rc == 1 )); then
    print -u2 -- "→ Gemini レビューの実行中に再利用の記録（logs/.*.review-state）が増えた・変わった。子の前の状態に戻して不合格（NEEDS_FIX）にする"
  else
    print -u2 -- "→ Gemini レビューの実行中の再利用の記録（logs/.*.review-state）を確かめられない・戻せない。不合格（NEEDS_FIX）にする。中身を手で確かめる"
  fi
fi
elapsed=$(( ($(date +%s) - t0) / 60 ))

rc=0
typeset -a stops; stops=()
(( ! retried )) || stops+=("一時エラーで 1 回やり直し（残り ${retry_to}）")
if (( GEM_NOOUT )); then
  rc=8; stops+=("出力 ${noout_sec} 秒なしで止めた")
elif (( GEM_IDLE_KILLED )); then
  rc=3; stops+=("idle（裏の作業待ち）のまま止めた。正常完了ではない")
elif (( GEM_RC != 0 )); then
  rc=$GEM_RC
fi
stop_line="${(j: / :)stops}"; [[ -n "$stop_line" ]] || stop_line="なし"
# 必須検証の仕組みの有無をランチャ側で見て判定へ渡す（仕組みがあるのに「該当なし（未導入）」・NA と書いた項目は未実施と同じ扱い）
checks_present="$(lanes_checks_present "$wt")" || checks_present=""
export LANES_CHECKS_PRESENT="$checks_present"
if (( conv_rc != 0 )); then
  # 最後の結果が SUCCESS でない・本文が空・記録が壊れている → 本文からもエラーの本文からも VERDICT を読まない
  verdict="VERDICT: NONE"
  (( rc != 0 )) || rc=3
else
  verdict="$(lanes_extract_verdict "$plog")"
fi
[[ "$verdict" == "VERDICT: PASS" ]] && verdict="VERDICT: CLEAN"
(( rc == 0 )) || verdict="VERDICT: NONE"   # agy が非 0 で終わった・見張りで止めた本文の VERDICT は採用しない
head_after="$(git -C "$wt" rev-parse --short=12 HEAD)"
# P0/P1 と明示 CLEAN の矛盾は必ず不合格
typeset -A sev; for k in P0 P1 P2 P3; do sev[$k]=$(lanes_count_findings "$plog" $k); done
sevsum="P0:${sev[P0]} P1:${sev[P1]} P2:${sev[P2]} P3:${sev[P3]}"
[[ "$verdict" == 'VERDICT: NONE' ]] || (( rc != 0 || sev[P0] + sev[P1] == 0 )) || verdict="VERDICT: NEEDS_FIX"
gate="$(rvd_gate "$round" "$verdict" "${sev[P0]}" "${sev[P1]}")"
raw_verdict="$verdict"; followups=""
# round 3 以降の P2/P3 は、元から CLEAN（P3 だけ）でも残件を必ず後回し票に保存する（run-claude-review.sh と同じ）
if (( round >= 3 && sev[P2] + sev[P3] > 0 )) && [[ "$verdict" != 'VERDICT: NONE' ]]; then
  followups="$logdir/$series.followups.md"
  if ! rvd_write_followups "$plog" "$followups" "$round" "$head_after" "$label"; then
    rc=3; verdict="VERDICT: NONE"; gate=FIX
  fi
fi
# 指摘があっても、必須検証の成功（または親の記録の使い回し）が確かめられなければ昇格させない
checks="$(lanes_parse_review "$plog" checks)"
if [[ "$gate" == MERGE_WITH_FOLLOWUP && "$checks" == COMPLETE ]] && (( rc == 0 && sev[P2] + sev[P3] > 0 )); then
  verdict="VERDICT: CLEAN"
elif [[ "$gate" == MERGE_WITH_FOLLOWUP ]]; then
  gate=FIX
fi
# 解消宣言は判定と同じ解析器で読む。コード例・引用・表の中の書式例では未解決指摘を解除しない
resolved="$(lanes_parse_review "$plog" resolved)" || resolved=NO
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
# 状態表示が同じでも、既に変更済みのファイルの上書きや commit を検出する
snapshot_after="$(rvd_snapshot "$wt")" || snapshot_after=ERROR
conditions_after="$(review_context)" || conditions_after=ERROR
# 設定（core.hooksPath など）・hooks・タグ・stash の書き換えも、作業ツリーの変更と同じく不合格にする
guard_after="$(rvd_git_guard "$wt")" || guard_after=ERROR
dirty=0
if [[ "$snapshot_after" == ERROR || "$snapshot_before" != "$snapshot_after" || "$conditions_after" != "$context" \
    || "$guard_after" == ERROR || "$guard_before" != "$guard_after" ]] || (( state_tampered )); then
  dirty=1; verdict="VERDICT: NEEDS_FIX"
  [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  (( rc != 0 )) || rc=4
fi
# 読み取り専用の約束を破った（禁止の道具・質問の道具を使った、監査できない）なら、本文に関係なく不合格（EXIT:4）
if (( audit_violation )); then
  verdict="VERDICT: NEEDS_FIX"
  [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  rc=4
fi
# 合格（CLEAN）は、必須検証の成功（成功行か親の chk-run の記録の使い回し）を確かめたときだけ保存する。
# 回のどの経路（通常・後回し票・前回の指摘の後回し）で CLEAN になっても、ここで同じ条件を見る（CLEAN を通す最後の 1 か所）
checks_note=""
if [[ "$verdict" == 'VERDICT: CLEAN' && "$checks" != COMPLETE ]]; then
  verdict="VERDICT: NEEDS_FIX"; [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  checks_note="必須検証の成功を確かめられないので CLEAN を NEEDS_FIX にした"
fi
# 記録の原本を logs/ へ写す（子の終了後だけ）。写せなければ合格を保存しない（EXIT:3・VERDICT: NONE）
publish_ok=1; gem_publish || publish_ok=0
if (( ! publish_ok )); then
  verdict="VERDICT: NONE"; [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  (( rc != 0 )) || rc=3
fi
(( rc != 0 )) || [[ "$verdict" == 'VERDICT: CLEAN' || "$verdict" == 'VERDICT: NEEDS_FIX' ]] || rc=3
# 周回の上限を超えて CLEAN にならなければ ESCALATE（人に返す）。続けるなら人が直して LANES_REVIEW_MAX_ROUNDS を上げる
gate="$(rvd_escalate "$round" "$verdict" "$gate")"

{
  print -- "## Gemini レビュー証跡（$label）"
  print -- "- $verdict"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- モード: $mode / base=$base / round=$round"
  lanes_model_effort_evidence gemini-review
  print -- "- 指摘: $sevsum / GATE: $gate"
  [[ "$gate" != ESCALATE ]] || print -- "- 周回の上限（LANES_REVIEW_MAX_ROUNDS=${LANES_REVIEW_MAX_ROUNDS:-5}）を超えた → ここで止めて人に判断を返す（続ける＝直して上限を上げる / 締める＝残りを .lanes/accepted-limitations.md か後回し票へ）"
  print -- "- 必須検証の成功確認: $checks（仕組みがあると見た項目: ${checks_present:-なし}。その項目の「該当なし（未導入）」・NA は受け付けない）${checks_note:+ → $checks_note}"
  rvd_checks_evidence
  [[ -z "$followups" ]] || print -- "- 元の判定: $raw_verdict / P2/P3 の保存先: $followups"
  print -- "- 読み取り専用: plan モード・端末サンドボックス・拒否の一覧 ${deny_n} 件（写し: $settings_copy）"
  print -- "- 監査（実行の記録）: agy の結果 $gstatus（rc=$GEM_RC）/ 質問・承認の道具 ${asks_n} 回 / 禁止の道具 ${viol_n} 件${viol_names:+（$viol_names）} / 記録の形の誤り ${invalid_n} 件"
  print -- "- 見張り: $stop_line / print-timeout $print_timeout（全体の上限。やり直しには残り時間だけを渡す）"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分 / EXIT:$rc"
  print -- "- HEAD: $head → $head_after / 内容・履歴・条件の変更検出 $dirty（0=なし、1=あり）"
  if (( publish_ok )); then
    print -- "- ログ: $log（本文）/ $json（生）/ $final（渡した全文）。本文と生の記録は、子の終了後に原本（$rec）から写した"
  else
    print -- "- ログ: logs/ へ写せなかった → 合格を保存しない（EXIT:3）。原本は $rec にある（渡した全文: $final）"
  fi
  print -- "- 作業場所（scratch）: $scratch（子が書けるのは $work だけ。${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"
} > "$evidence"

# 本文の後ろに証跡と終了の記録を足す（原本と、写せていれば logs/ の写しの両方）。再利用の記録には原本を保存する
{ print -- ""; print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; print -- "$verdict"; } >> "$plog"
(( ! publish_ok )) || cp -- "$plog" "$log"
cat "$evidence"
final_rc=$rc
(( rc == 0 )) && rvd_save_state "$logdir" "$series" "$round" "$(git -C "$wt" rev-parse HEAD)" "$verdict" "$gate" "$label" "$context" "$snapshot_after" "$review_base" "$plog" "$pending_note" "$blocking_previous" gemini
(( rc == 0 )) && [[ "$verdict" != "VERDICT: CLEAN" && "$verdict" != "VERDICT: NEEDS_FIX" ]] && final_rc=3   # 完走したのに VERDICT が無い
lanes_mark_done "$final_rc" "$verdict" "gemini rc=$rc gate=$gate $sevsum"
exit $final_rc
