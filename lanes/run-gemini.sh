#!/bin/zsh -f
# 軽い実装レーン（Gemini / Antigravity CLI agy）。レビューは別レーンで行う（構成のレビュー役。入口は run-review.sh）。
# 構成（LANES_TOOLS）に gemini が無ければ起動しない（exit 2）。GEMINI_MODEL / GEMINI_EFFORT が空なら付けない。
# 使い方: run-gemini.sh <worktree> <prompt.md> [label] --verify "<検証コマンド>" --allow-path <相対パス> [--no-push] [--dry-run]
#   label は指示書の直後に置く（不明なオプションは止めて記録する。その後ろの - で始まらない語は、そのオプションの値として読み捨てる）
# --verify は必須。長時間の全体テストと build はここへ渡す。正常終了なら差分なしでも検証する。
# --allow-path は必須・複数指定可。ファイルは完全一致、末尾 / は配下。開始時の未保存変更は拒否する。
# agy には --sandbox / --settings / ANTIGRAVITY_HEADLESS=true を強制し、MCP と作業場所外の編集を拒否する。
# MCP 設定自体の読み込み・接続開始を隔離するものではない。ツール呼び出しの拒否を強制する。
# Git の書き込みはランチャが担当。今回の COMMIT_MSG.txt と許可範囲の差分だけを、検証成功後に保存する。
# agy の書き込み先は worktree と scratch だけ。Git 管理領域（.git 本体・フック・設定）はサンドボックスへ渡さない。
# 本体 checkout（.git がディレクトリで作業場所の中にある）では起動しない。専用の linked worktree が前提。
# agy の終了後、ランチャが git を実行する前に worktree の .git ファイル（管理領域への入口）が変わっていないことを確かめる。
# Git の読み取り（diff / log / status）は書き込み不要の形で許す（GIT_OPTIONAL_LOCKS=0）。
# main / master / 統合先の枝（LANES_BASE_BRANCH）/ detached は push しない。--no-push は通常終了時もローカル保存まで。
# agy の子孫を開始時刻付きで記録し、終了時には自分の子だけを回収する。
# idle が続いても子が実行中なら待つ。子が無く出力が止まったときの強制停止は EXIT:3。
# 異常終了時は差分あり・今回のメッセージあり・監査と検証成功の場合だけ救済 commit（EXIT:3・push なし）。
# 無出力上限は EXIT:8、作業中の差分を scratch に保存。全体の上限は --print-timeout（既定 75m）。
# 変更なしの一時エラーだけ 1 回再試行。前回のメッセージは再試行前にも退避する。
# 書き込み先と JSON ログは厳密に監査し、不明・破損・欠損は成功扱いにしない。
# 出力: logs/<label>.{log,json,stderr.log,prompt.md,evidence.md,pid,done,verify.log}
# 終了コード: 0=正常完了かつ検証成功／2=引数・前提／3=agy 異常終了（救済保存も含む）
#             ／4=監査・保存範囲違反／5=メッセージ無し・commit 失敗／6=push 失敗／7=検証失敗／8=無出力停止
set -euo pipefail
# 設定値の誤りもすぐには止めず、label が決まってから今回の失敗として .done に残す（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"

usage="使い方: run-gemini.sh <worktree> <prompt.md> [label] --verify \"<cmd>\" --allow-path <相対パス> [--allow-path <相対パス> ...] [--no-push] [--dry-run]"
wt="${1:-}"; prompt="${2:-}"
[[ -n "$wt" && -n "$prompt" ]] || lanes_die "$usage"
shift 2
label=""; dry=0; push=1; verify=""
typeset -a allowed_paths
allowed_paths=()
while (( $# )); do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --no-push) push=0; shift ;;
    --verify) (( $# >= 2 )) || { lanes_defer_die "--verify に値が無い"; shift; continue; }; [[ -z "$verify" ]] || lanes_defer_die "--verify が 2 回"; verify="$2"; shift 2 ;;
    --allow-path) (( $# >= 2 )) || { lanes_defer_die "--allow-path に値が無い"; shift; continue; }; allowed_paths+=("$2"); shift 2 ;;
    --*) lanes_defer_die "不明なオプション: $1 / $usage"; lanes_unknown_opt_width "$@"; shift "$REPLY" ;;   # 値らしい次の語も読み捨てる（label と取り違えない）
    *) [[ -z "$label" ]] || lanes_die "label が 2 回: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
wt="${wt:A}"; prompt="${prompt:A}"
[[ -n "$label" ]] || label="${prompt:t:r}"
# ここから排他を取るまでの誤り（GEMINI_* の値など）は、取れれば今回の .done に残す
lanes_early_target "$wt" "$label" "$dry"
lanes_require_label "$label"
lanes_require_worktree "$wt"

# 保存範囲は文章から推測しない。末尾 / はディレクトリ全体、それ以外は完全一致。
# 起動前の変更、範囲外の変更、リンクで外へ向く変更は保存しない。Git のパスは NUL 区切りで扱う。
gem_changes() {   # initial / check / stage。stage も保存直前に同じ検査を行う
  python3 - "$wt" "$1" "${allowed_paths[@]}" <<'PY'
import os, subprocess, sys
from pathlib import Path
wt, mode, *scopes = sys.argv[1:]
root = Path(wt).resolve()
def fail(message):
    print('[run-gemini] ' + message, file=sys.stderr)
    sys.exit(1)
def reserved(p):
    return p.split('/')[0] in ('.git', 'logs')
for scope in scopes:
    plain = scope.rstrip('/')
    if (not plain or scope.startswith('/') or any(c in scope for c in '\n\r\0')
            or any(p in ('', '.', '..') for p in plain.split('/')) or reserved(plain)):
        fail('--allow-path が不正（相対パス・logs と .git 以外を指定）')
    if not (root / plain).resolve().is_relative_to(root):
        fail('--allow-path が作業場所の外を指している')
def allowed(p):
    return any(p == s or (s.endswith('/') and p.startswith(s)) for s in scopes)
raw = subprocess.check_output(['git', '-C', wt, 'status', '--porcelain=v1', '-z', '--untracked-files=all'])
entries = iter(raw.split(b'\0'))
paths = set()
for entry in entries:
    if not entry:
        continue
    flag, name = entry[:2].decode('ascii'), os.fsdecode(entry[3:])
    names = [name]
    if 'R' in flag or 'C' in flag:
        names.append(os.fsdecode(next(entries)))
    # ランチャ自身の未追跡ログだけは許容。追跡済みログの変更やステージ追加は拒否。
    if flag == '??' and name.startswith('logs/'):
        continue
    if mode == 'initial':
        fail('開始時に未保存の変更がある → 起動禁止（変更はそのまま残す）')
    for p in names:
        if reserved(p) or not allowed(p):
            fail('許可範囲外の変更がある → commit しない')
        if not (root / p).resolve().is_relative_to(root):
            fail('変更ファイルが作業場所の外を指している → commit しない')
        paths.add(p)
if mode == 'stage' and paths:
    # パス指定の特殊構文を無効にし、確認した変更だけをステージする。
    subprocess.run(['git', '-C', wt, '--literal-pathspecs', 'add', '-A', '--pathspec-from-file=-',
                    '--pathspec-file-nul'], input=b''.join(os.fsencode(p) + b'\0' for p in sorted(paths)), check=True)
print(len(paths))
PY
}

print_timeout="${GEMINI_PRINT_TIMEOUT:-75m}"
idle_grace="${GEMINI_IDLE_GRACE:-60}"; resume_grace="${GEMINI_IDLE_RESUME_GRACE:-300}"; noout_sec="${GEMINI_NOOUTPUT_SEC:-600}"; poll="${GEMINI_POLL_SEC:-5}"
[[ "$idle_grace" == <-> && "$resume_grace" == <-> && "$noout_sec" == <-> && "$poll" == <-> ]] || lanes_die "GEMINI_IDLE_GRACE / GEMINI_IDLE_RESUME_GRACE / GEMINI_NOOUTPUT_SEC / GEMINI_POLL_SEC は整数秒"
(( poll >= 1 )) || lanes_die "GEMINI_POLL_SEC は 1 以上"
[[ "$print_timeout" =~ '^[0-9]+(ms|s|m|h)?$' ]] || lanes_die "GEMINI_PRINT_TIMEOUT の形が不正（例: 75m）"

logdir="$wt/logs"
log="$logdir/$label.log"; json="$logdir/$label.json"; err="$logdir/$label.stderr.log"
final="$logdir/$label.prompt.md"; evidence="$logdir/$label.evidence.md"
json1="$logdir/$label.try1.json"; err1="$logdir/$label.try1.stderr.log"
if (( dry )); then
  final="$logdir/$label.dry-run.prompt.md"
else
  lanes_mark_start "$logdir" "$label" gemini "$wt"
fi
lanes_require_tool gemini run-gemini.sh
lanes_entry_preflight
[[ -n "${verify//[[:space:]]/}" ]] || lanes_die "--verify は必須（全体テストと build を指定）"
(( ${#allowed_paths} )) || lanes_die "--allow-path は必須（今回の保存可能なファイル、または末尾 / のディレクトリ）"
gem_changes initial >/dev/null || lanes_die "作業開始前の変更・保存範囲の確認に失敗"
if (( ! dry )); then
  for f in "$log" "$json" "$err" "$evidence" "$final" "$json1" "$err1"; do lanes_rotate_log "$f"; done
fi
mkdir -p "$logdir"
if (( dry )); then scratch="$(lanes_scratch_path "$wt" "$label")"; else lanes_scratch_prepare "$wt" "$label" gemini; scratch="$LANES_SCRATCH"; fi

lanes_require_prompt "$prompt"
lanes_check_gemini_subscription
# --sandbox が無効になる環境では走らせない。対象は Mac の端末サンドボックス。
[[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] || lanes_die "端末サンドボックスを強制できない環境 → 起動禁止"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny file-write*)' /usr/bin/true 2>/dev/null \
  || lanes_die "端末サンドボックスを有効にできない → 起動禁止"
gem_help="$(ANTIGRAVITY_HEADLESS=true "$GEMINI_BIN" --help < /dev/null 2>&1)" || lanes_die "agy --help の確認に失敗"
for option in --sandbox --settings; do
  [[ "$gem_help" == *"$option"* ]] || lanes_die "agy が $option に未対応 → 起動禁止"
done
unset gem_help

branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="(detached)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir)"
gitcommon="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
# サンドボックス内の agy が .git/hooks や設定を書き換えると、ランチャがサンドボックスの外で走らせる
# git commit などから実行されうる。管理領域が作業場所・scratch の外にある linked worktree に限る。
gitlink="$wt/.git"
[[ -f "$gitlink" && ! -L "$gitlink" ]] || lanes_die "本体 checkout（.git がディレクトリ）またはリンクの .git では起動しない。git worktree add で専用 worktree を作ってから渡す"
for gd in "$gitdir" "$gitcommon"; do
  [[ "${gd:A}/" != "${wt:A}/"* && "${gd:A}/" != "${scratch:A}/"* ]] || lanes_die "Git 管理領域が worktree / scratch の中にある → 起動禁止: $gd"
done
gitlink_sum="$(shasum -a 256 < "$gitlink")" || lanes_die ".git ファイルを読めない"
# agy の終了後・ランチャの git 実行前に呼ぶ。入口が変わっていたら git を一切実行せず EXIT:4 で止める。
gem_gitlink_check() {
  local now=""
  if [[ -f "$gitlink" && ! -L "$gitlink" ]]; then now="$(shasum -a 256 < "$gitlink" 2>/dev/null)" || now=""; fi
  [[ -n "$now" && "$now" == "$gitlink_sum" ]] && return 0
  print -- "[run-gemini] $(lanes_now) worktree の .git ファイルが変わった → git を実行せず停止（commit・検証もしない）" >> "$log"
  print -u2 -- "→ $gitlink が agy の実行中に変わった。git を実行せず停止（EXIT:4）。中身を確認してから git worktree repair 等で直す"
  lanes_mark_done 4 "EXIT:4" ".git ファイルの変更を検出（git 未実行）"
  exit 4
}
preamble=""
if [[ "${GEMINI_NO_PREAMBLE:-0}" != "1" ]]; then
  preamble="$LANES_DIR/templates/gemini-impl-preamble.md"
  [[ -s "$preamble" ]] || lanes_die "前置きテンプレが無い: $preamble（不要なら GEMINI_NO_PREAMBLE=1）"
fi
msgfile="$scratch/COMMIT_MSG.txt"
# 同じ label の再利用時も、今回作られた完了情報しか受け付けない。
archive_message() {
  [[ ! -L "$msgfile" && ( ! -e "$msgfile" || -f "$msgfile" ) ]] || lanes_die "COMMIT_MSG.txt が通常ファイルではない"
  lanes_rotate_log "$msgfile"
}
if (( ! dry )); then archive_message; fi
{
  print -- "# Gemini 実装（$label）"
  print -- "worktree: $wt"
  print -- "branch: $branch"
  print -- "HEAD: $head"
  print -- "started: $(lanes_now)"
  print -- "scratch: $scratch"
  print -- "commit メッセージの書き先: $msgfile"
  print -- "保存可能な相対パス（末尾 / は配下を含む）:"
  printf -- '- %s\n' "${allowed_paths[@]}"
  print -- ""
  [[ -n "$preamble" ]] && { cat "$preamble"; print -- ""; }
  lanes_scratch_rule "$scratch"
  print -- ""
  print -- "---"
  print -- ""
  print -- "# 案件固有の指示"
  print -- ""
  cat "$prompt"
} > "$final"

# 設定は起動単位で渡す。利用者の許可設定より deny が優先され、設定ファイルを変更しない。
gem_settings='{"permissions":{"deny":["mcp(*)"]},"allowNonWorkspaceAccess":false,"enableTerminalSandbox":true,"modelProvider":"","useG1Credits":false}'
cmd=("$GEMINI_BIN")
if [[ -n "$GEMINI_MODEL" ]]; then cmd+=(--model "$GEMINI_MODEL"); fi
if [[ -n "$GEMINI_EFFORT" ]]; then cmd+=(--effort "$GEMINI_EFFORT"); fi
cmd+=(--mode accept-edits --sandbox --settings "$gem_settings"
     --output-format stream-json --print-timeout "$print_timeout" --add-dir "$scratch")
# agy を新しいプロセスグループで起動する（止めるときにグループごと止められるように）
if (( dry )); then
  print -- "[dry-run] scratch: $scratch"
  print -- "[dry-run] cd ${(q)wt} && ANTIGRAVITY_HEADLESS=true TMPDIR=${(q)scratch}/ LANES_SCRATCH=${(q)scratch} GIT_DIR=${(q)gitdir} GIT_WORK_TREE=${(q)wt} GIT_CONFIG_GLOBAL=${(q)scratch}/gitconfig lanes_start_child ${(q)cmd[@]} -p \"\$(<${(q)final})\" < /dev/null > ${(q)json} 2> ${(q)err}"
  print -- "[dry-run] 見張り: idle（root agent idle）の後 子が無く json が ${idle_grace} 秒動かなければ異常終了 / 出力 ${noout_sec} 秒なしで EXIT:8 / --print-timeout $print_timeout / 確認間隔 ${poll} 秒"
  print -- "[dry-run] 必須検証（サンドボックス外・commit 前）: $verify"
  print -- "[dry-run] 終了後: 子孫を停止 → 書き込み・保存範囲検査 → 必須検証 → 今回の COMMIT_MSG.txt と許可範囲の変更だけを commit（異常終了の救済は EXIT:3・push なし）"
  exit 0
fi

# サンドボックス内の git 用の最小 gitconfig（user.name / email だけ。秘密は入れない）
gname="$(git -C "$wt" config user.name || true)"; gmail="$(git -C "$wt" config user.email || true)"
[[ -n "$gname" && -n "$gmail" ]] || lanes_die "git の user.name / user.email が取れない（$wt）"
lanes_fresh_file "$scratch/gitconfig"
{ print -- "[user]"; print -- "\tname = $gname"; print -- "\temail = $gmail"; print -- "[core]"; print -- "\tpager = cat"; print -- "[safe]"; print -- "\tdirectory = *"; } > "$scratch/gitconfig"

# 依存の自動用意（node_modules 無しで tsc が見つからず EXIT:7 になった対策）
# 探す場所は worktree の直下と、その 1 段下の apps/*/・packages/*/（よくある monorepo の形。どのリポでも同じ探し方）。
# ロックファイル（依存の版を固定するファイル）があって node_modules/.bin が無い所だけ、サンドボックスの外で入れる（秘密は読まない）:
#   package-lock.json → npm ci / pnpm-lock.yaml → pnpm install --frozen-lockfile（pnpm が無ければ止める）
#   yarn.lock だけの所は自動では入れない（版によって固定の付け方が違うため。案内だけ出す）
typeset -a dep_dirs
dep_dirs=("$wt" "$wt"/apps/*(/N) "$wt"/packages/*(/N))
for d in "${dep_dirs[@]}"; do
  # apps/・packages/ やその下が worktree の外を指す symlink だと、外で依存の導入（npm ci など）を動かしてしまうので止める
  [[ "${d:A}" == "${wt:A}" || "${d:A}/" == "${wt:A}/"* ]] || lanes_die "依存の導入先が worktree の外を指している（symlink）→ 起動禁止: $d → ${d:A}"
  [[ -d "$d/node_modules/.bin" ]] && continue
  rel="${d#$wt}"; rel="${rel#/}"; tag="${${rel:-root}//\//_}"
  if [[ -f "$d/package-lock.json" ]]; then
    print -- "[run-gemini] npm ci: ${rel:-.}"
    lanes_fresh_file "$scratch/npm-ci-$tag.log"
    ( cd "$d" && npm ci --silent ) > "$scratch/npm-ci-$tag.log" 2>&1 || lanes_die "npm ci 失敗: $d（$scratch/npm-ci-$tag.log）"
  elif [[ -f "$d/pnpm-lock.yaml" ]]; then
    command -v pnpm >/dev/null 2>&1 || lanes_die "pnpm-lock.yaml があるのに pnpm が無い: $d（pnpm を入れるか、依存を入れてから起動する）"
    print -- "[run-gemini] pnpm install --frozen-lockfile: ${rel:-.}"
    lanes_fresh_file "$scratch/pnpm-install-$tag.log"
    ( cd "$d" && pnpm install --frozen-lockfile --silent ) > "$scratch/pnpm-install-$tag.log" 2>&1 \
      || lanes_die "pnpm install 失敗: $d（$scratch/pnpm-install-$tag.log）"
  elif [[ -f "$d/yarn.lock" ]]; then
    print -- "[run-gemini] yarn.lock の依存は自動では入れない（必要なら起動前に入れる）: ${rel:-.}"
  fi
done

# ---- 子プロセスの記録と停止 ----
# 無出力の監視用に、監督役と agy の子孫を pid・pgid・lstart で数える。
# 停止対象の同一性確認と回収は共通監督役が行う。
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
gem_track_tree() {   # 根（agy）が起動時と同じプロセスのときだけ子孫を GEM_TRACK に足す。死んだ・別物になった記録は外す
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
# 停止は共通監督役に任せる。待受ポートや作業場所だけでは所有者と判断しない。
gem_kill_all() { lanes_kill_child; }
# .pid の子の記録（child_pid / child_lstart）を差し替える（再実行でも lanes_child_alive が今の子を見るように）
# （lanes_record_child は起動時の中身＋今の子だけを書き直すので、前の子の記録は残らない）
gem_record_child() { lanes_record_child "$1"; }

mtime_of() { local m; m="$(stat -f %m "$1" 2>/dev/null)" || m=0; print -- "${m:-0}"; }
idle_count() { local n; n="$(grep -c 'root agent idle' "$1" 2>/dev/null)" || n=0; print -- "${n:-0}"; }

# agy を 1 回走らせて見張る。結果: GEM_RC / GEM_IDLE_KILLED / GEM_NOOUT / GEM_SECS
run_agy_once() {
  local j="$1" e="$2" now last m idle_at=0 idle_seen=0 n ta grace=$idle_grace
  GEM_RC=0; GEM_IDLE_KILLED=0; GEM_NOOUT=0; ta=$(date +%s)
  # 子の実行中はログへパスのまま書かない（子が logs/<label>.log を外向きの symlink にすると先へ追記してしまう）。
  # 子の起動前に開いた番号（fd）にだけ書く。差し替えられても、開いた元のファイルに書くだけで外へは届かない
  lanes_logdir_check
  exec {GEM_LOGFD}>>"$log"
  ANTIGRAVITY_HEADLESS=true GIT_DIR="$gitdir" GIT_WORK_TREE="$wt" GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat \
    lanes_start_child "${cmd[@]}" -p "$(<"$final")" < /dev/null > "$j" 2> "$e"
  GEM_PGID="$LANES_CHILD"; GEM_TRACK=()
  GEM_ROOT_LS="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$LANES_CHILD" 2>/dev/null)" || GEM_ROOT_LS=""
  GEM_ROOT_LS="${(j: :)${=GEM_ROOT_LS}}"
  gem_record_child "$LANES_CHILD"
  last=$ta
  while kill -0 "$LANES_CHILD" 2>/dev/null; do
    sleep "$poll"
    kill -0 "$LANES_CHILD" 2>/dev/null || break
    gem_track_tree
    now=$(date +%s)
    m="$(mtime_of "$j")"; if (( m > last )); then last=$m; fi
    m="$(mtime_of "$e")"; if (( m > last )); then last=$m; fi
    n="$(idle_count "$e")"
    if (( n > idle_seen )); then
      idle_seen=$n; idle_at=$now; grace=$idle_grace
      print -u "$GEM_LOGFD" -- "[run-gemini] $(lanes_now) agy が idle（裏の作業待ち）。子の処理が無く、json が ${idle_grace} 秒動かなければ異常終了として停止"
    fi
    if (( idle_at > 0 )); then
      m="$(mtime_of "$j")"
      if (( m > idle_at )); then
        # json が動いた（裏の作業の出力か、agy が続きを始めた）→ 見張りは解除せず時計だけ戻す。動いた後の猶予は長め（GEMINI_IDLE_RESUME_GRACE、既定 300 秒）
        idle_at=$now; if (( grace < resume_grace )); then grace=$resume_grace; fi
      elif (( now - idle_at >= grace && ${#GEM_TRACK} <= 2 )); then
        # テスト等の子が動いている間は idle だけで停止しない。全体の時間上限と無出力監視は維持。
        GEM_IDLE_KILLED=1
        print -u "$GEM_LOGFD" -- "[run-gemini] $(lanes_now) idle のまま ${grace} 秒 → 異常終了として停止（EXIT:3）"
        break
      fi
    fi
    if (( now - last >= noout_sec )); then
      GEM_NOOUT=1
      print -u "$GEM_LOGFD" -- "[run-gemini] $(lanes_now) json / stderr が ${noout_sec} 秒更新なし → 停止（EXIT:8）"
      break
    fi
  done
  if (( GEM_IDLE_KILLED || GEM_NOOUT )); then gem_kill_all; fi
  wait "$LANES_CHILD" 2>/dev/null || GEM_RC=$?
  exec {GEM_LOGFD}>&-
  lanes_logdir_check
  # 監督役の終了は子孫の回収完了を意味する。終了後に集団番号を再利用しない。
  LANES_CHILD=""; GEM_PGID=""
  GEM_SECS=$(( $(date +%s) - ta ))
  return 0
}

audit="$scratch/gemini-audit.txt"; body_file="$scratch/gemini-response.txt"
run_audit() {   # 引数: 検査する json（1 回目と再実行の両方）
  # scratch は agy が書ける場所。子の回収後に、前からある物（symlink など）を消してから新しく作る
  lanes_fresh_file "$audit"; lanes_fresh_file "$body_file"
  python3 - "$audit" "$wt" "$scratch" "$body_file" "$GEM_IDLE_KILLED" "$@" <<'PY' || print -u2 -- "[run-gemini] 書き込み検査（python）が失敗"
import json, os, re, sys
out, wt, scr, body_out = sys.argv[1:5]
allow_incomplete = sys.argv[5] == '1'
srcs = sys.argv[6:]
wt = os.path.realpath(wt); scr = os.path.realpath(scr)
status, body, error, turns, usage, asks = "NONE", "", "", 0, {}, 0
outside, suspect, writes, invalid = [], [], set(), []
WRITE_HINT = ("write", "replace", "edit", "delete", "move", "rename", "create", "append", "copy", "patch")
GONE_HINT = ("delete", "move", "rename")   # 消す・動かす系は「外に無い」こと自体が書き込みの証拠なので実在を問わない
PATH_KEYS = ("file", "path", "dir", "directory", "target", "destination")
def unescape(v):   # Markdown 風のエスケープ（\_ など）を外す
    return re.sub(r"\\(.)", r"\1", v)
def resolve(p):
    p = os.path.expanduser(p)
    return os.path.realpath(p if os.path.isabs(p) else os.path.join(wt, p))
def inside(rp):
    return rp == wt or rp.startswith(wt + os.sep) or rp == scr or rp.startswith(scr + os.sep)
for src in srcs:
    try:
        lines = open(src, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeError):
        invalid.append('ログを読み取れない'); continue
    if not lines:
        invalid.append('ログが空'); continue
    results = 0
    last_event = None
    for line in lines:
        try: d = json.loads(line)
        except (ValueError, TypeError):
            invalid.append('JSON の不正行'); continue
        if not isinstance(d, dict) or not isinstance(d.get('event'), str):
            invalid.append('イベントの形式が不正'); continue
        last_event = d['event']
        if d.get("event") == "result":
            r = d.get("result")
            if not isinstance(r, dict) or r.get('status') not in ('SUCCESS', 'ERROR'):
                invalid.append('結果の形式が不正'); continue
            if any(not isinstance(r.get(k, ''), str) for k in ('response', 'error')):
                invalid.append('結果本文の形式が不正'); continue
            if type(r.get('num_turns', 0)) is not int or r.get('num_turns', 0) < 0 or not isinstance(r.get('usage', {}), dict):
                invalid.append('結果集計の形式が不正'); continue
            results += 1
            status = r.get("status", "?"); body = r.get("response", "") or r.get("error", "")
            error = r.get("error", "") or ""; turns = r.get("num_turns", 0); usage = r.get("usage", {})
            continue
        if d['event'] != 'step_update': continue
        su = d.get("step_update")
        if not isinstance(su, dict) or not isinstance(su.get('step_type'), str):
            invalid.append('作業記録の形式が不正'); continue
        name = su.get("tool_name") or ""
        if not isinstance(name, str) or (su['step_type'] == 'tool' and not name.strip()):
            invalid.append('ツール名の形式が不正'); continue
        if name.startswith("ask_"): asks += 1
        if su.get("step_type") != "tool" or not any(h in name.lower() for h in WRITE_HINT): continue
        info = su.get('tool_info')
        params = info.get('parameters') if isinstance(info, dict) else None
        if not isinstance(params, dict):
            invalid.append('書き込み先の記録が無い'); continue
        gone = any(h in name.lower() for h in GONE_HINT)
        path_seen = False
        for k, v in params.items():
            if not k.lower().endswith(PATH_KEYS) and not (gone and k.lower().endswith("source")): continue
            path_seen = True
            if not isinstance(v, str) or not v:
                invalid.append('書き込み先の形式が不正'); continue
            if "\n" in v or "\r" in v or "\0" in v:
                invalid.append('書き込み先に制御文字'); continue
            cands = [v] + ([unescape(v)] if unescape(v) != v else [])
            rps = [resolve(c) for c in cands]
            writes.add(rps[-1])
            # エスケープ表記の解釈が曖昧でも、外へ向く候補があれば成功扱いにしない。
            for rp in set(rps):
                if inside(rp): continue
                if gone or os.path.lexists(rp): outside.append(f"{name} {k}={rp}")
                else: suspect.append(f"{name} {k}={rp}")
        if not path_seen: invalid.append('書き込み先を特定できない')
    if results > 1 or (results == 1 and last_event != 'result'):
        invalid.append('結果が重複、または終端ではない')
    if results == 0 and not (allow_incomplete and src == srcs[-1]):
        invalid.append('終了結果が欠損')
def new_file(path):
    # 既存の物（symlink・ハードリンク）は辿らず、必ず新しい普通のファイルとして作る
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666), "w", encoding="utf-8")
with new_file(body_out) as f:
    f.write(body or "(応答なし)")
with new_file(out) as f:
    one = " ".join(str(error).split())[:300]
    f.write(f"status={status}\nturns={turns}\nusage={json.dumps(usage)}\nask_tools={asks}\nwrites={len(writes)}\nerror={one}\n")
    for o in sorted(set(outside)): f.write(f"outside={o}\n")
    for s in sorted(set(suspect)): f.write(f"suspect={s}\n")
    f.write(f"audit_errors={len(invalid)}\n")
    f.write(f"audit_ok={int(not invalid)}\n")
PY
}
audit_get() { local v; v="$(sed -n "s/^$1=//p" "$audit" 2>/dev/null | head -1)" || v=""; print -- "$v"; }

cd "$wt"
started="$(lanes_now)"; t0=$(date +%s)
head_before="$(git rev-parse --short=12 HEAD)"
head_full_before="$(git rev-parse HEAD)"
# 依存の用意などで差分が増えた場合も、agy を起動する前に止める。
gem_changes initial >/dev/null || lanes_die "agy 起動前に未保存の変更を検出"
{
  print -- "# run-gemini: $label"
  print -- "started: $started"
  print -- "pid: $$"
  print -- "worktree: $wt"
  print -- "git: $(lanes_git_summary "$wt")"
  print -- "model: ${GEMINI_MODEL:-(CLI の既定)} / effort: ${GEMINI_EFFORT:-(CLI の既定)} / mode: accept-edits / print-timeout: $print_timeout"
  print -- "見張り: idle ${idle_grace} 秒 / 無出力 ${noout_sec} 秒"
  print -- "prompt: $prompt"
  print -- "preamble: ${preamble:-(なし: GEMINI_NO_PREAMBLE=1)}"
  print -- "scratch: $scratch"
  print -- "----"
} > "$log"

retried=0; stop_line="なし"
run_agy_once "$json" "$err"
gem_gitlink_check
run_audit "$json"
gstatus="$(audit_get status)"; [[ -n "$gstatus" ]] || gstatus="NONE"
scope_ok=1; changes="$(gem_changes check)" || { scope_ok=0; changes=0; }
# 1 回だけの自動再実行: 見張りで止めていない・差分なし・外への書き込みなし・時間切れではない・一時的なエラー（503 / UNAVAILABLE / stream interrupted）
if (( ! GEM_IDLE_KILLED && ! GEM_NOOUT && scope_ok && changes == 0 )) && [[ "$gstatus" != "SUCCESS" && "$(audit_get audit_ok)" == 1 ]] \
   && ! grep -q -E '^(outside|suspect)=' "$audit" 2>/dev/null && (( GEM_SECS < 70 * 60 )) \
   && { grep -q -E 'UNAVAILABLE|code 503|(^|[^0-9])503([^0-9]|$)|stream was interrupted|interrupted' "$err" 2>/dev/null \
        || [[ "$(audit_get error)" =~ '(UNAVAILABLE|503|interrupted)' ]]; }; then
  retried=1
  print -- "[run-gemini] $(lanes_now) agy が $gstatus（一時的なエラー）・差分なし → 1 回だけ再実行（1 回目は ${json1:t} / ${err1:t}）" >> "$log"
  mv -f "$json" "$json1"; mv -f "$err" "$err1"
  archive_message
  run_agy_once "$json" "$err"
  gem_gitlink_check
  run_audit "$json1" "$json"
  gstatus="$(audit_get status)"; [[ -n "$gstatus" ]] || gstatus="NONE"
  scope_ok=1; changes="$(gem_changes check)" || { scope_ok=0; changes=0; }
fi
{ print -- ""; print -- "----"; cat "$body_file" 2>/dev/null || print -- "(応答なし)"; print -- ""; } >> "$log"

outside_n="$(grep -c '^outside=' "$audit" 2>/dev/null)" || outside_n=0; outside_n="${outside_n:-0}"
suspect_n="$(grep -c '^suspect=' "$audit" 2>/dev/null)" || suspect_n=0; suspect_n="${suspect_n:-0}"
asks_n="$(audit_get ask_tools)"; asks_n="${asks_n:-0}"
outside_paths="$(sed -n 's/^outside=//p' "$audit" 2>/dev/null | head -3 | tr '\n' ' ')" || outside_paths=""

rc=0; note=""; agy_err=0
stops=()
if (( retried )); then stops+=("一時エラーで 1 回再実行"); fi
if (( GEM_IDLE_KILLED )); then stops+=("idle（裏の作業待ち）で強制停止。正常完了ではない"); fi
if (( ${#stops} )); then stop_line="${(j: / :)stops}"; fi
if (( GEM_NOOUT )); then
  rc=8; stops+=("出力 ${noout_sec} 秒なしで停止"); stop_line="${(j: / :)stops}"
  lanes_fresh_file "$scratch/wip.patch"; lanes_fresh_file "$scratch/wip.status"
  git diff > "$scratch/wip.patch" 2>/dev/null || true
  git status --porcelain > "$scratch/wip.status" 2>/dev/null || true
  note="出力が ${noout_sec} 秒止まったので停止。作業途中の変更は戻さず残した（commit していない。$scratch/wip.patch）"
elif [[ "$(audit_get audit_ok)" != "1" ]]; then
  rc=4; note="書き込み検査が完了しなかった（$audit）→ 安全側で commit しない。親が確認"
elif (( outside_n > 0 || suspect_n > 0 )); then
  rc=4; note="worktree / scratch の外へ書き込み ${outside_n} 件: ${outside_paths% }（$audit）。戻していない。親が確認"
elif (( ! scope_ok )) || [[ "$(git rev-parse HEAD)" != "$head_full_before" ]]; then
  rc=4; note="保存範囲または HEAD が開始時の前提と違う → commit しない"
elif (( ! GEM_IDLE_KILLED && GEM_RC == 0 )) && [[ "$gstatus" == "SUCCESS" ]]; then
  rc=0
else
  # 検証済みの差分は救済保存できるが、異常終了の事実は EXIT:3 のまま残す。
  rc=3; agy_err=1; note="agy が正常完了していない（$gstatus / rc=$GEM_RC / idle=$GEM_IDLE_KILLED）"
fi

# 検証（サンドボックスの外・commit 前）。Gemini の自己申告は信じない
verify_line="未実施（前段で失敗）"; verified=0
vlog="$logdir/$label.verify.log"
if (( rc == 0 || (rc == 3 && changes > 0) )); then
  lanes_rotate_log "$vlog"
  vt0=$(date +%s); vrc=0
  ( cd "$wt" && zsh -c "$verify" ) > "$vlog" 2>&1 || vrc=$?
  lanes_logdir_check
  verify_line="EXIT:$vrc（$(( $(date +%s) - vt0 )) 秒）: $verify → $vlog"
  if (( vrc != 0 )); then
    if (( agy_err )); then rc=3; note="agy が SUCCESS でない（$gstatus）うえ、検証も失敗（EXIT:$vrc）→ commit していない。$vlog"
    else rc=7; note="検証が失敗（EXIT:$vrc）→ commit / push していない。$vlog"; fi
  else
    verified=1
  fi
fi

# commit / push（ランチャが行う。Gemini のサンドボックスには Git 管理領域を渡していない）
commit_line="なし"; push_line="なし"
if (( verified )); then
  # 検証コマンド自身による範囲外の編集も見逃さない。
  changes="$(gem_changes check)" || { rc=4; verified=0; changes=0; note="検証後に許可範囲外の変更を検出 → commit しない"; }
  if [[ "$(git rev-parse HEAD)" != "$head_full_before" ]]; then
    rc=4; verified=0; note="検証中に HEAD が変わった → commit しない"
  fi
fi
if (( verified && changes > 0 )); then
  if [[ -f "$msgfile" && ! -L "$msgfile" && -s "$msgfile" ]]; then
    if ! gem_changes stage >/dev/null; then
      rc=4; note="保存対象の最終確認に失敗 → commit しない"
    elif git diff --cached --quiet; then commit_line="ステージ後に差分なし"
    else
      if git commit -q -F "$msgfile"; then
        commit_line="$(git log --format='%h %s' -1)"
        if (( agy_err )); then note+="。検証成功の差分を救済 commit（EXIT:3・push なし）"; fi
      else rc=5; note="git commit に失敗"; fi
    fi
    if (( rc == 0 && push )); then
      case "$branch" in
        main|master|"${LANES_BASE_BRANCH:-develop}"|"(detached)") push_line="しない（枝 $branch）" ;;
        *) if git push -q origin "HEAD:$branch" 2>>"$err"; then push_line="origin/$branch"; else rc=6; note="git push に失敗（stderr を見る）"; fi ;;
      esac
    elif (( ! push )); then push_line="しない（--no-push）"
    fi
  else
    if (( ! agy_err )); then rc=5; fi
    note="変更はあるが今回の通常ファイル $msgfile が無い → commit していない"
  fi
elif (( rc == 0 )); then
  note="${note:-変更なし}"
fi

elapsed=$(( ($(date +%s) - t0) / 60 )); elapsed_s=$(( $(date +%s) - t0 ))
head_after="$(git rev-parse --short=12 HEAD)"
changed="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
untracked="$(git status --porcelain | grep -v '^?? logs/' | grep -c '^??')" || untracked=0
files="$(git diff --stat "$head_before" HEAD 2>/dev/null | tail -1 | sed 's/^ *//')" || files=""
{
  print -- "## Gemini 実装証跡（$label）"
  print -- "- 結果: EXIT:$rc（agy: $gstatus）${note:+ / $note}"
  print -- "- モデル: ${GEMINI_MODEL:-(CLI の既定)} / effort ${GEMINI_EFFORT:-(CLI の既定)} / accept-edits・端末サンドボックス / print-timeout $print_timeout"
  print -- "- 見張り: $stop_line"
  print -- "- 対象: $(lanes_git_summary "$wt")"
  print -- "- HEAD: $head_before → $head_after（${files:-差分なし}）/ 未コミット tracked $changed / 未追跡 $untracked"
  print -- "- 検証（ランチャ・サンドボックス外）: $verify_line"
  print -- "- commit: $commit_line / push: $push_line"
  print -- "- 書き込み検査: worktree・scratch の外 ${outside_n} 件 / 外だが実在不明 ${suspect_n} 件 / 承認・質問ツール ${asks_n} 回（$audit）"
  print -- "- 実行: $started 開始 / 約 ${elapsed} 分（${elapsed_s} 秒）"
  print -- "- ログ: $log / $json / $final"
  print -- "- 作業場所（scratch）: $scratch（${LANES_BASE_BRANCH:-develop} へのマージ後の cleanup で削除）"
  print -- "- レビュー: このあと run-review.sh（構成のレビュー役。Gemini はレビューに使わない）"
} > "$evidence"
{ print -- "----"; cat "$evidence"; print -- "finished: $(lanes_now)"; print -- "EXIT:$rc"; } >> "$log"
cat "$evidence"
lanes_mark_done "$rc" "EXIT:$rc" "$note"
exit $rc
