#!/bin/zsh -f
# QA 本線ランチャ（統合先の枝へのマージ後・読み取り主体）。使い方:
#   run-qa.sh <worktree> <prompt.md> [label] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# テンプレ templates/qa-bot.md を前置し、案件固有 prompt を結合する。
# 出力はレビュー本線と同型（logs/<label>.{log,json,stderr.log,prompt.md,evidence.md,pid,done}）
# 最終行 VERDICT: CLEAN | NEEDS_FIX。CLEAN = bot QA 成功（人の QA 待ちとして報告する）。NEEDS_FIX = 修正レーン → レビューのレーンへ戻す。
# 課題管理ツールとは連携しない（必要なら手順書に沿って自分で足す）。
# 司令塔の Shell から起動するときは、親が先に終わらないよう背景起動で親を残す。
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
# rvd_git_guard（git の管理フォルダ側の前後比較。Claude レビューと共通）を使う。読み込むのは関数の定義だけ
source "$LANES_DIR/review-dedup.zsh"

usage="使い方: run-qa.sh <worktree> <prompt.md> [label] [--dry-run]"
wt="${1:-}"; prompt="${2:-}"
[[ -n "$wt" && -n "$prompt" ]] || lanes_die "$usage"
shift 2
label=""; dry=0
while (( $# )); do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --mode|--base) lanes_defer_die "run-qa.sh は --mode/--base を取らない（指定した履歴の QA 専用）。$usage"; (( $# >= 2 )) && shift 2 || shift ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || lanes_die "label が 2 回指定されている: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
mode="qa"; base=""
wt="${wt:A}"; prompt="${prompt:A}"
[[ -n "$label" ]] || label="${prompt:t:r}"
# ここから排他を取るまでの誤りは、取れれば今回の .done に残す（前回の DONE を残したまま止まらない）
lanes_early_target "$wt" "$label" "$dry"
lanes_require_label "$label"
lanes_require_worktree "$wt"

logdir="$wt/logs"
log="$logdir/$label.log"; json="$logdir/$label.json"; err="$logdir/$label.stderr.log"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
# 起動の事実（.pid）を最初に残し、前回の出力をここで回転する（以後どこで落ちても .done は今回の失敗を指し、status が前回の証跡を案内しない）。
# dry-run は .pid / .done / ログを触らず、結合結果だけ <label>.dry-run.prompt.md に書く
if (( dry )); then
  final="$logdir/$label.dry-run.prompt.md"
else
  lanes_mark_start "$logdir" "$label" qa "$wt"
  for f in "$log" "$json" "$err" "$evidence" "$final"; do lanes_rotate_log "$f"; done
fi
# 構成（LANES_TOOLS）の点検。誤った構成・claude の無い構成では起動しない（exit 2。排他の後なので .done に残る）
lanes_require_tool claude run-qa.sh
mkdir -p "$logdir"
# レーン専用の作業場所（TMPDIR / LANES_SCRATCH）。マージ後 cleanup が消す
(( dry )) || lanes_scratch_prepare "$wt" "$label" qa

lanes_require_prompt "$prompt"
lanes_check_claude_subscription

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse HEAD)"
template="$LANES_DIR/templates/qa-bot.md"
[[ -s "$template" ]] || lanes_die "テンプレが無い: $template"

# QA にも共通の scratch 指示を渡す。dry-run ではフォルダを作らず予定パスだけ示す。
scratch_path="$(lanes_scratch_path "$wt" "$label")"
(( dry )) || scratch_path="$LANES_SCRATCH"
scratch_rule="$(lanes_scratch_rule "$scratch_path")"

# テンプレ + 案件固有プロンプトを結合して、実際に渡した全文を残す
python3 - "$template" "$prompt" "$final" "$wt" "$branch" "$head" "$base" "$mode" "$(lanes_now)" "$scratch_rule" "$scratch_path" <<'PY'
import sys, pathlib
tpl, case, out, wt, branch, head, base, mode, date = sys.argv[1:10]
t = pathlib.Path(tpl).read_text(encoding="utf-8")
for k, v in {"WORKTREE": wt, "BRANCH": branch, "HEAD": head, "BASE": base or "(なし)", "MODE": mode, "DATE": date, "SCRATCH": sys.argv[11]}.items():
    t = t.replace("{{" + k + "}}", v)
c = pathlib.Path(case).read_text(encoding="utf-8")
pathlib.Path(out).write_text(sys.argv[10] + "\n\n" + t.rstrip() + "\n\n---\n\n# 案件固有の指示（司令塔が記入）\n\n" + c.rstrip() + "\n", encoding="utf-8")
PY

# 読み取り専用の担保: --tools で内蔵ツール集合を絞り、編集系とサブエージェント起動は明示拒否。
# 可変長オプションは `=` 形式にして後続を食わせない。プロンプトは stdin（ARG_MAX 回避）。-p は最後。
# --strict-mcp-config: ユーザー設定の MCP（外部サービスへの接続）を読み込まない。必要なら --mcp-config=<file> を足す
# --output-format stream-json: 1 行 1 イベントで進行中も $json が増える（生死監視の「最終出力」に使う）。json だと終了までゼロ出力
# モデル・effort は設定が空なら付けない（CLI の既定を使う）
# 環境変数の effort が設定ファイルと違う値で勝っていたら知らせる（渡す値は変えない）
lanes_effort_override_note CLAUDE_EFFORT
model_args=()
[[ -z "${CLAUDE_MODEL:-}" ]] || model_args+=(--model "$CLAUDE_MODEL")
[[ -z "${CLAUDE_EFFORT:-}" ]] || model_args+=(--effort "$CLAUDE_EFFORT")
# 使えるツールに編集系・サブエージェントがあれば止め、拒否は固定の一覧 + CLAUDE_REVIEW_DENY にする（外から外せない）
lanes_claude_review_resolve
cmd=("$CLAUDE_BIN" --tools="$LANES_CLAUDE_REVIEW_TOOLS" --allowedTools="$LANES_CLAUDE_REVIEW_TOOLS" --disallowedTools="$LANES_CLAUDE_REVIEW_DENY" --strict-mcp-config --permission-mode manual "${model_args[@]}" --output-format stream-json --verbose -p)
if (( dry )); then
  print -- "[dry-run] cd ${(q)wt} && ${(q)cmd[@]} < ${(q)final} > ${(q)json} 2> ${(q)err}"
  print -- "[dry-run] 結合済みプロンプト: $final"
  exit 0
fi

cd "$wt"
# 状態の記号だけでなく、履歴・索引・各ファイルの内容/種類/実行権限を記録する。
# 既存の未保存変更が同じ M のまま書き換えられても検出する。実値は保存しない。
qa_snapshot() {
  python3 - "$wt" "$1" "$label" <<'SNAP'
import hashlib, json, os, pathlib, stat, subprocess, sys
root, out, label = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args])
def digest(data):
    return hashlib.sha256(data).hexdigest()
tracked = set(git("ls-files", "-z", "--cached").split(b"\0")) - {b""}
others = set(git("ls-files", "-z", "--others", "--exclude-standard").split(b"\0")) - {b""}
ignored = set(git("ls-files", "-z", "--others", "--ignored", "--exclude-standard").split(b"\0")) - {b""}
# 依存物・ビルド等の既知の生成物だけを省く。除外された手動メモや設定も内容比較する。
generated = ("node_modules/", ".next/", ".turbo/", ".cache/", "coverage/", "test-results/", "playwright-report/")
ignored = {raw for raw in ignored if not os.fsdecode(raw).startswith(generated) and not os.fsdecode(raw).endswith(".tsbuildinfo")}
files = {}
outputs = {"logs/" + label + "." + suffix for suffix in
           ("log", "json", "stderr.log", "prompt.md", "evidence.md", "pid", "done", "launch.log")}
for raw in sorted(tracked | others | ignored):
    name = os.fsdecode(raw)
    # ランチャ自身の未追跡出力だけを除外する。追跡対象の logs は比較する。
    if raw not in tracked and name in outputs:
        continue
    path = root / name
    try:
        st = path.lstat()
        mode = stat.S_IFMT(st.st_mode) | (st.st_mode & 0o111)
        if path.is_symlink():
            value = digest(os.fsencode(os.readlink(path)))
        elif path.is_file():
            h = hashlib.sha256()
            with path.open("rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
            value = h.hexdigest()
        elif path.is_dir() and raw in tracked:
            # submodule の履歴・未保存変更も比較する。
            value = digest(subprocess.check_output(["git", "-C", str(path), "diff", "--binary", "HEAD"]) +
                           subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"]) +
                           subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "-uall"]))
        else:
            value = "特殊ファイル"
        files[name] = [mode, value]
    except FileNotFoundError:
        files[name] = None
snapshot = {"HEAD": git("rev-parse", "HEAD").decode().strip(),
            "branch": git("rev-parse", "--symbolic-full-name", "HEAD").decode().strip(),
            "index": digest(git("ls-files", "--stage", "-z") + git("ls-files", "-v", "-z")), "files": files}
out.write_text(json.dumps(snapshot, ensure_ascii=True, sort_keys=True))
SNAP
}
before="$LANES_SCRATCH/qa-before.json"
after="$LANES_SCRATCH/qa-after.json"
qa_snapshot "$before" || lanes_die "QA 開始時の内容を記録できない"
# 写しは子（QA の Claude）が書ける $LANES_SCRATCH にあるので、中身のハッシュ（指紋）をメモリ（変数）に持ち、比べる前に確かめる。
# 子が「前」の写しを「後」に合わせて書き換えて、変更を隠すことを防ぐ
before_sum="$(shasum -a 256 < "$before")" || lanes_die "QA 開始時の写しの指紋を取れない"
# QA も Bash 付きのツール集合で動くので、Claude レビューと同じく git の管理フォルダ側（共通の config・config.worktree・hooks・
# info/attributes・タグ・stash）も前後で比べる
guard_before="$(rvd_git_guard "$wt")" || lanes_die "QA 開始時の git 管理フォルダの確認に失敗"
python3 - "$before" "$head" <<'EXPECTED' || lanes_die "QA 準備中に対象履歴が変化した"
import json, sys
sys.exit(0 if json.load(open(sys.argv[1]))["HEAD"] == sys.argv[2] else 1)
EXPECTED
started="$(lanes_now)"; t0=$(date +%s)

# QA の子から push（と fetch）をできなくする（読み取り主体の役。git の通信は要らない）
lanes_block_git_transport
# 子は監督役の下で背景起動して wait（シグナルで wait が中断され、trap が子へ TERM を伝播できる）。
# 他のランチャと同じく、親コマンド終了後に残った孫も監督役が回収する。
rc=0
lanes_start_child "${cmd[@]}" < "$final" > "$json" 2> "$err"
wait "$LANES_CHILD" || rc=$?
lanes_logdir_check
LANES_CHILD=""   # 以後の trap で（pid 再利用した）別プロセスを kill しない
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
# 変換が非 0（result 無し・is_error・想定外の失敗すべて）なら本文の VERDICT は採用しない（run-claude-review.sh と同じ）
if (( conv_rc != 0 )); then
  (( conv_rc == 4 || conv_rc == 5 )) || print -u2 -- "warn: JSON→本文の変換に失敗（rc=$conv_rc）。$json を直接読むこと"
  verdict="VERDICT: NONE"
else
  verdict="$(lanes_extract_verdict "$log")"
fi
[[ "$verdict" == "VERDICT: PASS" ]] && verdict="VERDICT: CLEAN"
(( rc == 0 )) || verdict="VERDICT: NONE"   # claude が非 0 で終わった本文の VERDICT は採用しない
head_after="$(git rev-parse HEAD)"
# 「後」の写しの場所も子が書ける。symlink などを置かれていたら、その先へ書かないよう先に消してから作る
rm -rf -- "$after"
qa_snapshot "$after" || lanes_die "QA 終了時の内容を記録できない"
before_ok=1
[[ -f "$before" && ! -L "$before" && "$(shasum -a 256 < "$before" 2>/dev/null)" == "$before_sum" ]] || before_ok=0
guard_after="$(rvd_git_guard "$wt")" || guard_after=ERROR
touched="$(python3 - "$before" "$after" <<'COMPARE'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:])
for key in ("HEAD", "branch", "index"):
    if a[key] != b[key]:
        print("  変更: " + key)
for name in sorted(set(a["files"]) | set(b["files"])):
    if a["files"].get(name, "未存在") != b["files"].get(name, "未存在"):
        print("  内容変更: " + json.dumps(name, ensure_ascii=False))
COMPARE
)" || lanes_die "QA 前後の比較に失敗"
if (( ! before_ok )); then
  [[ -z "$touched" ]] || touched+=$'\n'
  touched+="  変更: QA 開始時の写し（$before）が QA の実行中に書き換えられた（前後の比較を信用できない）"
fi
if [[ "$guard_after" != "$guard_before" ]]; then
  [[ -z "$touched" ]] || touched+=$'\n'
  touched+="  変更: git の管理フォルダ（config・config.worktree・hooks・info/attributes・タグ・stash のどれか）"
fi
dirty="$(print -r -- "$touched" | grep -c . || true)"
if (( dirty )); then
  verdict="VERDICT: NEEDS_FIX"
  (( rc != 0 )) || rc=4
fi
scope="full"; [[ "$mode" == "delta" ]] && scope="delta（起点 $base）"

{
  print -- "## QA レビュー証跡（$label）"
  print -- "- $verdict"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- モード: $scope"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分 / EXIT:$rc"
  print -- "- レビュー中の HEAD 変化: $head → $head_after / 作業ツリー・git 管理フォルダの変更 $dirty 件（内容・索引・履歴・設定・hooks・タグ・stash の比較。変更ありは不合格）"
  [[ -n "$touched" ]] && print -r -- "$touched"
  print -- "- ログ: $log（本文）/ $json（生）/ $final（渡した全文）"
  if [[ -n "${LANES_SCRATCH:-}" ]]; then print -- "- 作業場所（scratch）: $LANES_SCRATCH（マージ後の cleanup で削除）"; fi
} > "$evidence"

{ print -- ""; print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; print -- "$verdict"; } >> "$log"
cat "$evidence"
final_rc=$rc
(( rc == 0 )) && [[ "$verdict" != "VERDICT: CLEAN" && "$verdict" != "VERDICT: NEEDS_FIX" ]] && final_rc=3   # 完走したのに VERDICT が無い
lanes_mark_done "$final_rc" "$verdict" "claude rc=$rc"
exit $final_rc
