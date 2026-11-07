#!/bin/zsh -f
# Codex レビュー（codex exec review）の判定テスト。旧ログと失敗・引用・矛盾の合成例で安全側の判定を確かめる。
# 実行: zsh lanes/tests/test-codex-verdict.sh
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"; source "$LANES_DIR/_common.sh"
F="${0:A:h}/fixtures/codex-verdict"
pass=0; fail=0
check() {   # <fixture> <期待 VERDICT> [P0 P1 P2 P3 の期待件数]
  local got; got="$(lanes_codex_verdict "$F/$1")"
  local sev="" k; if (( $# > 2 )); then for k in P0 P1 P2 P3; do sev+="$(lanes_count_findings "$F/$1" $k) "; done; sev="${sev% }"; fi
  if [[ "$got" == "VERDICT: $2" && ( $# -le 2 || "$sev" == "$3" ) ]]; then
    pass=$(( pass + 1 )); print -- "ok   $1 → $got${sev:+ ($sev)}"
  else
    fail=$(( fail + 1 )); print -- "FAIL $1 → $got${sev:+ ($sev)}（期待 VERDICT: $2${3:+ ($3)}）"
  fi
}
check needs_fix-p1-form.log                            NEEDS_FIX "0 1 0 0"
check needs_fix-p2-store.log                           NEEDS_FIX "0 0 1 0"
# 自由文だけではレビューの完了を保証できない。旧 CLEAN の期待値を NONE に変更する。
check clean-ja-shuusei-ga-hitsuyou-na-mondai-nashi.log NONE      "0 0 0 0"
check clean-ja-fuguai-kakunin-dekinakatta.log          NONE
check clean-ja-mitsukarimasen-deshita.log              NONE
check clean-ja-mondai-mitsukaranakatta.log             NONE
check clean-en-did-not-find-any.log                    NONE
check clean-en-no-issues-found.log                     NONE
check clean-p3-only.log                                NONE     "0 0 0 1"
# 重大な指摘があるのに末尾 CLEAN で上書きする旧挙動を禁止する。
check explicit-clean-wins.log                          NEEDS_FIX "0 1 0 0"
check none-empty.log                                   NONE
check does-not-exist.log                               NONE
check explicit-clean.log                              CLEAN     "0 0 0 0"
check explicit-pass.log                               CLEAN
check explicit-bold-clean.log                         CLEAN
check explicit-inline-clean.log                       CLEAN
check explicit-bullet-clean.log                       CLEAN
check explicit-needs-fix.log                          NEEDS_FIX
check bare-p0-clean.log                                NEEDS_FIX "1 0 0 0"
check bare-p1-clean.log                                NEEDS_FIX "0 1 0 0"
check bold-p1-clean.log                                NEEDS_FIX "0 1 0 0"
check numbered-p1-clean.log                            NEEDS_FIX "0 1 0 0"
check bare-p2-clean.log                                NEEDS_FIX "0 0 1 0"
check p3-explicit-clean.log                            CLEAN     "0 0 0 1"
check unavailable-ja.log                               NONE
check unavailable-ja-clean.log                         NONE
check unavailable-en-clean.log                         NONE
# 「できました」など完了を示す肯定文は、実施不能の否定文として拾わない。
check available-ja-performed-clean.log                CLEAN
check available-ja-executed-clean.log                 CLEAN
check available-ja-completed-clean.log                CLEAN
check available-ja-carried-out-clean.log              CLEAN
check verdict-code-fence.log                           NONE      "0 0 0 0"
check verdict-tilde-fence.log                          NONE      "0 0 0 0"
check verdict-unclosed-fence.log                       NONE
check quoted-verdict.log                               NONE      "0 0 0 0"
check table-verdict.log                                NONE      "0 0 0 0"
check indented-verdict.log                             NONE      "0 0 0 0"
check numbered-verdict.log                             NONE
check mid-body-verdict.log                             NONE
check conflicting-verdicts.log                        NEEDS_FIX
check code-example-then-clean.log                     CLEAN     "0 0 0 0"
check partial-verdict.log                              NONE
scratch_root="${LANES_SCRATCH:-${TMPDIR:?TMPDIR が必要}}"
T="$(mktemp -d "${scratch_root%/}/codex-events.XXXXXX")"
trap 'rm -rf -- "$T"' EXIT
# 通常レビューの本文は既存実ログ由来の例を利用し、CLI の完了イベントを別に再現する。
python3 - "$LANES_DIR" "$F" "$T" <<'PY_EVENTS'
import hashlib, json, os, pathlib, subprocess, sys, time
lanes, fixtures, root = map(pathlib.Path, sys.argv[1:])
passed = 0
producer = root / "producer.py"
producer.write_text("import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text(),end='')")
def check(body, expected, *, tail=True, error=False, mutate=False):
    global passed
    log, proof, stream = root/'body.log', root/'proof.json', root/'events.jsonl'
    events = [{'type': 'thread.started', 'thread_id': 'test'}, {'type': 'turn.started'},
              {'type': 'item.completed', 'item': {'id': 'i', 'type': 'agent_message', 'text': body}}]
    if error: events.append({'type': 'turn.failed', 'error': {'message': '模擬中断'}})
    if tail: events.append({'type': 'turn.completed', 'usage': {}})
    stream.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in events))
    subprocess.run([sys.executable,str(lanes/'codex-review-output.py'),str(log),str(proof),
                    sys.executable,str(producer),str(stream)],check=True)
    if mutate: log.write_text(log.read_text()+'\n変更')
    code='LANES_DIR="$1"; source "$LANES_DIR/_common.sh"; lanes_codex_verdict "$2" "$3"'
    r=subprocess.run(['zsh','-fc',code,'_',str(lanes),str(log),str(proof)],capture_output=True,text=True,check=True)
    assert r.stdout.strip() == 'VERDICT: '+expected, (body,r.stdout,expected)
    passed += 1
for fixture in sorted(fixtures.glob('clean-*.log')):
    expected='NONE' if fixture.name=='clean-p3-only.log' else 'CLEAN'
    check(fixture.read_text(),expected)
check('No issues found.','NONE',tail=False)
check('No issues found.','NONE',error=True)
check('No issues found.','NONE',mutate=True)
# 本文に CR（\r）が入っても、完了証明のハッシュは書き手と同じバイト列で照合する。
check('No issues found.\r\n','CLEAN')
check('確認した。\r変更に問題は見つからなかった','CLEAN')
check('作業を開始します。','NONE')
check('Review was interrupted. No issues found.','NONE')
check('[P2] 残件\nレビューを完了できませんでした\nVERDICT: CLEAN','NONE')
check('[P1] 重大な残件\nReview was interrupted.','NONE')
check('[P2] 残件\n```\n途切れた出力','NONE')
# 中間イベントの本文は保存せず、受信時刻だけで監視上の生存を更新する。
repo=root/'heartbeat'; (repo/'logs').mkdir(parents=True)
subprocess.run(['git','init','-q',str(repo)],check=True)
assert os.path.realpath(subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(repo)), '一時リポの外の git に届いている: ' + str(repo)   # 本物のリポを書き換えない
subprocess.run(['git','-C',str(repo),'-c','user.name=Test User','-c','user.email=you@example.com',
                'commit','--allow-empty','-qm','test: 初期化'],check=True)
producer.write_text("import json,time\nprint(json.dumps({'type':'turn.started'}),flush=True)\n"
                    "for _ in range(15):\n print(json.dumps({'type':'item.completed','item':{'type':'command_execution','command':'非公開の模擬本文'}}),flush=True); time.sleep(.2)\n"
                    "print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'No issues found.'}}),flush=True)\n"
                    "print(json.dumps({'type':'turn.completed'}),flush=True)\n")
log, proof = repo/'logs/pulse.last.md', repo/'logs/pulse.completion.json'
p=subprocess.Popen([sys.executable,str(lanes/'codex-review-output.py'),str(log),str(proof),sys.executable,str(producer)])
try:
    start=subprocess.check_output(['ps','-o','lstart=','-p',str(p.pid)],env={**os.environ,'LC_ALL':'C','TZ':'UTC'},text=True).strip()
    (repo/'logs/pulse.pid').write_text(f'pid={p.pid}\nlstart={start}\nstarted_epoch={int(time.time())-7200}\n')
    for _ in range(50):
        if proof.exists(): break
        time.sleep(.02)
    first=proof.stat().st_mtime_ns
    time.sleep(1.3)
    assert proof.stat().st_mtime_ns > first and '非公開' not in proof.read_text() and not log.exists()
    result=subprocess.run(['zsh','-f',str(lanes/'lanes-status.sh'),str(repo),'pulse'],capture_output=True,text=True)
    assert result.returncode == 10 and result.stdout.startswith('RUNNING'), result.stdout
    p.wait(timeout=10)
    assert json.loads(proof.read_text())['completed'] is True and log.read_text()=='No issues found.'
    passed += 1
finally:
    if p.poll() is None: p.terminate(); p.wait(timeout=5)
print(f'---- 完了イベント {passed} passed, 0 failed')
PY_EVENTS
# 本文を直接与えて、解消宣言・必須検証・レビュー不能の判定を両方向で固定する。
parse_case() {   # <mode> <期待> <本文>
  local f="$T/case.md" got; print -r -- "$3" > "$f"
  if [[ "$1" == codex ]]; then got="$(lanes_extract_verdict "$f")"; else got="$(lanes_parse_review "$f" "$1")"; fi
  if [[ "$got" == "$2" ]]; then pass=$(( pass + 1 )); print -- "ok   $1 → $got"
  else fail=$(( fail + 1 )); print -- "FAIL $1 → $got（期待 $2）: ${3//$'\n'/ / }"; fi
}
nl=$'\n'; fence='```'
# 解消宣言: 独立した実際の行だけを採用し、コード例・引用・表・閉じていない領域・否定の併記は解除しない。
parse_case resolved YES "全件の解消根拠を確認${nl}RESOLVED_PREVIOUS_FINDINGS: YES${nl}VERDICT: CLEAN"
parse_case resolved NO  "書式の例:${nl}${fence}${nl}RESOLVED_PREVIOUS_FINDINGS: YES${nl}${fence}${nl}VERDICT: CLEAN"
parse_case resolved NO  "~~~${nl}RESOLVED_PREVIOUS_FINDINGS: YES${nl}~~~${nl}VERDICT: CLEAN"
parse_case resolved NO  "> RESOLVED_PREVIOUS_FINDINGS: YES${nl}VERDICT: CLEAN"
parse_case resolved NO  "    RESOLVED_PREVIOUS_FINDINGS: YES${nl}VERDICT: CLEAN"
parse_case resolved NO  "| RESOLVED_PREVIOUS_FINDINGS: YES | 例 |${nl}VERDICT: CLEAN"
parse_case resolved NO  "RESOLVED_PREVIOUS_FINDINGS: YES${nl}${fence}${nl}途切れた出力"
parse_case resolved NO  "RESOLVED_PREVIOUS_FINDINGS: YES${nl}RESOLVED_PREVIOUS_FINDINGS: NO${nl}VERDICT: CLEAN"
parse_case resolved NO  "解消宣言は RESOLVED_PREVIOUS_FINDINGS: YES と書く${nl}VERDICT: CLEAN"
parse_case resolved NO  "VERDICT: CLEAN"
# build はレビューでは回さない。build だけの未実施・省略は正直な報告として受理する。
skip_line='CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP'
pass_line='CHECKS: typecheck=PASS lint=PASS unit=PASS build=PASS'
parse_case checks COMPLETE   "$skip_line"
parse_case checks COMPLETE   "$pass_line"
parse_case checks COMPLETE   "build: 未実施（最終検証で担保）${nl}${skip_line}"
parse_case checks COMPLETE   "- build: 未実施（実施条件に当たらない）${nl}${skip_line}"
parse_case checks COMPLETE   "| build | 未実施（最終検証で担保） |${nl}${skip_line}"
parse_case checks COMPLETE   "ビルド: 省略（最終検証で担保）${nl}${skip_line}"
parse_case checks COMPLETE   "build: skipped${nl}${skip_line}"
parse_case checks INCOMPLETE "build: 失敗${nl}${skip_line}"
parse_case checks INCOMPLETE "| build | FAIL |${nl}${skip_line}"
parse_case checks INCOMPLETE "typecheck / build: 未実施${nl}${skip_line}"
parse_case checks INCOMPLETE "unit・build: 未実施${nl}${skip_line}"
parse_case checks INCOMPLETE "Could not run lint${nl}${skip_line}"
parse_case checks INCOMPLETE "CHECKS: typecheck=PASS lint=PASS unit=PASS build=FAIL"
parse_case checks INCOMPLETE "CHECKS: typecheck=PASS lint=PASS unit=SKIP build=SKIP"
parse_case checks INCOMPLETE "${skip_line}${nl}${pass_line}"
parse_case checks INCOMPLETE "${fence}${nl}${skip_line}${nl}${fence}"
parse_case checks INCOMPLETE "build: 未実施"
# 対象リポジトリにその仕組み自体が無い項目は NA（該当なし（未導入））として受理する。仕組みがあるのに未実施なら従来どおり不足。
na_line='CHECKS: typecheck=PASS lint=NA unit=NA build=SKIP'
parse_case checks COMPLETE   "$na_line"
parse_case checks COMPLETE   "lint: 該当なし（未導入。package.json に lint が無い）${nl}${na_line}"
parse_case checks COMPLETE   "| unit | 該当なし（未導入） |${nl}${na_line}"
parse_case checks INCOMPLETE "lint: 未実施${nl}${na_line}"
parse_case checks INCOMPLETE "CHECKS: typecheck=PASS lint=NA unit=SKIP build=SKIP"
parse_case checks INCOMPLETE "CHECKS: typecheck=PASS lint=NA unit=NA build=NA"
# ランチャが見た仕組みの有無（LANES_CHECKS_PRESENT）と突き合わせる。仕組みがある項目の NA・該当なしは不合格
LANES_CHECKS_PRESENT=lint parse_case checks INCOMPLETE "$na_line"
LANES_CHECKS_PRESENT=typecheck parse_case checks COMPLETE "$na_line"
LANES_CHECKS_PRESENT=all parse_case checks COMPLETE "$na_line"
LANES_CHECKS_PRESENT=all parse_case checks INCOMPLETE "CHECKS: typecheck=NA lint=NA unit=NA build=SKIP"
LANES_CHECKS_PRESENT=unit parse_case codex 'VERDICT: NEEDS_FIX' "- 単体テスト: 該当なし（未導入）${nl}VERDICT: CLEAN"
LANES_CHECKS_PRESENT=unit parse_case codex 'VERDICT: NEEDS_FIX' "| unit | 該当なし |${nl}VERDICT: CLEAN"
LANES_CHECKS_PRESENT=lint parse_case codex 'VERDICT: CLEAN' "- 単体テスト: 該当なし（未導入）${nl}VERDICT: CLEAN"
# 言い換え（未導入など）と、項目名の太字・行内コードも同じく突き合わせる
LANES_CHECKS_PRESENT=lint parse_case codex 'VERDICT: NEEDS_FIX' "- lint: 未導入${nl}VERDICT: CLEAN"
LANES_CHECKS_PRESENT=lint parse_case codex 'VERDICT: NEEDS_FIX' "| lint | 未導入 |${nl}VERDICT: CLEAN"
LANES_CHECKS_PRESENT=lint parse_case codex 'VERDICT: NEEDS_FIX' "**lint**: 該当なし（未導入）${nl}VERDICT: CLEAN"
LANES_CHECKS_PRESENT=lint parse_case codex 'VERDICT: NEEDS_FIX' "\`lint\`: 該当なし${nl}VERDICT: CLEAN"
LANES_CHECKS_PRESENT=unit parse_case codex 'VERDICT: NEEDS_FIX' "- 単体テスト: 仕組みが無い${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NEEDS_FIX' "**lint**: 未実施${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NEEDS_FIX' "- \`unit\`: 未実施${nl}VERDICT: CLEAN"
parse_case checks INCOMPLETE "**lint**: 未実施${nl}${na_line}"
parse_case checks COMPLETE   "**lint**: 該当なし（未導入）${nl}${na_line}"
# 明示 CLEAN との組み合わせ: build だけの未実施は CLEAN のまま、他の未実施・build 失敗は NEEDS_FIX。
parse_case codex 'VERDICT: CLEAN'     "build: 未実施（実施条件に当たらない）${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NEEDS_FIX' "ビルドに失敗${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NEEDS_FIX' "lint: 未実施${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: CLEAN'     "unit: 該当なし（未導入）${nl}${na_line}${nl}VERDICT: CLEAN"
# レビュー不能の判定: 直後で否定された言い回しは不能の報告ではない。否定の無い不能は従来どおり NONE。
parse_case codex 'VERDICT: CLEAN' "レビューで確認できなかった点はない${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: CLEAN' "レビューで確認できなかったことはありません${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: CLEAN' "レビューの範囲で確認できなかった箇所も無い${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NONE'  "レビューで確認できなかった${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NONE'  "レビューを完了できなかった。理由は時間切れ${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NONE'  "レビューを中断した${nl}VERDICT: CLEAN"
parse_case codex 'VERDICT: NONE'  "レビューを完了できなかった点はないとは言えない${nl}VERDICT: CLEAN"
print -- "---- $pass passed, $fail failed"
(( fail == 0 ))
