#!/bin/zsh -f
# 実装ランチャ（Claude）。使い方:
#   run-claude.sh <worktree> <prompt.md> [label] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# 既定の実装役。役割に合わせて振り分ける入口は run-impl.sh。Codex で実装したいときだけ run-codex.sh。
# 構成（LANES_TOOLS）に claude が無ければ起動しない（exit 2）。CLAUDE_MODEL が空なら --model、CLAUDE_EFFORT が空なら --effort を付けない
# 許可: CLAUDE_IMPL_PERMISSION_MODE（既定 acceptEdits）と CLAUDE_IMPL_ALLOWED_TOOLS（既定 Bash,Edit,Write,Read,Glob,Grep,TodoWrite）を渡す
# 出力: logs/<label>.{log,json,stderr.log,prompt.md,evidence.md,pid,done}
# 共通の前置き templates/claude-impl-preamble.md（自己レビュー最大2回・範囲外を触らない）を案件プロンプトの前に自動で付ける。CLAUDE_NO_PREAMBLE=1 で無効
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"

usage="使い方: run-claude.sh <worktree> <prompt.md> [label] [--dry-run]"
wt="${1:-}"; prompt="${2:-}"
[[ -n "$wt" && -n "$prompt" ]] || lanes_die "$usage"
shift 2
label=""; dry=0
while (( $# )); do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || lanes_die "label が 2 回: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
wt="${wt:A}"; prompt="${prompt:A}"
[[ -n "$label" ]] || label="${prompt:t:r}"
# ここから排他を取るまでの誤りは、取れれば今回の .done に残す（前回の DONE を残したまま止まらない）
lanes_early_target "$wt" "$label" "$dry"
lanes_require_label "$label"
lanes_require_worktree "$wt"

logdir="$wt/logs"
log="$logdir/$label.log"; json="$logdir/$label.json"; err="$logdir/$label.stderr.log"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
if (( dry )); then
  final="$logdir/$label.dry-run.prompt.md"
else
  lanes_mark_start "$logdir" "$label" claude "$wt"
  for f in "$log" "$json" "$err" "$evidence" "$final"; do lanes_rotate_log "$f"; done
fi
lanes_require_tool claude run-claude.sh
lanes_entry_preflight
mkdir -p "$logdir"
# レーン専用の作業場所。一時ファイルは ~/Downloads ではなくここへ。マージ後 cleanup が消す
if (( dry )); then scratch="$(lanes_scratch_path "$wt" "$label")"; else lanes_scratch_prepare "$wt" "$label" claude; scratch="$LANES_SCRATCH"; fi

lanes_require_prompt "$prompt"
lanes_check_claude_subscription

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
# 共通の前置き（無効化: CLAUDE_NO_PREAMBLE=1）。有効なのにテンプレが無ければ止める（黙って規則を落とさない）
preamble=""
if [[ "${CLAUDE_NO_PREAMBLE:-0}" != "1" ]]; then
  preamble="$LANES_DIR/templates/claude-impl-preamble.md"
  [[ -s "$preamble" ]] || lanes_die "前置きテンプレが無い: $preamble（不要なら CLAUDE_NO_PREAMBLE=1）"
fi
{
  print -- "# Claude 実装（$label）"
  print -- "worktree: $wt"
  print -- "branch: $branch"
  print -- "HEAD: $head"
  print -- "started: $(lanes_now)"
  print -- "scratch: $scratch"
  print -- ""
  lanes_scratch_rule "$scratch"
  print -- ""
  if [[ -n "$preamble" ]]; then
    cat "$preamble"
    print -- ""
    print -- "---"
    print -- ""
    print -- "# 案件固有の指示"
    print -- ""
  fi
  cat "$prompt"
} > "$final"

# 実装: 編集可。レビュー用 deny は付けない。stream-json で進行監視。
# 非対話の -p では許可の確認を出せない（確認が要る操作は拒否される）ので、許可モードと確認なしで使えるツールを明示する。
# 可変長オプション（--allowedTools）は `=` 形式にして後続を食わせない。プロンプトは stdin で渡し、-p は最後に置く。
# 空にした設定は付けない（そのときは利用者の ~/.claude/settings.json 次第）
# 環境変数の effort が設定ファイルと違う値で勝っていたら知らせる（渡す値は変えない）
lanes_effort_override_note CLAUDE_EFFORT
cmd=("$CLAUDE_BIN" --strict-mcp-config)
if [[ -n "$CLAUDE_IMPL_PERMISSION_MODE" ]]; then cmd+=(--permission-mode="$CLAUDE_IMPL_PERMISSION_MODE"); fi
if [[ -n "$CLAUDE_IMPL_ALLOWED_TOOLS" ]]; then cmd+=(--allowedTools="$CLAUDE_IMPL_ALLOWED_TOOLS"); fi
if [[ -n "$CLAUDE_MODEL" ]]; then cmd+=(--model "$CLAUDE_MODEL"); fi
if [[ -n "$CLAUDE_EFFORT" ]]; then cmd+=(--effort "$CLAUDE_EFFORT"); fi
cmd+=(--output-format stream-json --verbose -p)
if (( dry )); then
  print -- "[dry-run] scratch: $scratch（TMPDIR / LANES_SCRATCH。プロンプト先頭に置き場所の指示あり）"
  print -- "[dry-run] cd ${(q)wt} && TMPDIR=${(q)scratch}/ LANES_SCRATCH=${(q)scratch} ${(q)cmd[@]} < ${(q)final} > ${(q)json} 2> ${(q)err}"
  exit 0
fi

cd "$wt"
started="$(lanes_now)"; t0=$(date +%s)
head_before="$(git rev-parse --short=12 HEAD)"
{
  print -- "# run-claude: $label"
  print -- "started: $started"
  print -- "pid: $$"
  print -- "worktree: $wt"
  print -- "git: $(lanes_git_summary "$wt")"
  print -- "prompt: $prompt"
  print -- "preamble: ${preamble:-(なし: CLAUDE_NO_PREAMBLE=1)}"
  print -- "scratch: $scratch"
  print -- "----"
} > "$log"

rc=0
lanes_start_child "${cmd[@]}" < "$final" > "$json" 2> "$err"
wait "$LANES_CHILD" || rc=$?
lanes_logdir_check
LANES_CHILD=""

elapsed=$(( ($(date +%s) - t0) / 60 ))
head_after="$(git rev-parse --short=12 HEAD)"
# 最終テキストを log 末尾へ（result イベントがあれば）
python3 - "$json" "$log" <<'PY' || true
import json, pathlib, sys
src, dst = sys.argv[1], sys.argv[2]
raw = pathlib.Path(src).read_text(encoding="utf-8", errors="replace")
body = None
for line in raw.splitlines():
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if isinstance(d, dict) and d.get("type")=="result" and isinstance(d.get("result"), str):
        body = d["result"]
if body:
    with open(dst, "a", encoding="utf-8") as f:
        f.write("\n----\n" + body + "\n")
PY
changed="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
untracked="$(git status --porcelain | grep -c '^??' || true)"
{
  print -- "## Claude 実装証跡（$label）"
  print -- "- 結果: EXIT:$rc"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- HEAD: $head_before → $head_after / tracked 変更 $changed / 未追跡 $untracked"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分"
  print -- "- ログ: $log / $json / $final"
  print -- "- 作業場所（scratch）: $scratch（${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"
} > "$evidence"
{ print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; } >> "$log"
cat "$evidence"
lanes_mark_done "$rc" "EXIT:$rc"
exit $rc
