#!/bin/zsh -f
# detach-run.sh の「補助」（切り離しに使う python3）の選び方と動かし方のテスト。
# 経緯: 起動する対象のリポジトリの仮想環境を有効にしたシェルから detach-run.sh を呼ぶと、PATH の先頭の python3・mkdir や、
#       作業場所・PYTHONPATH にある同じ名前のファイルが、呼び出し元の環境変数を持ったままランチャの中で動いた。
#       PATH から選んで「対象の中のものを除く」直し方は、場所の推量・パスの比較・確かめる起動が要り、場合分けが尽きなかった。
#       補助は、スクリプトに書いた 2 つの絶対パスだけから選び、環境変数を 1 つも渡さずに -I -S で動かす形にした。
# 確かめること（かっこの中は、外すとその項目が赤になる安全策）:
#   1. 対象の模型（PATH は印を書く偽物だけ・Python と zsh が見る環境変数は対象の中・作業場所と PYTHONPATH に偽モジュール）で、
#      作業場所 4 通り × 起動ログ 2 通りとも、印が 1 つも書かれずに起動できる。-f なしで .zshenv がフックを置いていても同じ
#      （決め打ちの絶対パス / -I / 補助の側の mkdir / ここ文書をやめたこと / cd しないこと）
#   2. 補助に環境変数が渡らない。旗は -I -S -（exec -c の -c / -I / -S）
#   3. 呼び出し元の環境変数を受け取れなければ、起動せずに exit 2（補助の環境へ倒す逃げ道を消したこと）
#   4. 補助は決め打ちの 2 つの場所だけから、前から順に選ぶ。どちらも使えなければ exit 2 で、PATH の python3 は動かない
#      （PATH へ倒さないこと / 2 段目 / 順番）
#   5. 起動したコマンドの環境変数は、直に起動したときと同じ。作業場所・umask・無視にしたシグナル・引数のバイト列はそのまま、
#      標準入力は /dev/null、3 番以降の fd は無い、新しいセッションの頭。補助の入口が環境変数を書き換えても同じ
#      （( ) で包まないこと / fd 3 のデータだけを子の環境にすること）
#   6. 終了コードと文言（空 1・不足 2・無いコマンド 2・フォルダを作れない 1・起動ログがフォルダ 2・成功 0）。
#      引数とパスを出さない（mkdir の try / 固定の文言）。文言を UTF-8 のバイト列で直に書くこと自体は、ここでは見分けられない
#      （3.7 以降の python3 は、ロケールが C でも print が同じバイト列を出す）。
#      起動ログの末尾が /. のときは、手前のファイルを起動ログにせずに止まる（作るフォルダを、書かれたままの引数から求めること）。
#      標準エラーを閉じていても、終了コードは同じ（文言を書けなくても止めないこと）
#   7. 端の入力（消した作業場所・相対パスや - 始まりや空白と = と日本語を含む起動ログ・末尾が / や途中に // のある起動ログ・
#      PATH が無い場所だけ・TMPPREFIX が書けない場所・名前だけのコマンド）でも起動できる
#      （補助の前に外部コマンドを呼ばないこと / コマンドの名前の解決を足さないこと）
#   8. 書き方の決まり（静的）: 補助へ乗り換える行までのシェルの部分が、許した命令の並びそのもの（1 行でも増えた・変わったら赤）。
#      候補はちょうど 2 つ。補助の本文に一重引用符が無く、読み込むのは決まった標準ライブラリだけで、Python として読める
#   5〜7 は、呼び出し元のロケールなしと UTF-8 の 2 通りで回す。
# 使い方: test-detach-run-helper.sh [<detach-run.sh>]
#   引数を省くと、キットの lanes/detach-run.sh を確かめる。引数は、安全策を外した写しや直す前の版で赤になることを確かめるときに渡す。
# 決まり:
#   - detach-run.sh は、空の環境（env -i）と作り物の変数だけで回す。本物の環境変数は渡さない。値は出力に出さない（名前だけ）。
#   - 写し（候補の絶対パスを置き換えたスクリプト）を使う項目は、置き換えが効いていることを先に確かめる。
#   - 利用者の設定は読まない。作業ツリーの目印は空の .git フォルダ（git は呼ばない）。全データを一時領域に置き、外へ通信しない。
#   - 結果は、一時領域の場所（別の作業ツリーの中かどうか・名前に改行や空白や = や [ があるかどうか）に依らない。
#     作業場所は 16 進で、環境変数の一覧は NUL 区切りで比べる（改行で分けない）。
#   - 検査対象が返した番号のプロセスを止めない（時間切れは失敗を報告するだけ。誤った番号・使い回された番号かもしれないため）。
# 台帳・FIFO やリンクの起動ログ・記録の使い回しは test-review-reuse-launch.sh、引数を転記しないことは test-common-process.sh が見る。
set -euo pipefail
setopt extended_glob
LANES_DIR="${0:A:h:h}"
case $# in
  0) DETACH="$LANES_DIR/detach-run.sh" ;;
  1) DETACH="${1:A}" ;;
  *) print -u2 -- "使い方: test-detach-run-helper.sh [<detach-run.sh>]"; exit 2 ;;
esac
[[ -f "$DETACH" ]] || { print -u2 -- "確かめる detach-run.sh が無い: $DETACH"; exit 2; }
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-detach-helper.XXXXXX")"; T="${T:A}"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
H="$T/home"; mkdir -p "$H"
export HOME="$H" XDG_CONFIG_HOME="$H/.config" LANES_CONF="$T/no-such.conf"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }

# 補助の候補（detach-run.sh に書いてある 2 つ）。包みが最後に渡す「本物」は、同じ決め方で選ぶ（PATH からは探さない）
C1=/Library/Developer/CommandLineTools/usr/bin/python3
C2=/usr/bin/python3
if [[ -f "$C1" && -x "$C1" ]]; then REAL="$C1"; elif [[ -f "$C2" && -x "$C2" ]]; then REAL="$C2"
else fail "決め打ちの 2 つの場所に python3 が無い（Mac は xcode-select --install。detach-run.sh はこの環境では起動できない）"; fi
SRC="$(<"$DETACH")"
MARKS="$T/marks"      # 動いてはいけないものが動いたら、ここに 1 行ずつ足す（名前と、目印の変数が見えたかどうかだけ。値は書かない）
MSG1="ERROR: 切り離しに使う python3 が決まった場所（$C1・$C2）に無いので起動しない。PATH の python3 は使わない（Mac は xcode-select --install、Linux は OS の python3 を入れる）"
MSG2='ERROR: 起動ログのフォルダを作れないので起動しない。書けるフォルダの下のパスを指定する'
MSG3='ERROR: 呼び出し元の環境変数を受け取れないので起動しない'
MSG_OPEN='ERROR: 起動ログを開けない、または起動ログに使えない種類（symlink・ハードリンク・FIFO など）なので起動しない。普通のファイルのパスを指定する'
MSG_SPAWN='ERROR: 分離起動に失敗（引数・例外本文は非表示）'
HEADER=$'\n=== detach-run ==='; HEADER_NL="$HEADER"$'\n'
print -r -- '呼び出し元の標準入力' > "$T/stdin.txt"
# どの起動にも渡す作り物の変数（HOME・LOGNAME は、渡さないと zsh が本物の値を入れるので必ず渡す）
base_env=(HOME="$H" LOGNAME=fake-user FAKE_SECRET_MARK=fake-secret-value)

# スクリプトを、空の環境（env -i）と作り物の変数だけで回す: run <スクリプト> <作業場所> [名前=値 ...] -- [引数...]
#   結果: rc（終了コード）・$T/out（標準出力）・$T/err（標準エラー）
#   run_pre: 起動の直前に、呼び出し元の側でやること（umask・無視するシグナル・開いておく fd など）
#   run_zsh: 起動に使う zsh（-f なしの場面だけ差し替える）
run_pre=':'; run_zsh=(/bin/zsh -f)
run() {
  local script="$1" dir="$2"; shift 2
  local -a vars; vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
  shift
  rc=0
  ( cd "$dir" && eval "$run_pre" && exec /usr/bin/env -i "${base_env[@]}" "${vars[@]}" "${run_zsh[@]}" "$script" "$@" ) \
    > "$T/out" 2> "$T/err" < "$T/stdin.txt" || rc=$?
}
# 直前の run が起動できたこと（exit 0・標準出力は pid の 1 行だけ）を確かめ、起動したコマンドが終わるまで待つ: launched <説明>
# kill -0 は、その番号のプロセスが居るかどうかを見るだけ（何も止めない）。時間切れは失敗を報告するだけにする
# （起動するのは短く終わるコマンドだけ。番号は検査対象が返したものなので、それを根拠に止めない）
launched() {
  local n=0
  (( rc == 0 )) || { cat "$T/err" >&2; fail "$1: 起動できない（rc=$rc）"; }
  pid="$(<"$T/out")"
  [[ "$pid" == <1-> && "$(wc -l < "$T/out" | tr -d ' ')" == 1 ]] || fail "$1: 標準出力が pid の 1 行でない"
  while kill -0 "$pid" 2>/dev/null; do
    n=$(( n + 1 ))
    (( n <= 500 )) || fail "$1: 起動したコマンドが 10 秒で終わらない（番号 $pid のプロセスが居る。止めていない）"
    sleep 0.02
  done
}
# 直前の run が、起動せずに止まったこと: stopped <説明> <終了コード> <標準エラーの全文> <起動していたら出来るファイル>
stopped() {
  [[ "$rc" == "$2" ]] || { cat "$T/err" >&2; fail "$1: 終了コードが $2 でない（rc=$rc）"; }
  [[ "$(<"$T/err")" == "$3" ]] || { cat "$T/err" >&2; fail "$1: 標準エラーが決まった文言と違う"; }
  [[ ! -s "$T/out" ]] || fail "$1: 止まったのに標準出力がある（pid を返している）"
  [[ ! -e "$4" ]] || fail "$1: 止まったのにコマンドが起動した"
}
# 印が 1 つも無いこと（偽の実行ファイル・フックの印と、偽モジュールが読まれた印）: no_marks <説明>
no_marks() {
  local -a ran; ran=("$T"/**/*.ran(N))
  [[ ! -s "$MARKS" ]] || fail "$1: 動いてはいけないものが、ランチャの中で動いた: $(LC_ALL=C sort -u "$MARKS" | tr '\n' ' ')"
  (( ! ${#ran} )) || fail "$1: 偽モジュールが読まれた: ${(j: :)${(@)ran:t:r}}"
}
# 動いたら印を書く偽の実行ファイル: mkfake <パス>
mkfake() {
  mkdir -p "${1:h}"
  print -r -- "#!/bin/sh"$'\n'"echo \"${1:t} 目印の変数=\${FAKE_SECRET_MARK:+見えた}\" >> ${(qq)MARKS}" > "$1"
  chmod +x "$1"
}
# 包み（候補の置き換え先）。sh の行を実行してから、本物の python3 へ渡す: mkwrap <パス> <sh の行>
mkwrap() {
  mkdir -p "${1:h}"
  print -r -- "#!/bin/sh"$'\n'"$2"$'\n'"exec ${(qq)REAL} \"\$@\"" > "$1"
  chmod +x "$1"
}
# 写し: 候補を選ぶ 2 行の絶対パスを置き換えたスクリプトを作る: mkcopy <名前> <1 番目の置き換え先> <2 番目の置き換え先> → REPLY
# 置き換えるのは選ぶ行だけ（文言の中の場所の表記は元のまま。置き換え先の名前に改行や空白があっても、文言は変わらない）。
# 置き換えが効いていること（選ぶ行に元の候補が残っていない・置き換え先が入っている）を先に確かめる
mkcopy() {
  local body="$SRC" pick1="set -- $C1 " pick2="set -- $C2 "
  body="${body//$pick1/set -- ${(q)2} }"; body="${body//$pick2/set -- ${(q)3} }"
  [[ "$body" != *"$pick1"* && "$body" != *"$pick2"* && "$body" == *"set -- ${(q)2} "* && "$body" == *"set -- ${(q)3} "* ]] \
    || fail "写しを作れない（候補を選ぶ行が決まった形でない・置き換えが効いていない）: $1"
  REPLY="$T/$1.sh"; print -r -- "$body" > "$REPLY"
}

# ---- 1. 対象の模型で、印が 1 つも書かれない ----
W="$T/target"      # 起動する対象のリポジトリの模型（仮想環境 .venv 付き）
mkdir -p "$W/.git" "$W/src" "$W/pylib" "$W/zdot" "$T/outside" "$T/out-logs"
for f in python3 python mkdir env sh bash zsh cat rm; do mkfake "$W/.venv/bin/$f"; done
# 補助の本文が読み込む名前の偽モジュール（読まれたら、自分の隣に <名前>.py.ran を作る）。作業場所と PYTHONPATH に置く
for d in "$W" "$W/src" "$T/outside" "$W/pylib"; do
  for m in fcntl os stat sys subprocess pathlib sitecustomize startup; do
    print -r -- 'open(__file__ + ".ran", "w").close()' > "$d/$m.py"
  done
done
print -r -- "chpwd() { print -r -- 'chpwd のフック' >> ${(qq)MARKS} }" > "$W/zdot/.zshenv"
target_env=(PATH="$W/.venv/bin" VIRTUAL_ENV="$W/.venv" PYTHONPATH="$W/pylib" PYTHONHOME="$W/.venv" PYTHONSTARTUP="$W/pylib/startup.py"
  __PYVENV_LAUNCHER__="$W/.venv/bin/python3" DEVELOPER_DIR="$W/dev" TMPPREFIX="$W/no-such-dir/zsh" HOME="$W")
# 用意の確認: 偽物は名前で呼べば動く・偽モジュールは -I なしなら読まれる・フックは cd で動く（どれも印が付く）
( cd "$W" && /usr/bin/env -i PATH="$W/.venv/bin" /bin/zsh -f -c 'python3; mkdir -p x' )
( cd "$W" && /usr/bin/env -i "$REAL" -B -S -c 'import pathlib' ) > /dev/null 2>&1 || true
( cd "$W" && /usr/bin/env -i HOME="$H" ZDOTDIR="$W/zdot" /bin/zsh -c 'cd /' )
[[ -f "$MARKS" && "$(grep -c '' "$MARKS")" == 3 && -e "$W/pathlib.py.ran" ]] || fail "印を書く偽物・偽モジュール・フックが効いていない（用意が誤り）"
rm -f -- "$MARKS" "$W/pathlib.py.ran"
n=0
for dir in "$W" "$W/src" "$T/outside" /; do
  for log in "$W/logs/launch.log" "$T/out-logs/1.log"; do
    n=$(( n + 1 ))
    run "$DETACH" "$dir" "${target_env[@]}" -- "$log" /usr/bin/touch "$T/started-1-$n"
    no_marks "作業場所 $dir・起動ログ $log"
    launched "作業場所 $dir・起動ログ $log"
    [[ -f "$T/started-1-$n" && -f "$log" ]] || fail "作業場所 $dir・起動ログ $log: コマンドが動いていない・起動ログが無い"
  done
done
run_zsh=(/bin/zsh)
run "$DETACH" "$W/src" "${target_env[@]}" ZDOTDIR="$W/zdot" -- "$W/logs/launch.log" /usr/bin/touch "$T/started-1-zshenv"
run_zsh=(/bin/zsh -f)
no_marks "-f なし・.zshenv のフック"; launched "-f なし・.zshenv のフック"
[[ -f "$T/started-1-zshenv" ]] || fail "-f なし・.zshenv のフック: コマンドが動いていない"
pass "対象の仮想環境を有効にした形（PATH は偽物だけ・環境変数は対象の中・偽モジュール）でも、対象のものはランチャの中で動かずに起動できる（作業場所 4 通り × 起動ログ 2 通り・-f なし）"

# ---- 2. 補助に環境変数が渡らない。旗は -I -S - ----
mkwrap "$T/w2/python3" "/usr/bin/env -0 > ${(qq)T}/w2.env; printf '%s\\n' \"\$1\" \"\$2\" \"\$3\" > ${(qq)T}/w2.args"
mkfake "$T/w2/second"
mkcopy copy2 "$T/w2/python3" "$T/w2/second"
# 基準: 空の環境で sh のスクリプトを動かしたときに見える名前（sh 自身が足すもの。機械ごとの一覧は持たない）。
# env には /bin/sh を渡す（スクリプトのパスを直に渡すと、一時領域のパスに = があるとき変数の代入と読まれる）。
# 一覧は NUL 区切りで取る（PWD の値に改行があっても、その続きを名前と取り違えない）
print -r -- $'#!/bin/sh\n/usr/bin/env -0' > "$T/w2/baseline"
/usr/bin/env -i /bin/sh "$T/w2/baseline" > "$T/w2.base"
# NUL 区切りの環境の一覧から、名前だけを並べて取る: env_names <ファイル> → reply
env_names() { reply=("${(@ps:\0:)$(<"$1")}"); reply=("${(@)reply:#}"); reply=("${(@o)reply%%\=*}") }
run "$REPLY" "$W" "${target_env[@]}" -- "$T/out-logs/2.log" /usr/bin/touch "$T/started-2"
launched "環境を記録する包み"; no_marks "環境を記録する包み"
env_names "$T/w2.base"; want=("${reply[@]}")
env_names "$T/w2.env"; got=("${reply[@]}")
(( ${#want} )) && [[ "${(pj:\0:)want}" == "${(pj:\0:)got}" ]] \
  || fail "補助に環境変数が渡っている（sh 自身が足す名前: ${(j: :)want} / 補助から見えた名前: ${(j: :)got}）"
(( ! ${got[(Ie)FAKE_SECRET_MARK]} )) || fail "補助から目印の変数が見える"
[[ "$(<"$T/w2.args")" == $'-I\n-S\n-' ]] || fail "補助の旗が -I -S - でない"
pass "補助には環境変数が 1 つも渡らない（見えるのは sh 自身が足す名前だけ）。旗は -I -S -"

# ---- 3. 呼び出し元の環境変数を受け取れなければ、起動しない ----
print -rn -- $'FAKE_A=1\0' > "$T/noterm.bin"      # 終わりの印（NUL 2 つ）の無いデータ
mkwrap "$T/w3/closed" 'exec 3<&-'
mkwrap "$T/w3/noterm" "exec 3< ${(qq)T}/noterm.bin"
for w in closed noterm; do
  mkcopy "copy3-$w" "$T/w3/$w" "$T/w2/second"
  run "$REPLY" "$W" -- "$T/out-logs/3-$w.log" /usr/bin/touch "$T/started-3-$w"
  stopped "fd 3 が $w" 2 "$MSG3" "$T/started-3-$w"
done
no_marks "fd 3 を受け取れない包み"
pass "呼び出し元の環境変数を受け取れない（fd 3 が閉じている・終わりの印が無い）ときは、空の環境で起動せずに exit 2 で止まる"

# ---- 4. 補助は決め打ちの 2 つの場所だけから、前から順に選ぶ ----
mkfake "$T/w4/path/python3"; mkfake "$T/w4/fake-second"
mkdir -p "$T/w4/isdir"; print -r -- '#!/bin/sh' > "$T/w4/noexec"
mkwrap "$T/w4/first" "echo first >> ${(qq)T}/w4.used"; mkwrap "$T/w4/second" "echo second >> ${(qq)T}/w4.used"
# (a) どちらも使えない（無い / フォルダと、実行できないファイル）→ exit 2。PATH の先頭の偽 python3 は動かない
for a b in "$T/w4/none1" "$T/w4/none2" "$T/w4/isdir" "$T/w4/noexec"; do
  mkcopy copy4a "$a" "$b"
  run "$REPLY" "$W" PATH="$T/w4/path" -- "$T/out-logs/4a.log" /usr/bin/touch "$T/started-4a"
  no_marks "候補がどちらも使えない"
  stopped "候補がどちらも使えない" 2 "$MSG1" "$T/started-4a"
done
# (b) 1 番目が無い → 2 番目で起動する
mkcopy copy4b "$T/w4/none1" "$T/w4/second"
run "$REPLY" "$W" PATH="$T/w4/path" -- "$T/out-logs/4b.log" /usr/bin/touch "$T/started-4b"
launched "1 番目の候補が無い"; no_marks "1 番目の候補が無い"
[[ -f "$T/started-4b" && "$(<"$T/w4.used")" == second ]] || fail "1 番目の候補が無いとき、2 番目で起動していない"
# (c) 1 番目がある → 2 番目（偽物）は動かない
rm -f -- "$T/w4.used"
mkcopy copy4c "$T/w4/first" "$T/w4/fake-second"
run "$REPLY" "$W" PATH="$T/w4/path" -- "$T/out-logs/4c.log" /usr/bin/touch "$T/started-4c"
launched "1 番目の候補がある"; no_marks "1 番目の候補がある"
[[ -f "$T/started-4c" && "$(<"$T/w4.used")" == first ]] || fail "1 番目の候補があるのに、それで起動していない"
pass "補助は決め打ちの 2 つの場所だけから前から順に選ぶ（どちらも使えなければ exit 2。PATH の python3 へは倒さない）"

# ---- 5. 起動したコマンドは、直に起動したときと変わらない ----
print -r -- $'#!/bin/zsh -f\n"$@"\nexit $?' > "$T/direct.zsh"      # 直の起動（基準）: 同じ深さの zsh からそのまま起動する
cat > "$T/probe.py" <<'EOF_PROBE'
import os, signal, sys
def same(a, b):
    return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)
fds = []
for n in range(3, 64):
    try:
        os.fstat(n)
        fds.append(str(n))
    except OSError:
        pass
mask = os.umask(0)
out = [
    b"cwd " + os.fsencode(os.getcwd()).hex().encode(),
    b"umask %o" % mask,
    b"stdin " + (b"devnull" if same(os.fstat(0), os.stat("/dev/null")) else b"other"),
    b"fds " + (",".join(fds) or "-").encode(),
    b"session " + (b"leader" if os.getpid() == os.getsid(0) == os.getpgrp() else b"member"),
    b"hup " + (b"ignored" if signal.getsignal(signal.SIGHUP) == signal.SIG_IGN else b"default"),
    b"argv " + " ".join(os.fsencode(a).hex() for a in sys.argv[1:]).encode(),
]
os.write(1, b"\n".join(out) + b"\n")
EOF_PROBE
# 補助の入口が環境変数を書き換える形（Xcode の /usr/bin/python3・pyenv の shims と同じ）の包み
mkwrap "$T/w5/python3" 'FAKE_WRAP_ADDED=1; PATH=/fake/wrap/bin; MANPATH="/fake/wrap/man:${MANPATH-}"; export FAKE_WRAP_ADDED PATH MANPATH'
mkcopy copy5 "$T/w5/python3" "$T/w2/second"; copy5="$REPLY"
mkdir -p "$T/cwd5"
# 作業場所は 16 進で比べる（一時領域の名前に改行があっても、行の区切りと取り違えない）
cwd_hex="$(print -rn -- "$T/cwd5" | od -An -v -tx1 | tr -d ' \n')"
# そのまま渡りにくい形の変数も置く: スクリプトの中の名前と同じになりうるもの・空の値・改行と = と日本語・パイプの容量を超える長さ・
# zsh が変数にできない名前（直に起動しても渡らない）
t5_env=(PATH=/usr/bin:/bin k=呼び出し元の値 log=呼び出し元の値 FAKE_EMPTY= FAKE_TEXT=$'1 行目\n2 行目 = 日本語'
  FAKE_BIG="${(l:100000::x:):-}" FAKE.DOT=1)
argv_hex='e697a5e69cace8aa9e 61ff62 737020616365'      # 日本語・UTF-8 でないバイトを含む引数・空白を含む引数
run_pre='umask 027; trap "" HUP; exec 5</dev/null 9</dev/null'
for loc in '' LC_ALL=en_US.UTF-8; do
  # 用意の確認: 直に起動すると、呼び出し元が開いていた fd 5・9（このテストを回す側が開いていた fd も見えうる）・無視にした HUP・
  # umask が見え、標準入力は呼び出し元のまま
  run "$T/direct.zsh" "$T/cwd5" "${t5_env[@]}" $loc -- "$REAL" -I -S "$T/probe.py"
  ctl=("${(@f)$(<"$T/out")}")
  [[ "$rc" == 0 && "${ctl[1]}" == "cwd $cwd_hex" && "${ctl[2]}" == 'umask 27' && "${ctl[3]}" == 'stdin other'
      && ",${ctl[4]#fds }," == *,5,* && ",${ctl[4]#fds }," == *,9,* && "${ctl[6]}" == 'hup ignored' ]] \
    || { cat "$T/out" "$T/err" >&2; fail "直の起動で、呼び出し元の fd・umask・シグナルが見えない（用意が誤り。ロケール ${loc:-なし}）"; }
  run "$T/direct.zsh" "$T/cwd5" "${t5_env[@]}" $loc -- /usr/bin/env -0
  # NUL で分けてから並べる（分けると並べるを 1 つの式に重ねると、並び方が変わる）。
  # zsh が起動するコマンドごとに付ける _ は除く（切り離しでは付かない。直す前も同じ）
  direct=("${(@ps:\0:)$(<"$T/out")}"); direct=("${(@o)direct:#_=*}")
  (( rc == 0 && ${direct[(I)FAKE_TEXT=*]} && ${direct[(I)k=*]} && ${direct[(I)FAKE_EMPTY=]} )) || fail "直の起動の環境変数を取れない（用意が誤り）"
  for script in "$DETACH" "$copy5"; do
    what="${script:t}・ロケール ${loc:-なし}"
    rm -f -- "$T/5.log" "$T/5p.log"
    run "$script" "$T/cwd5" "${t5_env[@]}" $loc -- "$T/5.log" /usr/bin/env -0
    launched "$what"
    got="$(<"$T/5.log")"
    [[ "$got" == "$HEADER_NL"* ]] || fail "$what: 起動ログが見出しで始まっていない"
    detached=("${(@ps:\0:)${got#$HEADER_NL}}"); detached=("${(@o)detached}")
    [[ "${(pj:\0:)detached}" == "${(pj:\0:)direct}" ]] \
      || fail "$what: 起動したコマンドの環境変数が、直に起動したときと違う（名前だけ出す。直: ${(j: :)${(@)direct%%\=*}} / 切り離し: ${(j: :)${(@)detached%%\=*}}）"
    run "$script" "$T/cwd5" "${t5_env[@]}" $loc -- "$T/5p.log" "$REAL" -I -S "$T/probe.py" 日本語 $'a\xffb' 'sp ace'
    launched "$what"
    [[ "$(<"$T/5p.log")" == "${HEADER_NL}cwd $cwd_hex"$'\numask 27\nstdin devnull\nfds -\nsession leader\nhup ignored\nargv '"$argv_hex" ]] \
      || { cat "$T/5p.log" >&2; fail "$what: 作業場所・umask・標準入力・fd・セッション・無視にした HUP・引数のバイト列のどれかが違う"; }
  done
done
run_pre=':'
pass "起動したコマンドの環境変数は直に起動したときと同じ。作業場所・umask・無視にした HUP・引数のバイト列はそのまま、標準入力は /dev/null、3 番以降の fd は無く、新しいセッションの頭（補助の入口が環境変数を書き換えても同じ）"

# ---- 6. 終了コードと文言 ----
print -r -- 'ファイル' > "$T/plain-file"
mkcopy copy6 "$T/w3/closed" "$T/w2/second"; copy6="$REPLY"      # 呼び出し元の環境変数を受け取れない写し（3 と同じ）
for loc in '' LC_ALL=en_US.UTF-8; do
  what="ロケール ${loc:-なし}"
  run "$DETACH" "$W" $loc --
  [[ "$rc" == 1 && ! -s "$T/out" && "$(<"$T/err")" == *'1: launch.log' ]] || fail "$what: 引数なしが exit 1 でない（rc=$rc）"
  run "$DETACH" "$W" $loc -- '' /usr/bin/touch "$T/started-6"
  [[ "$rc" == 1 && ! -s "$T/out" && ! -e "$T/started-6" ]] || fail "$what: 起動ログが空の指定が exit 1 でない（rc=$rc）"
  run "$DETACH" "$W" $loc -- "$T/out-logs/6.log"
  stopped "$what・コマンドなし" 2 'usage: detach-run.sh <launch.log> <cmd> [args...]' "$T/started-6"
  rm -f -- "$T/out-logs/6.log"
  run "$DETACH" "$W" $loc -- "$T/out-logs/6.log" "$T/no-such-command" FAKE-ARG-MARK
  stopped "$what・無いコマンド" 2 "$MSG_SPAWN" "$T/started-6"
  [[ "$(<"$T/out-logs/6.log")" == "$HEADER" ]] || fail "$what・無いコマンド: 起動ログに見出しのほかのもの（引数・パス・例外の本文）が出ている"
  run "$DETACH" "$W" $loc -- "$T/plain-file/sub/6.log" /usr/bin/touch "$T/started-6"
  stopped "$what・フォルダを作れない" 1 "$MSG2" "$T/started-6"
  run "$DETACH" "$W" $loc -- "$T/out-logs" /usr/bin/touch "$T/started-6"
  stopped "$what・起動ログがフォルダ" 2 "$MSG_OPEN" "$T/started-6"
  # 起動ログの末尾が /. のとき、手前のもの（/. を除いたパス）を起動ログにして起動しない。作るフォルダは /. の手前そのものなので、
  # 手前が普通のファイル・デバイスなら「フォルダを作れない」、手前がフォルダになる（無ければ作る）なら「起動ログがフォルダ」で止まる
  rm -rf -- "$T/dot6"; mkdir -p "$T/dot6/dir"
  for log in /dev/null/. "$T/plain-file/." "$T/plain-file/./." "$T/plain-file/.//"; do
    run "$DETACH" "$W" $loc -- "$log" /usr/bin/touch "$T/started-6"
    stopped "$what・起動ログ $log" 1 "$MSG2" "$T/started-6"
  done
  [[ "$(<"$T/plain-file")" == 'ファイル' ]] || fail "$what: 末尾が /. の起動ログで、手前の普通のファイルへ書いている"
  for log in "$T/dot6/dir/x.log/." "$T/dot6/dir/." "$T/dot6/new/."; do
    run "$DETACH" "$W" $loc -- "$log" /usr/bin/touch "$T/started-6"
    stopped "$what・起動ログ $log" 2 "$MSG_OPEN" "$T/started-6"
  done
  # 標準エラーを閉じていても（文言を書けなくても）、終了コードは同じ。標準入力は、開いた場合と閉じた場合。
  # 標準エラーの記録（$T/err）が空であることは、閉じる用意が効いていることの確認を兼ねる
  for run_pre in 'exec 2>&-' 'exec 2>&- <&-'; do
    shut="$what・${run_pre#exec }"
    rm -f -- "$T/out-logs/6.log"
    run "$DETACH" "$W" $loc -- "$T/out-logs/6.log" "$T/no-such-command" FAKE-ARG-MARK
    stopped "$shut・無いコマンド" 2 '' "$T/started-6"
    [[ "$(<"$T/out-logs/6.log")" == "$HEADER" ]] || fail "$shut・無いコマンド: 起動ログに見出しのほかのもの（文言・引数・例外の本文）が出ている"
    run "$DETACH" "$W" $loc -- "$T/plain-file/sub/6.log" /usr/bin/touch "$T/started-6"
    stopped "$shut・フォルダを作れない" 1 '' "$T/started-6"
    run "$DETACH" "$W" $loc -- "$T/out-logs" /usr/bin/touch "$T/started-6"
    stopped "$shut・起動ログがフォルダ" 2 '' "$T/started-6"
    run "$copy6" "$W" $loc -- "$T/out-logs/6.log" /usr/bin/touch "$T/started-6"
    stopped "$shut・環境を受け取れない" 2 '' "$T/started-6"
  done
  run_pre=':'
  run "$DETACH" "$W" $loc -- "$T/out-logs/6.log" /usr/bin/true
  launched "$what・成功"
done
pass "終了コードと文言（空 1・不足 2・無いコマンド 2・フォルダを作れない 1・起動ログがフォルダ 2・成功 0）。文言は固定で、引数・パス・例外の本文を出さない。末尾が /. の起動ログは、手前のファイルを起動ログにせずに止まる。標準エラーを閉じていても終了コードは同じ（ロケール 2 通りで同じ）"

# ---- 7. 端の入力でも起動できる ----
mkdir -p "$T/bin7"
print -r -- "#!/bin/sh"$'\n'"echo ran >> ${(qq)T}/started-7-named" > "$T/bin7/named-cmd"; chmod +x "$T/bin7/named-cmd"
i=0
for loc in '' LC_ALL=en_US.UTF-8; do
  i=$(( i + 1 )); what="ロケール ${loc:-なし}"; R="$T/rel$i"; mkdir -p "$R" "$T/gone$i"
  run_pre='rmdir "$T/gone$i"'
  run "$DETACH" "$T/gone$i" $loc -- "$T/out-logs/7.log" /usr/bin/touch "$T/started-7-$i-gone"
  run_pre=':'
  launched "$what・消した作業場所"
  [[ ! -d "$T/gone$i" && -f "$T/started-7-$i-gone" ]] || fail "$what・消した作業場所: コマンドが動いていない（または作業場所を消せていない）"
  # 末尾の / は、無いものとして扱う（起動ログは、/ を除いた名前の普通のファイル）
  for log in logs/rel.log -dash.log x.log ./dot.log "$R/sp ace/a=b 日本語.log" "$R//sl//a.log" "$R/new/n.log" "$R/tr/t.log/"; do
    rm -f -- "$T/started-7"
    run "$DETACH" "$R" $loc -- "$log" /usr/bin/touch "$T/started-7"
    launched "$what・起動ログ $log"
    ( cd "$R" && [[ -f "${log%/}" ]] ) && [[ -f "$T/started-7" ]] || fail "$what・起動ログ $log: 起動ログがその場所に無い・コマンドが動いていない"
  done
  for v in PATH="$T/no-such-dir/bin" TMPPREFIX="$T/no-such-dir/zsh"; do
    rm -f -- "$T/started-7"
    run "$DETACH" "$R" "$v" $loc -- "$T/out-logs/7.log" /usr/bin/touch "$T/started-7"
    launched "$what・${v%%\=*} が無い場所"
    [[ -f "$T/started-7" ]] || fail "$what・${v%%\=*} が無い場所: コマンドが動いていない"
  done
  rm -f -- "$T/started-7-named"
  run "$DETACH" "$R" PATH="$T/bin7" $loc -- "$T/out-logs/7.log" named-cmd
  launched "$what・名前だけのコマンド"
  [[ "$(<"$T/started-7-named")" == ran ]] || fail "$what・名前だけのコマンド: 呼び出し元の PATH から起動していない"
done
pass "端の入力でも起動できる（消した作業場所・相対パスや - 始まりや空白と = と日本語を含む起動ログ・末尾が / や途中に // のある起動ログ・PATH や TMPPREFIX が無い場所・名前だけのコマンド）"

# ---- 8. 書き方の決まり（静的）----
# 補助が動き出すまでのシェルの部分は、許した命令の並びそのものと比べる（禁じた書き方を並べて探すのでは、並べていない書き方を見逃す。
# 絶対パスの外部コマンドを 1 行足しても、1 の偽の PATH では見つからない）。比べるのは、1 行目（#! の行）と、2 行目からの
# 注記だけの行・空行・補助の本文（Python）を除いた残りの全部。字下げも含めて 1 字でも違えば赤にする
lines=("${(@f)SRC}")
open_line="detach_py_source() { print -r -- '"; close_line="' }"
s=${lines[(ie)$open_line]}; e=${lines[(ie)$close_line]}
(( s < e && e <= ${#lines} )) || fail "補助の本文の始まりと終わりの行が見つからない（本文は一重引用符の中に置く決まり）"
body=("${(@)lines[s+1,e-1]}")
code=("${lines[1]}")
for l in "${(@)lines[2,s]}" "${(@)lines[e,-1]}"; do
  [[ "$l" == [[:space:]]#(|\#*) ]] || code+=("$l")
done
# 乗り換える行より前の、シェルの語（二重引用符の中身は除く。文言の中の場所の表記を数えない）
words=(${(s: :)${(j: :)${(@)code[2,-2]//\"[^\"]#\"/}}})
found=(${(M)words:#*python3*})
[[ "${(j: :)found}" == "$C1 $C2" ]] || fail "補助の候補が、決まった 2 つの絶対パス（この順）だけになっていない"
cat > "$T/shell.want" <<'EOF_SHELL'
#!/bin/zsh -f
set -euo pipefail
: "${1:?launch.log}"
(( $# >= 2 )) || { print -u2 -- "usage: detach-run.sh <launch.log> <cmd> [args...]"; exit 2; }
set -- /Library/Developer/CommandLineTools/usr/bin/python3 "$@"
[[ -f "$1" && -x "$1" ]] || set -- /usr/bin/python3 "${@:2}"
[[ -f "$1" && -x "$1" ]] || { print -u2 -- "ERROR: 切り離しに使う python3 が決まった場所（/Library/Developer/CommandLineTools/usr/bin/python3・/usr/bin/python3）に無いので起動しない。PATH の python3 は使わない（Mac は xcode-select --install、Linux は OS の python3 を入れる）" || :; exit 2; }
detach_env_dump() {
  set -- "${(@k)parameters[(R)*export*]}"
  while (( $# )); do print -rn -- "$1=${(P)1}"$'\0'; shift; done
  print -n -- $'\0'
}
detach_py_source() { print -r -- '
' }
exec -c "$1" -I -S - "${@:2}" 3< <(detach_env_dump) < <(detach_py_source)
EOF_SHELL
print -r -- "${(F)code}" > "$T/shell.got"
cmp -s "$T/shell.want" "$T/shell.got" \
  || { diff "$T/shell.want" "$T/shell.got" >&2 || true
       fail "補助が動き出すまでのシェルの部分が、許した命令の並びと違う（上の差分の < が決まった行、> が検査対象の行）"; }
[[ "${(F)body}" != *"'"* ]] || fail "補助の本文に一重引用符がある"
found=(${(M)body:#[[:space:]]#(import|from) *})      # 字下げした読み込みも拾う
[[ "${(F)found}" == $'import fcntl, os, stat, sys, subprocess\nfrom pathlib import Path' ]] \
  || fail "補助の本文が読み込むものが、決まった標準ライブラリ（偽モジュールを置いている名前）と違う"
print -r -- "${(F)body}" > "$T/body.py"
/usr/bin/env -i "$REAL" -I -S -c 'import sys; compile(open(sys.argv[1], "rb").read(), "body", "exec", dont_inherit=True)' "$T/body.py" 2> "$T/err" \
  || { cat "$T/err" >&2; fail "補助の本文が Python として読めない"; }
pass "書き方の決まり（静的）: 乗り換える行までのシェルの部分が、許した命令の並びそのもの・候補はちょうど 2 つ・本文に一重引用符が無く、決まった標準ライブラリだけを読み、Python として読める"

print -r -- "合格 $count 件"
