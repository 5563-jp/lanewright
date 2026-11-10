#!/bin/zsh -f
# レビューランチャ（Claude の別セッション・読み取り専用）。codex の無い構成（③ claude-gemini / ④ claude-only）のレビュー役。
# codex のある構成では run-codex-review.sh が既定。振り分けの入口は run-review.sh。CLAUDE_MODEL / CLAUDE_EFFORT が空なら付けない。使い方:
#   run-claude-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# 同じ確認を繰り返さないため、既定は --mode auto（run-codex-review.sh と同じ review-dedup.zsh の仕組み）。
#   初回は full。前回 CLEAN・条件一致・未保存変更なしなら前回の HEAD からの delta、同じ HEAD なら前回の結果を使う（--force で回す）。
#   前回 NEEDS_FIX なら full に戻して未解決指摘を引き継ぐ。明示の --mode delta も前回の記録が使えなければ full にする。
#   round は --round か label 末尾 -r<N>。round 3 以降の P2/P3 は必須検証の成功確認がある場合だけ、後回し票を保存して CLEAN へ進める。
#   比較起点（full の起点・再利用条件）は --base を commit に直したもの、無ければ origin/<LANES_BASE_BRANCH>（その枝の無い repo は --base 必須）
# 必須検証の使い回し（LANES_REVIEW_REUSE_CHECKS=1 が既定）: 起動直後に chk-run.sh --query で問い合わせ、親が同じ中身で確認コマンドを
#   通した記録があれば、指示書に「必須検証は回さない」と入れ、テンプレの「検証 1 に未実施があれば CLEAN を出さない」を適用しない
#   （必須検証は済んだものとして判定する）。使い回しの有無と記録は再利用条件に入る
# 出力: <worktree>/logs/<label>.log（本文）/ <label>.json（生。stream-json = 1 行 1 イベントで進行中も増える）/ <label>.stderr.log
#       / <label>.prompt.md（実際に渡した全文。dry-run は <label>.dry-run.prompt.md）/ <label>.evidence.md（PR 貼り付け用）
#       / <label>.pid（起動時）/ <label>.done（終了時）← 生死は lanes-status.sh <worktree> <label> で見る
#       / .<系列>.review-state（再利用の記録）/ <系列>.followups.md（round 3 以降の後回し票）
# label 省略時はプロンプトのファイル名（拡張子なし）。英数と . _ - のみ
# 最終行は必ず VERDICT: CLEAN | NEEDS_FIX | NONE（NONE = 完走せず / claude 非 0 / is_error）。終了コード: claude の rc（非 0 ならそのまま）、rc 0 で VERDICT が取れなければ 3
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
source "$LANES_DIR/review-dedup.zsh"

usage="使い方: run-claude-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]"
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
    *) [[ -z "$label" ]] || lanes_die "label が 2 回指定されている: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
wt="${wt:A}"; prompt="${prompt:A}"
[[ -n "$label" ]] || label="${prompt:t:r}"
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
log="$logdir/$label.log"; json="$logdir/$label.json"; err="$logdir/$label.stderr.log"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
# 起動の事実（.pid）を最初に残す（以後どこで落ちても .done は今回の失敗を指し、status が前回の証跡を案内しない）。
# dry-run は .pid / .done / ログを触らず、結合結果だけ <label>.dry-run.prompt.md に書く
(( dry )) || lanes_mark_start "$logdir" "$label" claude-review "$wt"
lanes_require_tool claude run-claude-review.sh
lanes_entry_preflight
lanes_require_prompt "$prompt"
series="$(rvd_series "$label")"
round="$(rvd_round "$logdir" "$series" "$label" "$round")"
[[ "$round" == <-> && ${#round} -le 6 ]] || lanes_die "round が不正"
record="$(rvd_prev_record "$logdir" "$series" "$round")"
prev_head="$(rvd_record_get "$record" head)"
prev_v="$(rvd_record_get "$record" verdict)"
requested_mode="$mode"
policy=early; (( round >= 3 )) && policy=followups
# 再利用の条件（指示・起点・設定・検証の設定・必須検証の使い回し）。変わったら同じ HEAD でも省略しない（review-dedup.zsh の rvd_context）
review_context() { rvd_context "$LANES_DIR" "$prompt" "$review_base" "$requested_mode" "$policy" "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$wt" "$checks_key" claude; }
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
  for f in "$log" "$json" "$err" "$evidence"; do lanes_rotate_log "$f"; done
  [[ "$(rvd_snapshot "$wt")" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "省略判定中に内容・指示が変化した。再実行する"
  {
    print -- "## Claude レビュー証跡（$label）"
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
  for f in "$log" "$json" "$err" "$evidence" "$final"; do lanes_rotate_log "$f"; done
fi
mkdir -p "$logdir"
# レーン専用の作業場所（TMPDIR / LANES_SCRATCH）。マージ後 cleanup が消す
(( dry )) || lanes_scratch_prepare "$wt" "$label" claude-review
lanes_check_claude_subscription

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
template="$LANES_DIR/templates/claude-review-$mode.md"
[[ -s "$template" ]] || lanes_die "テンプレが無い: $template"
delta_note=""
[[ "$mode" == "delta" ]] && delta_note="$(rvd_delta_note "$wt" "$base" "$round")"

# テンプレ + 案件固有プロンプト + ランチャの追記（delta の説明・前回の未解決指摘・必須検証のきまり）を結合して、実際に渡した全文を残す
LANES_ACCEPTED_NOTE="$(rvd_accepted_note "$wt")" python3 - "$template" "$prompt" "$final" "$wt" "$branch" "$head" "$base" "$mode" "$(lanes_now)" "$(rvd_checks_rule)" "$delta_note" "$unresolved_note" <<'PY'
import os, sys, pathlib
tpl, case, out, wt, branch, head, base, mode, date, checks_rule, delta_note, unresolved = sys.argv[1:13]
t = pathlib.Path(tpl).read_text(encoding="utf-8")
for k, v in {"WORKTREE": wt, "BRANCH": branch, "HEAD": head, "BASE": base, "MODE": mode, "DATE": date}.items():
    t = t.replace("{{" + k + "}}", v)
c = pathlib.Path(case).read_text(encoding="utf-8")
extra = [p.rstrip() for p in (delta_note, unresolved, os.environ.get("LANES_ACCEPTED_NOTE", "")) if p.strip()]
rule = checks_rule.rstrip()
extra.append(rule if rule.startswith("#") else "# 必須検証の成功行\n- " + rule)
pathlib.Path(out).write_text(t.rstrip() + "\n\n---\n\n# 案件固有の指示（司令塔が記入）\n\n" + c.rstrip()
                             + "\n\n---\n\n" + "\n\n".join(extra) + "\n", encoding="utf-8")
PY

# 読み取り専用の担保: --tools で内蔵ツール集合を絞り、編集系とサブエージェント起動は明示拒否。
# 可変長オプションは `=` 形式にして後続を食わせない。プロンプトは stdin（ARG_MAX 回避）。-p は最後。
# --strict-mcp-config: ユーザー設定の MCP（外部サービスにつなぐ追加の道具）を読み込まない。必要なら --mcp-config=<file> を足す
# --output-format stream-json: 1 行 1 イベントで進行中も $json が増える（生死監視の「最終出力」に使う）。json だと終了までゼロ出力
# 使えるツールに編集系・サブエージェントがあれば止め、拒否は固定の一覧 + CLAUDE_REVIEW_DENY にする（外から外せない）
lanes_claude_review_resolve
cmd=("$CLAUDE_BIN" --tools="$LANES_CLAUDE_REVIEW_TOOLS" --allowedTools="$LANES_CLAUDE_REVIEW_TOOLS" --disallowedTools="$LANES_CLAUDE_REVIEW_DENY" --strict-mcp-config --permission-mode manual)
if [[ -n "$CLAUDE_MODEL" ]]; then cmd+=(--model "$CLAUDE_MODEL"); fi
if [[ -n "$CLAUDE_EFFORT" ]]; then cmd+=(--effort "$CLAUDE_EFFORT"); fi
cmd+=(--output-format stream-json --verbose -p)
if (( dry )); then
  print -- "[dry-run] series=$series round=$round mode=$mode base=$base prev_head=${prev_head:0:12}（判定 $decided）/ 必須検証の使い回し: $RVD_CHECKS_REUSE"
  print -- "[dry-run] cd ${(q)wt} && ${(q)cmd[@]} < ${(q)final} > ${(q)json} 2> ${(q)err}"
  print -- "[dry-run] 結合済みプロンプト: $final"
  exit 0
fi

cd "$wt"
snapshot_before="$(rvd_snapshot "$wt")" || lanes_die "レビュー前の内容確認に失敗"
[[ "$snapshot_before" == "$tree" && "$(review_context)" == "$context" ]] || lanes_die "起動準備中に内容・指示が変化した。再実行する"
guard_before="$(rvd_git_guard "$wt")" || lanes_die "レビュー前の git 管理フォルダの確認に失敗"
# 再利用の記録（logs/.<series>.review-state）は worktree の中にあり、子は Bash で書ける。偽の CLEAN を書かれたまま
# 子が非 0 で終わると記録が上書きされず、次の --mode auto が「同じ HEAD なので省略」で偽の CLEAN を使い得る。
# 前の中身はメモリ（変数）に持ち、子の後で変わっていたら元に戻して不合格にする（run-codex-review.sh と同じ）
state_file="$(rvd_state_file "$logdir" "$series")"
# 今の系列だけでなく、logs/ にある全部の系列の記録を覚える（別の系列の記録に偽の CLEAN を作られても戻す）
states_before="$(rvd_states_snapshot "$logdir")" || lanes_die "レビュー前の再利用の記録の確認に失敗"
# 「使い回し禁止」の印の有無も覚える（子が印を消したら改ざんとして扱う）
blocked_before=0; rvd_reuse_blocked "$logdir" && blocked_before=1
started="$(lanes_now)"; t0=$(date +%s)

# レビューの子から push（と fetch）をできなくする。Bash の先頭一致の拒否は `git -C . push` などを通すため、git 側で止める
lanes_block_git_transport
# 子は監督役（lanes_start_child）の下で背景起動して wait（シグナルで wait が中断され、trap が子へ TERM を伝播できる）。
# QA・Codex レビューと同じく、レビューが立てたテスト用のサーバーなどの孫も、子の終了後に監督役が回収する。
rc=0
lanes_start_child "${cmd[@]}" < "$final" > "$json" 2> "$err"
wait "$LANES_CHILD" || rc=$?
lanes_logdir_check
LANES_CHILD=""   # 以後の trap で（pid 再利用した）別プロセスを kill しない
# 再利用の記録が子の実行中に変わっていたら、まず元の中身に戻す（以後どこで終わっても偽の記録を残さない）
state_tampered=0
states_rc=0; print -r -- "$states_before" | rvd_states_restore "$logdir" || states_rc=$?
# 印が子の実行中に消されていたら、改ざんとして扱う（印は置き直す）
if (( blocked_before )) && ! rvd_reuse_blocked "$logdir"; then
  print -u2 -- "→ Claude レビューの実行中に「使い回し禁止」の印が消された。置き直して不合格（NEEDS_FIX）にする"
  (( states_rc != 0 )) || states_rc=1
fi
# 戻しきれなかった・印が消されたときは、印を置く（logs/ の外にも）。置けなければその旨を出す（以後も full で回すよう人が確かめる）
if (( states_rc == 2 )) || { (( blocked_before )) && ! rvd_reuse_blocked "$logdir"; }; then
  rvd_mark_blocked "$logdir" || print -u2 -- "→ 「使い回し禁止」の印を置けない。logs/ と ${XDG_STATE_HOME:-~/.local/state}/lanewright/ の権限を確かめる。次のレビューは --mode full --force で回す"
fi
if (( states_rc != 0 )); then
  state_tampered=1
  if (( states_rc == 1 )); then
    print -u2 -- "→ Claude レビューの実行中に再利用の記録（logs/.*.review-state）が増えた・変わった。子の前の状態に戻して不合格（NEEDS_FIX）にする"
  else
    print -u2 -- "→ Claude レビューの実行中の再利用の記録（logs/.*.review-state）を確かめられない・戻せない。不合格（NEEDS_FIX）にする。中身を手で確かめる"
  fi
fi
elapsed=$(( ($(date +%s) - t0) / 60 ))

# stream-json（1 行 1 イベント）から最後の result イベントを抜いて本文にする。旧形式（単一 JSON）にも対応。
# result が無ければ exit 4（完走せず）: 生を本文に残すが、途中の tool_result 等から VERDICT を拾わない
conv_rc=0
python3 - "$json" "$log" <<'PY' || conv_rc=$?
import json, sys, pathlib
src, dst = sys.argv[1], sys.argv[2]
raw = pathlib.Path(src).read_text(encoding="utf-8", errors="replace")
result, events = None, 0
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    events += 1
    if isinstance(d, dict) and d.get("type") == "result":
        result = d
if result is None:
    try:
        d = json.loads(raw)
        if isinstance(d, dict) and "result" in d:
            result = d
    except Exception:
        pass
if result is None:
    pathlib.Path(dst).write_text(raw + f"\n[meta] result イベントが無い（途中終了の可能性。events={events}）\n", encoding="utf-8")
    sys.exit(4)
body = result.get("result")
meta = (f"\n\n[meta] is_error={result.get('is_error')} duration_ms={result.get('duration_ms')} "
        f"cost_usd={result.get('total_cost_usd')} turns={result.get('num_turns')} session={result.get('session_id')} events={events}\n")
if result.get("is_error") is True or not isinstance(body, str):
    # エラー時の本文や JSON 全体から VERDICT を拾わない（exit 5 → VERDICT NONE）
    pathlib.Path(dst).write_text((body if isinstance(body, str) else json.dumps(result, ensure_ascii=False)) + meta
                                 + "[meta] is_error または result が文字列でないため VERDICT は採用しない\n", encoding="utf-8")
    sys.exit(5)
# 正常応答は本文の最終行を保つ。共通判定は本文末尾の VERDICT だけを採用する。
pathlib.Path(dst).write_text(meta.strip() + "\n\n" + body, encoding="utf-8")
PY
# 必須検証の仕組みの有無をランチャ側で見て判定へ渡す（仕組みがあるのに「該当なし（未導入）」・NA と書いた項目は未実施と同じ扱い）
checks_present="$(lanes_checks_present "$wt")" || checks_present=""
export LANES_CHECKS_PRESENT="$checks_present"
if (( conv_rc != 0 )); then
  verdict="VERDICT: NONE"
else
  verdict="$(lanes_extract_verdict "$log")"
fi
[[ "$verdict" == "VERDICT: PASS" ]] && verdict="VERDICT: CLEAN"
(( rc == 0 )) || verdict="VERDICT: NONE"   # claude が非 0 で終わった本文の VERDICT は採用しない
head_after="$(git rev-parse --short=12 HEAD)"
# P0/P1 と明示 CLEAN の矛盾は必ず不合格
typeset -A sev; for k in P0 P1 P2 P3; do sev[$k]=$(lanes_count_findings "$log" $k); done
sevsum="P0:${sev[P0]} P1:${sev[P1]} P2:${sev[P2]} P3:${sev[P3]}"
[[ "$verdict" == 'VERDICT: NONE' ]] || (( rc != 0 || sev[P0] + sev[P1] == 0 )) || verdict="VERDICT: NEEDS_FIX"
gate="$(rvd_gate "$round" "$verdict" "${sev[P0]}" "${sev[P1]}")"
raw_verdict="$verdict"; followups=""
# round 3 以降の P2/P3 は、元から CLEAN（P3 だけ）でも残件を必ず後回し票に保存する（run-codex-review.sh と同じ）
if (( round >= 3 && sev[P2] + sev[P3] > 0 )) && [[ "$verdict" != 'VERDICT: NONE' ]]; then
  followups="$logdir/$series.followups.md"
  if ! rvd_write_followups "$log" "$followups" "$round" "$head_after" "$label"; then
    rc=3; verdict="VERDICT: NONE"; gate=FIX
  fi
fi
# 指摘があっても、必須検証の成功（または親の記録の使い回し）が確かめられなければ昇格させない
checks="$(lanes_parse_review "$log" checks)"
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
resolved="$(lanes_parse_review "$log" resolved)" || resolved=NO
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
# 状態表示が同じでも、既に変更済みのファイルの上書きや commit を検出する。
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
(( rc != 0 )) || [[ "$verdict" == 'VERDICT: CLEAN' || "$verdict" == 'VERDICT: NEEDS_FIX' ]] || rc=3
# 周回の上限を超えて CLEAN にならなければ ESCALATE（人に返す）。続けるなら人が直して LANES_REVIEW_MAX_ROUNDS を上げる
gate="$(rvd_escalate "$round" "$verdict" "$gate")"

{
  print -- "## Claude レビュー証跡（$label）"
  print -- "- $verdict"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- モード: $mode / base=$base / round=$round"
  print -- "- 指摘: $sevsum / GATE: $gate"
  [[ "$gate" != ESCALATE ]] || print -- "- 周回の上限（LANES_REVIEW_MAX_ROUNDS=${LANES_REVIEW_MAX_ROUNDS:-5}）を超えた → ここで止めて人に判断を返す（続ける＝直して上限を上げる / 締める＝残りを .lanes/accepted-limitations.md か後回し票へ）"
  print -- "- 必須検証の成功確認: $checks（仕組みがあると見た項目: ${checks_present:-なし}。その項目の「該当なし（未導入）」・NA は受け付けない）"
  rvd_checks_evidence
  [[ -n "$followups" ]] && print -- "- 元の判定: $raw_verdict / P2/P3 の保存先: $followups"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分 / EXIT:$rc"
  print -- "- HEAD: $head → $head_after / 内容・履歴・条件の変更検出 $dirty（0=なし、1=あり）"
  print -- "- ログ: $log（本文）/ $json（生）/ $final（渡した全文）"
  if [[ -n "${LANES_SCRATCH:-}" ]]; then print -- "- 作業場所（scratch）: $LANES_SCRATCH（${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"; fi
} > "$evidence"

{ print -- ""; print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; print -- "$verdict"; } >> "$log"
cat "$evidence"
final_rc=$rc
(( rc == 0 )) && rvd_save_state "$logdir" "$series" "$round" "$(git -C "$wt" rev-parse HEAD)" "$verdict" "$gate" "$label" "$context" "$snapshot_after" "$review_base" "$log" "$pending_note" "$blocking_previous"
(( rc == 0 )) && [[ "$verdict" != "VERDICT: CLEAN" && "$verdict" != "VERDICT: NEEDS_FIX" ]] && final_rc=3   # 完走したのに VERDICT が無い
lanes_mark_done "$final_rc" "$verdict" "claude rc=$rc gate=$gate $sevsum"
exit $final_rc
