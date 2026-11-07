#!/bin/zsh -f
# 実装ランチャ（Codex。明示したときだけ使う。既定の実装は run-claude.sh、振り分けの入口は run-impl.sh）。
# 構成（LANES_TOOLS）に codex が無ければ起動しない（exit 2）。CODEX_MODEL / CODEX_EFFORT が空なら付けない。
# sandbox は CODEX_IMPL_SANDBOX（既定 workspace-write）を明示する。使い方:
#   run-codex.sh <worktree> <prompt.md> [label] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# 出力: <worktree>/logs/<label>.log（全出力）/ <label>.last.md（最終メッセージ）/ <label>.evidence.md（PR 貼り付け用）
#       <label>.pid（起動時）/ <label>.done（終了時）← 生死は lanes-status.sh <worktree> <label> で見る
# label 省略時はプロンプトのファイル名（拡張子なし）。英数と . _ - のみ
# 起動は親を残したままバックグラウンドで行う（短命のシェルから nohup & で切り離すと親の終了で即死する）
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"

usage="使い方: run-codex.sh <worktree> <prompt.md> [label] [--dry-run]"
(( $# >= 2 )) || lanes_die "$usage"
wt="$1"; prompt="$2"; shift 2; label=""; dry=0
[[ -n "$wt" && -n "$prompt" ]] || lanes_die "$usage"
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
log="$logdir/$label.log"; last="$logdir/$label.last.md"; evidence="$logdir/$label.evidence.md"
# 起動の事実（.pid）を最初に残す。以後どこで落ちても _common.sh の TRAPEXIT が .done（FAILED）を書く。dry-run はファイルを触らない
if (( ! dry )); then
  lanes_mark_start "$logdir" "$label" codex "$wt"
  lanes_scratch_prepare "$wt" "$label" codex   # レーン専用の作業場所（TMPDIR / LANES_SCRATCH）
  lanes_rotate_log "$log"; lanes_rotate_log "$last"; lanes_rotate_log "$evidence"   # 前回の出力はここで回転（失敗時に前回の証跡を指さない）
fi
lanes_require_tool codex run-codex.sh

lanes_require_prompt "$prompt"
lanes_check_codex_subscription
lanes_codex_no_mcp_args "$wt"

# sandbox（閉じ込めの範囲）を明示する（指定しないと ~/.codex/config.toml 次第になる）。空なら付けない
case "$CODEX_IMPL_SANDBOX" in
  ""|read-only|workspace-write|danger-full-access) ;;
  *) lanes_die "CODEX_IMPL_SANDBOX は read-only / workspace-write / danger-full-access のどれか（空なら付けない）: '$CODEX_IMPL_SANDBOX'" ;;
esac
sandbox_args=()
if [[ -n "$CODEX_IMPL_SANDBOX" ]]; then sandbox_args+=(--sandbox "$CODEX_IMPL_SANDBOX"); fi
git_common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" || lanes_die "git の管理フォルダを確かめられない: $wt"
git_dir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir)" || lanes_die "git の管理フォルダを確かめられない: $wt"
if [[ "$CODEX_IMPL_SANDBOX" == workspace-write ]]; then
  # worktree の .git は本体のリポの管理フォルダを指すので、commit に要る場所だけを書ける場所に足す。
  #   その worktree 専用の gitdir（.git/worktrees/<名前>。HEAD・index・HEAD の reflog・COMMIT_EDITMSG）と、
  #   共通の管理フォルダの objects（commit の中身）・refs（枝の先）・logs（枝の reflog）
  # 共通の config・hooks・info は足さない。サンドボックスの中から書けると、後でサンドボックスの外の git 操作から実行され得るため。
  # ただし gitdir の中の制御ファイル（commondir・gitdir・config.worktree）は書けてしまう（commondir を偽の管理フォルダへ向けて
  # そこの config に core.fsmonitor / core.hooksPath を書く筋がある）。書ける場所を gitdir の中の
  # 個々のファイル（HEAD・index・logs/HEAD など）に絞ると、git が作る一時ファイル（index.lock・ORIG_HEAD など）の置き場が無くなり
  # commit が落ちるので絞らない。代わりに下の cdx_git_fingerprint で子の前後を比べ、違えば git を 1 回も呼ばずに止める。
  # 管理フォルダが分かれていない（worktree でなく本体の checkout で回す）ときは、index や HEAD が共通の管理フォルダの直下にあり
  # 絞れないので、管理フォルダ全体を足して注意を出す（レーンは worktree で回す前提。docs/config.md）
  # 値は TOML（設定ファイルの書式）の配列。JSON の文字列は TOML の文字列としても読める
  if [[ "${git_dir:A}" == "${git_common:A}" ]]; then
    print -u2 -- "注意: $wt は worktree ではない（管理フォルダが共通）。commit のため git の管理フォルダ全体（config・hooks を含む）を Codex の書ける場所に足す"
    git_roots=("${git_common:A}")
  else
    git_roots=("${git_dir:A}" "${git_common:A}/objects" "${git_common:A}/refs" "${git_common:A}/logs")
  fi
  roots="$(python3 -c 'import json, sys; print(json.dumps(sorted(set(sys.argv[1:]))))' "${git_roots[@]}")"
  sandbox_args+=(-c "sandbox_workspace_write.writable_roots=$roots")
fi

# 子の実行中に書き換えられると、ランチャがサンドボックスの外で回す git が任意のコマンドを動かし得る、git の制御ファイルの指紋
# （中身は _common.sh の lanes_git_ctl_fingerprint。Codex レビューと共通）
cdx_git_fingerprint() { lanes_git_ctl_fingerprint "$wt" "$git_dir" "$git_common"; }

# プロンプトは stdin で渡す（`-` = stdin から読む）。位置引数だと `-` や `---` で始まる md がオプション扱いされて即死する
cmd=("$CODEX_BIN" exec "${LANES_CODEX_NO_MCP_ARGS[@]}" "${sandbox_args[@]}")
if [[ -n "$CODEX_MODEL" ]]; then cmd+=(-m "$CODEX_MODEL"); fi
if [[ -n "$CODEX_EFFORT" ]]; then cmd+=(-c "model_reasoning_effort=$CODEX_EFFORT"); fi
# Codex CLI 自身が -o の先へ書く（サンドボックスの外の処理）。logs/ の中だと、子が置いた symlink を辿って外へ書きうるので、
# 子の書ける場所（worktree・TMPDIR・/tmp）の外にあるランチャ専用のフォルダへ書かせ、子の後に logs/ へ写す
out_root="${XDG_STATE_HOME:-$HOME/.local/state}/lanewright/out"
if (( dry )); then
  out_dir="$out_root/$label.XXXXXX"
else
  mkdir -p "$out_root" && chmod 700 "${out_root:h}" "$out_root" || lanes_die "最終メッセージの置き場所を作れない: $out_root"
  out_dir="$(mktemp -d "$out_root/$label.XXXXXX")" || lanes_die "最終メッセージの置き場所を作れない: $out_root"
fi
cmd+=(--skip-git-repo-check -o "$out_dir/last.md" -)
if (( dry )); then
  print -- "[dry-run] cd ${(q)wt} && ${(q)cmd[@]} < ${(q)prompt} > ${(q)log} 2>&1"
  exit 0
fi

cd "$wt"
started="$(lanes_now)"; t0=$(date +%s)
head_before="$(git rev-parse --short=12 HEAD)"
git_fp_before="$(cdx_git_fingerprint)" || lanes_die "起動前の git 制御ファイルの確認に失敗"
{
  print -- "# run-codex: $label"
  print -- "started: $started"
  print -- "pid: $$"
  print -- "worktree: $wt"
  print -- "git: $(lanes_git_summary "$wt")"
  print -- "prompt: $prompt"
  print -- "----"
} > "$log"

# 子は背景起動して wait（シグナルで wait が中断され、trap が子へ TERM を伝播できる）
rc=0
lanes_start_child "${cmd[@]}" < "$prompt" >> "$log" 2>&1
wait "$LANES_CHILD" || rc=$?
lanes_logdir_check
# 子の後は書き手がランチャだけなので、確かめた logs/ へ写してよい
if [[ -f "$out_dir/last.md" && ! -L "$out_dir/last.md" ]]; then cp "$out_dir/last.md" "$last"; else : > "$last"; fi
rm -rf -- "$out_dir"
LANES_CHILD=""   # 以後の trap で（pid 再利用した）別プロセスを kill しない

elapsed=$(( ($(date +%s) - t0) / 60 ))
# git を 1 回も呼ぶ前に、制御ファイルが変わっていないかを見る（run-gemini.sh の .git ファイルの確認と同じやり方）
git_fp_after="$(cdx_git_fingerprint 2>/dev/null)" || git_fp_after=ERROR
if [[ "$git_fp_after" != "$git_fp_before" ]]; then
  print -- "[run-codex] $(lanes_now) git の制御ファイル（.git・commondir・gitdir・config・config.worktree・hooks）が変わった → git を実行せず停止" >> "$log"
  print -u2 -- "→ Codex の実行中に git の制御ファイルが変わった。git を実行せず停止（EXIT:4）。$wt/.git と $git_dir・$git_common の中身を手で確かめてから直す"
  print -- "EXIT:4" >> "$log"
  lanes_mark_done 4 "VERDICT: NEEDS_FIX" "git の制御ファイルの変更を検出（git 未実行）"
  exit 4
fi
head_after="$(git rev-parse --short=12 HEAD)"
verdict="$(lanes_extract_verdict "$last")"
if (( rc == 0 )) && [[ "$verdict" == "VERDICT: NONE" ]]; then rc=3; fi
if (( rc == 0 )) && [[ "$verdict" == "VERDICT: NEEDS_FIX" ]]; then rc=4; fi
changed="$(git -c core.fsmonitor=false status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
untracked="$(git -c core.fsmonitor=false status --porcelain | grep -c '^??' || true)"

{
  print -- "## Codex 実装証跡（$label）"
  print -- "- 結果: EXIT:$rc / 自己申告 $verdict"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- HEAD: $head_before → $head_after / 未 commit の tracked 変更 $changed 件 / 未追跡 $untracked 件"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分"
  print -- "- ログ: $log（全出力）/ $last（最終メッセージ）"
  if [[ -n "${LANES_SCRATCH:-}" ]]; then print -- "- 作業場所（scratch）: $LANES_SCRATCH（${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"; fi
} > "$evidence"

{ print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; } >> "$log"
cat "$evidence"
lanes_mark_done "$rc" "$verdict"
exit $rc
