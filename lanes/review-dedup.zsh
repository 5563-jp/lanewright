# review-dedup.zsh — run-codex-review.sh と run-claude-review.sh から source する。同じレビューの繰り返しを省く
#  - 系列（series）: label の末尾 -r<N> を外したもの（rev-wap83-r5 → rev-wap83）。round は -r<N> から取る
#  - 前回 CLEAN・未保存変更なし・条件一致のときだけ delta または同一結果を再利用する
#  - 前回 NEEDS_FIX は指摘本文を渡して full。旧記録も full で検証し直す
#  - round 3 以降の P2/P3 は後回し票へ保存。必須検証の成功確認がある場合だけランチャが CLEAN にする
#  - 必須検証の使い回し: 親が同じ中身で chk-run.sh を通した記録があれば、レビューの中で回させない（rvd_checks_query）
# 依存なし（_common.sh を読まなくても使える。tests/test-review-dedup.sh が単体で試す）

rvd_series() { if [[ "$1" =~ '^(.+)-r([0-9]+)$' ]]; then print -- "${match[1]}"; else print -- "$1"; fi; }
rvd_label_round() { if [[ "$1" =~ '-r([0-9]+)$' ]]; then print -- "${match[1]}"; else print -- 0; fi; }
rvd_state_file() { print -- "$1/.$2.review-state"; }   # <logdir> <series>
# 本文も同じ JSON 記録に格納する。旧 key=value 形式は読み取りだけ互換にする。
rvd_state_get() {
  python3 - "$1" "$2" <<'PY_STATE'
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
  python3 - "$1" <<'PY_SNAPSHOT'
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
  python3 - "$1" <<'PY_GUARD'
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
# 必須検証の使い回しの有無と使った記録（rvd_checks_key）、レビュー役（codex / claude）も含める。
# 記録が変わった（使い回しが無くなった・親が回し直した）ら、同じ HEAD でも前回の結果を使わない。
# <root> <prompt> <base> <mode> <policy> <model> <effort> [worktree] [使い回しの鍵] [レビュー役]
rvd_context() {
  python3 - "$@" <<'PY_CONTEXT'
import hashlib, json, os, pathlib, sys
root, prompt, base, mode, policy, model, effort = sys.argv[1:8]
wt = sys.argv[8] if len(sys.argv) > 8 else ''
reuse = sys.argv[9] if len(sys.argv) > 9 else ''
kind = sys.argv[10] if len(sys.argv) > 10 else ''
h = hashlib.sha256()
for value in [base, mode, policy, model, effort, 'checks-reuse:' + reuse, 'reviewer:' + kind]: h.update(value.encode() + b'\0')
for p in [pathlib.Path(prompt), *[pathlib.Path(root) / f for f in
          ['review-dedup.zsh', 'run-codex-review.sh', 'run-claude-review.sh', '_common.sh', 'codex-review-output.py',
           'templates/claude-review-full.md', 'templates/claude-review-delta.md', 'templates/codex-review-focus.md']]]:
    h.update(p.read_bytes() + b'\0')
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
rvd_save_state() {
  [[ "$5" == 'VERDICT: CLEAN' || "$5" == 'VERDICT: NEEDS_FIX' ]] || return 1
  local f; f="$(rvd_state_file "$1" "$2")"
  python3 - "$f" "$3" "$4" "$5" "$6" "$7" "${8:-}" "${9:-}" "${10:-}" "${11:-}" "${12:-}" "${13:-0}" <<'PY_SAVE'
import json, os, pathlib, sys
f, rnd, head, verdict, gate, label, context, tree, base, report, pending, blocking = sys.argv[1:]
body = pathlib.Path(report).read_text(encoding='utf-8') if report else ''
record = dict(last_round=rnd, last_head=head, last_verdict=verdict, last_gate=gate,
              last_label=label, last_context=context, last_tree=tree, last_base=base,
              last_report=(pending + '\n' if pending else '') + body,
              last_blocking_previous=blocking, last_exit=0)
tmp = pathlib.Path(f + '.tmp.' + str(os.getpid()))
tmp.write_text(json.dumps(record, ensure_ascii=False) + '\n', encoding='utf-8')
os.replace(tmp, f)
PY_SAVE
}

# 未解決の本文を渡す。重大な指摘の解消確認と、round 3 以降の軽微な指摘の保存を区別する。
rvd_unresolved_note() {
  local record="$1"
  print -- '# 前回の未解決指摘（今回の全体レビューで全件の解消を確認する）'
  print -- '- 各指摘について現時点のファイル・行と解消根拠を記す。未解決・確認不能なら NEEDS_FIX。'
  print -- '- 全件の解消を確認できた場合だけ、行頭からそのまま RESOLVED_PREVIOUS_FINDINGS: YES とだけ独立した行に記す（箇条書き・引用・表・コードブロック・行内コード・太字にしない）。'
  if (( ${2:-0} >= 3 )); then
    print -- '- round 3 以降: 前回の指摘が P2/P3 だけなら、必須検証の成功後にランチャが前回本文も後回し票へ保存して通す。未解決のまま全件解消を宣言しない。前回に P0/P1 がある場合、または指摘の重大度を1件も判定できない場合は、引き続き全件の解消確認が必要。'
  fi
  rvd_record_get "$record" report
}

# <wt> <prev> <round> → developer_instructions に足す delta の説明
rvd_delta_note() {
  local wt="$1" prev="$2" round="$3" own
  own="$(git -C "$wt" log --no-merges --format='- %h %s' "$prev..HEAD" --not "origin/${LANES_BASE_BRANCH:-develop}" 2>/dev/null | head -40 || true)"
  cat <<EOT
# 再レビュー（round $round・delta。2 回目以降の既定）
- 前回レビューした head \`${prev:0:12}\` からの差分だけを見る（CLI の --base にこの head を渡している）。差分の外は掘り返さない。
- origin/${LANES_BASE_BRANCH:-develop} の取り込みで入った変更は対象外。この枝で前回から足された commit は次のとおり:
${own:-- （merge だけ）}
- 見るのは「前回の指摘が直っているか」「直しで新しい退行が出ていないか」だけ。
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
# ランチャの記録（logs/ の直下の .pid・ログ・証跡・起動ログなど）は指紋に入らない（chk-run.sh の LANE_RECORD_RE）ので、
# detach-run.sh が先に logs/launch.log を書いていても、前のレーンの記録が残っていても、記録と合う。
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
    no-record) print -r -- "この中身の確認済みの記録が無い。先に chk-run.sh を通す" ;;
    cache-link) print -r -- "記録のファイルがリンクになっている" ;;
    uncommitted) print -r -- "未 commit の変更か未追跡のファイルがある（logs/ が git に無視されていなければ .gitignore に足す）" ;;
    unresolvable) print -r -- "確認コマンドか依存を確実に照合できない（外を指すリンク・解決できない書き方など）" ;;
    input-changed) print -r -- "記録の後で入力が変わった（依存・環境変数・確認コマンド・ランチャの記録でない無視対象のファイル）。chk-run.sh と同じ環境から呼ぶ（起動のときだけ環境変数を足す・外すと合わない）" ;;
    state-error) print -r -- "作業ツリーの状態を読めない" ;;
  esac
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
