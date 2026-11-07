#!/bin/zsh -f
# レビューランチャ（Codex の review）。codex のある構成（① full / ② claude-codex）のレビュー役。振り分けの入口は run-review.sh。使い方:
#   run-codex-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# 同じ確認を繰り返さないため、既定は --mode auto。
#   前回 CLEAN・条件一致・未保存変更なしの場合だけ delta / 同一結果を再利用。未解決指摘は full で引き継ぐ。
#   round は --round か label 末尾 -r<N>。round 3 以降の P2/P3 は必須検証の成功確認がある場合だけ、後回し票を保存して CLEAN へ進める。
#   仕組みは review-dedup.zsh。
# 必須検証の使い回し（LANES_REVIEW_REUSE_CHECKS=1 が既定）: 起動直後に chk-run.sh --query で問い合わせ、親が同じ中身で確認コマンドを
#   通した記録があれば、指示書に「必須検証は回さない」と入れ、必須検証は済んだもの（成功確認 COMPLETE と同じ）として判定する。
#   使い回しの有無と記録は再利用条件に入る。記録が無ければ今までどおりレビューの中で回させる
# codex の無い構成のレビューは run-claude-review.sh。構成（LANES_TOOLS）に codex が無ければ起動しない（exit 2）。
# CODEX_MODEL / CODEX_EFFORT が空なら付けない。比較起点の既定は origin/<LANES_BASE_BRANCH>。
# sandbox は CODEX_REVIEW_SANDBOX（既定 read-only）を明示し、子の git の通信（push・fetch）は止める。
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"

usage="使い方: run-codex-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]"
wt="${1:-}"; prompt="${2:-}"
[[ -n "$wt" && -n "$prompt" ]] || lanes_die "$usage"
shift 2
label=""; mode="auto"; base=""; dry=0; round=0; force=0
while (( $# )); do
  case "$1" in
    --mode) (( $# >= 2 )) || { lanes_defer_die "--mode に値が無い"; shift; continue; }; mode="$2"; shift 2 ;;
    --base) (( $# >= 2 )) || { lanes_defer_die "--base に値が無い"; shift; continue; }; base="$2"; shift 2 ;;
    --round) (( $# >= 2 )) || { lanes_defer_die "--round に値が無い"; shift; continue; }; round="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --force) force=1; shift ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || lanes_die "label 二重: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
wt="${wt:A}"; prompt="${prompt:A}"
[[ -n "$label" ]] || label="${prompt:t:r}"
# ここから排他を取るまでの誤り（--mode・--round の値など）は、取れれば今回の .done に残す
lanes_early_target "$wt" "$label" "$dry"
lanes_require_label "$label"
lanes_require_worktree "$wt"
[[ "$mode" == "auto" || "$mode" == "full" || "$mode" == "delta" ]] || lanes_die "--mode は auto|full|delta"

# 起点はレビュー開始前に commit へ固定し、再利用判定にも含める。
source "$LANES_DIR/review-dedup.zsh"
[[ "$round" == <-> && ${#round} -le 6 ]] || lanes_die "--round は 0〜999999 の整数"
# 必須検証の使い回しの問い合わせ。指紋に作業ツリー（無視対象の logs/ も含む）と環境変数が入るので、logs/ に .pid を書く前・
# scratch や git の通信止めを export する前に、親が chk-run.sh を回したのと同じ環境で呼ぶ
rvd_checks_query "$LANES_DIR" "$wt"
[[ "$RVD_CHECKS_REUSE" == yes ]] && LANES_REVIEW_CHECKS_REUSED=1 || LANES_REVIEW_CHECKS_REUSED=0
checks_key="$(rvd_checks_key)"
logdir="$wt/logs"
(( dry )) || lanes_mark_start "$logdir" "$label" codex-review "$wt"
lanes_require_tool codex run-codex-review.sh
lanes_entry_preflight
lanes_require_prompt "$prompt"
series="$(rvd_series "$label")"
round="$(rvd_round "$logdir" "$series" "$label" "$round")"
[[ "$round" == <-> && ${#round} -le 6 ]] || lanes_die "round が不正"
record="$(rvd_prev_record "$logdir" "$series" "$round")"
prev_head="$(rvd_record_get "$record" head)"
prev_v="$(rvd_record_get "$record" verdict)"
requested_mode="$mode"
# 既定の比較起点が進んだ場合も条件変更として再確認する。
# 統合先の枝が無い repo（main だけの運用など）では既定の起点が無いので、--base の指定を案内して止める。
if [[ -z "$base" ]]; then
  base="$(git -C "$wt" rev-parse --verify --end-of-options "origin/${LANES_BASE_BRANCH:-develop}^{commit}" 2>/dev/null)" || lanes_die "比較起点 origin/${LANES_BASE_BRANCH:-develop} が無い。その枝の無い repo では --base <sha|branch> を指定する（統合先は LANES_BASE_BRANCH で変えられる）"
else
  base="$(git -C "$wt" rev-parse --verify --end-of-options "$base^{commit}" 2>/dev/null)" || lanes_die "--base を commit として解決できない"
fi
review_base="$base"
policy=early; (( round >= 3 )) && policy=followups
# 再利用の条件（指示・起点・設定・検証の設定）。検証の設定が変わったら同じ HEAD でも省略しない（review-dedup.zsh の rvd_context）
review_context() { rvd_context "$LANES_DIR" "$prompt" "$review_base" "$requested_mode" "$policy" "$CODEX_MODEL" "$CODEX_EFFORT" "$wt" "$checks_key" codex; }
context="$(review_context)"
tree="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
decided="$(rvd_decide_mode "$wt" "$prev_head" "$prev_v" "$context" "$(rvd_record_get "$record" context)" "$tree" "$(rvd_record_get "$record" tree)")"
# 前のレビューで再利用の記録を戻しきれなかった印があれば、どの系列でも前回の記録を使わない（毎回 full。--mode delta も full にする）
if rvd_reuse_blocked "$logdir"; then
  decided=full
  print -u2 -- "注意: logs/.review-reuse-blocked がある（前のレビューで再利用の記録を戻しきれなかった）。前回の記録を使わず full でレビューする。logs/.*.review-state を確かめてから印を消す"
fi
skip_same=0
if [[ "$mode" == auto ]]; then
  case "$decided" in
    delta) mode=delta; base="$prev_head" ;;
    same) if (( force )); then mode=full; else skip_same=1; mode=full; fi ;;
    *) mode=full ;;
  esac
elif [[ "$mode" == delta && "$decided" == full ]]; then
  mode=full
elif [[ "$decided" == same ]] && (( ! force )); then
  skip_same=1
fi
unresolved_note=""
if [[ "$prev_v" == 'VERDICT: NEEDS_FIX' ]]; then
  # 未解決のある系列では明示 delta も全体へ戻す。
  mode=full; base="$review_base"; skip_same=0
  [[ -n "$(rvd_record_get "$record" report)" ]] || lanes_die "前回の未解決指摘本文が無い。復元してから再レビューする"
  unresolved_note="$(rvd_unresolved_note "$record" "$round")"
fi

log="$logdir/$label.log"; err="$logdir/$label.stderr.log"; proof="$logdir/$label.completion.json"; body_log="$logdir/$label.last.md"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
if (( skip_same )); then
  if (( dry )); then
    print -- "[dry-run] series=$series round=$round prev_head=${prev_head:0:12} → 同じ head をもう一度レビューしない（前回 $prev_v を使う。回すなら --force）"
    exit 0
  fi
  for f in "$log" "$err" "$evidence"; do lanes_rotate_log "$f"; done
  [[ "$(rvd_snapshot "$wt")" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "省略判定中に内容・指示が変化した。再実行する"
  {
    print -- "## Codex レビュー証跡（$label）"
    print -- "- $prev_v"
    print -- "- 対象: $(lanes_git_summary "$wt")"
    print -- "- モード: skip-same-head（前回 round と同じ head ${prev_head:0:12}。レビューしていない）/ round=$round"
    rvd_checks_evidence
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
  for f in "$log" "$err" "$evidence" "$final" "$proof" "$body_log"; do lanes_rotate_log "$f"; done
fi
mkdir -p "$logdir"
# レーン専用の作業場所。レビュー役の一時 DB・ビルド・ログはここへ（~/Downloads に置かせない）。マージ後 cleanup が消す
if (( dry )); then scratch="$(lanes_scratch_path "$wt" "$label")"; else lanes_scratch_prepare "$wt" "$label" codex-review; scratch="$LANES_SCRATCH"; fi
scratch_rule="$(lanes_scratch_rule "$scratch")"

lanes_require_prompt "$prompt"
lanes_check_codex_subscription

if [[ "$mode" == "delta" ]]; then
  [[ -n "$base" ]] || base="$prev_head"
  [[ -n "$base" ]] || lanes_die "--mode delta には --base が必要（前回レビューの記録も無い）"
fi
[[ -n "$base" ]] || base="origin/${LANES_BASE_BRANCH:-develop}"

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
template="$LANES_DIR/templates/claude-review-$mode.md"
[[ -s "$template" ]] || template="$LANES_DIR/templates/claude-review-full.md"
LANES_ACCEPTED_NOTE="$(rvd_accepted_note "$wt")" python3 - "$template" "$prompt" "$final" "$wt" "$branch" "$head" "$base" "$mode" "$(lanes_now)" "$scratch" "$scratch_rule" "$(rvd_checks_rule)" <<'PY'
import os, sys, pathlib
tpl, case, out, wt, branch, head, base, mode, date, scratch, rule, checks_rule = sys.argv[1:13]
t = pathlib.Path(tpl).read_text(encoding="utf-8")
for k, v in {"WORKTREE": wt, "BRANCH": branch, "HEAD": head, "BASE": base or "(なし)", "MODE": mode, "DATE": date, "SCRATCH": scratch}.items():
    t = t.replace("{{" + k + "}}", v)
# 役名だけ Codex に読み替え（Claude レビュー用のテンプレを流用）
t = t.replace("Claude", "Codex")
c = pathlib.Path(case).read_text(encoding="utf-8")
pathlib.Path(out).write_text(
t.rstrip() + "\n\n" + rule.rstrip() + "\n\n---\n\n# 案件固有の指示\n\n" + c.rstrip()
+ "\n\nbuild はレビューでは回さない（統合先（LANES_BASE_BRANCH。今は " + (os.environ.get("LANES_BASE_BRANCH") or "develop") + "）に入れる直前の最終 head の chk-run と CI で 1 回だけ担保する）。"
# 必須検証のきまり（review-dedup.zsh の rvd_checks_rule。使い回すときは「回さない」、使わないときは成功行の書き方）
+ ("\n\n" if checks_rule.startswith("#") else "") + checks_rule.rstrip()
# 受け入れ済みの限界（.lanes/accepted-limitations.md。review-dedup.zsh の rvd_accepted_note）
+ (("\n\n" + os.environ["LANES_ACCEPTED_NOTE"].rstrip()) if os.environ.get("LANES_ACCEPTED_NOTE", "").strip() else "")
+ "\n\n最終行は次のいずれか1行だけ:\nVERDICT: CLEAN\nVERDICT: NEEDS_FIX\n", encoding="utf-8")
PY

# --base と自由形式 PROMPT は併用せず、保存した全文を developer_instructions に渡す。
focus="$LANES_DIR/templates/codex-review-focus.md"
delta_note=""
[[ "$mode" == "delta" ]] && delta_note="$(rvd_delta_note "$wt" "$base" "$round")"
devinst="$(python3 - "$focus" "$final" "$delta_note" "$unresolved_note" <<'PY2'
import sys, json, pathlib
parts = [pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").rstrip(),
         pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").rstrip()]
parts.extend(p for p in sys.argv[3:] if p.strip())
print(json.dumps("\n\n".join(parts), ensure_ascii=False))
PY2
)"
# 実行場所の設定も含めて MCP を無効化する。確認できなければ起動しない。
(( ${+functions[lanes_codex_no_mcp_args]} )) || lanes_die "Codex の MCP 無効化処理が無い → 起動禁止"
lanes_codex_no_mcp_args "$wt"
# 読み取り専用をコードで強制する（指定しないと ~/.codex/config.toml 次第で、danger-full-access なら外へ書ける）。
# CODEX_REVIEW_SANDBOX は read-only（既定）か workspace-write だけ。どちらでも作業ツリーの変更は前後の比較で不合格にする
# lanes.env を差し替えた環境（テストなど）でキーが無くても、読み取り専用に倒す
CODEX_REVIEW_SANDBOX="${CODEX_REVIEW_SANDBOX:-read-only}"
[[ "$CODEX_REVIEW_SANDBOX" == read-only || "$CODEX_REVIEW_SANDBOX" == workspace-write ]] \
  || lanes_die "CODEX_REVIEW_SANDBOX は read-only か workspace-write: '$CODEX_REVIEW_SANDBOX'"
cmd=("$CODEX_BIN" exec review --json "${LANES_CODEX_NO_MCP_ARGS[@]}" -c "sandbox_mode=\"$CODEX_REVIEW_SANDBOX\"")
if [[ -n "$CODEX_MODEL" ]]; then cmd+=(-c "model=$CODEX_MODEL"); fi
if [[ -n "$CODEX_EFFORT" ]]; then cmd+=(-c "model_reasoning_effort=$CODEX_EFFORT"); fi
cmd+=(-c "developer_instructions=$devinst" --base "$base")
if (( dry )); then
  print -- "[dry-run] series=$series round=$round mode=$mode base=$base prev_head=${prev_head:0:12}（判定 $decided）"
  print -- "[dry-run] scratch: $scratch（TMPDIR / LANES_SCRATCH。developer_instructions に置き場所の指示あり）"
  print -- "[dry-run] cd ${(q)wt} && TMPDIR=${(q)scratch}/ LANES_SCRATCH=${(q)scratch} ${(q)cmd[@]} > ${(q)log} 2> ${(q)err}  # prompt archived at ${(q)final}"
  exit 0
fi

cd "$wt"
started="$(lanes_now)"; t0=$(date +%s)
head_before="$(git rev-parse --short=12 HEAD)"
snapshot_before="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
[[ "$snapshot_before" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "起動準備中に内容・指示が変化した。再実行する"
# git の制御ファイルの前後比較（run-codex.sh と同じ）。CODEX_REVIEW_SANDBOX=workspace-write だと子は worktree の .git ファイルを
# 書けるので、偽の gitdir へ向け直されると、子の後でランチャが回す git から偽の設定（core.fsmonitor など）が実行され得る。
# 管理フォルダの場所は子の前に確かめておき、子の後は git を呼ぶ前に指紋だけで比べる。read-only でも同じく比べる
git_common="$(git rev-parse --path-format=absolute --git-common-dir)" || lanes_die "git の管理フォルダを確かめられない: $wt"
git_dir="$(git rev-parse --path-format=absolute --git-dir)" || lanes_die "git の管理フォルダを確かめられない: $wt"
git_fp_before="$(lanes_git_ctl_fingerprint "$wt" "$git_dir" "$git_common")" || lanes_die "起動前の git 制御ファイルの確認に失敗"
# 設定・hooks・タグ・stash の書き換えも、Claude レビューと同じく前後で比べる（review-dedup.zsh の rvd_git_guard）
guard_before="$(rvd_git_guard "$wt")" || lanes_die "レビュー前の git 管理フォルダの確認に失敗"
# 再利用の記録（logs/.<series>.review-state）は worktree の中にあり、workspace-write の子が書ける。偽の CLEAN を書かれたまま
# 子が非 0 で終わると記録が上書きされず、次の --mode auto が「同じ HEAD なので省略」で偽の CLEAN を使い得る。
# 前の中身はメモリ（変数）に持ち、子の後で変わっていたら元に戻して不合格にする
state_file="$(rvd_state_file "$logdir" "$series")"
# 今の系列だけでなく、logs/ にある全部の系列の記録を覚える（別の系列の記録に偽の CLEAN を作られても戻す）
states_before="$(rvd_states_snapshot "$logdir")" || lanes_die "レビュー前の再利用の記録の確認に失敗"
# 「使い回し禁止」の印の有無も覚える（子が印を消したら改ざんとして扱う）
blocked_before=0; rvd_reuse_blocked "$logdir" && blocked_before=1

# レビューの子から push（と fetch）をできなくする（読み取り専用の役。git の通信は要らない）
lanes_block_git_transport
rc=0
lanes_start_child python3 "$LANES_DIR/codex-review-output.py" "$body_log" "$proof" "${cmd[@]}" > /dev/null 2> "$err"
wait "$LANES_CHILD" || rc=$?
lanes_logdir_check
LANES_CHILD=""
# 再利用の記録が子の実行中に変わっていたら、まず元の中身に戻す（以後どこで終わっても偽の記録を残さない）
state_tampered=0
states_rc=0; print -r -- "$states_before" | rvd_states_restore "$logdir" || states_rc=$?
# 印が子の実行中に消されていたら、改ざんとして扱う（印は置き直す）
if (( blocked_before )) && ! rvd_reuse_blocked "$logdir"; then
  print -u2 -- "→ Codex レビューの実行中に「使い回し禁止」の印が消された。置き直して不合格（NEEDS_FIX）にする"
  (( states_rc != 0 )) || states_rc=1
fi
# 戻しきれなかった・印が消されたときは、印を置く（logs/ の外にも）。置けなければその旨を出す（以後も full で回すよう人が確かめる）
if (( states_rc == 2 )) || { (( blocked_before )) && ! rvd_reuse_blocked "$logdir"; }; then
  rvd_mark_blocked "$logdir" || print -u2 -- "→ 「使い回し禁止」の印を置けない。logs/ と ${XDG_STATE_HOME:-~/.local/state}/lanewright/ の権限を確かめる。次のレビューは --mode full --force で回す"
fi
if (( states_rc != 0 )); then
  state_tampered=1
  if (( states_rc == 1 )); then
    print -u2 -- "→ Codex レビューの実行中に再利用の記録（logs/.*.review-state）が増えた・変わった。子の前の状態に戻して不合格（NEEDS_FIX）にする"
  else
    print -u2 -- "→ Codex レビューの実行中の再利用の記録（logs/.*.review-state）を確かめられない・戻せない。不合格（NEEDS_FIX）にする。中身を手で確かめる"
  fi
fi
# git を 1 回も呼ぶ前に、制御ファイルが変わっていないかを見る（run-codex.sh と同じやり方）
git_fp_after="$(lanes_git_ctl_fingerprint "$wt" "$git_dir" "$git_common" 2>/dev/null)" || git_fp_after=ERROR
if [[ "$git_fp_after" != "$git_fp_before" ]]; then
  if [[ -f "$body_log" ]]; then cp "$body_log" "$log"; else : > "$log"; fi
  print -- "[run-codex-review] $(lanes_now) git の制御ファイル（.git・commondir・gitdir・config・config.worktree・hooks）が変わった → git を実行せず停止" >> "$log"
  print -u2 -- "→ Codex レビューの実行中に git の制御ファイルが変わった。git を実行せず停止（EXIT:4）。$wt/.git と $git_dir・$git_common の中身を手で確かめてから直す"
  print -- "EXIT:4" >> "$log"
  lanes_mark_done 4 "VERDICT: NEEDS_FIX" "git の制御ファイルの変更を検出（git 未実行）"
  exit 4
fi
if [[ -f "$body_log" ]]; then cp "$body_log" "$log"; else : > "$log"; fi
elapsed=$(( ($(date +%s) - t0) / 60 ))
head_after="$(git rev-parse --short=12 HEAD)"
# codex review --base はカスタム PROMPT（VERDICT 強制）を渡せず、出力（overall_explanation + findings を CLI が描画）に
# VERDICT 行は出ない（developer_instructions で頼んでも出ない）。
# 完了イベント・本文の一致・肯定の成功文を確認する。任意の非空本文だけでは合格にしない。
# 必須検証の仕組みの有無をランチャ側で見て判定へ渡す（仕組みがあるのに NA と書いた項目は未実施と同じ扱い）
checks_present="$(lanes_checks_present "$wt")" || checks_present=""
export LANES_CHECKS_PRESENT="$checks_present"
verdict="$(lanes_codex_verdict "$body_log" "$proof")"
(( rc == 0 )) || verdict="VERDICT: NONE"
# P0/P1 と明示 CLEAN の矛盾は必ず不合格。共通判定の旧版でも通さない。
typeset -A sev; for k in P0 P1 P2 P3; do sev[$k]=$(lanes_count_findings "$log" $k); done
sevsum="P0:${sev[P0]} P1:${sev[P1]} P2:${sev[P2]} P3:${sev[P3]}"
[[ "$verdict" == 'VERDICT: NONE' ]] || (( rc != 0 || sev[P0] + sev[P1] == 0 )) || verdict="VERDICT: NEEDS_FIX"
gate="$(rvd_gate "$round" "$verdict" "${sev[P0]}" "${sev[P1]}")"
raw_verdict="$verdict"; followups=""
# P3 だけなら元から CLEAN でも、残件は必ず保存する。
if (( round >= 3 && sev[P2] + sev[P3] > 0 )); then
  followups="$logdir/$series.followups.md"
  if ! rvd_write_followups "$log" "$followups" "$round" "$head_after" "$label"; then
    rc=3; verdict="VERDICT: NONE"; gate=FIX
  fi
fi
# 指摘があっても、必須検証の成功が明示されなければ昇格させない。
checks="$(lanes_parse_review "$body_log" checks)"
if [[ "$gate" == MERGE_WITH_FOLLOWUP && "$checks" == COMPLETE ]] && (( rc == 0 && sev[P2] + sev[P3] > 0 )); then
  verdict="VERDICT: CLEAN"
elif [[ "$gate" == MERGE_WITH_FOLLOWUP ]]; then
  gate=FIX
fi
# P3 が明示 CLEAN と併記されても、同じ成功確認を迂回させない。
if (( round >= 3 && sev[P2] + sev[P3] > 0 )) && [[ "$verdict" == 'VERDICT: CLEAN' && "$checks" != COMPLETE ]]; then
  verdict="VERDICT: NEEDS_FIX"; gate=FIX
fi
# 解消宣言は判定と同じ解析器で読む。コード例・引用・表の中の書式例では未解決指摘を解除しない。
resolved="$(lanes_parse_review "$log" resolved)" || resolved=NO
pending_note="$unresolved_note"; blocking_previous=0
[[ "$resolved" != YES ]] || pending_note=""
if [[ -n "$unresolved_note" && "$resolved" != YES ]]; then
  # 前回の軽微な指摘も保存対象。今回の本文から省かれていても取りこぼさない。
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
snapshot_after="$(rvd_snapshot "$wt")" || snapshot_after=ERROR
conditions_after="$(review_context)" || conditions_after=ERROR
guard_after="$(rvd_git_guard "$wt")" || guard_after=ERROR
dirty=0
if [[ "$snapshot_after" == ERROR || "$snapshot_before" != "$snapshot_after" || "$conditions_after" != "$context" \
    || "$guard_after" == ERROR || "$guard_before" != "$guard_after" ]] || (( state_tampered )); then
  dirty=1; verdict="VERDICT: NEEDS_FIX"
  [[ "$gate" == STOP_P0P1 ]] || gate=FIX
  (( rc != 0 )) || rc=4
fi
# NONE を EXIT:0 の証跡として残さない。
(( rc != 0 )) || [[ "$verdict" == 'VERDICT: CLEAN' || "$verdict" == 'VERDICT: NEEDS_FIX' ]] || rc=3
# 周回の上限を超えて CLEAN にならなければ ESCALATE（人に返す）。続けるなら人が直して LANES_REVIEW_MAX_ROUNDS を上げる
gate="$(rvd_escalate "$round" "$verdict" "$gate")"

{
  print -- "## Codex レビュー証跡（$label）"
  print -- "- $verdict"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- モード: $mode / base=$base / round=$round"
  print -- "- 指摘: $sevsum / GATE: $gate"
  [[ "$gate" != ESCALATE ]] || print -- "- 周回の上限（LANES_REVIEW_MAX_ROUNDS=${LANES_REVIEW_MAX_ROUNDS:-5}）を超えた → ここで止めて人に判断を返す（続ける＝直して上限を上げる / 締める＝残りを .lanes/accepted-limitations.md か後回し票へ）"
  print -- "- 必須検証の成功確認: $checks（仕組みがあると見た項目: ${checks_present:-なし}。その項目の NA は受け付けない）"
  rvd_checks_evidence
  [[ -n "$followups" ]] && print -- "- 元の判定: $raw_verdict / P2/P3 の保存先: $followups"
  print -- "- 実行: $started / 約 ${elapsed} 分 / EXIT:$rc"
  print -- "- HEAD: $head_before → $head_after / 対象・条件の変更検出 $dirty（0=なし、1=あり）"
  print -- "- ログ: $log / $final"
  print -- "- 作業場所（scratch）: $scratch（${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"
} > "$evidence"
{ print -- ""; print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; print -- "$verdict"; } >> "$log"
cat "$evidence"
final_rc=$rc
(( rc == 0 )) && rvd_save_state "$logdir" "$series" "$round" "$(git -C "$wt" rev-parse HEAD)" "$verdict" "$gate" "$label" "$context" "$snapshot_after" "$review_base" "$log" "$pending_note" "$blocking_previous"
(( rc == 0 )) && [[ "$verdict" != "VERDICT: CLEAN" && "$verdict" != "VERDICT: NEEDS_FIX" ]] && final_rc=3
lanes_mark_done "$final_rc" "$verdict" "codex-review rc=$rc gate=$gate $sevsum"
exit $final_rc
