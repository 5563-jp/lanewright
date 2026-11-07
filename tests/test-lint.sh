#!/bin/zsh -f
# キットの静的検査（lint（書き方の誤りを実行せずに見つける検査））。selftest.sh が tests/test-*.sh として自動で拾う。
# 使い方: zsh tests/test-lint.sh
# 確かめること:
#   1. 全シェルの構文: シェバン（先頭行の #!）が bash のものは bash -n、zsh のもの・シェバンの無い zsh 用（_common.sh・
#      *.zsh・lanes.env・lanes.conf.example）は zsh -n。bash と zsh の両方から読み込む _git-isolate.sh は両方で見る
#   2. bash のスクリプトの shellcheck（シェルスクリプトの静的検査ツール）を -S warning（警告以上）で。
#      shellcheck が入っていなければ「未導入のため省略」と出して、この項目だけ省いて緑にする（構文の検査は必ず回す）。
#      そのときは「LANES_PARTIAL: <理由>」の行を出し、selftest.sh の表では「緑(一部)」になる（省いたことを普通の緑に紛れさせない）。
#      LANES_LINT_STRICT=1 のときは、未導入を赤にする（公開前の確認など、必ず回したいとき。selftest.sh 経由でも効く）
#   3. Python の pyflakes（未使用の import・未定義の名前などを見つける検査）。入っていなければ
#      Python の組み込みの compile で構文だけ見る（__pycache__ は作らない。このときも LANES_PARTIAL を出す）
#   4. この検査自身が、わざと入れた誤り（構文・shellcheck の警告・pyflakes の指摘）を赤にすること（一時フォルダで）
# zsh のスクリプトには shellcheck が使えない（zsh を解釈できない）ので、構文の検査と各テストの実行で担保する。
# 終了コード: 0 = 緑 / 1 = 赤（誤りの一覧を出す）
set -euo pipefail
# LANES_LINT_KIT: 検査する場所を差し替える（このテスト自身が、壊したファイルで赤になることを確かめるときに使う）
KIT="${LANES_LINT_KIT:-${0:A:h:h}}"; KIT="${KIT:A}"
count=0; red=0
typeset -a errors
errors=()
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
bad() { red=1; errors+=("$*"); }
typeset -a partial   # 道具が無くて省いた検査（最後に LANES_PARTIAL の 1 行にまとめて出す）
partial=()

# 対象のファイル（git の管理の有無に関係なく、ログ・作業用の隠しフォルダ・Python のキャッシュ・テストの入力データは除く）
typeset -a all_files bash_files zsh_files py_files
all_files=("${(@f)$(cd "$KIT" && find . \( -name .git -o -name logs -o -name .lanes -o -name __pycache__ -o -name fixtures -o -name node_modules \) -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort)}")
bash_files=(); zsh_files=(); py_files=()
for f in "${all_files[@]}"; do
  [[ -n "$f" ]] || continue
  first="$(head -1 "$KIT/$f" 2>/dev/null || true)"
  case "$first" in
    '#!'*python*) py_files+=("$f"); continue ;;
    '#!'*bash*) bash_files+=("$f"); continue ;;
    '#!'*zsh*) zsh_files+=("$f"); continue ;;
    '#!'*) continue ;;
  esac
  case "$f" in
    *.py) py_files+=("$f") ;;
    */_git-isolate.sh) bash_files+=("$f"); zsh_files+=("$f") ;;
    *.sh|*.zsh|*/lanes.env|lanes.conf.example) zsh_files+=("$f") ;;
  esac
done
(( ${#bash_files} && ${#zsh_files} && ${#py_files} )) || { print -u2 -- "FAIL: 検査対象が見つからない（bash ${#bash_files} / zsh ${#zsh_files} / Python ${#py_files}）"; exit 1; }

# 1. 構文
n_err=${#errors}
for f in "${bash_files[@]}"; do
  out="$(cd "$KIT" && bash -n "$f" 2>&1)" || bad "bash -n: $f: $out"
done
for f in "${zsh_files[@]}"; do
  out="$(cd "$KIT" && zsh -fn "$f" 2>&1)" || bad "zsh -n: $f: $out"
done
(( ${#errors} == n_err )) && pass "構文: bash ${#bash_files} 本・zsh ${#zsh_files} 本に誤りなし"

# 2. shellcheck（bash のスクリプト）
n_err=${#errors}
if command -v shellcheck >/dev/null 2>&1; then
  out="$(cd "$KIT" && shellcheck -S warning -s bash "${bash_files[@]}" 2>&1)" || bad "shellcheck -S warning:"$'\n'"$out"
  (( ${#errors} == n_err )) && pass "shellcheck -S warning: bash ${#bash_files} 本に警告なし"
elif [[ "${LANES_LINT_STRICT:-0}" == 1 ]]; then
  bad "shellcheck が未導入（LANES_LINT_STRICT=1 なので赤。brew install shellcheck で入れる）"
else
  pass "shellcheck: 未導入のため省略（brew install shellcheck で入れると回る。LANES_LINT_STRICT=1 で未導入を赤にできる）"
  partial+=("shellcheck が未導入のため bash の静的検査を省略")
fi

# 3. Python（pyflakes。無ければ組み込みの compile で構文だけ）。作業場所はキットの外にして、キットのファイルを import しない
n_err=${#errors}
abs_py=("${(@)py_files/#/$KIT/}")
if (cd / && python3 -m pyflakes --version) >/dev/null 2>&1; then
  out="$(cd / && python3 -m pyflakes "${abs_py[@]}" 2>&1)" || bad "pyflakes:"$'\n'"${out//$KIT\//}"
  (( ${#errors} == n_err )) && pass "pyflakes: Python ${#py_files} 本に指摘なし"
else
  out="$(cd / && python3 -I -c '
import sys
bad = 0
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as stream:
            compile(stream.read(), path, "exec", dont_inherit=True)
    except SyntaxError as error:
        bad = 1
        print(f"{path}:{error.lineno}: {error.msg}")
sys.exit(bad)
' "${abs_py[@]}" 2>&1)" || bad "Python の構文:"$'\n'"${out//$KIT\//}"
  (( ${#errors} == n_err )) && pass "Python の構文: ${#py_files} 本に誤りなし（pyflakes が未導入のため構文だけ。python3 -m pip install pyflakes で入れると回る）"
  partial+=("pyflakes が未導入のため Python は構文だけ")
fi

# 4. この検査自身が誤りを見逃さないこと（一時フォルダに、構文の誤り・shellcheck の警告・pyflakes の指摘を入れて赤になるか）
#    入れ子の実行では LANES_LINT_STRICT を外す（未導入の赤は上の 2. で 1 回だけ出す）
if [[ -z "${LANES_LINT_KIT:-}" ]]; then
  base="${LANES_SCRATCH:-${TMPDIR:-}}"
  [[ -n "$base" && -d "$base" ]] || { print -u2 -- "FAIL: LANES_SCRATCH か TMPDIR の既存ディレクトリが必要"; exit 1; }
  M="$(mktemp -d "${base%/}/lint.XXXXXX")"
  {
    mkdir -p "$M/ok"
    print -r -- $'#!/bin/bash\necho ok' > "$M/ok/a.sh"
    print -r -- $'#!/bin/zsh -f\nprint ok' > "$M/ok/b.sh"
    print -r -- 'print("ok")' > "$M/ok/c.py"
    rc=0; LANES_LINT_STRICT=0 LANES_LINT_KIT="$M/ok" zsh -f "${0:A}" > "$M/ok.out" 2>&1 || rc=$?
    (( rc == 0 )) || { cat "$M/ok.out" >&2; bad "誤りの無い一時フォルダで赤になった"; }
    typeset -A broken want
    broken=(bash-syntax $'#!/bin/bash\nif then' zsh-syntax $'#!/bin/zsh -f\nif [[ ; then' py-syntax 'def (')
    want=(bash-syntax 'bash -n' zsh-syntax 'zsh -n' py-syntax 'c.py')
    if command -v shellcheck >/dev/null 2>&1; then broken[shellcheck]=$'#!/bin/bash\ncd $1\necho "$undefined_var"'; want[shellcheck]='SC'; fi
    if (cd / && python3 -m pyflakes --version) >/dev/null 2>&1; then broken[pyflakes]=$'import os\nprint(undefined_name)'; want[pyflakes]='undefined'; fi
    for k in "${(@k)broken}"; do
      mkdir -p "$M/$k"; cp "$M/ok/"* "$M/$k/"
      case "$k" in
        bash-syntax|shellcheck) print -r -- "${broken[$k]}" > "$M/$k/a.sh" ;;
        zsh-syntax) print -r -- "${broken[$k]}" > "$M/$k/b.sh" ;;
        *) print -r -- "${broken[$k]}" > "$M/$k/c.py" ;;
      esac
      rc=0; LANES_LINT_STRICT=0 LANES_LINT_KIT="$M/$k" zsh -f "${0:A}" > "$M/$k.out" 2>&1 || rc=$?
      if (( rc != 1 )) || ! grep -qF -- "${want[$k]}" "$M/$k.out"; then cat "$M/$k.out" >&2; bad "わざと入れた誤り（$k）で赤にならない（rc=$rc）"; fi
    done
  }
  if (( ! red )); then
    rm -rf -- "$M"
    pass "この検査自身が、わざと入れた誤り（${(j:・:)${(@ko)broken}}）を赤にする"
  fi
fi

if (( red )); then
  print -u2 -- "FAIL: 静的検査で ${#errors} 件"
  for e in "${errors[@]}"; do print -u2 -r -- "  - $e"; done
  exit 1
fi
(( ! ${#partial} )) || print -r -- "LANES_PARTIAL: ${(j:・:)partial}"
print -r -- "PASS: $count 件"
