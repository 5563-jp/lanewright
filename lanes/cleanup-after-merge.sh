#!/bin/zsh -f
# マージ後の 3 ステップ後片付け + 残骸退避。使い方:
#   cleanup-after-merge.sh <worktree> [--apply]
# 既定は dry-run（何をするか表示だけ）。--apply で実行。
# やること:
#   1. HEAD が origin/<統合先>（設定キー LANES_BASE_BRANCH。既定 develop）に含まれている（＝マージ済み）ことを確認。未マージなら何もしない（squash / rebase マージは祖先にならないので「未マージ」扱い＝安全側）
#   2. tracked の未 commit 変更（staged 含む）があれば patch を退避先に保存して停止。残骸パターン外の未追跡（git add 忘れ）があっても停止。勝手に捨てない
#   3. 残骸（run-*.sh / prompts/ / logs/ / *.log / review 出力 等。ignore 済みも含む）を $LANES_ARCHIVE_ROOT/<repo>/<日付>-<枝>/ へ退避
#   4. worktree 削除 → ローカル枝削除 → リモート枝はリモート先端も origin/<統合先> 済みのときだけ削除
#   5. main / master / 統合先は永久枝。ローカルもリモートも絶対に消さない
#   .env* は退避しない。linked worktree の .env* は本体 checkout と同一でなければ停止（worktree 削除で消えるため）
#   本体 checkout（.git ディレクトリを直接持つ方）を渡した場合は 3 の退避 + 残骸削除だけ行い、worktree / 枝は消さない
#   6. そのレーンの作業場所（$LANES_SCRATCH_ROOT/<repo>/<label>/。.lane の worktree= が一致するもの）を削除。
#      一時 PostgreSQL は実体を照合して pg_ctl stop。実行中のレーンや不明な DB があれば後片付け全体を停止する
#   7. LANES_DOWNLOADS_SCAN=1 のときだけ、~/Downloads に置き忘れたレビュー出力らしい一時物（*review* / *.diff / *.patch 等）を
#      一覧で知らせる（消さない）
#   8. 生存情報の控え（$LANES_SCRATCH_ROOT/.cleanup-guards/）は、記録したプロセスがすべて終了していれば --apply の完了時に消す
# 終了コード: 0 完了 / 2 引数・前提エラー / 4 未 commit・未追跡あり / 5 未マージ / 6 .env 不一致 / 7 実行中レーン・照合不能で停止
#   8 worktree 消失時に現世代の停止を確認できない scratch だけ保全（削除していない）。ほかの後片付けは完了
set -euo pipefail
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
base="${LANES_BASE_BRANCH:-develop}"
git check-ref-format --branch "$base" >/dev/null 2>&1 || lanes_die "LANES_BASE_BRANCH が枝名として不正: $base"
# 永久枝（ローカルもリモートも消さない）
is_permanent() { [[ "$1" == main || "$1" == master || "$1" == "$base" ]]; }

wt="${1:-}"; apply=0
[[ -n "$wt" ]] || lanes_die "使い方: cleanup-after-merge.sh <worktree> [--apply]"
[[ -z "${2:-}" || "${2:-}" == "--apply" ]] || lanes_die "第2引数は --apply のみ（渡されたのは: ${2}）"
[[ "${2:-}" == "--apply" ]] && apply=1
# worktree がもう無い（gh pr merge --delete-branch が worktree ごと消した等）: 枝・退避は何もせず、
# 対応する scratch が残っていれば現世代の停止を証明できないため消さずに保全し、終了コード 8 で知らせる。
# 無ければ Downloads の見張り（LANES_DOWNLOADS_SCAN=1 のとき）だけ行う。
missing_wt=0
if [[ ! -d "$wt" ]]; then
  missing_wt=1; wt="${wt:A}"
else
  lanes_require_worktree "$wt"
  wt="$(git -C "$wt" rev-parse --path-format=absolute --show-toplevel)"
fi   # サブディレクトリを渡されても toplevel に正規化
say() { if (( apply )); then print -- "[apply] $*"; else print -- "[dry-run] $*"; fi; }
g() { git -c core.quotePath=false -C "$wt" "$@"; }                       # 非 ASCII ファイル名をそのまま出す

# 生存情報は worktree と削除する scratch の外に置く。途中で worktree が消えても再確認できる。
guard_key="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$wt")"
guard_dir="$LANES_SCRATCH_ROOT/.cleanup-guards/$guard_key"
[[ "${guard_dir:A}/" != "${wt:A}/"* ]] || lanes_die "生存情報の退避先が削除対象の中にある"
check_active_lanes() {
  local pf saved blocked=0 key
  # .done があってもランチャ自身や子が生きていたら削除しない。古い世代の .pid も確認する。
  for pf in "$wt"/logs/*.pid(ND.) "$guard_dir"/*.pid(ND.); do
    if lanes_pid_alive "$pf" || lanes_child_alive "$pf"; then
      blocked=1
      if (( apply )) && [[ "${pf:h}" != "$guard_dir" ]]; then
        mkdir -p "$guard_dir"
        key="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$pf")"
        saved="$guard_dir/$key.pid"
        cp -p "$pf" "$saved"
      fi
    fi
  done
  (( ! blocked )) || { print -u2 -- "→ 実行中レーンあり。scratch・worktree・監視ファイル・枝の後片付けをすべて停止"; return 7; }
  return 0
}

# 一時 PostgreSQL はデータ領域・開始時刻・所有者・実行主体がすべて一致した場合だけ pg_ctl で止める。
# ps の引数や環境変数は読まず、照合できないときは停止も削除もしない。直接 TERM する代替経路は作らない。
stop_scratch_pg() {
  local pmf="$1" pgctl
  pgctl="$(command -v pg_ctl 2>/dev/null || true)"
  [[ -n "$pgctl" ]] || pgctl="$(print -l /opt/homebrew/opt/postgresql@*/bin/pg_ctl(N) /usr/local/opt/postgresql@*/bin/pg_ctl(N) | tail -1)"
  python3 - "$pmf" "$apply" "$pgctl" <<'PG'
import calendar, datetime, os, pathlib, subprocess, sys
pmf, apply, pgctl = pathlib.Path(sys.argv[1]), sys.argv[2] == "1", sys.argv[3]
env = dict(os.environ, LC_ALL="C", TZ="UTC")
def ps(field, pid):
    r = subprocess.run(["ps", "-o", field + "=", "-p", str(pid)], env=env, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""
def verify():
    lines = pmf.read_text().splitlines()
    pid = int(lines[0])
    if pid <= 1:
        raise ValueError()
    # kill -0 の権限エラーも「不明」として止める。
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    data = pmf.parent.resolve()
    if len(lines) < 3 or pathlib.Path(lines[1]).resolve() != data:
        raise ValueError()
    uid = int(ps("uid", pid))
    if uid != os.getuid() or data.stat().st_uid != uid or pmf.stat().st_uid != uid:
        raise ValueError()
    if pathlib.Path(ps("comm", pid)).name not in ("postgres", "postmaster"):
        raise ValueError()
    started = calendar.timegm(datetime.datetime.strptime(ps("lstart", pid), "%a %b %d %H:%M:%S %Y").timetuple())
    if abs(started - int(lines[2])) > 2:
        raise ValueError()
    proc_cwd = pathlib.Path(f"/proc/{pid}/cwd")
    if proc_cwd.exists():
        cwd = proc_cwd.resolve()
    else:
        r = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True, text=True)
        names = [x[1:] for x in r.stdout.splitlines() if x.startswith("n")]
        if r.returncode or len(names) != 1:
            raise ValueError()
        cwd = pathlib.Path(names[0]).resolve()
    if cwd != data:
        raise ValueError()
    return pid, started, tuple(lines)
try:
    identity = verify()
    if identity is None:
        sys.exit(0)
    if not apply:
        print("[dry-run] 一時 PostgreSQL の実体照合 OK（停止・削除はしない）")
        sys.exit(0)
    if not pgctl or verify() != identity:
        raise ValueError()
    r = subprocess.run([pgctl, "-D", str(pmf.parent), "stop", "-m", "fast", "-w", "-t", "20"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if r.returncode:
        raise ValueError()
    # 同じ pid が直後に再利用された場合も安全側に倒して残す。
    try:
        os.kill(identity[0], 0)
    except ProcessLookupError:
        print("[apply] 一時 PostgreSQL の停止を確認")
        sys.exit(0)
    raise ValueError()
except (OSError, ValueError, IndexError, subprocess.SubprocessError):
    print("→ PostgreSQL の実体または停止を確認できない。停止要求の追加送信・削除は行わない", file=sys.stderr)
    sys.exit(1)
PG
}

# 先に全対象の安全性を確認してから削除する。途中の失敗でも worktree の監視情報を残す。
typeset -ga preserved_scratch=()
cleanup_scratch() {
  local meta d lw ll pmf
  local -a dirs=()
  preserved_scratch=()
  check_active_lanes || return $?
  for meta in "$LANES_SCRATCH_ROOT"/*/*/.lane(ND.); do
    d="${meta:h}"
    lw="$(sed -n 's/^worktree=//p' "$meta" | head -1)"
    [[ -n "$lw" && "${lw:A}" == "$wt" ]] || continue
    # ランチャが作ったものだけ消す: フォルダ名が .lane の label（ずらしたときは label-<数>）と一致し、リンクでないこと
    ll="$(sed -n 's/^label=//p' "$meta" | head -1)"
    [[ -n "$ll" && ! -L "$d" && ( "${d:t}" == "$ll" || "${d:t}" == "$ll"-<2-> ) ]] || { print -u2 -- "→ .lane の label と合わないので消さない: $d"; continue; }
    lanes_scratch_guard "$d" || { print -u2 -- "→ scratch パスが想定外なので停止"; return 7; }
    # worktree 消失後は退避した記録が現世代のものか確認できない。
    # 古い終了済み記録があっても、新レーン/新しい子の不在証明にはしない。消さずに保全して先へ進む。
    if (( missing_wt )); then
      preserved_scratch+=("$d")
      continue
    fi
    # worktree を入れた QA の管理用ディレクトリは worktree remove より先に消さない。
    [[ "$wt/" != "${d:A}/"* ]] || continue
    dirs+=("$d")
  done
  # 旧 QA が worktree/logs/qa に作った DB も停止を確認してから片付ける。
  for d in "${dirs[@]}" "$wt/logs"; do
    for pmf in "$d"/**/postmaster.pid(ND.); do stop_scratch_pg "$pmf" || return 7; done
  done
  check_active_lanes || return $?
  for d in "${dirs[@]}"; do
    say "作業場所（scratch）を削除: $d"
    if (( apply )); then rm -rf -- "$d"; fi
  done
  (( ${#dirs} || ${#preserved_scratch} )) || print -- "作業場所（scratch）: このレーンの分はなし"
  report_preserved_scratch
  return 0
}

# 保全した scratch と、手で確認して消す手順を出す（after-develop-merge.sh はこの後 QA へ進む）。
report_preserved_scratch() {
  local d
  (( ${#preserved_scratch} )) || return 0
  print -- "→ worktree が無く現世代の停止を確認できない scratch を ${#preserved_scratch} 件保全した（削除していない。ほかの後片付けは完了）:"
  printf '   %s\n' "${preserved_scratch[@]}"
  print -- "  手で消す手順（フォルダごとに）:"
  print -- "   1. フォルダ名＝label。そのレーンのランチャ・子が残っていないことを確かめる（.lane の worktree= と label= を見て、該当 worktree があれば lanes-status.sh <worktree> <label> が RUNNING / STALLED でないこと）"
  print -- "   2. 中に postmaster.pid があれば pg_ctl -D <postmaster.pid のあるフォルダ> stop -m fast で止める"
  print -- "   3. rm -rf -- <フォルダ>"
}

# 記録したプロセスがすべて終了した生存情報の控えを消す（--apply の完了時だけ）。
# 生存・同一性不明のものは残す。書き込み中の控えを消さないよう、1 分以上前のものだけ見る。
prune_cleanup_guards() {
  local root="$LANES_SCRATCH_ROOT/.cleanup-guards" gd pf
  (( apply )) || return 0
  [[ -d "$root" && ! -L "$root" ]] || return 0
  for gd in "$root"/*(N/); do
    for pf in "$gd"/*.pid(N.mm+0); do
      lanes_pid_alive "$pf" || lanes_child_alive "$pf" || rm -f -- "$pf"
    done
    rmdir -- "$gd" 2>/dev/null || true
  done
  rmdir -- "$root" 2>/dev/null || true
  return 0
}

# ---- 7. ~/Downloads の見張り（LANES_DOWNLOADS_SCAN=1 のときだけ。報告だけで消さない）----
sweep_downloads() {
  local dl="$HOME/Downloads" hits
  [[ "${LANES_DOWNLOADS_SCAN:-0}" == 1 ]] || return 0
  [[ -d "$dl" ]] || return 0
  hits=("${(@f)$(find "$dl" -mindepth 1 -maxdepth 1 -mtime -3 \( -iname '*review*' -o -iname '*-pg-*' -o -iname '*.diff' -o -iname '*.patch' -o -iname '*.prompt.md' -o -iname '*.log' \) 2>/dev/null | sort)}"); hits=("${(@)hits:#}")
  (( ${#hits} )) || return 0
  print -- "注意: ~/Downloads にレビュー由来らしい一時物が ${#hits} 件（直近3日。消していない。不要ならゴミ箱へ）:"
  printf '   %s\n' "${hits[@]}"
  return 0
}

check_active_lanes || exit $?

if (( missing_wt )); then
  print -- "worktree : $wt（もう無い。枝の削除・退避はしない。scratch と（設定があれば）~/Downloads の確認だけ）"
  cleanup_scratch
  prune_cleanup_guards
  sweep_downloads
  (( ! ${#preserved_scratch} )) || exit 8
  exit 0
fi

# --git-common-dir は本体 checkout だと相対 ".git" を返すので絶対パスで取る
common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir)"
main_repo="${common:h}"                       # 本体 checkout（.git の親）
repo_name="${main_repo:t}"
is_main=0; [[ "$gitdir" == "$common" ]] && is_main=1
branch="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$branch" ]] || branch="detached"
head="$(git -C "$wt" rev-parse HEAD)"
slug="${branch//\//-}"
# 枝の無い worktree（QA 専用 checkout 等）は同じ日の退避先が重ならないよう worktree 名を付ける
[[ "$branch" != detached ]] || slug="detached-${wt:t}"
dest="$LANES_ARCHIVE_ROOT/$repo_name/$(date +%Y%m%d)-$slug"
# worktree が同名パスだと cp 自己コピーで止まり remove まで進まない
if [[ "${dest:A}" == "${wt:A}" ]]; then
  dest="$LANES_ARCHIVE_ROOT/$repo_name/merged-cleanup-$(date +%Y%m%d)-$slug"
fi

# H1: 呼び出し元 cwd が削除対象 worktree だと Bot Shell が spawn /bin/zsh ENOENT になる
if [[ "${PWD:A}/" == "${wt:A}/"* ]]; then
  if (( apply && ! is_main )); then
    lanes_die "cwd（$PWD）が削除対象 worktree の中。cd $main_repo してから再実行する"
  fi
  print -u2 -- "warn: cwd（$PWD）が対象 worktree の中。--apply すると Bot Shell が ENOENT になるので cd $main_repo してから"
fi

if (( apply )); then
  git -C "$main_repo" fetch -q origin "$base" || lanes_die "origin/$base の fetch に失敗。--apply では古い判定で消さない"
else
  git -C "$main_repo" fetch -q origin "$base" 2>/dev/null || print -u2 -- "warn: origin/$base の fetch に失敗（ローカルの origin/$base で判定する）"
fi
merged=0; git -C "$main_repo" merge-base --is-ancestor "$head" "origin/$base" 2>/dev/null && merged=1

print -- "worktree : $wt"
print -- "repo     : $repo_name（本体 $main_repo）"
print -- "branch   : $branch @ ${head:0:12}  merged_into_origin/$base=$merged  main_checkout=$is_main"
print -- "archive  : $dest"

# linked worktree で未マージなら、退避もせずここで終わり（_runs にコピーを積まない）
if (( ! is_main && ! merged )); then
  print -- "→ origin/$base に未マージ（squash / rebase マージなら祖先にならない）。worktree も枝も消さない。退避もしない"
  exit 5
fi
(( ! is_main )) && is_permanent "$branch" && lanes_die "永久枝（main / master / $base）の worktree は消さない（退避もしない）"

# 2. tracked 変更（staged 含む）は捨てない
tracked=("${(@f)$(g status --porcelain --untracked-files=no)}"); tracked=("${(@)tracked:#}")
if (( ${#tracked} )); then
  print -- "tracked の未 commit 変更 ${#tracked} 件（staged 含む）:"; printf '   %s\n' "${tracked[@]}"
  say "patch（staged + unstaged + バイナリ）を $dest/uncommitted.patch に保存"
  if (( apply )); then mkdir -p "$dest"; g diff --binary HEAD > "$dest/uncommitted.patch"; fi
  if (( ! is_main )); then
    print -- "→ tracked 変更が残っているので worktree は削除しない。commit するか捨てるか決めてから再実行"
    exit 4
  fi
fi

# 3. 退避対象 = 残骸パターンに一致する未追跡（ignore 外）+ ignore 済み。残骸パターン外の未追跡は git add 忘れの可能性があるので停止
# 退避してよい残骸（キットのランチャ・指示書が作る名前だけ）。ここにも下の生成物（generated_re）にも当たらない未追跡ファイルは「知らない物」として後片付けを止める
residue_re='^(logs/|prompts/|run-[^/]*\.sh$|[^/]*\.log$|IMPLEMENTATION_DONE|review[^/]*\.md$|[^/]*\.prompt\.md$|[^/]*\.patch$|\.claude-task-[^/]*\.md$|\.check-[^/]*\.sh$|\.launch-[^/]*\.sh$|\.ci-fix-[^/]*\.md$|\.login-[^/]*\.md$)'
# 依存とフレームワークのキャッシュはモノレポの各パッケージ配下（apps/web/node_modules/ 等）にもできる
generated_re='^(node_modules/|\.next/|\.turbo/|\.cache/|coverage/|test-results/|playwright-report/|[^/]*\.tsbuildinfo$)|^([^/]+/)+(node_modules|\.next|\.turbo)/|^([^/]+/)+[^/]*\.tsbuildinfo$'
untracked=(); ignored=(); others=()
for f in "${(@0)$(g ls-files -z --others --exclude-standard)}"; do
  [[ -n "$f" ]] || continue
  [[ "$f" =~ '(^|/)\.env' ]] && continue
  if [[ "$f" =~ "$residue_re" && "$f" != */ ]]; then untracked+=("$f"); else others+=("$f"); fi
 done
for f in "${(@0)$(g ls-files -z --others --ignored --exclude-standard)}"; do
  [[ -n "$f" ]] || continue
  [[ "$f" =~ '(^|/)\.env' ]] && continue
  if [[ "$f" =~ "$residue_re" && "$f" != */ ]]; then
    ignored+=("$f")
  elif [[ ! "$f" =~ "$generated_re" || "$f" == */ ]]; then
    others+=("$f")
  fi
 done
if (( ${#others} )); then
  print -- "→ 退避対象・削除可能な生成物以外の未追跡/除外ファイル ${#others} 件。後片付けを停止:"
  printf '   %s\n' "${others[@]}"
  exit 4
fi
archive=("${untracked[@]}" "${ignored[@]}")

# .env*: 本体 checkout なら触らない。linked worktree は削除で一緒に消えるので、本体と同一コピーがあるときだけ進む
envs=()
for e in "${(@0)$(g ls-files -z --others)}"; do
  [[ "$e" =~ '(^|/)\.env' && ! "$e" =~ '(^|/)(node_modules|\.next)/' ]] && envs+=("$e")
done
if (( ${#envs} )); then
  if (( is_main )); then
    print -- "注意: .env 系 ${#envs} 件は触らない（本体 checkout）"
  else
    for e in "${envs[@]}"; do
      if [[ ! -f "$main_repo/$e" ]] || ! cmp -s "$wt/$e" "$main_repo/$e"; then
        print -- "→ $e が本体 checkout と一致しない/無い。worktree 削除で消えるので手で退避してから再実行"
        exit 6
      fi
    done
    print -- "注意: .env 系 ${#envs} 件は本体と同一なので worktree ごと消えて問題なし"
  fi
fi

check_active_lanes || exit $?

if (( ${#archive} )); then
  preview="$(printf '%s ' "${archive[@]:0:6}")"; (( ${#archive} > 6 )) && preview+="…(計 ${#archive})"
  say "残骸 ${#untracked} 件 + ignore 済み残骸 ${#ignored} 件を退避: $preview"
  if (( apply )); then
    # 同じ日・同じ枝で後片付けを繰り返すと退避先が重なり、前回退避した symlink を cp が書き込み先として辿りうる。
    # 既にあるなら番号付きの新しいフォルダにして、退避先は必ず空から作る
    if [[ -e "$dest" || -L "$dest" ]]; then
      n=1; while [[ -e "$dest-$n" || -L "$dest-$n" ]]; do n=$(( n + 1 )); done; dest="$dest-$n"
    fi
    mkdir -p "${dest:h}" && mkdir "$dest" || { print -u2 -- "error: 退避先を新しく作れない: $dest"; exit 1; }
    for f in "${archive[@]}"; do mkdir -p "$dest/${f:h}"; cp -pP "$wt/$f" "$dest/$f"; done   # symlink は辿らずリンクのまま退避（外のファイルの中身を写さない）
    print -- "  退避完了 → $dest（$(du -sh "$dest" | cut -f1)）"
  fi
else
  print -- "退避対象なし"
fi

cleanup_scratch

if (( is_main )); then
  print -- "本体 checkout なので worktree / 枝は消さない（退避 + 残骸削除のみ）。$base 以外に居るなら: git -C $main_repo checkout $base"
  if (( apply )) && (( ${#archive} )); then
    for f in "${archive[@]}"; do rm -f "$wt/$f"; done
    for f in "${archive[@]}"; do d="${f:h}"; while [[ "$d" != "." && -d "$wt/$d" ]]; do rmdir "$wt/$d" 2>/dev/null || break; d="${d:h}"; done; done
    print -- "  退避済みの残骸を本体から削除した"
  fi
  prune_cleanup_guards
  sweep_downloads
  exit 0
fi

# 4. 削除（マージ済み・tracked 変更なし・未追跡は残骸のみ、が確認できたときだけ）
check_active_lanes || exit $?
say "git worktree remove --force $wt"
say "確認済みのローカル先端と一致する場合だけ枝 $branch を削除"
if (( apply )); then
  git -C "$main_repo" worktree remove --force "$wt"
  git -C "$main_repo" worktree prune
  if is_permanent "$branch"; then
    print -- "→ $branch は永久枝。ローカル branch -D しない"
  elif [[ "$branch" != "detached" ]]; then
    if git -C "$main_repo" worktree list --porcelain | grep -Fx "branch refs/heads/$branch" >/dev/null; then
      lanes_die "別の worktree が枝 $branch を使用中。ローカル枝は消さない"
    fi
    git -C "$main_repo" update-ref -d "refs/heads/$branch" "$head" || {
      print -u2 -- "→ ローカル枝が更新されたか削除に失敗。新しい先端は消さない"
      exit 7
    }
  fi
fi
if is_permanent "$branch"; then
  print -- "→ $branch は永久枝。ローカルもリモートも消さない"
elif [[ "$branch" != "detached" ]]; then
  remote_rc=0; remote_out="$(git -C "$main_repo" ls-remote --exit-code origin "refs/heads/$branch" 2>/dev/null)" || remote_rc=$?
  remote_sha="${remote_out%%$'\t'*}"
  if (( remote_rc != 0 && remote_rc != 2 )); then
    print -- "→ リモート照会に失敗（exit $remote_rc、オフライン?）。リモート枝は触らない"
  elif [[ -n "$remote_sha" ]]; then
    git -C "$main_repo" fetch -q origin "refs/heads/$branch" 2>/dev/null || true
    if git -C "$main_repo" merge-base --is-ancestor "$remote_sha" "origin/$base" 2>/dev/null; then
      say "確認済みのリモート先端 ${remote_sha[1,12]} と一致する場合だけ枝 $branch を削除"
      # 空の更新先 + expected old OID は削除専用の比較条件。新しい履歴を上書きしない。
      if (( apply )); then
        git -C "$main_repo" push --force-with-lease="refs/heads/$branch:$remote_sha" origin ":refs/heads/$branch" || {
          print -u2 -- "→ リモート枝が更新されたか削除に失敗。新しい先端は消さない"
          exit 7
        }
      fi
    else
      print -- "→ リモート枝 $branch（${remote_sha[1,12]}）に origin/$base 未マージの commit あり。リモートは消さない"
    fi
  else
    print -- "リモート枝なし（GitHub 側で削除済み）"
  fi
fi
prune_cleanup_guards
sweep_downloads
print -- "done: $wt"
