# review-dedup.zsh — run-codex-review.sh・run-claude-review.sh・run-gemini-review.sh から source する。同じレビューの繰り返しを省く
#  （入口の run-review.sh も、系列の前回のレビュー役を読むのに source する: rvd_prev_reviewer）
#  - 系列（series）: label の末尾 -r<N> を外したもの（rev-wap83-r5 → rev-wap83）。round は -r<N> から取る
#  - 前回 CLEAN・未保存変更なし・条件一致のときだけ delta または同一結果を再利用する
#  - 前回 NEEDS_FIX は指摘本文を渡し、前回レビューした HEAD からの delta で見る（rvd_fix_mode）。旧記録・同じ HEAD・未保存変更は full
#  - round 3 以降の P2/P3 は後回し票へ保存。必須検証の成功確認がある場合だけランチャが CLEAN にする
#  - 必須検証の使い回し: 親が同じ中身で chk-run.sh を通した記録があれば、レビューの中で回させない（rvd_checks_query）
# 依存なし（_common.sh を読まなくても使える。tests/test-review-dedup.sh が単体で試す）

rvd_series() { if [[ "$1" =~ '^(.+)-r([0-9]+)$' ]]; then print -- "${match[1]}"; else print -- "$1"; fi; }
rvd_label_round() { if [[ "$1" =~ '-r([0-9]+)$' ]]; then print -- "${match[1]}"; else print -- 0; fi; }
rvd_state_file() { print -- "$1/.$2.review-state"; }   # <logdir> <series>
# 本文も同じ JSON 記録に格納する。旧 key=value 形式は読み取りだけ互換にする。
rvd_state_get() {
  python3 -I - "$1" "$2" <<'PY_STATE'
import json, pathlib, sys
p, key = pathlib.Path(sys.argv[1]), sys.argv[2]
if p.is_file():
    raw = p.read_text(encoding='utf-8')
    try:
        value = json.loads(raw).get(key, '')
    except (ValueError, AttributeError):
        value = next((line.split('=', 1)[1] for line in reversed(raw.splitlines()) if line.startswith(key + '=')), '')
    print(value)
PY_STATE
}

# <logdir> <series> <label> <explicit_round> → 使う round
rvd_round() {
  local logdir="$1" series="$2" label="$3" r="${4:-0}" lr last
  (( r > 0 )) && { print -- "$r"; return; }
  lr="$(rvd_label_round "$label")"; (( lr > 0 )) && { print -- "$lr"; return; }
  last="$(rvd_state_get "$(rvd_state_file "$logdir" "$series")" last_round)"
  print -- $(( ${last:-0} + 1 ))
}

# HEAD・判定・終了状態は同じ有効な記録から読む。旧記録は条件情報が無いので再利用しない。
rvd_evidence_head() { [[ -f "$1" ]] || return 0; grep -Eq 'EXIT:0([[:space:]]|$)' "$1" || return 0; sed -n 's/^- HEAD: [0-9a-f]* → \([0-9a-f]*\).*/\1/p' "$1" | tail -1; }
rvd_evidence_verdict() { [[ -n "$(rvd_evidence_head "$1")" ]] || return 0; sed -En 's/^- (VERDICT: (CLEAN|NEEDS_FIX))$/\1/p' "$1" | head -1; }
rvd_prev_record() {
  local logdir="$1" series="$2" round="$3" k f v state
  state="$(rvd_state_file "$logdir" "$series")"
  # 同じ label / round の再実行でも、最新の有効な結果を優先する。
  v="$(rvd_state_get "$state" last_verdict)"
  [[ "$(rvd_state_get "$state" last_exit)" == 0 ]] || v=""
  if [[ "$v" == 'VERDICT: CLEAN' || "$v" == 'VERDICT: NEEDS_FIX' ]]; then print -r -- "$state"; return; fi
  for (( k = round - 1; k >= 1; k-- )); do
    f="$logdir/$series-r$k.evidence.md"
    v="$(rvd_evidence_verdict "$f")"
    [[ -n "$v" ]] && { print -r -- "$f"; return; }
  done
  return 0
}
rvd_record_get() {
  local f="$1" key="$2"
  [[ -n "$f" ]] || return 0
  if [[ "$f" == *.review-state ]]; then rvd_state_get "$f" "last_$key"; return; fi
  case "$key" in
    head) rvd_evidence_head "$f" ;;
    verdict) rvd_evidence_verdict "$f" ;;
    report) [[ -f "${f%.evidence.md}.log" ]] && cat "${f%.evidence.md}.log" ;;
  esac
  return 0
}
rvd_prev_head() { rvd_record_get "$(rvd_prev_record "$1" "$2" "$3")" head; }
rvd_prev_verdict() { rvd_record_get "$(rvd_prev_record "$1" "$2" "$3")" verdict; }

# 内容・index・HEAD と HEAD の操作履歴を比較する。出力は状態と要約値だけ（内容は表示しない）。
# 未追跡 logs/ はランチャの出力なので除外。追跡済み logs/ と未追跡ソースは検査する。
# 無視対象のファイル（.env.local・手元の設定やメモなど）も中身まで比べる（QA の写しと同じ考え方）。
# 既知の生成物（依存・ビルドとテストの出力・キャッシュ）は、どの深さにあっても比べない。レビューがテストを回すと書き換わるため。
rvd_snapshot() {
  python3 -I - "$1" <<'PY_SNAPSHOT'
import hashlib, os, pathlib, stat, subprocess, sys
GENERATED_DIRS = {"node_modules", ".next", ".turbo", ".cache", "coverage", "test-results", "playwright-report",
                  "dist", "build", "out", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"}
GENERATED_SUFFIXES = (".tsbuildinfo", ".pyc")
def is_generated(name):
    parts = name.rstrip("/").split("/")
    return any(seg in GENERATED_DIRS for seg in parts) or name.endswith(GENERATED_SUFFIXES)
def ignored_files(wt, exclude_logs):
    # --directory: 無視されたフォルダを 1 行にまとめて出す（node_modules の中身を全部並べない）。生成物でないフォルダだけ中を歩く
    raw = subprocess.check_output(['git', '-C', str(wt), 'ls-files', '--others', '--ignored', '--exclude-standard',
                                   '--directory', '-z'], stderr=subprocess.DEVNULL)
    found = set()
    for entry in (e for e in raw.split(b'\0') if e):
        name = os.fsdecode(entry)
        if (exclude_logs and (name == 'logs/' or name.startswith('logs/'))) or is_generated(name):
            continue
        if not name.endswith('/'):
            found.add(entry); continue
        for root_dir, dirs, files in os.walk(wt / name):
            rel_root = os.path.relpath(root_dir, wt).replace(os.sep, '/')
            keep = []
            for d in sorted(dirs):
                if is_generated(f"{rel_root}/{d}/"):
                    continue
                if os.path.islink(os.path.join(root_dir, d)):
                    found.add(os.fsencode(f"{rel_root}/{d}"))   # フォルダを指す symlink は辿らず、行き先だけ比べる
                else:
                    keep.append(d)
            dirs[:] = keep
            for fname in files:
                rel = f"{rel_root}/{fname}"
                if not is_generated(rel):
                    found.add(os.fsencode(rel))
    return found
def snapshot(wt, exclude_logs=False):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(wt), *args], stderr=subprocess.DEVNULL)
    h = hashlib.sha256()
    for args in [('rev-parse', 'HEAD'), ('symbolic-ref', '-q', 'HEAD'),
                 ('reflog', 'show', '--format=%H %gs', 'HEAD'), ('ls-files', '--stage', '-z')]:
        try:
            h.update(git(*args))
        except subprocess.CalledProcessError:
            if args[0] != 'symbolic-ref': raise
    tracked = set(git('ls-files', '-z').split(b'\0')) - {b''}
    others = set(git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0')) - {b''}
    if exclude_logs: others = {p for p in others if not p.startswith(b'logs/')}
    ignored = ignored_files(wt, exclude_logs) - tracked
    for raw in sorted(tracked | others | ignored):
        p = wt / os.fsdecode(raw)
        h.update(raw + b'\0')
        try:
            st = p.lstat()
        except FileNotFoundError:
            h.update(b'missing'); continue
        h.update(str(stat.S_IMODE(st.st_mode)).encode())
        if p.is_symlink(): h.update(os.fsencode(os.readlink(p)))
        elif p.is_file():
            with p.open('rb') as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
        elif p.is_dir():
            h.update(b'directory')
            # 初期化済み submodule も、未追跡ファイルを含めて再帰的に比較する。
            if (p / '.git').exists(): h.update(snapshot(p).encode())
    status = git('status', '--porcelain', '-z', '--untracked-files=all').split(b'\0')
    dirty = any(row and not (exclude_logs and row.startswith(b'?? logs/')) for row in status)
    return ('dirty' if dirty else 'clean') + ':' + h.hexdigest()
print(snapshot(pathlib.Path(sys.argv[1]), exclude_logs=True))
PY_SNAPSHOT
}

# Claude レビュー（③④）の前後比較に足す、git の管理フォルダ側の指紋。rvd_snapshot（省略判定の鍵にも使う）とは分ける。
# 対象: 共通の config・この worktree の config.worktree・hooks の中身・info/attributes・タグ・stash。
# 枝（refs/heads）と origin の追跡枝は入れない。worktree 同士で共有され、並行する他のレーンの commit や fetch で変わるため（誤検出になる）。
# ここで見ていない書き換え（他の枝の作成など）が前後の比較に出ないことは docs/roles.md に書いてある。
rvd_git_guard() {
  python3 -I - "$1" <<'PY_GUARD'
import hashlib, os, pathlib, subprocess, sys
wt = sys.argv[1]
def git(*args):
    return subprocess.check_output(['git', '-C', wt, *args], stderr=subprocess.DEVNULL)
common = pathlib.Path(git('rev-parse', '--path-format=absolute', '--git-common-dir').decode().strip())
gitdir = pathlib.Path(git('rev-parse', '--path-format=absolute', '--git-dir').decode().strip())
h = hashlib.sha256()
def add_file(p):
    h.update(os.fsencode(str(p)) + b'\0')
    try:
        if p.is_symlink(): h.update(b'link:' + os.fsencode(os.readlink(p)))
        elif p.is_file(): h.update(str(p.stat().st_mode).encode() + b':' + p.read_bytes())
        else: h.update(b'missing')
    except OSError:
        h.update(b'unreadable')
for p in [common / 'config', gitdir / 'config.worktree', common / 'info' / 'attributes']:
    add_file(p)
hooks = common / 'hooks'
if hooks.is_dir():
    for root_dir, dirs, files in os.walk(hooks):
        dirs.sort()
        for name in sorted(files): add_file(pathlib.Path(root_dir) / name)
h.update(git('for-each-ref', '--format=%(refname) %(objectname)', 'refs/tags'))
try:
    h.update(git('stash', 'list', '--format=%H'))
except subprocess.CalledProcessError:
    pass
print(h.hexdigest())
PY_GUARD
}

# 起点・案件指示・設定・実装・テンプレの内容を条件に含める（値そのものは記録しない）。
# 検証の設定（LANES_CHECK_CMD の値・対象の .lanes/check.sh の中身・package.json の scripts のうち検証に関わるもの）も含める。
# 検証が「未導入」で CLEAN になった後に検証を足したら、同じ HEAD でも前回の結果を使わずにレビューし直す。
# 必須検証の使い回しの有無と使った記録（rvd_checks_key）、レビュー役（codex / claude / gemini）も含める。
# 記録が変わった（使い回しが無くなった・親が回し直した）ら、同じ HEAD でも前回の結果を使わない。
# キットのファイルが無い（一部だけを写したテストの置き場など）ときは「無い」ことを条件に入れる（後で置かれたら条件が変わる）。
# 読み取り専用の制限の設定（Gemini の拒否の一覧・Claude の使えるツールと拒否・Codex の sandbox）も [制限の設定] で入れる。
# 制限を強めたら、前の制限の下で出た CLEAN を同じ HEAD でも使わない。
# <root> <prompt> <base> <mode> <policy> <model> <effort> [worktree] [使い回しの鍵] [レビュー役] [制限の設定]
rvd_context() {
  python3 -I - "$@" <<'PY_CONTEXT'
import hashlib, json, os, pathlib, sys
root, prompt, base, mode, policy, model, effort = sys.argv[1:8]
wt = sys.argv[8] if len(sys.argv) > 8 else ''
reuse = sys.argv[9] if len(sys.argv) > 9 else ''
kind = sys.argv[10] if len(sys.argv) > 10 else ''
restrict = sys.argv[11] if len(sys.argv) > 11 else ''
h = hashlib.sha256()
for value in [base, mode, policy, model, effort, 'checks-reuse:' + reuse, 'reviewer:' + kind, 'restrict:' + restrict]: h.update(value.encode() + b'\0')
h.update(pathlib.Path(prompt).read_bytes() + b'\0')
for f in ['review-dedup.zsh', 'run-codex-review.sh', 'run-claude-review.sh', 'run-gemini-review.sh', '_common.sh',
          'codex-review-output.py', 'templates/claude-review-full.md', 'templates/claude-review-delta.md',
          'templates/codex-review-focus.md']:
    try:
        h.update((pathlib.Path(root) / f).read_bytes() + b'\0')
    except FileNotFoundError:
        h.update(b'missing:' + f.encode() + b'\0')
# 検証の設定。名前は _common.sh の lanes_checks_present が見るものと同じ
h.update(b'check-cmd:' + os.environ.get('LANES_CHECK_CMD', '').encode() + b'\0')
if wt:
    # 受け入れ済みの限界が変わったら、同じ HEAD でも前回の結果を使わない
    try:
        h.update(b'accepted:' + (pathlib.Path(wt) / '.lanes' / 'accepted-limitations.md').read_bytes() + b'\0')
    except OSError:
        h.update(b'accepted:missing\0')
    check = pathlib.Path(wt) / '.lanes' / 'check.sh'
    try:
        h.update(b'check-sh:' + check.read_bytes() + b'\0')
    except FileNotFoundError:
        h.update(b'check-sh:missing\0')
    try:
        scripts = json.loads((pathlib.Path(wt) / 'package.json').read_text(encoding='utf-8')).get('scripts') or {}
    except (OSError, ValueError, AttributeError):
        scripts = {}
    if not isinstance(scripts, dict): scripts = {}
    names = ['typecheck', 'type-check', 'typecheck:all', 'check-types', 'tsc', 'lint', 'test', 'test:unit', 'unit', 'test:ci']
    h.update(b'scripts:' + json.dumps({n: scripts.get(n) for n in names}, sort_keys=True, ensure_ascii=False).encode() + b'\0')
print(h.hexdigest())
PY_CONTEXT
}

# 前回 CLEAN・条件一致・前後とも未保存変更なしの場合だけ省略または delta にする。
rvd_decide_mode() {
  local wt="$1" prev="$2" verdict="${3:-}" context="${4:-}" old_context="${5:-}" tree="${6:-}" old_tree="${7:-}" head
  [[ "$verdict" == 'VERDICT: CLEAN' && -n "$context" && "$context" == "$old_context" && "$tree" == clean:* && "$old_tree" == clean:* ]] || { print -- full; return; }
  [[ -n "$prev" ]] && git -C "$wt" rev-parse -q --verify "$prev^{commit}" >/dev/null 2>&1 || { print -- full; return; }
  head="$(git -C "$wt" rev-parse HEAD)"
  if [[ "$(git -C "$wt" rev-parse "$prev^{commit}")" == "$head" ]]; then
    [[ "$tree" == "$old_tree" ]] && print -- same || print -- full
    return
  fi
  git -C "$wt" merge-base --is-ancestor "$prev" HEAD 2>/dev/null && { print -- delta; return; }
  print -- full
}

# <round> <verdict> <p0> <p1> → CLEAN | FIX | STOP_P0P1 | MERGE_WITH_FOLLOWUP
# 周回の上限（LANES_REVIEW_MAX_ROUNDS、既定 5）。上限を超えた周で CLEAN にならなければ、P0/P1 が残っていても
# ESCALATE を返す＝ランチャはそこで止まり、「直して続けるか・締めるか」を人に返す（周回が終わらなくなるのを防ぐ）。
# 周回は系列（label の末尾 -r<N> を外した名前）ごとに数える。label の頭を変えると数え直しになるので、同じ系列で回す
rvd_escalate() {   # <round> <verdict> <gate> → 最終の gate
  local max="${LANES_REVIEW_MAX_ROUNDS:-5}"
  if [[ "$max" == <-> ]] && (( $1 > max )) && [[ "$2" != 'VERDICT: CLEAN' ]]; then print -- ESCALATE; else print -r -- "$3"; fi
}
# 受け入れ済みの限界（対象リポの .lanes/accepted-limitations.md）。人が「直さずに受け入れる」と決めた種類の指摘を書いておくと、
# レビューの指示書に必ず入る。そこに当てはまる指摘は P0〜P2 にしない（気づいたら P3 で一言だけ）。symlink は読まない
rvd_accepted_note() {   # <worktree> → 指示書に入れる文（ファイルが無ければ空）
  local f="$1/.lanes/accepted-limitations.md"
  [[ -f "$f" && ! -L "$f" && -s "$f" ]] || return 0
  print -r -- "# 受け入れ済みの限界（人が直さずに受け入れると決めたもの）"
  print -r -- "次に当てはまる指摘は P0〜P2 にしない。当てはまるか迷ったら、当てはまる前提で P3 として一言だけ書く。ここに無い種類の指摘はいつもどおり重さを付ける。"
  print -r -- ""
  cat -- "$f"
}

rvd_gate() {
  local round="$1" v="$2" p0="$3" p1="$4"
  if (( p0 + p1 > 0 )); then (( round >= 3 )) && print -- STOP_P0P1 || print -- FIX; return; fi
  [[ "$v" == "VERDICT: CLEAN" ]] && { print -- CLEAN; return; }
  [[ "$v" == "VERDICT: NEEDS_FIX" ]] && (( round >= 3 )) && { print -- MERGE_WITH_FOLLOWUP; return; }
  print -- FIX
}

# <log> <followups.md> <round> <head> <label> : P2/P3 の行を後回し票の下書きに足す
rvd_write_followups() {
  local log="$1" out="$2" round="$3" head="$4" label="$5"
  local lines; lines="$(lanes_parse_review "$log" followups)" || return 1
  [[ -n "$lines" ]] || return 1
  { [[ -s "$out" ]] || print -- "# 後回し票の下書き（round 3 以降の P2/P3。止めずに通したもの）"
    print -- ""; print -- "## round $round（$label / head $head / $(date '+%Y-%m-%d %H:%M %Z')）"; print -r -- "$lines"; } >> "$out"
}

# 前回本文の全指摘が P2/P3 なら後回し可能。1 は対象外、2 は読み取り／保存失敗。
# 前回に重大度付き指摘が無かった場合は、後続の軽微な指摘に紛れて解除しない。
# <record> <out> <round> <head> <label> <write:0|1>
rvd_previous_followups() {
  local record="$1" out="$2" round="$3" head="$4" label="$5" write="$6" tmp level n
  local -A counts
  [[ "$(rvd_record_get "$record" blocking_previous)" != 1 ]] || return 1
  tmp="$(mktemp "${LANES_SCRATCH%/}/review-previous.XXXXXX")" || return 2
  {
    rvd_record_get "$record" report > "$tmp" || return 2
    [[ -s "$tmp" ]] || return 2
    for level in P0 P1 P2 P3; do
      n="$(lanes_parse_review "$tmp" "$level")" || return 2
      [[ "$n" == <-> ]] || return 2
      counts[$level]="$n"
    done
    (( counts[P0] + counts[P1] == 0 && counts[P2] + counts[P3] > 0 )) || return 1
    if (( write )); then rvd_write_followups "$tmp" "$out" "$round" "$head" "$label" || return 2; fi
    return 0
  } always {
    rm -f -- "$tmp"
  }
}

# <logdir> <series> <round> <head> <verdict> <gate> <label> <context> <tree> <base> <report> [未解決本文] [前回の解消確認必須:0|1]
#   [レビュー役: codex|claude|gemini]（入口の run-review.sh が、同じ系列の r2 以降を同じレビュー役で続けるのに読む。rvd_prev_reviewer）
rvd_save_state() {
  [[ "$5" == 'VERDICT: CLEAN' || "$5" == 'VERDICT: NEEDS_FIX' ]] || return 1
  local f; f="$(rvd_state_file "$1" "$2")"
  python3 -I - "$f" "$3" "$4" "$5" "$6" "$7" "${8:-}" "${9:-}" "${10:-}" "${11:-}" "${12:-}" "${13:-0}" "${14:-}" <<'PY_SAVE'
import json, os, pathlib, sys
f, rnd, head, verdict, gate, label, context, tree, base, report, pending, blocking, reviewer = sys.argv[1:]
body = pathlib.Path(report).read_text(encoding='utf-8') if report else ''
record = dict(last_round=rnd, last_head=head, last_verdict=verdict, last_gate=gate,
              last_label=label, last_context=context, last_tree=tree, last_base=base,
              last_report=(pending + '\n' if pending else '') + body,
              last_blocking_previous=blocking, last_exit=0)
# レビュー役は分かるときだけ残す（渡されない旧の呼び出しは、読む側が証跡の見出しから判別する）
if reviewer in ('codex', 'claude', 'gemini'):
    record['last_reviewer'] = reviewer
tmp = pathlib.Path(f + '.tmp.' + str(os.getpid()))
tmp.write_text(json.dumps(record, ensure_ascii=False) + '\n', encoding='utf-8')
os.replace(tmp, f)
PY_SAVE
}

# ---- 系列の前回のレビュー役（入口の run-review.sh が、r2 以降も同じ役で続けるのに使う）----
# 証跡（<label>.evidence.md）の 1 行目の見出し「## Codex|Gemini|Claude レビュー証跡（…）」から役を読む（codex / gemini / claude）。
# 読めない・見出しが違うときは何も出さない。symlink は辿らない
rvd_evidence_reviewer() {   # <evidence.md>
  local first=""
  [[ -f "$1" && ! -L "$1" ]] || return 0
  { IFS= read -r first < "$1"; } 2>/dev/null || true
  if [[ "$first" =~ '^## (Codex|Gemini|Claude) レビュー証跡' ]]; then print -r -- "${(L)match[1]}"; fi
  return 0
}
# <record>（rvd_prev_record の結果）→ その記録を残したレビュー役（codex / gemini / claude）。分からなければ何も出さない。
#   再利用の記録（.review-state）なら last_reviewer、無い旧記録は last_label の証跡の見出し。証跡の記録ならその見出し
rvd_record_reviewer() {
  local f="$1" v label
  [[ -n "$f" ]] || return 0
  if [[ "$f" == *.review-state ]]; then
    [[ -f "$f" && ! -L "$f" ]] || return 0
    v="$(rvd_state_get "$f" last_reviewer 2>/dev/null)" || v=""
    case "$v" in codex|gemini|claude) print -r -- "$v"; return 0 ;; esac
    label="$(rvd_state_get "$f" last_label 2>/dev/null)" || label=""
    [[ ! "$label" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || rvd_evidence_reviewer "${f:h}/$label.evidence.md"
    return 0
  fi
  rvd_evidence_reviewer "$f"
}
# <logdir> <series> → 前回のレビュー役（codex / gemini / claude）。分からなければ何も出さない。次の順で探す:
#   1. 再利用の記録（logs/.<系列>.review-state）の last_reviewer（無い旧記録は、その記録の last_label の証跡の見出し）
#   2. 系列の証跡（logs/<系列>-r<N>.evidence.md）のうち N が最大のものの見出し（記録が無いとき。失敗した回の証跡でもよい）
rvd_prev_reviewer() {
  local logdir="$1" series="$2" state v f n best=-1 latest=""
  state="$(rvd_state_file "$logdir" "$series")"
  v="$(rvd_record_reviewer "$state")"
  if [[ -n "$v" ]]; then print -r -- "$v"; return 0; fi
  for f in "$logdir/$series"-r<->.evidence.md(N); do
    n="${${f:t}#"$series"-r}"; n="${n%.evidence.md}"
    if [[ "$n" == <-> && ${#n} -le 6 ]] && (( n > best )); then best=$n; latest="$f"; fi
  done
  [[ -z "$latest" ]] || rvd_evidence_reviewer "$latest"
  return 0
}
# ---- 実装した道具（同じ道具でのレビューの禁止。入口の run-review.sh と run-gemini-review.sh が同じ判定を使う）----
# <logdir> [--impl-engine の値] → 0 = Gemini で実装した。--impl-engine gemini か、logs/ の .pid に Gemini の実装レーン（lane=gemini）が
# 1 つでもあれば当たり（どちらかに当たれば Gemini で実装したとみなす。--impl-engine claude でも logs/ の記録は打ち消さない。
# 迷ったら Gemini に回さない側）。レビュー・QA の .pid（lane=gemini-review など）は数えない。logs/ が symlink なら中を読まない
rvd_impl_gemini() {
  local logdir="$1" impl="${2:-}" f v
  [[ "$impl" != gemini ]] || return 0
  [[ -d "$logdir" && ! -L "$logdir" ]] || return 1
  for f in "$logdir"/*.pid(N.); do
    v="$(sed -n 's/^lane=//p' "$f" 2>/dev/null)" || v=""
    [[ "${v%%$'\n'*}" != gemini ]] || return 0
  done
  return 1
}

# 前回 NEEDS_FIX の後の周回（round 2 以降）は差分だけを見る（1 回目は全体・2 回目からは差分）。
# 前回レビューした HEAD が今の HEAD の祖先で、前後とも未保存変更が無く、比較起点（今の base == 前回の base）と
# レビュー役（今の役 == 前回の役。rvd_record_reviewer）が同じだと確かめられるときだけ delta。
# それ以外（起点変更・役の変更・役の分からない記録・旧記録・同じ HEAD・枝の作り直し・未保存変更）は full。
# 役を変えたら、新しい役は元の変更を一度も見ていないので全体を見る（前回の指摘はどちらでも引き継ぐ）。
# 指示の変更（round 3 からの後回しの方針を含む）は前回の指摘の引き継ぎで足りるので、ここでは見ない。
rvd_fix_mode() {   # <worktree> <前回の head> <今の tree> <前回の tree> <今の base> <前回の base> <今の役> <前回の役> → delta / full
  local wt="$1" prev="$2" tree="${3:-}" old_tree="${4:-}" cur_base="${5:-}" prev_base="${6:-}" cur_kind="${7:-}" prev_kind="${8:-}"
  [[ -n "$cur_kind" && "$cur_kind" == "$prev_kind" ]] || { print -- full; return; }
  [[ -n "$prev" && -n "$cur_base" && "$cur_base" == "$prev_base" && "$tree" == clean:* && "$old_tree" == clean:* ]] || { print -- full; return; }
  git -C "$wt" rev-parse -q --verify "$prev^{commit}" >/dev/null 2>&1 || { print -- full; return; }
  [[ "$(git -C "$wt" rev-parse "$prev^{commit}")" != "$(git -C "$wt" rev-parse HEAD)" ]] || { print -- full; return; }
  git -C "$wt" merge-base --is-ancestor "$prev" HEAD 2>/dev/null && { print -- delta; return; }
  print -- full
}
# 未解決の本文を渡す。重大な指摘の解消確認と、round 3 以降の軽微な指摘の保存を区別する。
rvd_unresolved_note() {
  local record="$1"
  print -- '# 前回の未解決指摘（今回のレビューで全件の解消を確認する）'
  print -- '- 各指摘について現時点のファイル・行と解消根拠を記す。未解決・確認不能なら NEEDS_FIX。'
  print -- '- 全件の解消を確認できた場合だけ、行頭からそのまま RESOLVED_PREVIOUS_FINDINGS: YES とだけ独立した行に記す（箇条書き・引用・表・コードブロック・行内コード・太字にしない）。'
  if (( ${2:-0} >= 3 )); then
    print -- '- round 3 以降: 前回の指摘が P2/P3 だけなら、必須検証の成功後にランチャが前回本文も後回し票へ保存して通す。未解決のまま全件解消を宣言しない。前回に P0/P1 がある場合、または指摘の重大度を1件も判定できない場合は、引き続き全件の解消確認が必要。'
  fi
  rvd_record_get "$record" report
}

# <wt> <prev> <round> [base] → developer_instructions に足す delta の説明
rvd_delta_note() {
  local wt="$1" prev="$2" round="$3" base_ref="${4:-origin/${LANES_BASE_BRANCH:-develop}}" base_label own=""
  if [[ "$base_ref" =~ '^[0-9a-f]{40}$' ]]; then base_label="${base_ref:0:12}"; else base_label="$base_ref"; fi
  if own="$(git -C "$wt" log --no-merges --format='- %h %s' "$prev..HEAD" --not "$base_ref" 2>/dev/null)"; then
    own="$(print -r -- "$own" | head -40)"
    [[ -n "$own" ]] || own="- （merge だけ）"
  else
    own="- （commit 一覧を取得できない。上の範囲の差分をそのまま読む）"
  fi
  cat <<EOT
# 再レビュー（round $round・delta。2 回目以降の既定）
- 前回レビューした head \`${prev:0:12}\` からの差分だけを見る（CLI の --base にこの head を渡している）。差分の外は掘り返さない。
- 比較起点（\`${base_label}\`）の取り込みで入った変更は対象外。この枝で前回から足された commit は次のとおり:
$own
- 見るのは「前回の指摘が直っているか」「直しで新しい退行が出ていないか」だけ。前回の指摘の解消の確認には差分の外のファイルを読んでよいが、新しい指摘は今回の差分の行と、その直しが直接影響する箇所だけにする（差分の外の既存のコードは掘り返さない）。
- 検証は delta テンプレートの条件に従う。typecheck / lint は全体、テストは該当条件に応じて実施し、未実施を隠さない。build はレビューでは回さない（最終 head の chk-run と CI で担保）。
- 差分が認証・決済・DB・秘密の扱い・CI 設定に触れたときだけ、範囲を広げてよい（その旨を最初に書く）。
EOT
  if (( round >= 3 )); then
    print -- "- round 3 以降: P0/P1 は停止。P2/P3 は後回し票に保存するが、必須検証が未実施・失敗・確認不能なら通さない。P2/P3 を P1 に格上げしない。"
  fi
}

# ---- 再利用の記録（logs/.<系列>.review-state）を、系列を問わず全部守る ----
# 記録は worktree の中にあり、レビューの子は書ける。今の系列の記録だけを守ると、別の系列の記録に条件の合う偽の CLEAN を
# 作られ、後でその系列のレビューが「同じ HEAD なので省略」で偽の結果を使い得る。子の前に全部の中身を覚え、子の後で
# 増えた・変わった・消えた・普通のファイルでなくなった記録があれば、子の前の状態へ戻して不合格にする。
# rvd_states_snapshot <logdir> → 覚えた中身（1 行の JSON）を出す
rvd_states_snapshot() {
  python3 -I - "$1" <<'PY_STATES'
import base64, json, os, re, stat, sys
d = sys.argv[1]; out = {}
if os.path.isdir(d) and not os.path.islink(d):
    for e in os.scandir(d):
        if re.fullmatch(r"\..+\.review-state", e.name):
            s = e.stat(follow_symlinks=False)
            if stat.S_ISREG(s.st_mode) and s.st_nlink == 1:
                with open(os.path.join(d, e.name), "rb") as f:
                    out[e.name] = base64.b64encode(f.read()).decode()
            else:
                out[e.name] = None
print(json.dumps(out, sort_keys=True))
PY_STATES
}
# rvd_states_restore <logdir>（覚えた中身は標準入力で渡す。記録が増えても引数の長さの上限に当たらない）
#   → 0 = 変わっていない / 1 = 変わっていたので戻した / 2 = 戻しきれなかった
# 戻すときは、記録の名前の物（普通のファイル・読めないファイル・フォルダ・symlink）を 1 つずつ消し、覚えた普通のファイルだけを
# 開いたフォルダの中で O_EXCL|O_NOFOLLOW で作り直す。1 つ失敗しても残りを最後まで試す。
# 戻しきれなかったときは exit 2。ランチャは rvd_mark_blocked で「使い回し禁止」の印を置く（logs/ の中と、子の作業場所の外の
# 両方）。ランチャはこの印があると、どの系列でも前回の記録を使わず（同じ HEAD の省略も差分にもしない）毎回 full でレビューする
rvd_states_restore() {
  python3 -I -c '
import base64, json, os, re, shutil, stat, sys
d = sys.argv[1]
pat = re.compile(r"\..+\.review-state")
def block(dfd):
    pass  # 印はランチャが rvd_mark_blocked で置く（logs/ の外にも置くため）
try:
    before = json.loads(sys.stdin.read())
    dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except Exception:
    sys.exit(2)
def current(name):
    try:
        s = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if not (stat.S_ISREG(s.st_mode) and s.st_nlink == 1):
            return None
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
        with os.fdopen(fd, "rb") as f:
            return base64.b64encode(f.read()).decode()
    except OSError:
        return None
try:
    names = [n for n in os.listdir(dfd) if pat.fullmatch(n)]
except OSError:
    block(dfd); sys.exit(2)
now = {n: current(n) for n in names}
if now == before and None not in now.values():
    sys.exit(0)
failed = False
for name in names:
    if name in before and before[name] is not None and now.get(name) == before[name]:
        continue
    try:
        s = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if stat.S_ISDIR(s.st_mode):
            # 子が作った同じ名前のフォルダ。中の symlink は辿らずに消す
            shutil.rmtree(os.path.join(d, name))
        else:
            os.unlink(name, dir_fd=dfd)
    except OSError:
        failed = True
for name, data in before.items():
    if data is None or (name in now and now[name] == data):
        continue
    try:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=dfd)
        with os.fdopen(fd, "wb") as f:
            f.write(base64.b64decode(data))
    except OSError:
        failed = True
if failed:
    block(dfd); sys.exit(2)
sys.exit(1)
' "$1"
}
# 「使い回し禁止」の印。logs/ の中（人が見つけやすい）と、logs/ の外（${XDG_STATE_HOME:-~/.local/state}/lanewright/reuse-blocked/
# の下に、logs/ の実パスの指紋の名前で置く）の両方に置く。子が logs/ の印を消したり、logs/ を書けなくして印を作らせなかったりしても、
# 外の印が残る。どちらか一方でもあれば使い回さない。印は人が logs/.*.review-state の中身を確かめてから、両方とも消す
# （消し方は rvd_mark_blocked が出す案内を見る）。
# 限界: Claude のレビューの子は同じ利用者の権限で Bash を使えるので、外の印も消せる。ランチャはレビューの前後で印の有無を比べ、
# 消されていたら改ざんとして不合格にし、印を置き直す（気づく守り。完全な閉じ込めではない）。Codex のレビューは読み取り専用で外へ書けない
rvd_block_files() {   # <logdir> → 印のパスを 2 行で出す（1 行目 logs/ の中、2 行目 外）
  local real key
  real="${1:A}"
  key="$(print -rn -- "$real" | shasum -a 256 | cut -c1-32)" || return 1
  print -r -- "$1/.review-reuse-blocked"
  print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/lanewright/reuse-blocked/$key"
}
rvd_reuse_blocked() {   # <logdir> → 0 = 前回の記録を使ってはいけない
  local f
  for f in "${(@f)$(rvd_block_files "$1")}"; do [[ -e "$f" || -L "$f" ]] && return 0; done
  return 1
}
rvd_mark_blocked() {   # <logdir> → 0 = logs/ の外の印は置けた（logs/ の中は置ければ置く）/ 1 = どちらも置けない
  local files inner outer ok=1
  files=("${(@f)$(rvd_block_files "$1")}"); inner="${files[1]}"; outer="${files[2]}"
  ( umask 077; mkdir -p -- "${outer:h}" && : >> "$outer" ) 2>/dev/null && [[ -f "$outer" && ! -L "$outer" ]] && ok=0
  [[ -L "$inner" ]] || ( : >> "$inner" ) 2>/dev/null || true
  print -u2 -- "印: $inner と $outer（logs/.*.review-state の中身を確かめてから両方消す）"
  return $ok
}

# ---- 必須検証の使い回し（親の chk-run.sh の記録）----
# <lanes_dir> <wt>: chk-run.sh --query で問い合わせ、結果を RVD_CHECKS_REUSE（yes / no / off）・RVD_CHECKS_HEAD・RVD_CHECKS_AT・
# RVD_CHECKS_SRC・RVD_CHECKS_REASON に入れる。LANES_REVIEW_REUSE_CHECKS=0 なら問い合わせず off。
# 指紋には環境変数も入るので、ランチャは scratch や git の通信止めの export より前に呼ぶ。
# ランチャの記録（logs/ の直下の .pid・ログ・証跡・起動ログなどのうち、ランチャが台帳 logs/.lanes-records に載せた持ち主のもの）は
# 指紋に入らない（chk-run.sh の is_lane_record）ので、detach-run.sh が先に logs/launch.log を書いていても、前のレーンの記録が
# 残っていても、記録と合う。台帳に無い名前のファイル（確認コマンドが読む logs/input.json など）は入力のまま。
# _common.sh が外した API キーなどは、親が chk-run.sh を回したときの環境に戻して渡す（chk-run.sh は何も実行しない）
rvd_checks_query() {
  local lanes_dir="$1" wt="$2" out="" rc=0 line
  typeset -g RVD_CHECKS_REUSE=no RVD_CHECKS_HEAD="" RVD_CHECKS_AT="" RVD_CHECKS_SRC="" RVD_CHECKS_FP="" RVD_CHECKS_REASON=""
  if [[ "${LANES_REVIEW_REUSE_CHECKS:-1}" != 1 ]]; then RVD_CHECKS_REUSE=off; RVD_CHECKS_REASON="LANES_REVIEW_REUSE_CHECKS=0"; return 0; fi
  [[ -f "$lanes_dir/chk-run.sh" ]] || { RVD_CHECKS_REASON="chk-run.sh が無い"; return 0; }
  if (( ${+functions[lanes_with_caller_auth_env]} )); then
    out="$(lanes_with_caller_auth_env bash "$lanes_dir/chk-run.sh" "$wt" --query 2>/dev/null)" || rc=$?
  else
    out="$(bash "$lanes_dir/chk-run.sh" "$wt" --query 2>/dev/null)" || rc=$?
  fi
  if (( rc == 0 )) && [[ "${${(f)out}[1]:-}" == reuse=yes ]]; then
    for line in "${(@f)out}"; do
      case "$line" in
        head=*) RVD_CHECKS_HEAD="${line#head=}" ;;
        recorded=*) RVD_CHECKS_AT="${line#recorded=}" ;;
        check=*) RVD_CHECKS_SRC="${line#check=}" ;;
        fp=*) RVD_CHECKS_FP="${line#fp=}" ;;
      esac
    done
    # 3 つ揃わない答えは使わない（形の崩れた答えで検証を省かない）
    if [[ "$RVD_CHECKS_HEAD" =~ '^[0-9a-f]{7,40}$' && -n "$RVD_CHECKS_AT" && -n "$RVD_CHECKS_FP" && ( "$RVD_CHECKS_SRC" == .lanes/check.sh || "$RVD_CHECKS_SRC" == LANES_CHECK_CMD ) ]]; then
      RVD_CHECKS_REUSE=yes; return 0
    fi
    RVD_CHECKS_HEAD="" RVD_CHECKS_AT="" RVD_CHECKS_SRC="" RVD_CHECKS_FP=""; RVD_CHECKS_REASON="答えの形が不正"; return 0
  fi
  RVD_CHECKS_REASON="${${out##*reason=}%%$'\n'*}"
  [[ "$out" == *reason=* ]] || RVD_CHECKS_REASON="問い合わせに失敗（exit $rc）"
  return 0
}
# 再利用条件（rvd_context）に入れる鍵。使い回すときは使った記録と、照合した入力の指紋まで入れる
# （記録の日時は分単位なので、同じ分に別の環境・依存で確認し直しても鍵が変わるようにする）
rvd_checks_key() {
  if [[ "${RVD_CHECKS_REUSE:-}" == yes ]]; then print -r -- "yes:${RVD_CHECKS_HEAD}:${RVD_CHECKS_AT}:${RVD_CHECKS_SRC}:${RVD_CHECKS_FP}"; else print -r -- none; fi
}
# 使わなかった理由（chk-run.sh --query の reason）に、人が読める一言を足す
rvd_checks_reason_hint() {
  case "${1:-}" in
    no-check) print -r -- "確認コマンドが未設定" ;;
    no-record) print -r -- "この中身の確認済みの記録が無い。先に chk-run.sh を通す（通したのに無いときは、chk-run.sh の出力の record=no の行に、記録しなかった理由が出ている）" ;;
    cache-link) print -r -- "記録のファイルがリンクになっている" ;;
    uncommitted) print -r -- "未 commit の変更か未追跡のファイルがある（logs/ が git に無視されていなければ .gitignore に足す）" ;;
    unresolvable) print -r -- "確認コマンドか依存を確実に照合できない（外を指すリンク・解決できない書き方など）" ;;
    input-changed) print -r -- "記録の後で入力が変わった（依存・環境変数・確認コマンド・ランチャの記録でない無視対象のファイル）。chk-run.sh と同じ環境から呼ぶ（起動のときだけ環境変数を足す・外すと合わない）" ;;
    state-error) print -r -- "作業ツリーの状態を読めない" ;;
  esac
  return 0
}
# 親の記録を使えないときに、レビューの子を起動せずに止めるか（LANES_REVIEW_REQUIRE_CHECKS=1 のとき）。rvd_checks_query の後に呼ぶ。
# <allow>: 1 = この起動は --allow-missing-checks 付き（記録なしで回す）。
# 0 を返したら止める（理由と直し方が RVD_CHECKS_BLOCK に入る）。1 を返したら今までどおり起動する。
# 止めるのは chk-run.sh --query の理由が no-record / uncommitted / input-changed のとき（利用者が直してから chk-run.sh を通せば
# 記録が残る・合う理由）。確認コマンドが未設定（no-check）・記録の後で照合できなくなった（unresolvable など）・問い合わせの失敗は
# 止めない（止めない側に倒す）。
# chk-run.sh が「通ったが記録しない」（record=no。確認コマンドを照合できない書き方・確認の途中で入力が変わる、など）構成は、
# 記録が 1 件も無いので no-record として止まる。chk-run.sh を通し直すだけでは直らないので、文言で record=no の理由を先に直すよう案内する。
# 経緯: 記録が無いまま起動したレビューは、読み取り専用の閉じ込めの中で必須検証を回せず、毎回「必須検証が未完了」の指摘で
# 終わっていた（直しのレーンでは直せない指摘）
rvd_checks_block() {
  local allow="${1:-0}" reason="${RVD_CHECKS_REASON:-}" hint fix
  typeset -g RVD_CHECKS_BLOCK="" RVD_CHECKS_ALLOWED=0
  [[ "${LANES_REVIEW_REQUIRE_CHECKS:-0}" == 1 ]] || return 1
  [[ "${RVD_CHECKS_REUSE:-}" == no ]] || return 1   # yes = 記録を使う / off = 問い合わせていない（LANES_REVIEW_REUSE_CHECKS=0）
  case "$reason" in
    no-record) fix="先に chk-run.sh <worktree> を通し、出力に recorded= が出たことを確かめてからやり直す（record=no と出るなら、そこに出る理由を先に直す。通し直すだけでは記録されない）" ;;
    uncommitted) fix="変更を commit してから（ログなどの置き場は .gitignore に足してから）chk-run.sh <worktree> を通し、やり直す" ;;
    input-changed) fix="chk-run.sh <worktree> を、レビューを起動するのと同じ環境から通し直してからやり直す" ;;
    *) return 1 ;;
  esac
  if [[ "$allow" == 1 ]]; then RVD_CHECKS_ALLOWED=1; return 1; fi
  hint="$(rvd_checks_reason_hint "$reason")"
  RVD_CHECKS_BLOCK="親の chk-run の記録を使えないので、レビューを起動しない（${reason}${hint:+＝$hint}）。${fix}。この起動だけ記録なしで回すなら --allow-missing-checks を付ける（LANES_REVIEW_REQUIRE_CHECKS=1）"
  return 0
}
# 証跡に出す 1 行。<skip>: 同じ head の前回の結果を使って、今回はレビューしていないとき
# 使い回さないときは「回させた」（指示した）事実だけを書く。回せたかどうかは、証跡の「必須検証の成功確認」の行が示す
rvd_checks_evidence() {
  local reason="${RVD_CHECKS_REASON:-なし}" hint
  if [[ "${RVD_CHECKS_REUSE:-}" == yes ]]; then
    print -r -- "- 必須検証: 親の chk-run の記録を使用（head ${RVD_CHECKS_HEAD}・${RVD_CHECKS_AT}・確認コマンド ${RVD_CHECKS_SRC}）。レビューの中では回していない"
    return 0
  fi
  hint="$(rvd_checks_reason_hint "$reason")"; [[ -z "$hint" ]] || reason+="＝$hint"
  if [[ "${1:-}" == skip ]]; then
    print -r -- "- 必須検証: 今回は回していない（同じ head の前回の結果を使用。親の chk-run の記録は使わない: $reason）"
  else
    [[ "${RVD_CHECKS_ALLOWED:-0}" != 1 ]] || reason+="。--allow-missing-checks で起動"
    print -r -- "- 必須検証: レビューの中で回すよう指示（親の chk-run の記録は使わない: $reason）。回せたかは「必須検証の成功確認」の行を見る"
  fi
}
# 指示書に足す必須検証のきまり。使い回すときは「回さない」、使わないときは成功行（CHECKS:）の書き方
rvd_checks_rule() {
  if [[ "${RVD_CHECKS_REUSE:-}" == yes ]]; then
    cat <<EOT
# 必須検証の使い回し（ランチャが確認済み）
- 必須検証（typecheck / lint / unit）は親が同じ中身で実施済み（chk-run の記録: head ${RVD_CHECKS_HEAD}・${RVD_CHECKS_AT}・確認コマンド ${RVD_CHECKS_SRC}）。回さないこと。
- 確かめたい点があれば、該当テスト 1 本か小さな再現だけを回す（全件・全体の typecheck / lint は回さない）。
- テンプレートの「検証 1（typecheck / lint / unit）に未実施があれば CLEAN を出さない」はこのレビューには適用しない。検証の表には「typecheck / lint / unit: 親の chk-run で実施済み（使い回し）」と書く。成功行（CHECKS:）は書かなくてよい。
- 何を確かめたことになるかは確認コマンドの中身次第（入っていない項目は確かめていない）。確認コマンドに無い検証が要ると判断したら、その旨を指摘として書く。
- 自分で回したテストが失敗したら「unit: 失敗」と書き、指摘にする（失敗の報告はランチャが不合格にする）。
EOT
  else
    print -r -- "必須検証の typecheck / lint / unit test をすべて実施し成功した場合だけ、判定の前に独立した行で CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP と記す（build を回さなかった報告は「build: 未実施（最終検証で担保）」でよい）。typecheck / lint / unit に未実施・失敗があればこの成功行を書かず、項目と理由を明記する。ただし、対象リポジトリにその仕組み自体が無い（package.json の scripts・設定ファイル・LANES_CHECK_CMD・.lanes/check.sh のどれにも無い、または指示書に「未導入」とある）項目は、成功行のその項目を NA にし（例: CHECKS: typecheck=PASS lint=NA unit=NA build=SKIP）、本文に「lint: 該当なし（未導入）＋根拠」と書く。仕組みがあるのに回していない項目は NA にせず未実施として扱う（ランチャも package.json の scripts・LANES_CHECK_CMD・.lanes/check.sh を見て、仕組みがある項目の NA は不合格にする）。"
  fi
}
