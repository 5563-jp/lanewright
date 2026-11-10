#!/bin/zsh -f
# after-develop-merge.sh — 統合先の枝へのマージ後: マージ対象固定 → 専用 worktree → feature 後片付け → bot QA
# 統合先の枝は設定キー LANES_BASE_BRANCH（既定 develop。ファイル名は互換のため after-develop-merge のまま）。
# bot QA が VERDICT: CLEAN なら「人の QA 待ち」として報告し、NEEDS_FIX なら修正レーンへ戻す。
# 課題管理ツール（チケットの状態など）とは連携しない。必要なら手順書に沿って自分で足す。フルラウンド自動連鎖は作らない。
#
# 使い方:
#   after-develop-merge.sh <feature-worktree> [--apply] [--skip-qa] [--no-deps] [--qa-prompt <path>] [--label <label>] [--repo owner/name] [--main-checkout <path> --feature-head <sha>]
# --repo 省略時: origin URL から推定。不明なら PR を照会せず、取り込み履歴だけで QA へ進む。
#
# 既定: dry-run（計画表示のみ。cleanup --apply しない / QA を exec しない）
# --apply: 実行。QA 有効時は cleanup のあと run-qa.sh を起動（通常は exec。設定キー LANES_DETACH_QA=1 なら detach-run.sh で切り離して起動）
# --skip-qa: cleanup のみ（cleanup-after-merge.sh に委譲。終了コードもそのまま返す）
# 後片付けが 8（feature の worktree 消失で、現世代の停止を確認できない scratch だけ保全）のときは、
# 保全した scratch と手で消す手順を出したうえで QA へ進む
# QA 用の専用 worktree:
#   - 依存: 本体 checkout の node_modules は共有しない（別の履歴の依存を混ぜない・QA から本体を書き換えさせない）。
#     固定した履歴のロックファイルから専用 worktree の中で入れ直す（package-lock.json → npm ci /
#     pnpm-lock.yaml → pnpm install --frozen-lockfile / yarn.lock → yarn install --frozen-lockfile）。
#     対象はルートと apps/* ・ packages/* のうちロックファイルを持つ所。--no-deps で省略。ログは logs/qa-deps-*.log
#   - .env 系: 本体 checkout の未追跡の .env* を複製し、本体と同一であることを cmp で確認する（中身は表示しない）。
#     .env.sentry-build-plugin（ソースマップ送信用の鍵）は複製しない。後片付けは cleanup-after-merge.sh の本体一致確認に乗る
#   - 後片付け: 次回の --apply（QA あり）の開始時に、同じリポジトリの終わった QA worktree
#     （全 .pid に新しい .done があり、ランチャも子も生きていない）を cleanup-after-merge.sh --apply に流す。
#     手で片付けるときは cleanup-after-merge.sh <QA_WORKTREE> --apply
set -euo pipefail
LANES_DIR="${0:A:h}"
SCRIPT_DIR="$LANES_DIR"
# shellcheck source=/dev/null
source "${LANES_DIR}/_common.sh"
BASE_BRANCH="${LANES_BASE_BRANCH:-develop}"
# 設定キー LANES_DETACH_QA=1 のときだけ QA を detach-run.sh で切り離して起動する（シェルの終わりにプロセスグループごと止める
# Bot から呼ぶとき用）。lanes.env が 0 / 1 であることを確かめ済み。既定 0 は QA へそのまま exec する
typeset -g AFTER_MERGE_DETACH_QA=0
[[ "${LANES_DETACH_QA:-0}" != 1 ]] || AFTER_MERGE_DETACH_QA=1
git check-ref-format --branch "$BASE_BRANCH" >/dev/null 2>&1 || lanes_die "LANES_BASE_BRANCH が枝名として不正: $BASE_BRANCH"

REPO_SLUG="${LANES_REPO_SLUG:-}"
USAGE='使い方: after-develop-merge.sh <feature-worktree> [--apply] [--skip-qa] [--no-deps] [--qa-prompt <path>] [--label <label>] [--repo owner/name] [--main-checkout <path> --feature-head <sha>]'

APPLY=0
SKIP_QA=0
NO_DEPS=0
QA_PROMPT=""
LABEL=""
FEATURE_WT=""
MAIN_OVERRIDE=""
HEAD_OVERRIDE=""

while (( $# > 0 )); do
  case "$1" in
    --main-checkout|--feature-head)
      (( $# >= 2 )) || lanes_die "$USAGE"
      if [[ "$1" == "--main-checkout" ]]; then MAIN_OVERRIDE="$2"; else HEAD_OVERRIDE="$2"; fi
      shift 2
      ;;
    --apply) APPLY=1; shift ;;
    --skip-qa) SKIP_QA=1; shift ;;
    --no-deps) NO_DEPS=1; shift ;;
    --qa-prompt)
      (( $# >= 2 )) || { print -u2 -- "$USAGE"; exit 2; }
      QA_PROMPT="$2"; shift 2
      ;;
    --label)
      (( $# >= 2 )) || { print -u2 -- "$USAGE"; exit 2; }
      LABEL="$2"; shift 2
      ;;
    --repo)
      (( $# >= 2 )) || { print -u2 -- "$USAGE"; exit 2; }
      REPO_SLUG="$2"; shift 2
      ;;
    -h|--help)
      print -- "$USAGE"
      exit 0
      ;;
    -*)
      print -u2 -- "不明なオプション: $1"
      print -u2 -- "$USAGE"
      exit 2
      ;;
    *)
      if [[ -z "$FEATURE_WT" ]]; then
        FEATURE_WT="$1"; shift
      else
        print -u2 -- "余分な引数: $1"
        print -u2 -- "$USAGE"
        exit 2
      fi
      ;;
  esac
done

[[ -n "$FEATURE_WT" ]] || { print -u2 -- "$USAGE"; exit 2; }

# 相対プロンプトは呼び出し時点で確定する。削除前に専用 worktree へ内容を退避する。
FEATURE_WT="${FEATURE_WT:A}"
if [[ -n "$QA_PROMPT" ]]; then
  QA_PROMPT="${QA_PROMPT:A}"
  lanes_require_prompt "$QA_PROMPT"
fi
if [[ -d "$FEATURE_WT" ]]; then
  lanes_require_worktree "$FEATURE_WT"
  FEATURE_WT="$(git -C "$FEATURE_WT" rev-parse --path-format=absolute --show-toplevel)"
  _common_dir="$(git -C "$FEATURE_WT" rev-parse --path-format=absolute --git-common-dir)"
  MAIN_CHECKOUT="${_common_dir:h}"
  FEATURE_HEAD="$(git -C "$FEATURE_WT" rev-parse HEAD)"
  [[ -z "$HEAD_OVERRIDE" || "$HEAD_OVERRIDE" == "$FEATURE_HEAD" ]] || lanes_die "--feature-head が実際の HEAD と一致しない"
  [[ -z "$MAIN_OVERRIDE" || "${MAIN_OVERRIDE:A}" == "$MAIN_CHECKOUT" ]] || lanes_die "--main-checkout が対象リポジトリと一致しない"
else
  [[ -n "$MAIN_OVERRIDE" && "$HEAD_OVERRIDE" =~ '^[0-9a-fA-F]{40}$' ]] || lanes_die "削除済み feature は --main-checkout と --feature-head（40桁）が必要"
  MAIN_CHECKOUT="${MAIN_OVERRIDE:A}"
  lanes_require_worktree "$MAIN_CHECKOUT"
  FEATURE_HEAD="$(git -C "$MAIN_CHECKOUT" rev-parse --verify "$HEAD_OVERRIDE^{commit}")" || lanes_die "指定した feature HEAD が無い"
fi
FEATURE_SHORT="${FEATURE_HEAD[1,12]}"

# feature に本体 checkout 自身が渡されたか判定する。
IS_MAIN=0
# REPO_SLUG: --repo / LANES_REPO_SLUG / origin URL 推定
if [[ -z "$REPO_SLUG" ]]; then
  _origin_url="$(git -C "$MAIN_CHECKOUT" remote get-url origin 2>/dev/null || true)"
  if [[ "$_origin_url" == *github.com[:/]* ]]; then
    REPO_SLUG="${${_origin_url#*github.com[:/]}%.git}"
  fi
fi
if [[ -n "$REPO_SLUG" ]]; then
  print -- "repo: $REPO_SLUG"
else
  # GitHub 以外の接続先では PR を照会せず、取り込み履歴だけで進む
  print -u2 -- "warn: GitHub のリポジトリ名を特定できない。PR は照会しない（照会するなら --repo owner/name）"
fi

if [[ "$FEATURE_WT" -ef "$MAIN_CHECKOUT" ]]; then
  IS_MAIN=1
fi

_die_not_merged() {
  print -u2 -- "error: feature HEAD は origin/$BASE_BRANCH に未マージ。exit 5"
  print -u2 -- "  feature: $FEATURE_WT"
  print -u2 -- "  HEAD:    $FEATURE_HEAD"
  exit 5
}

_verify_merged() {
  # FETCH_HEAD を直後に固定し、以後の fetch / 別レーンの更新で検証対象を変えない。
  git -C "$MAIN_CHECKOUT" fetch -q origin "refs/heads/$BASE_BRANCH" || lanes_die "origin/$BASE_BRANCH を取得できない"
  DEVELOP_SNAPSHOT="$(git -C "$MAIN_CHECKOUT" rev-parse FETCH_HEAD)"
  git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$FEATURE_HEAD" "$DEVELOP_SNAPSHOT" || _die_not_merged
  # その feature が最初に統合先の本線へ入った履歴を選ぶ。後続の PR を取り違えない。
  MERGE_SHA="$FEATURE_HEAD"
  local candidate first_parent
  first_parent="$(git -C "$MAIN_CHECKOUT" rev-list --first-parent "$DEVELOP_SNAPSHOT")"
  if ! print -r -- "$first_parent" | grep -Fx "$FEATURE_HEAD" >/dev/null; then
    MERGE_SHA=""
    for candidate in "${(@f)$(git -C "$MAIN_CHECKOUT" rev-list --first-parent --reverse --ancestry-path "$FEATURE_HEAD..$DEVELOP_SNAPSHOT")}"; do
      if git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$FEATURE_HEAD" "$candidate"; then MERGE_SHA="$candidate"; break; fi
    done
    [[ -n "$MERGE_SHA" ]] || lanes_die "feature の取り込み履歴を特定できない"
  fi
}

_resolve_merged_pr() {
  # PR は feature の先端と取り込み履歴へ結び付ける。現在の統合先の先端は検索キーにしない。
  # gh（GitHub の CLI）が無い・未ログインなら PR は「未特定」のまま進む。
  PR_NUMBER=""; PR_TITLE=""; PR_URL=""; PR_BASE=""; CHANGED_FILES=(); CHANGED_FILES_NOTE=""
  local api_json="" parsed="" list_json=""
  [[ -n "$REPO_SLUG" ]] && api_json="$(gh api -H 'Accept: application/vnd.github+json' "repos/${REPO_SLUG}/commits/${FEATURE_HEAD}/pulls" 2>/dev/null || true)"
  parsed="$(print -r -- "$api_json" | python3 -c '
import json,sys
try: data=json.load(sys.stdin)
except (ValueError,TypeError): sys.exit(0)
feature,merge,base_ref=sys.argv[1:]
candidates=[p for p in data if p.get("merged_at") and (p.get("base") or {}).get("ref")==base_ref and
            (p.get("head") or {}).get("sha")==feature and p.get("merge_commit_sha")==merge] if isinstance(data,list) else []
if len(candidates)==1:
    p=candidates[0]
    print(p["number"]); print((p.get("title") or "").replace("\n"," ")); print(p.get("html_url") or "")
    print((p.get("base") or {}).get("sha") or "")
' "$FEATURE_HEAD" "$MERGE_SHA" "$BASE_BRANCH")"
  if [[ -z "$parsed" && -n "$REPO_SLUG" ]]; then
    list_json="$(gh pr list -R "$REPO_SLUG" --base "$BASE_BRANCH" --state merged --limit 100 --json number,title,url,mergeCommit,headRefOid,baseRefOid 2>/dev/null || true)"
    # パイプ左辺への環境変数代入では Python に届かないため、固定値は引数で渡す。
    parsed="$(print -r -- "$list_json" | python3 -c '
import json,sys
try: data=json.load(sys.stdin)
except (ValueError,TypeError): sys.exit(0)
feature,merge=sys.argv[1:]
candidates=[p for p in data if (p.get("mergeCommit") or {}).get("oid")==merge and
            p.get("headRefOid",feature)==feature] if isinstance(data,list) else []
if len(candidates)==1:
    p=candidates[0]
    print(p["number"]); print((p.get("title") or "").replace("\n"," ")); print(p.get("url") or "")
    print(p.get("baseRefOid") or "")
' "$FEATURE_HEAD" "$MERGE_SHA")"
  fi
  if [[ -n "$parsed" ]]; then
    PR_NUMBER="$(print -r -- "$parsed" | sed -n '1p')"
    PR_TITLE="$(print -r -- "$parsed" | sed -n '2p')"
    PR_URL="$(print -r -- "$parsed" | sed -n '3p')"
    PR_BASE="$(print -r -- "$parsed" | sed -n '4p')"
  fi
  _changed_files
  PROMPT_ID="${PR_NUMBER:-${MERGE_SHA[1,12]}}"
}

# ファイル一覧は固定した履歴から作る（API のページ数制限に依存しない）。
# マージコミットならその第 1 親との差分＝取り込み全体。fast-forward（feature 先端が統合先の本線に直接載った）では
# 先端 1 commit 分にならないよう、取り込み前の統合先の位置を探して feature の全 commit 分を出す。
_changed_files() {
  local base="" entry
  if [[ "$MERGE_SHA" != "$FEATURE_HEAD" ]]; then
    # 取り込み全体が確定しているので、差分が空でも単一 commit への格下げや注記はしない。
    CHANGED_FILES=("${(@f)$(git -C "$MAIN_CHECKOUT" diff --no-renames --name-only "$MERGE_SHA^1" "$MERGE_SHA" 2>/dev/null || true)}")
    CHANGED_FILES=("${(@)CHANGED_FILES:#}")
    return 0
  else
    # 1. PR の基点（GitHub が記録した統合先側の先端）。手元に無い・祖先関係が取れないときは使わない。
    if [[ "$PR_BASE" =~ '^[0-9a-fA-F]{40}$' ]] && git -C "$MAIN_CHECKOUT" cat-file -e "$PR_BASE^{commit}" 2>/dev/null; then
      base="$(git -C "$MAIN_CHECKOUT" merge-base "$PR_BASE" "$FEATURE_HEAD" 2>/dev/null || true)"
    fi
    # 2. 手元の origin/<統合先> の更新記録で、feature 先端をまだ含んでいなかった最後の位置。
    if [[ -z "$base" ]]; then
      for entry in "${(@f)$(git -C "$MAIN_CHECKOUT" reflog show --format=%H "refs/remotes/origin/$BASE_BRANCH" -- 2>/dev/null || true)}"; do
        [[ -n "$entry" ]] || continue
        git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$FEATURE_HEAD" "$entry" 2>/dev/null && continue
        base="$(git -C "$MAIN_CHECKOUT" merge-base "$entry" "$FEATURE_HEAD" 2>/dev/null || true)"
        break
      done
    fi
    if [[ -n "$base" && "$base" != "$FEATURE_HEAD" ]]; then
      CHANGED_FILES=("${(@f)$(git -C "$MAIN_CHECKOUT" diff --no-renames --name-only "$base" "$FEATURE_HEAD" 2>/dev/null || true)}")
      CHANGED_FILES=("${(@)CHANGED_FILES:#}")
      CHANGED_FILES_NOTE="fast-forward の取り込み。\`${base[1,12]}..${FEATURE_HEAD[1,12]}\` の全体"
      (( ${#CHANGED_FILES} )) && return 0
    fi
  fi
  # 取り込み前の位置が分からないときは、少なくとも対象 commit の分を出し、一部の可能性を明記する。
  CHANGED_FILES=("${(@f)$(git -C "$MAIN_CHECKOUT" show --format= --name-only "$MERGE_SHA" 2>/dev/null || true)}")
  CHANGED_FILES=("${(@)CHANGED_FILES:#}")
  CHANGED_FILES_NOTE="取り込み前の統合先（$BASE_BRANCH）の位置を特定できず、\`${MERGE_SHA[1,12]}\` 1 commit 分のみ（一部の可能性あり。\`git log\` で補完する）"
}

_default_label() { print -r -- "qa-auto-${PR_NUMBER:-${MERGE_SHA[1,12]}}"; }

# 未起動 QA の巻き戻し用。無視された追加物も含め、別の処理が触った場所は撤去しない。
# 依存（node_modules/）はここで入れた生成物なので比較から外す（巨大な木を毎回読まない）。
_pending_qa_snapshot() {
  python3 - "$QA_WORKTREE" <<'PY_PENDING'
import hashlib, os, pathlib, stat, subprocess, sys
root = pathlib.Path(sys.argv[1])
def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)
try:
    if root.is_symlink() or not (root / ".git").is_file() or (root / ".git").is_symlink():
        raise ValueError()
    h = hashlib.sha256((root / ".git").read_bytes())
    h.update(git("rev-parse", "HEAD"))
    h.update(git("ls-files", "--stage", "-z"))
    branch = subprocess.run(["git", "-C", str(root), "symbolic-ref", "-q", "HEAD"], capture_output=True)
    if branch.returncode != 1: raise ValueError()
    paths = set(git("ls-files", "-z").split(b"\0") + git("ls-files", "--others", "-z").split(b"\0")) - {b""}
    paths = {p for p in paths if not (p.startswith(b"node_modules/") or b"/node_modules/" in p)}
    for name in sorted(paths):
        p = root / os.fsdecode(name)
        mode = p.lstat().st_mode
        h.update(name + b"\0" + str(mode).encode() + b"\0")
        if stat.S_ISLNK(mode): h.update(os.fsencode(os.readlink(p)))
        elif stat.S_ISREG(mode): h.update(p.read_bytes())
        else: raise ValueError()
    print(h.hexdigest())
except (OSError, ValueError, subprocess.CalledProcessError):
    sys.exit(1)
PY_PENDING
}

# 親リンクも解決し、書き込み先が QA 専用 worktree 内に収まる場合だけ準備を続ける。
_qa_require_local_path() {
  python3 - "$QA_WORKTREE" "$1" <<'PY_QA_PATH' || { print -u2 -- "QA 領域外／解決不能の準備先: $1"; return 1; }
import pathlib, sys
try:
    root = pathlib.Path(sys.argv[1]).resolve(strict=True)
    pathlib.Path(sys.argv[2]).resolve().relative_to(root)
except (OSError, RuntimeError, ValueError):
    sys.exit(1)
PY_QA_PATH
}

_write_auto_prompt() {
  # $1 = 指示書の保存先
  local out="$1"
  _qa_require_local_path "$out" || return 1
  mkdir -p "${out:h}"
  {
    print -- "# QA（自動生成）— ${REPO_SLUG:-${MAIN_CHECKOUT:t}}"
    print -- ""
    print -- "${BASE_BRANCH} へのマージ直後の bot QA 用ケースプロンプト（最小）。"
    print -- ""
    print -- "## マージ情報"
    if [[ -n "$PR_NUMBER" ]]; then
      print -- "- PR: #${PR_NUMBER} — ${PR_TITLE}"
      print -- "- URL: ${PR_URL}"
    else
      print -- "- PR: （特定できず。feature の取り込み履歴を固定）"
    fi
    print -- "- merge SHA: \`${MERGE_SHA}\`"
    print -- "- 作業対象 checkout: \`${QA_WORKTREE}\`（固定した履歴の専用 worktree）"
    print -- ""
    print -- "## 変更ファイル（パスのみ・固定した取り込み履歴）"
    [[ -z "$CHANGED_FILES_NOTE" ]] || print -- "- 注: ${CHANGED_FILES_NOTE}"
    if (( ${#CHANGED_FILES[@]} > 0 )); then
      local f
      for f in "${CHANGED_FILES[@]}"; do
        print -- "- \`${f}\`"
      done
    else
      print -- "- （取得できず。\`git show --stat ${MERGE_SHA}\` で補完可）"
    fi
    print -- ""
    print -- "## 手順"
    print -- "1. 観点リストを BOT / HUMAN に分けて列挙する（先に観点、そのあと bot 実行可能なチェック）。"
    print -- "2. Preview URL（公開前の確認用 URL）は司令塔が後から埋めてよい（空欄のまま進めず、分かる範囲で確認）。"
    print -- "3. bot でできる範囲を実行し、最終行に \`VERDICT: CLEAN\` または \`VERDICT: NEEDS_FIX\` を出す。"
    print -- "4. CLEAN なら「人の QA 待ち」として報告する。NEEDS_FIX なら直し方を書き、修正レーンへ戻す。課題管理ツールの状態は変えない。"
    print -- ""
    print -- "## 注意"
    print -- "- 巨大 diff は埋め込まない（このプロンプトは小さく保つ）。"
    print -- "- 本番 / main には触らない。"
  } > "$out"
  print -- "wrote QA prompt: $out"
}

# 本体 checkout の未追跡の .env* を QA worktree へ複製し、同一であることを確かめる（中身は表示しない）。
# 後片付けは cleanup-after-merge.sh の「本体と同一なら worktree ごと消してよい」確認に乗る。
_copy_qa_envs() {
  local e n=0
  local -a envs=()
  for e in "${(@0)$(git -C "$MAIN_CHECKOUT" ls-files -z --others --directory --no-empty-directory)}"; do
    [[ -n "$e" && "$e" != */ ]] || continue
    [[ "$e" =~ '(^|/)\.env' && ! "$e" =~ '(^|/)(node_modules|\.next)/' ]] || continue
    # ソースマップ送信用の鍵は QA に渡さない（QA では build しないので不要）。
    [[ "${e:t}" != .env.sentry-build-plugin ]] || continue
    # 通常ファイルだけ。リンクは内容の同一性を保証できないので複製しない。
    [[ -f "$MAIN_CHECKOUT/$e" && ! -L "$MAIN_CHECKOUT/$e" ]] || continue
    envs+=("$e")
  done
  for e in "${envs[@]}"; do
    _qa_require_local_path "$QA_WORKTREE/$e" || return 1
    [[ ! -e "$QA_WORKTREE/$e" && ! -L "$QA_WORKTREE/$e" ]] || continue
    [[ -d "$QA_WORKTREE/${e:h}" ]] || continue
    cp -p -- "$MAIN_CHECKOUT/$e" "$QA_WORKTREE/$e" || return 1
    cmp -s -- "$MAIN_CHECKOUT/$e" "$QA_WORKTREE/$e" || return 1
    n=$(( n + 1 ))
  done
  print -- "QA worktree: .env 系 ${n} 件を本体 checkout から複製（本体と同一を確認。中身は表示しない）"
}

# 固定した履歴のロックファイルから、QA worktree の中に依存を入れる。本体の node_modules は共有しない。
_install_qa_deps() {
  local d name log
  local -a cmd
  if (( NO_DEPS )); then print -- "QA worktree: 依存の用意を省略（--no-deps）"; return 0; fi
  for d in "$QA_WORKTREE" "$QA_WORKTREE"/apps/*(N/) "$QA_WORKTREE"/packages/*(N/); do
    if [[ -f "$d/package-lock.json" ]]; then cmd=(npm ci)
    elif [[ -f "$d/pnpm-lock.yaml" ]]; then cmd=(pnpm install --frozen-lockfile)
    elif [[ -f "$d/yarn.lock" ]]; then cmd=(yarn install --frozen-lockfile)
    else continue; fi
    _qa_require_local_path "$d" || return 1
    _qa_require_local_path "$d/node_modules" || return 1
    # ワークスペースのルートで入った所は入れ直さない。
    [[ ! -d "$d/node_modules/.bin" ]] || continue
    name="${${d#$QA_WORKTREE}#/}"; name="${${name:-root}//\//-}"
    log="$QA_WORKTREE/logs/qa-deps-$name.log"
    _qa_require_local_path "$log" || return 1
    lanes_records_claim "$QA_WORKTREE/logs" "file:${log:t}"   # 書く前にランチャの記録の台帳へ載せる（chk-run.sh が入力に数えない）
    print -- "QA worktree: 依存を用意: ${name}（${cmd[*]}。ログ $log）"
    ( cd "$d" && "${cmd[@]}" ) > "$log" 2>&1 || { print -u2 -- "依存の用意に失敗: $d（$log）"; return 1; }
  done
  return 0
}

# 終わった QA worktree（同じリポジトリ・今回以外）を既存の後片付けへ流す。止まっても新しい QA は止めない。
# 終わった＝ logs/*.pid が 1 つ以上あり、各 .pid に同じ時刻以降の .done があり、ランチャも子も生きていない。
_sweep_finished_qa() {
  local line qpath pf done_f n=0 rc finished
  local root="${LANES_SCRATCH_ROOT:A}/${MAIN_CHECKOUT:t}"
  for line in "${(@f)$(git -C "$MAIN_CHECKOUT" worktree list --porcelain)}"; do
    [[ "$line" == "worktree "* ]] || continue
    qpath="${${line#worktree }:A}"
    [[ "${qpath:h}" == "$root" && "${qpath:t}" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*-checkout$' && "$qpath" != "${QA_WORKTREE:A}" ]] || continue
    [[ -d "$qpath" && ! -L "$qpath" ]] || continue
    local -a pids=("$qpath"/logs/*.pid(N.))
    (( ${#pids} )) || continue
    finished=1
    for pf in "${pids[@]}"; do
      done_f="${pf%.pid}.done"
      if [[ ! -f "$done_f" || "$pf" -nt "$done_f" ]] || lanes_pid_alive "$pf" || lanes_child_alive "$pf"; then finished=0; break; fi
    done
    (( finished )) || continue
    print -- "終わった QA worktree を後片付け: $qpath"
    rc=0; zsh -f "$SCRIPT_DIR/cleanup-after-merge.sh" "$qpath" --apply || rc=$?
    if (( rc == 0 )); then n=$(( n + 1 )); else print -u2 -- "注意: QA worktree の後片付けが EXIT:$rc で止まった（残したまま進む）: $qpath"; fi
  done
  (( n == 0 )) || print -- "終わった QA worktree ${n} 件を後片付けした（ログは退避先へ）"
  return 0
}

# ---- 実行 ----
_verify_merged
print -- "OK: feature HEAD は取得した $BASE_BRANCH の履歴に含まれる"
CLEANUP_CMD=(zsh -f "$SCRIPT_DIR/cleanup-after-merge.sh" "$FEATURE_WT")
(( ! APPLY )) || CLEANUP_CMD+=(--apply)

if (( ! SKIP_QA )); then
  _resolve_merged_pr
  [[ -n "$LABEL" ]] || LABEL="$(_default_label)"
  lanes_require_label "$LABEL"
  repo_name="${MAIN_CHECKOUT:t}"
  QA_WORKTREE="$LANES_SCRATCH_ROOT/$repo_name/${LABEL}-checkout"
  lanes_scratch_guard "$QA_WORKTREE" || lanes_die "QA worktree の保存先が不正"
  [[ "${QA_WORKTREE:A}/" != "$FEATURE_WT/"* ]] || lanes_die "QA worktree が削除対象の中にある"
  LOCAL_PROMPT="$QA_WORKTREE/logs/qa-case.md"
  print -- "PR: ${PR_NUMBER:-未特定} / feature: $FEATURE_HEAD / QA: $MERGE_SHA"
  print -- "QA worktree: $QA_WORKTREE / label: $LABEL"
fi
if (( ! APPLY )); then
  print -- "[dry-run] 後片付け: ${CLEANUP_CMD[*]}"
  if (( ! SKIP_QA )); then
    print -- "[dry-run] 同じリポジトリの終わった QA worktree（*-checkout）を cleanup-after-merge.sh --apply で片付ける"
    deps_plan="ロックファイルから"; (( ! NO_DEPS )) || deps_plan="省略"
    print -- "[dry-run] 固定した履歴 $MERGE_SHA の専用 worktree を作り、.env 系を本体から複製・依存を用意（${deps_plan}）して run-qa.sh を実行"
  fi
  exit 0
fi

# 呼び出し元が削除対象の中なら、外に移ってから再実行してもらう。
if (( ! IS_MAIN )) && [[ "${PWD:A}/" == "$FEATURE_WT/"* ]]; then
  lanes_die "cwd が削除対象 feature-worktree の中。cd $MAIN_CHECKOUT してから再実行する"
fi
cd "$MAIN_CHECKOUT"
if (( SKIP_QA )); then exec "${CLEANUP_CMD[@]}"; fi

_sweep_finished_qa
# 本体の統合先の枝の未送信履歴や未保存変更を変更せず、共有先由来の固定履歴だけを展開する。
[[ ! -e "$QA_WORKTREE" ]] || lanes_die "QA worktree が既にある。状態を確認して別の --label を指定する: $QA_WORKTREE"
mkdir -p "${QA_WORKTREE:h}"
git -C "$MAIN_CHECKOUT" worktree add --detach "$QA_WORKTREE" "$MERGE_SHA"
[[ "$(git -C "$QA_WORKTREE" rev-parse HEAD)" == "$MERGE_SHA" && -z "$(git -C "$QA_WORKTREE" status --porcelain)" ]] || lanes_die "QA worktree が固定履歴と一致しない/変更あり"
_qa_require_local_path "$QA_WORKTREE/logs" || lanes_die "QA ログの保存先が不正"
mkdir -p "$QA_WORKTREE/logs"
_qa_require_local_path "$LOCAL_PROMPT" || lanes_die "QA 指示書の保存先が不正"
[[ ! -e "$LOCAL_PROMPT" && ! -L "$LOCAL_PROMPT" ]] || lanes_die "QA 指示書の保存先に既存ファイルがある"
lanes_records_claim "$QA_WORKTREE/logs" "file:${LOCAL_PROMPT:t}"   # 書く前にランチャの記録の台帳へ載せる（chk-run.sh が入力に数えない）
if [[ -n "$QA_PROMPT" ]]; then
  cp "$QA_PROMPT" "$LOCAL_PROMPT"
else
  _write_auto_prompt "$LOCAL_PROMPT"
fi
# QA で typecheck・テストを回せるよう、.env 系と依存を feature の削除前に用意する（build は QA では回さない）。
# 失敗したら feature はそのまま（再実行できる）。QA worktree は調べられるよう残し、撤去手順を出す。
if ! _copy_qa_envs || ! _install_qa_deps; then
  print -u2 -- "QA の準備に失敗。feature の後片付けはしていない。確認後に撤去して再実行する: git -C ${(q)MAIN_CHECKOUT} worktree remove --force ${(q)QA_WORKTREE}"
  exit 1
fi
# プロンプトの複製が完了してから feature を削除する。
pending_snapshot="$(_pending_qa_snapshot)" || lanes_die "未起動 QA の内容を確認できない"
cleanup_rc=0
"${CLEANUP_CMD[@]}" || cleanup_rc=$?
if (( cleanup_rc == 8 )); then
  # scratch の保全だけが残った。一覧と手順は cleanup-after-merge.sh が出している。QA は止めない。
  print -u2 -- "注意: feature の scratch を保全したまま QA へ進む（上の一覧を手順に沿って確認してから手で削除する）"
  cleanup_rc=0
fi
if (( cleanup_rc != 0 )); then
  # 今回作った未使用の場所だけを戻す。変更・追加・起動記録があれば保全して停止する。
  current_snapshot="$(_pending_qa_snapshot)" || current_snapshot=""
  if [[ -n "$current_snapshot" && "$current_snapshot" == "$pending_snapshot" ]]; then
    rm -- "$LOCAL_PROMPT"
    # 内容が準備直後のままと確認できた（複製した .env 系・入れた依存だけ）ので、無視対象ごと撤去する。
    if git -C "$MAIN_CHECKOUT" worktree remove --force "$QA_WORKTREE"; then
      print -u2 -- "後片付け失敗: 未起動 QA worktree を撤去した。同じ --label で再実行できる"
    else
      print -u2 -- "後片付け失敗: 未起動 QA worktree の撤去にも失敗。残った作業場所を確認する"
    fi
  else
    print -u2 -- "後片付け失敗: QA worktree に変更あり/同一性不明のため保全する"
  fi
  exit "$cleanup_rc"
fi
[[ "$(git -C "$QA_WORKTREE" rev-parse HEAD)" == "$MERGE_SHA" ]] || lanes_die "QA 開始前に対象履歴が変化した"
print -- "== run-qa.sh: $QA_WORKTREE / $LABEL =="
if (( AFTER_MERGE_DETACH_QA )); then
  launch_log="$QA_WORKTREE/logs/${LABEL}.launch.log"
  _qa_require_local_path "$launch_log" || lanes_die "QA 起動ログの保存先が不正"
  qa_pid="$("$SCRIPT_DIR/detach-run.sh" "$launch_log" zsh -f "$SCRIPT_DIR/run-qa.sh" "$QA_WORKTREE" "$LOCAL_PROMPT" "$LABEL")"
  print -- "QA 起動要求 pid=$qa_pid label=$LABEL / launch-log: $launch_log"
  print -- "lanes-status.sh $QA_WORKTREE $LABEL で RUNNING/DONE を確認する"
  exit 0
fi
exec zsh -f "$SCRIPT_DIR/run-qa.sh" "$QA_WORKTREE" "$LOCAL_PROMPT" "$LABEL"
