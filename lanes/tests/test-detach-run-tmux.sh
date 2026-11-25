#!/bin/zsh -f
# detach-run.sh --tmux（tmux の画面の中に居続ける親からコマンドを起動する）のテスト。
# 確かめること（かっこの中は、外すとその項目が赤になる安全策）:
#  tmux が要らない項目（tmux が無い・専用のソケットを置けない環境でも回す）
#   1. 書き方（静的）: tmux の候補は、決まった 3 つの絶対パスの 1 行だけ
#   2. --tmux を付けない起動は変わらない: 1 つ目の引数が --tmux・--linger・--tmux-pane そのものでなければ、今までどおり起動ログの名前。
#      tmux は一度も呼ばれない
#   3. 使い方の誤り（名前・--linger・足りない引数）と、tmux が決まった場所に無いときは、決まった文言で exit 2。フォルダも起動ログも
#      作らない。PATH の tmux は動かない（PATH へ倒さないこと）
#   4. 門（画面の側）: テストが相手役（呼び出し元）になって --tmux-pane を直に呼ぶ。合図を書かずに口を閉じたら、コマンドは始まらない。
#      合図を書いたら始まり、画面に pid・起動ログの続き・終了コードが出る。切り替われないコマンドは、失敗の印が返る。pid を受け取った
#      後で画面の中の親が居なくなっても、合図を書けばコマンドは最後まで動く（門で待つこと / 結果を子が直に返すこと）
#   5. 相手の確かめと期限（画面の側）: 相手が同じ利用者だと OS が言わない（別の利用者の番号が返る・取れない）とき、画面の中の親は、
#      何も受け取らずに終わる（子を作らない = pid を返さない。コマンドは始まらない）。相手がつないだまま何も送らない・合図を書かない
#      ときは、自分の期限で、コマンドを始めずに終わる（相手の利用者を確かめること / 取れないときは閉じること / 画面の側の期限）
#   6. 起動ログの続きを流すことと、子の終了を見ることは別: 起動ログが、画面が読むより速く増え続けても（相手役が、画面から読めた量の
#      2 倍を足し続ける）、コマンドが終われば終了コードを出して終わる。遅れすぎた分は、省いたと断って末尾へ進む
#      （1 回に流す量を区切ること / 終わった時点の大きさまでで止めること / 遅れすぎたら省くこと）
#  tmux が要る項目（候補をテスト用の包みに置き換えた写しと、専用のソケットの tmux だけを使う）
#   7. tmux へ渡すもの: 実行ファイルは写しの候補だけ（PATH の偽の tmux・python3・zsh は動かない）。操作は new-session と has-session だけで、
#      接続先を指す引数（-S・-L）は付けない。作業場所は /。画面の中の親は /bin/zsh -f <入口> --tmux-pane <TMPDIR の下のフォルダ> を
#      複数の引数で渡す（既定のシェルを通らない）。環境変数は名前を挙げた 6 つだけ（包みの最初の一歩が控えた名前と、そのまま比べる。
#      1 つでも多ければ赤）で、HOME・USER・LOGNAME は OS のユーザー情報、PATH は決め打ち、呼び出し元からは TMUX_TMPDIR と LANG だけ
#      （呼び出し元の HOME・SHELL・PATH・XDG_CONFIG_HOME・TMUX・TERM・LC_ALL は渡らない）。この起動が立ち上げたサーバーの既定の環境にも、
#      呼び出し元の変数は入らない（決め打ちの場所 / 渡す環境を作ること / cwd=/ / 複数の引数）
#   8. 起動したコマンドから見えるもの（環境変数の名前と指紋・作業場所・umask・標準入力・出力先・3 番以降の fd・セッション・無視にした
#      シグナル・引数のバイト列）は、付けないときと同じ。違うのは親（tmux の画面のプロセス）だけ。標準出力は pid の 1 行、
#      起動ログと台帳は同じ。消した作業場所からでも、入口・一時フォルダ・tmux のサーバーの置き場（TMUX_TMPDIR）が相対パスでも起動できる
#      （umask・作業場所の fd・シグナル・fd を閉じる処理 / 相対パスを絶対にすること）
#   9. 画面に pid・起動ログの続き・終了コードを出し、--linger の間は残して、0 ならすぐ閉じる（利用者の設定が「終わった画面を残す」でも）。
#      同じ起動ログへの 2 回目は、今回の分だけを流す。画面の中の親の下に居るのは、起動したコマンドだけ。読み終わらない起動ログ
#      （/dev/zero）は流さず、コマンドが終われば終了コードを出して閉じる
#      （remain-on-exit を切ること / 読み口を見出しの後ろへ進めること / 子の回収 / 使わない環境の写しを閉じること / 流すのは普通のファイルだけ）
#  10. 画面で Ctrl-C・Ctrl-Z・Ctrl-\ を押しても、画面の中の親は動き続け（押した後の新しい出力が画面に届く）、セッションを閉じても、
#      コマンドは最後まで動く（画面の中の親が、画面のキーを受け流すこと）
#  11. 同じ名前のセッションがあれば <名前>-2。ほかのセッションには触らない。9 つとも埋まっていれば exit 2
#  12. 失敗（起動できないコマンド・起動ログが使えない・読めない・一時フォルダを作れない・読めない作業場所・セッションを作れない）では、
#      付けないときと同じ文言と終了コード（共通の失敗）か、決まった文言で exit 2。コマンドを始めず、セッションも一時フォルダも残さない
#  13. 起動ログを開いた後で別のファイルへ置き換えられたら、起動せず、その中身を画面へ流さない（読み口の照合）
#  14. 画面の中の親が動き出す前に、利用者が受け取る pid へ止める合図（TERM）を送ると、exit 2 で pid を出さず、一時フォルダを片付け、
#      コマンドは始まらない。強制終了（KILL）でも、コマンドは始まらず、セッションは自分で閉じる。外から止めなくても、画面の中の親が
#      つながってこない・tmux が返事をしないときは、期限で exit 2 になり、片付ける（合図を受けて片付けること / 待つ所の期限）
#  15. 呼び出し元の側: テストが相手役（画面の中の親）になる。pid の前後で口が閉じた・通った印が無い・失敗の印 → exit 2。
#      通った印 → pid を出して exit 0。相手が同じ利用者だと OS が言わない（別の利用者の番号が返る・取れない）ときは、環境変数・
#      コマンド・fd を送らずに exit 2。pid を返さない相手には、止める合図でも期限でも、門を開ける合図を書かずに終わる。
#      画面の中の親がつながったら、受け渡しの一時フォルダはすぐ消す
#      （相手の利用者を確かめること / 取れないときは閉じること / つながった後に片付けること / やり取りの期限）
#  16. chk-run.sh の直後に --tmux で起動したレビュー（偽の CLI の本物の起動）が、親の記録を使い回す
#  17. 後片付け: セッション・一時フォルダを残さない。一時領域のどこにも、画面にも、環境変数の値を書いていない
# 使い方: test-detach-run-tmux.sh [<detach-run.sh>]
#   引数を省くと、キットの lanes/detach-run.sh を確かめる。引数は、安全策を外した写しで赤になることを確かめるときに渡す。
# 決まり:
#   - 利用者の tmux（既定のサーバー）には触らない。本物の tmux を呼ぶ入口は、このテストが作る tmux-entry.py の 1 つだけ（テスト自身の
#     呼び出し・検査対象の呼び出し・後片付けの全部が通る）。入口は、先頭の引数が「許したサブコマンド」であることを確かめてから、
#     「専用のソケット（-S）・設定なし（-f /dev/null）」を前に付けて本物へ切り替わる（先頭がサブコマンドなら、その後ろに何が付いても
#     接続先は変わらない）。断ったら、本物を呼ばずに印を書いて exit 97（その印があれば、テストは赤）。検査対象の呼び出しは、
#     -S・-L で始まる引数がどこかにあるだけでも断る
#   - 本物のスクリプトを --tmux 付きで回すテストは無い。回すのは、tmux の候補の行だけを置き換えた写し（置き換えが効いていることを
#     先に確かめる）。候補の先はテスト用の包みで、最初の一歩は環境を書き換えない /usr/bin/perl（/bin/sh や python3 を最初に通すと、
#     PWD・LC_CTYPE などが足されて、検査対象が渡したものと見分けられない）。渡された環境変数の名前をそこで控えてから、入口へ移る。
#     入口は、引数・作業場所・決まった名前の値の指紋を記録し、本物の tmux へは、控えた名前の変数だけを渡す
#   - 期限・相手の確かめのテストは、決まった 1 行だけをさらに置き換えた写し（期限の秒数・相手の利用者番号を返す行）で回す
#   - detach-run.sh は、空の環境（env -i）と作り物の変数だけで回す。本物の環境変数は渡さない。値は出力にもファイルにも出さない
#     （比べるのは名前と指紋）
#   - 利用者の設定は読まない。作業ツリーの目印は空の .git フォルダ（16 だけ、既存のテストと同じ隔離で git を使う）。全データを一時領域に置く
#   - 結果は、一時領域の名前（空白・改行・= ・[ があるかどうか）にも、起動元の umask・無視にしているシグナルにも依らない。パスは文字列で
#     比べる（16 だけは、名前に改行があると chk-run.sh の側が記録を使い回せないので、省いて LANES_PARTIAL を出す）
#   - 動いている間の確かめは、秒数でなく合図で進める: 起動するコマンド（steps.sh）と、遅らせる相手は、テストが合図のファイルを作るまで
#     待つ。待ち時間の上限があるのは、確かめる側だけ（上限に当たるのは、赤のときだけ）
#   - 検査対象が返した番号のプロセスには、何も送らない（居るかどうかを見るだけ）。止めるのは、このテストのいま動いているジョブだけ
#   - tmux が決まった場所に無い・ソケットのパスが長すぎて置けない（LANES_TEST_SOCKET_ROOT に浅いフォルダを渡すと、そこへ置く）・
#     /usr/bin/perl が無い（または環境変数を足す）ときは、1〜6 だけを回して「LANES_PARTIAL: <理由>」を出す
set -euo pipefail
setopt extended_glob
LANES_DIR="${0:A:h:h}"
case $# in
  0) DETACH="$LANES_DIR/detach-run.sh" ;;
  1) DETACH="${1:A}" ;;
  *) print -u2 -- "使い方: test-detach-run-tmux.sh [<detach-run.sh>]"; exit 2 ;;
esac
[[ -f "$DETACH" ]] || { print -u2 -- "確かめる detach-run.sh が無い: $DETACH"; exit 2; }
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-detach-tmux.XXXXXX")"; T="${T:A}"
# <pid>: このテストのジョブで、いま動いているか（終わったジョブの pid は、別のプロセスに使い回されうるので数えない）
job_running() {
  local j
  for j in ${(v)jobstates}; do [[ "$j" == running:*:"$1"=* ]] && return 0; done
  return 1
}
real_tmux=""; sock=""; sock_dir=""; caller=""
cleanup() {
  local st=$?
  # 合図を待っている小道具（steps.sh・遅らせた相手）を、全部放す
  [[ ! -d "$T" ]] || : > "$T/release-all"
  # 裏で動かした呼び出し元が残っていたら、先に止める（このテストのいま動いているジョブだけ。サーバーを終わらせた後で、
  # 残った呼び出し元が包みを呼ぶと、専用のソケットにサーバーが立ち上がり直す）
  if [[ -n "$caller" ]] && job_running "$caller"; then kill -KILL "$caller" 2>/dev/null || true; fi
  # 専用のソケットがあるときだけ、そのサーバーを終わらせる（本物の tmux への入口を通す。入口は、専用のソケットしか指さない）
  if [[ -n "$sock" && -S "$sock" && -f "$T/tmux-entry.py" ]]; then
    /usr/bin/env -i "$REAL" -I -S "$T/tmux-entry.py" test kill-server > /dev/null 2>&1 || true
  fi
  [[ -z "$sock_dir" ]] || rm -rf -- "$sock_dir"
  (( st != 0 )) || rm -rf -- "$T"
}
trap cleanup EXIT
H="$T/home"; TMPD="$T/tmp"; CWD="$T/cwd"; CALLS="$T/calls"
mkdir -p "$H" "$TMPD" "$CWD" "$CALLS" "$T/wrap" "$T/logs"
export HOME="$H" XDG_CONFIG_HOME="$H/.config" LANES_CONF="$T/no-such.conf"

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -r -u2 -- "FAIL: $*（$T）"; exit 1; }
# 待つ側の上限（秒）。上限に当たるのは、赤のときだけ（緑のときは、合図や条件が成り立った所で先へ進む）
LIMIT=30
# <秒> <条件のコマンド...>: 条件が成り立つまで待つ（上限つき）
wait_for() {
  local limit=$(( $1 * 20 )) n=0; shift
  until "$@" > /dev/null 2>&1; do
    n=$(( n + 1 )); (( n < limit )) || return 1
    sleep 0.05
  done
}
sha() { print -rn -- "$1" | shasum -a 256 | cut -d' ' -f1; }
alive() { kill -0 "$1" 2>/dev/null; }      # 居るかどうかを見るだけ（何も送らない）
gone() { ! kill -0 "$1" 2>/dev/null; }

# 補助の python3 は、detach-run.sh と同じ決め方で選ぶ（PATH からは探さない）。テストの小道具もこれで動かす
C1=/Library/Developer/CommandLineTools/usr/bin/python3
C2=/usr/bin/python3
if [[ -f "$C1" && -x "$C1" ]]; then REAL="$C1"; elif [[ -f "$C2" && -x "$C2" ]]; then REAL="$C2"
else fail "決め打ちの 2 つの場所に python3 が無い（detach-run.sh はこの環境では起動できない）"; fi
py() { /usr/bin/env -i "$REAL" -I -S "$@"; }

SRC="$(<"$DETACH")"
BINS_LINE='TMUX_BINS = ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux")'
MSG_USAGE=$'usage: detach-run.sh --tmux <セッション名> [--linger <秒>] <launch.log> <cmd> [args...]\n  セッション名は英数と _ -（先頭は英数・100 字まで）。--linger は 0〜86400 の整数の秒（既定 600）'
MSG_PANE='ERROR: 画面の中の親を始められない（--tmux-pane は、このスクリプトが自分で呼ぶもの。引数・例外本文は非表示）'
MSG_MKDIR='ERROR: 起動ログのフォルダを作れないので起動しない。書けるフォルダの下のパスを指定する'
MSG_OPEN='ERROR: 起動ログを開けない、または起動ログに使えない種類（symlink・ハードリンク・FIFO など）なので起動しない。普通のファイルのパスを指定する'
MSG_SPAWN='ERROR: 分離起動に失敗（引数・例外本文は非表示）'
MSG_CWD='ERROR: 作業場所を開けないので起動しない（--tmux は、読めないフォルダからは起動できない）'
MSG_WORK='ERROR: 受け渡しの一時フォルダ（TMPDIR があればその下。無ければ /tmp）を作れないので起動しない'
MSG_SESSION='ERROR: tmux のセッションを作れないので起動しない'
MSG_MANY='ERROR: 同じ名前の tmux のセッションが多すぎるので起動しない（終わったセッションを閉じるか、別の名前にする）'
MSG_LOG='ERROR: 起動ログを読めない、または開いた後で別のものに置き換わったので起動しない（--tmux は、起動ログの続きを画面に流す）'
MSG_STOP='ERROR: 止める合図（シグナル）を受けたので起動しない'
MSG_TALK='ERROR: tmux の画面の側（画面の中の親と、その子）とやり取りできないので起動しない（コマンドは始まっていない）'
MSG_PEER='ERROR: 受け渡しの相手が、同じ利用者だと確かめられないので起動しない'
MSG_NOTE2='NOTE: 同じ名前の tmux のセッションがあるので、名前の後ろに -2 を付けたセッションを作った'
SCREEN_HEAD_REST='。この画面を閉じても、Ctrl-C を押しても、起動したコマンドは止まらない（止めるのは kill '
SCREEN_NOFOLLOW='起動ログが普通のファイルでないので、続きはこの画面に流さない'
# 写しを作るときに置き換える行（検査対象に、この形の行がちょうどあること）
PEER_LINE='    return int.from_bytes(cred[4:8], sys.byteorder) if known else None'
HANDSHAKE_LINE='HANDSHAKE_SECONDS = 20'
PANE_LINE='PANE_SECONDS = HANDSHAKE_SECONDS + 5'
HEADER=$'\n=== detach-run ==='
print -r -- '呼び出し元の標準入力' > "$T/stdin.txt"
# どの起動にも渡す作り物の変数（HOME・LOGNAME は、渡さないと zsh が本物の値を入れるので必ず渡す）。鍵のつもりの印は毎回違う値
SECRET="fake-secret-$RANDOM-$RANDOM-$RANDOM"
base_env=(HOME="$H" LOGNAME=fake-user PATH=/usr/bin:/bin TMPDIR="$TMPD" FAKE_SECRET_MARK="$SECRET")

# スクリプトを、空の環境（env -i）と作り物の変数だけで回す: run <スクリプト> <作業場所> [名前=値 ...] -- [引数...]
#   結果: rc（終了コード）・$T/out（標準出力）・$T/err（標準エラー）。run_pre は、起動の直前に呼び出し元の側でやること
run_pre=':'
run() {
  local script="$1" dir="$2"; shift 2
  local -a vars; vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
  shift
  rc=0
  ( cd "$dir" && eval "$run_pre" && exec /usr/bin/env -i "${base_env[@]}" "${vars[@]}" /bin/zsh -f "$script" "$@" ) \
    > "$T/out" 2> "$T/err" < "$T/stdin.txt" || rc=$?
  entry_ok
}
# 本物の tmux への入口が、検査対象（かテスト自身）の呼び出しを断っていないこと（断ったら、入口が印を書く）
entry_ok() {
  [[ ! -e "$T/entry.violation" ]] || fail "本物の tmux への入口が、呼び出しを断った（接続先を指す引数・許していない操作。本物の tmux は呼んでいない）: $(LC_ALL=C sort -u "$T/entry.violation" | tr '\n' ' ')"
}
# 同じ形で裏で起動する（caller = 利用者が受け取る pid。このテストのジョブ）
run_bg() {
  local script="$1" dir="$2"; shift 2
  local -a vars; vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
  shift
  ( cd "$dir" && exec /usr/bin/env -i "${base_env[@]}" "${vars[@]}" /bin/zsh -f "$script" "$@" ) \
    > "$T/out" 2> "$T/err" < "$T/stdin.txt" &
  caller=$!
}
job_done() { ! job_running "$1"; }
# <秒> <説明>: 裏の呼び出し元が終わるのを待ち、終了コードを rc に入れる（終わらなければ、いま動いている自分のジョブだけ止めて失敗）
end_bg() {
  if ! wait_for "$1" job_done "$caller"; then
    if job_running "$caller"; then kill -KILL "$caller" 2>/dev/null || true; fi
    fail "$2: 呼び出し元が $1 秒で終わらない"
  fi
  rc=0; wait "$caller" 2>/dev/null || rc=$?
  entry_ok
}
# 直前の run が起動できたこと（exit 0・標準出力は pid の 1 行）: launched <説明> → pid
launched() {
  (( rc == 0 )) || { cat "$T/err" >&2; fail "$1: 起動できない（rc=$rc）"; }
  pid="$(<"$T/out")"
  [[ "$pid" == <1-> && "$(wc -l < "$T/out" | tr -d ' ')" == 1 ]] || fail "$1: 標準出力が pid の 1 行でない"
}
# 起動したコマンドが終わるまで待つ（時間切れは失敗を報告するだけ。番号は検査対象が返したものなので、それを根拠に止めない）
finished() { wait_for "$LIMIT" gone "$pid" || fail "$1: 起動したコマンドが $LIMIT 秒で終わらない（番号 $pid のプロセスが居る。止めていない）"; }
# 直前の run が、起動せずに止まったこと: stopped <説明> <終了コード> <標準エラーの全文> [起動していたら出来るファイル]
stopped() {
  [[ "$rc" == "$2" ]] || { cat "$T/err" >&2; fail "$1: 終了コードが $2 でない（rc=$rc）"; }
  [[ "$(<"$T/err")" == "$3" ]] || { cat "$T/err" >&2; fail "$1: 標準エラーが決まった文言と違う"; }
  [[ ! -s "$T/out" ]] || fail "$1: 止まったのに標準出力がある（pid を返している）"
  [[ -z "${4:-}" || ! -e "${4:-}" ]] || fail "$1: 止まったのにコマンドが起動した"
}
# 受け渡しの一時フォルダが残っていないこと
no_work() { local -a left; left=("$TMPD"/lanes-detach-*(N)); (( ! ${#left} )); }
# 動いたら印を書く偽の実行ファイル（名前と、目印の変数が見えたかどうかだけ。値は書かない）: mkfake <パス>
MARKS="$T/marks"
mkfake() {
  mkdir -p "${1:h}"
  print -r -- "#!/bin/sh"$'\n'"echo \"${1:t} 目印の変数=\${FAKE_SECRET_MARK:+見えた}\" >> ${(qq)MARKS}" > "$1"
  chmod +x "$1"
}
no_marks() {
  local -a ran; ran=("$T"/target/**/*.ran(N))
  [[ ! -s "$MARKS" ]] || fail "$1: 動いてはいけないものが動いた: $(LC_ALL=C sort -u "$MARKS" | tr '\n' ' ')"
  (( ! ${#ran} )) || fail "$1: 偽モジュールが読まれた: ${(j: :)${(@)ran:t:r}}"
}
# 写し: tmux の候補の行だけを置き換えたスクリプトを作る: mkcopy <名前> <候補の絶対パス...> → REPLY
# 候補は「バイト列を 16 進で書いて戻す」形で埋める（一時領域の名前に改行や引用符があっても、Python の文として読める）。
# 置き換えが効いていること（元の行が残っていない・新しい行が入っている）を先に確かめる
hexof() { REPLY="$(print -rn -- "$1" | od -An -v -tx1 | tr -d ' \n')"; }     # <文字列> → REPLY（バイト列の 16 進）
mkcopy() {
  local name="$1" p line="TMUX_BINS = ("; shift
  for p in "$@"; do
    hexof "$p"
    line+="os.fsdecode(b\"${REPLY//(#b)(??)/\\x${match[1]}}\"), "
  done
  line+=")"
  local body="${SRC//$BINS_LINE/$line}"
  [[ "$body" != *"$BINS_LINE"* && "$body" == *"$line"* ]] || fail "写しを作れない（tmux の候補の行が決まった形でない・置き換えが効いていない）: $name"
  REPLY="$T/$name.sh"; print -r -- "$body" > "$REPLY"
}
# 写しの 1 行だけを、さらに置き換えた写しを作る: mkedit <名前> <元のスクリプト> <元の行> <新しい行> → REPLY
# （期限の秒数・相手の利用者番号を返す行。元の行がちょうど 1 つあること・置き換えが効いていることを先に確かめる）
mkedit() {
  local body; body="$(<"$2")"
  local rest="${body#*$'\n'"$3"$'\n'}"
  [[ "$rest" != "$body" && "$rest" != *$'\n'"$3"$'\n'* ]] || fail "写しを作れない（置き換える行が、ちょうど 1 つでない）: $1"
  body="${body%%$'\n'"$3"$'\n'*}"$'\n'"$4"$'\n'"$rest"
  [[ "$body" != *$'\n'"$3"$'\n'* && "$body" == *$'\n'"$4"$'\n'* ]] || fail "写しを作れない（置き換えが効いていない）: $1"
  REPLY="$T/$1.sh"; print -r -- "$body" > "$REPLY"
}

# 起動したコマンドの側から見えるものを書き出す小道具（環境変数は名前と指紋だけ。値は書かない）: probe.py <書き出す先> [引数...]
cat > "$T/probe.py" <<'EOF_PROBE'
import fcntl, hashlib, os, signal, sys
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
env = os.environb
flags = fcntl.fcntl(1, fcntl.F_GETFL)
out = [
    "pid %d" % os.getpid(),
    "ppid %d" % os.getppid(),
    "cwd " + os.fsencode(os.getcwd()).hex(),
    "umask %o" % mask,
    "stdin " + ("devnull" if same(os.fstat(0), os.stat("/dev/null")) else "other"),
    "stdout " + ("same-as-stderr" if same(os.fstat(1), os.fstat(2)) else "other")
    + (" write-only" if flags & os.O_ACCMODE == os.O_WRONLY else " other") + (" append" if flags & os.O_APPEND else " no-append"),
    "fds " + (",".join(fds) or "-"),
    "session " + ("leader" if os.getpid() == os.getsid(0) == os.getpgrp() else "member"),
    "ignored " + ",".join(str(s) for s in range(1, signal.NSIG) if signal.getsignal(s) == signal.SIG_IGN),
    "argv " + " ".join(os.fsencode(a).hex() for a in sys.argv[2:]),
    "env-names " + " ".join(sorted(k.hex() for k in env)),
    "env-hash " + hashlib.sha256(b"\0".join(k + b"=" + v for k, v in sorted(env.items()))).hexdigest(),
]
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write("\n".join(out) + "\n")
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
EOF_PROBE
# テストの合図で進むコマンド: steps.sh <合図の頭> <段の数> <印のファイル> [終了コード]
# 段ごとに「steps: <i> 段目」を出して、<合図の頭>.<i> ができるまで待つ（テストが、確かめ終わってから作る。秒数では進まない）。
# 全部の段が済んだら「steps: 終了」を出し、印のファイルを作って終わる。テストが途中で落ちても残らないように、全部を放す合図
# （release-all。後片付けが作る）・一時領域が消えた・10 分、のどれかでも先へ進む
cat > "$T/steps.sh" <<'EOF_STEPS'
#!/bin/sh
i=1
while [ "$i" -le "$2" ]; do
  echo "steps: $i 段目"
  n=0
  while [ ! -e "$1.$i" ] && [ ! -e "${1%/*}/release-all" ] && [ -d "${1%/*}" ] && [ "$n" -lt 6000 ]; do sleep 0.1; n=$((n + 1)); done
  i=$((i + 1))
done
echo "steps: 終了"
: > "$3"
exit "${4:-0}"
EOF_STEPS
chmod +x "$T/steps.sh"

# ---- 1. 書き方（静的）----
lines=("${(@f)SRC}")
found=(${(M)lines:#*TMUX_BINS =*})
[[ "${(F)found}" == "$BINS_LINE" ]] || fail "tmux の候補が、決まった 3 つの絶対パス（この順）の 1 行になっていない"
pass "書き方（静的）: tmux の候補は、決まった 3 つの絶対パスの 1 行だけ"

# ---- 2. --tmux を付けない起動は変わらない ----
# 候補がどこにも無い写しと、偽の tmux だけの PATH で回す（付けない起動は tmux を探さない・呼ばない）
mkfake "$T/fakebin/tmux"
mkcopy copy-none "$T/none/tmux-1" "$T/none/tmux-2"; NONE="$REPLY"
i=0
for log in --tmuxx.log --linger.log --tmux-pane.log -t.log ./--tmux ./--linger ./--tmux-pane; do
  i=$(( i + 1 ))
  run "$NONE" "$CWD" PATH="$T/fakebin" -- "$log" /usr/bin/touch "$T/started-2-$i"
  launched "付けない起動・起動ログ $log"; finished "付けない起動・起動ログ $log"
  [[ -f "$T/started-2-$i" && "$(<"$CWD/$log")" == "$HEADER" ]] || fail "付けない起動・起動ログ $log: コマンドが動いていない・起動ログがその名前に無い"
done
[[ ! -e "$MARKS" ]] || fail "付けない起動で、PATH の tmux が動いた"
pass "--tmux を付けない起動は変わらない（--tmux で始まるだけの名前・./--tmux は起動ログの名前のまま。tmux は探さない・呼ばない）"

# ---- 3. 使い方の誤りと、tmux が決まった場所に無いとき ----
long100="L${(l:99::x:):-}"
for bad in "--tmux" "--tmux lane.x" "--tmux lane:x" "--tmux -lane" "--tmux _lane" "--tmux レーン" "--tmux ${long100}x" \
    "--tmux ok --linger" "--tmux ok --linger -1" "--tmux ok --linger 1.5" "--tmux ok --linger 1e3" "--tmux ok --linger nan" \
    "--tmux ok --linger 86401" "--tmux ok --linger 000000" "--tmux ok --linger 5 --linger" "--tmux ok --tmux" "--linger 5"; do
  args=(${=bad})
  [[ "$bad" == "--tmux" ]] && args+=("")      # 空のセッション名
  run "$NONE" "$CWD" PATH="$T/fakebin" -- "${args[@]}" "$T/logs/3/e.log" /usr/bin/touch "$T/started-3"
  stopped "使い方の誤り（$bad）" 2 "$MSG_USAGE" "$T/started-3"
done
run "$NONE" "$CWD" PATH="$T/fakebin" -- --tmux ok "$T/logs/3/e.log"
stopped "使い方の誤り（コマンドなし）" 2 "$MSG_USAGE" "$T/started-3"
run "$NONE" "$CWD" PATH="$T/fakebin" -- --tmux ok --linger 5 "$T/logs/3/e.log" /usr/bin/touch "$T/started-3"
stopped "tmux が決まった場所に無い" 2 "ERROR: tmux が決まった場所（$T/none/tmux-1・$T/none/tmux-2）に無いので起動しない。PATH の tmux は使わない（--tmux を外すか、tmux を入れる）" "$T/started-3"
[[ ! -e "$MARKS" ]] || fail "tmux が決まった場所に無いとき、PATH の tmux が動いた"
[[ ! -e "$T/logs/3" ]] || fail "使い方の誤り・tmux が無いときに、起動ログのフォルダを作った"
mkdir -p "$T/isdir/tmux-1" "$T/none"; print -r -- '#!/bin/sh' > "$T/none/noexec"
mkcopy copy-unusable "$T/isdir/tmux-1" "$T/none/noexec"
run "$REPLY" "$CWD" PATH="$T/fakebin" -- --tmux ok "$T/logs/3/e.log" /usr/bin/touch "$T/started-3"
stopped "tmux の候補がフォルダと、実行できないファイル" 2 "ERROR: tmux が決まった場所（$T/isdir/tmux-1・$T/none/noexec）に無いので起動しない。PATH の tmux は使わない（--tmux を外すか、tmux を入れる）" "$T/started-3"
[[ ! -e "$MARKS" ]] || fail "tmux の候補が使えないとき、PATH の tmux が動いた"
run "$NONE" "$CWD" -- --tmux-pane "$T/no-such-work"
stopped "受け渡しのフォルダが無い --tmux-pane" 2 "$MSG_PANE"
pass "使い方の誤り（名前・--linger・足りない引数）と、tmux が決まった場所に無いときは、決まった文言で exit 2（フォルダも起動ログも作らない。PATH の tmux は動かない）"

# ---- 4. 門（画面の側）: テストが相手役（呼び出し元）になって、--tmux-pane を直に呼ぶ ----
# 相手役: fake-caller.py <一時領域> <入口> <場面>。ソケットを作り、画面の中の親を起動して、fd と中身を渡し、場面ごとに動く。
# 画面の中の親は、この相手役の子（相手役が自分で止められる）。結果は「名前 値」の行で出す。待つのは相手役の側だけ（上限つき）
cat > "$T/fake-caller.py" <<'EOF_CALLER'
import os, select, socket, subprocess, sys, time
T, script, scene = sys.argv[1:4]
LIMIT = 60      # 待つ側の上限（秒）。当たるのは、赤のときだけ
flood = scene == "flood"
work = os.path.join(T, "tmp", "lanes-detach-caller-" + scene)
os.mkdir(work, 0o700)
here = os.open(".", os.O_RDONLY)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
os.chdir(work); srv.bind("s"); os.fchdir(here); srv.listen(1)
screen = os.path.join(T, "caller-%s.screen" % scene)
# 画面は、ふつうはファイル。flood の場面だけ、この相手役が読む速さを決められるパイプにする
pane = subprocess.Popen(["/bin/zsh", "-f", script, "--tmux-pane", work], env={}, cwd="/", stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE if flood else open(screen, "wb"), stderr=subprocess.STDOUT, start_new_session=True)
def result(name, value):
    print(name, value, flush=True)
def pane_exit():
    """画面の中の親の終了コード。上限まで待っても終わらなければ、止めて timeout（この相手役の子なので、自分で止められる）"""
    try:
        return pane.wait(LIMIT)
    except subprocess.TimeoutExpired:
        pane.kill()
        pane.wait()
        return "timeout"
srv.settimeout(LIMIT)
conn = srv.accept()[0]
os.unlink(os.path.join(work, "s")); os.rmdir(work)
conn.settimeout(LIMIT)
log = os.path.join(T, "caller-%s.log" % scene)
w = os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
r = os.open(log, os.O_RDONLY)
mark = os.path.join(T, "caller-%s.started" % scene)
go = os.path.join(T, "caller-%s.go" % scene)
cmd = [b"/bin/sh", b"-c", b"echo started; : > \"$0\"; sleep 1; echo finished; exit 7", os.fsencode(mark)]
linger = b"1"
if scene == "no-command":
    cmd = [os.fsencode(os.path.join(T, "no-such-command"))]
if flood:
    # この相手役が合図（go）を作るまで終わらないコマンドと、画面が遅れてよい量（1MiB）より多い、前からの中身（約 2MiB）
    cmd = [b"/bin/sh", b"-c", b"while [ ! -e \"$0\" ] && [ -d \"${0%/*}\" ]; do sleep 0.1; done; exit 7", os.fsencode(go)]
    linger = b"0"
    os.write(w, (b"flood " * 10 + b"\n") * 34000)
body = b"\0".join([linger, b"18", b"", b"%d" % len(cmd)] + cmd + [b"PATH=/usr/bin:/bin", b"FAKE=1"])
def outcome():
    result("pane-exit", pane_exit())
    time.sleep(0.3)
    result("started", os.path.exists(mark))
    result("log-bytes", os.path.getsize(log))
    sys.exit(0)
if scene == "garbage":
    conn.sendall(b"X" * 64)
    result("pane-exit", pane_exit())
    sys.exit(0)
if scene == "silent":
    # つないだまま、何も送らない（口も閉じない）。画面の中の親は、自分の期限で終わるはず
    outcome()
try:
    conn.sendmsg([b"F"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, b"".join(fd.to_bytes(4, sys.byteorder) for fd in (w, r, here)))])
    conn.sendall(b"%020d" % len(body) + body)
except OSError:
    pass      # 相手が、もう口を閉じている（下で、pid が返らないことを見る）
pid = b""
try:
    while len(pid) < 20:
        chunk = conn.recv(20 - len(pid))
        if not chunk:
            break
        pid += chunk
except OSError:
    pass
if scene.startswith("peer"):
    # 環境変数・コマンド・fd を送ってみる。相手（画面の中の親）が、こちらを同じ利用者だと確かめられないときは、受け取らずに終わる
    # （子を作らない = pid が返らない）はず。確かめられれば pid が返る。どちらでも、合図は書かずに口を閉じる
    result("pid", "received" if len(pid) == 20 else "none")
    conn.close()
    outcome()
pid = int(pid)
ps = subprocess.run(["/bin/ps", "-o", "ppid=,pgid=", "-p", str(pid)], capture_output=True).stdout.split()
result("child-of-pane", len(ps) == 2 and int(ps[0]) == pane.pid)
result("own-session", len(ps) == 2 and int(ps[1]) == pid and os.getsid(pid) == pid)
if scene == "no-ack":
    conn.close()
    outcome()
def answered():
    data = b""
    try:
        while True:
            chunk = conn.recv(8)
            if not chunk:
                break
            data += chunk
    except OSError:
        data += b"(timeout)"
    return data.decode()
if scene == "no-gate":
    # pid は受け取ったが、合図を書かない（口も閉じない）。子は、自分の期限で、コマンドを始めずに終わるはず（失敗の印が返る）
    result("answer", answered())
    outcome()
if scene == "pane-killed":
    pane.kill()
    pane.wait()
conn.sendall(b"A")
result("answer", answered())
if scene == "no-command":
    result("pane-exit", pane_exit())
    result("log-bytes", os.path.getsize(log))
    sys.exit(0)
if flood:
    # 画面（パイプ）から読めた量の 2 倍を、起動ログへ足し続ける（画面は、追記に追いつけない。速さの競争でなく、仕組みでそうする）。
    # 読むのは 1 回 8KiB・0.01 秒おき（起動ログに足す量を抑えるため）。256KiB 読めたら、コマンドを終わらせる（go）。
    # その後、画面の中の親が終わって口が閉じるまで読み続ける（上限つき）
    texts = {"skipped": "=== 画面が追いつかないので、起動ログの途中を省いた（全部は起動ログにある）===".encode(),
             "exit-line": "=== 終了: 終了コード 7。この画面は 0 秒後に閉じる ===".encode()}
    out = pane.stdout.fileno()
    total, tail, seen, released, closed, limit = 0, b"", set(), False, False, time.monotonic() + LIMIT
    try:
        while time.monotonic() < limit and not closed:
            if select.select([out], [], [], 0.01)[0]:
                chunk = os.read(out, 8192)
                closed = not chunk
                total += len(chunk)
                seen.update(name for name, text in texts.items() if text in tail + chunk)
                tail = (tail + chunk)[-256:]
                os.write(w, b"." * (2 * len(chunk)))
            if not released and total >= 262144:
                open(go, "w").close()
                released, limit = True, time.monotonic() + LIMIT // 2
            time.sleep(0.01)
    finally:
        open(go, "w").close()
    result("released", released)
    if not closed:
        pane.kill()
    result("pane-exit", pane.wait() if closed else "timeout")
    for name in sorted(texts):
        result(name, name in seen)
    sys.exit(0)
for n in range(LIMIT * 20):
    if os.path.exists(mark):
        break
    time.sleep(0.05)
result("started", os.path.exists(mark))
if scene == "ack":
    result("pane-exit", pane_exit())
else:
    for n in range(LIMIT * 20):
        if b"finished" in open(log, "rb").read():
            break
        time.sleep(0.05)
result("log", open(log, "rb").read().decode().replace("\n", "|"))
EOF_CALLER
caller_scene() {   # <場面> [入口（省くと、確かめる detach-run.sh）] → REPLY に相手役の出力
  local rc=0
  REPLY="$(cd "$CWD" && py "$T/fake-caller.py" "$T" "${2:-$DETACH}" "$1" 2> "$T/caller-$1.err")" || rc=$?
  (( rc == 0 )) || { cat "$T/caller-$1.err" >&2; fail "相手役（呼び出し元・$1）が失敗（rc=$rc。用意が誤りか、画面の中の親がつながらない）"; }
}
caller_scene no-ack
[[ "$REPLY" == $'child-of-pane True\nown-session True\npane-exit 2\nstarted False\nlog-bytes 0' ]] \
  || fail "合図を書かずに口を閉じたのに、コマンドが始まった・子が画面の中の親の子でない・新しいセッションでない: ${REPLY//$'\n'/ / }"
caller_scene ack
[[ "$REPLY" == $'child-of-pane True\nown-session True\nanswer G\nstarted True\npane-exit 0\nlog started|finished|' ]] \
  || fail "合図を書いたのに、通った印が返らない・コマンドが動かない・画面の中の親が終わらない: ${REPLY//$'\n'/ / }"
[[ "$(<"$T/caller-ack.screen")" == "lanes: 起動した pid "<1->"$SCREEN_HEAD_REST"<1->"）。以下は起動ログの続き"$'\nstarted\nfinished\n\n=== 終了: 終了コード 7。この画面は 1 秒後に閉じる ===' ]] \
  || { cat "$T/caller-ack.screen" >&2; fail "画面に出るもの（pid・起動ログの続き・終了コード）が決まった形でない"; }
caller_scene no-command
[[ "$REPLY" == $'child-of-pane True\nown-session True\nanswer GF\npane-exit 2\nlog-bytes 0' ]] \
  || fail "切り替われないコマンドで、失敗の印が返らない・画面の中の親が終わらない・起動ログに何か書いた: ${REPLY//$'\n'/ / }"
caller_scene pane-killed
[[ "$REPLY" == $'child-of-pane True\nown-session True\nanswer G\nstarted True\nlog started|finished|' ]] \
  || fail "pid を受け取った後で画面の中の親が居なくなったとき、合図を書いてもコマンドが最後まで動かない: ${REPLY//$'\n'/ / }"
caller_scene garbage
[[ "$REPLY" == 'pane-exit 2' ]] || fail "形の違う中身を受け取った画面の中の親が、exit 2 で終わらない: $REPLY"
no_work || fail "相手役の受け渡しのフォルダが残っている（用意が誤り）"
pass "門（画面の側）: 合図を書かずに口を閉じたら、コマンドは始まらない。合図を書いたら始まり、画面に pid・起動ログの続き・終了コードが出る。切り替われないコマンドは失敗の印が返る。pid の後で画面の中の親が居なくなっても、合図を書けば最後まで動く"

# ---- 5. 相手の確かめと期限（画面の側）----
# 別の利用者は用意できないので、「相手の利用者番号を返す行」だけを置き換えた写しで確かめる（確かめる行そのものは、検査対象のまま）。
# 用意の確認: 置き換えていない入口では、同じ場面で pid が返る（相手役は、頼まれれば先へ進める役）
print -r -- "$SRC" > "$T/copy-plain.sh"
caller_scene peer-self "$T/copy-plain.sh"
[[ "$REPLY" == $'pid received\npane-exit 2\nstarted False\nlog-bytes 0' ]] \
  || fail "相手が自分と同じ利用者のとき、画面の中の親が pid を返さない（用意が誤り）: ${REPLY//$'\n'/ / }"
mkedit pane-peer-other "$T/copy-plain.sh" "$PEER_LINE" '    return os.geteuid() + 1'
caller_scene peer-other "$REPLY"
[[ "$REPLY" == $'pid none\npane-exit 2\nstarted False\nlog-bytes 0' ]] \
  || fail "相手が別の利用者（OS が返す利用者番号が自分と違う）なのに、画面の中の親が受け取って先へ進んだ（子を作った）: ${REPLY//$'\n'/ / }"
[[ "$(<"$T/caller-peer-other.screen")" == "$MSG_PANE" ]] || fail "相手が別の利用者のとき、画面に出るものが決まった文言でない"
mkedit pane-peer-none "$T/copy-plain.sh" "$PEER_LINE" '    return None'
caller_scene peer-none "$REPLY"
[[ "$REPLY" == $'pid none\npane-exit 2\nstarted False\nlog-bytes 0' ]] \
  || fail "相手の利用者番号を取れないのに、画面の中の親が受け取って先へ進んだ（取れないときは、閉じる側へ倒す）: ${REPLY//$'\n'/ / }"
# 期限だけを短くした写し: 相手がつないだまま何も送らない・合図を書かないとき、外から止めなくても、自分で終わる
mkedit pane-short "$T/copy-plain.sh" "$PANE_LINE" 'PANE_SECONDS = 2'; PANE_SHORT="$REPLY"
caller_scene silent "$PANE_SHORT"
[[ "$REPLY" == $'pane-exit 2\nstarted False\nlog-bytes 0' ]] \
  || fail "相手がつないだまま何も送らないとき、画面の中の親が期限で終わらない: ${REPLY//$'\n'/ / }"
caller_scene no-gate "$PANE_SHORT"
[[ "$REPLY" == $'child-of-pane True\nown-session True\nanswer F\npane-exit 2\nstarted False\nlog-bytes 0' ]] \
  || fail "合図が来ないまま期限が来たとき、子がコマンドを始めずに終わらない・失敗の印を返さない・画面の中の親が終わらない: ${REPLY//$'\n'/ / }"
no_work || fail "相手役の受け渡しのフォルダが残っている（用意が誤り）"
pass "相手の確かめと期限（画面の側）: 相手が同じ利用者だと OS が言わない（別の利用者の番号・取れない）とき、画面の中の親は何も受け取らずに終わる（子を作らない・コマンドは始まらない）。相手が何も送らない・合図を書かないときは、自分の期限で、コマンドを始めずに終わる"

# ---- 6. 起動ログの続きを流すことと、子の終了を見ることは別 ----
caller_scene flood
rm -f -- "$T/caller-flood.log"      # 数 MB ある。後の確かめ（一時領域の全部を読む）の前に消す
[[ "$REPLY" == $'child-of-pane True\nown-session True\nanswer G\nreleased True\npane-exit 0\nexit-line True\nskipped True' ]] \
  || fail "起動ログが、画面が読むより速く増え続けるとき、コマンドが終わっても画面の中の親が終了コードを出して終わらない（pane-exit timeout）・遅れすぎた分を省いていない: ${REPLY//$'\n'/ / }"
no_work || fail "相手役の受け渡しのフォルダが残っている（用意が誤り）"
pass "起動ログが、画面が読むより速く増え続けても、コマンドが終われば、画面の中の親は終了コードを出して終わる（1 回に流す量を区切り、終わった時点の大きさまでで止める。遅れすぎた分は、省いたと断って末尾へ進む）"

# ---- ここから tmux が要る。専用のソケットと、本物の tmux への入口と、テスト用の包み ----
partial=""
for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
  if [[ -f "$p" && -x "$p" ]]; then real_tmux="$p"; break; fi
done
[[ -n "$real_tmux" ]] || partial="tmux が決まった場所に無いので、--tmux の起動（7〜17）は確かめていない"
# ソケット（接続口のファイル）のパスには長さの上限がある（バイト数で測る）。収まらなければ LANES_TEST_SOCKET_ROOT の下に置く
bytes() { print -rn -- "$1" | wc -c | tr -d ' '; }
if [[ -z "$partial" ]]; then
  sock="$T/s"
  if (( $(bytes "$sock") > 100 )); then
    sock=""
    if [[ -n "${LANES_TEST_SOCKET_ROOT:-}" && -d "${LANES_TEST_SOCKET_ROOT:-}" ]]; then
      sock_dir="$(mktemp -d "${LANES_TEST_SOCKET_ROOT%/}/dt.XXXXXX")"; sock_dir="${sock_dir:A}"
      if (( $(bytes "$sock_dir/s") <= 100 )); then sock="$sock_dir/s"; fi
    fi
    [[ -n "$sock" ]] || partial="一時領域が深く、tmux のソケットのパスが長さの上限に収まらないので、--tmux の起動（7〜17）は確かめていない（LANES_TEST_SOCKET_ROOT に浅いフォルダを渡す）"
  fi
fi
[[ -n "$partial" || -x /usr/bin/perl ]] || partial="/usr/bin/perl が無いので、--tmux の起動（7〜17）は確かめていない（テスト用の包みの最初の一歩に使う）"
call_args() { reply=("${(@ps:\0:)$(<"$CALLS/$1.args")}"); }      # 包みが受け取った引数を読む: call_args <番号> → reply
ncalls() { local -a files; files=("$CALLS"/*.args(N)); print -r -- "${#files}"; }
reset_calls() { rm -f -- "$CALLS"/*(N); }
wrap_mode() { if [[ -n "${1:-}" ]]; then print -r -- "$1" > "$T/wrap.mode"; else rm -f -- "$T/wrap.mode"; fi; }
if [[ -z "$partial" ]]; then
  hexof "$T"; hex_t="$REPLY"; hexof "$REAL"; hex_python="$REPLY"; hexof "$real_tmux"; hex_tmux="$REPLY"; hexof "$sock"; hex_sock="$REPLY"
  # 本物の tmux を呼ぶ、ただ 1 つの入口: tmux-entry.py <test|subject> <tmux の引数...>
  #   test = このテスト自身の呼び出し。subject = 検査対象（detach-run.sh の写し）の呼び出し（下の包みから来る）
  # 先頭の引数が「許したサブコマンド」であることを確かめてから、専用のソケット（-S）・設定なし（-f /dev/null）を前に付けて、本物の tmux へ
  # 切り替わる。先頭がサブコマンドなら、その後ろは全部サブコマンドの引数として読まれるので、接続先（-S・-L）や設定ファイル（-f）を
  # 後ろから変えられない。断るときは、本物を呼ばずに、理由を entry.violation に書いて exit 97（テストは、その印があれば赤にする）。
  # subject の呼び出しは、引数・作業場所・環境変数の名前（包みの最初の一歩が控えたもの）・決まった名前の値の指紋を 1 回ごとに記録し、
  # wrap.mode の動きを足す。本物の tmux へは、控えた名前の変数だけを渡す（この入口の python3 が足したものを、サーバーへ持ち込まない）
  {
    print -r -- "REAL_TMUX, SOCK, PYTHON = (bytes.fromhex(h) for h in (\"$hex_tmux\", \"$hex_sock\", \"$hex_python\"))"
    cat <<'EOF_ENTRY'
import hashlib, os, sys, time
T = os.path.dirname(os.path.abspath(sys.argv[0]))
who, args = sys.argv[1], sys.argv[2:]
ALLOWED = {
    "subject": ("new-session", "has-session"),
    "test": ("new-session", "has-session", "kill-session", "kill-server", "list-sessions", "list-panes", "capture-pane",
             "send-keys", "set-option", "set-environment", "show-environment", "show-options"),
}
def refuse(why):
    with open(os.path.join(T, "entry.violation"), "a") as f:
        f.write("%s: %s\n" % (who, why))
    sys.exit(97)
def held(release):
    """合図のファイルができるまで待つ。全部を放す合図（release-all）・一時領域が消えた・10 分でも抜ける"""
    for n in range(6000):
        if os.path.exists(release) or os.path.exists(os.path.join(T, "release-all")) or not os.path.isdir(T):
            break
        time.sleep(0.1)
env, mode = {}, ""
if who == "subject":
    calls = os.path.join(T, "calls")
    names = os.path.join(calls, "names.%d" % os.getpid())
    with open(names, "rb") as f:
        passed = [name for name in f.read().split(b"\n") if name]
    n = len([name for name in os.listdir(calls) if name.endswith(".args")])
    with open(os.path.join(calls, "%d.args" % n), "wb") as f:
        f.write(b"\0".join(os.fsencode(a) for a in args))
    with open(os.path.join(calls, "%d.cwd" % n), "wb") as f:
        f.write(os.getcwdb())
    os.rename(names, os.path.join(calls, "%d.env" % n))
    with open(os.path.join(calls, "%d.values" % n), "w") as f:
        for name in (b"HOME", b"USER", b"LOGNAME", b"PATH", b"LANG", b"TMUX_TMPDIR"):
            f.write("%s %s\n" % (name.decode(), hashlib.sha256(os.environb[name]).hexdigest() if name in passed else "-"))
    env = {name: os.environb[name] for name in passed if name in os.environb}
    try:
        with open(os.path.join(T, "wrap.mode")) as f:
            mode = f.read().strip()
    except OSError:
        pass
if who not in ALLOWED or not args or args[0] not in ALLOWED[who]:
    refuse("先頭の引数が、許したサブコマンドでない")
if who == "subject" and any(a.startswith(("-S", "-L")) for a in args):
    refuse("接続先を指す引数（-S・-L）が付いている")
if mode == "refuse":
    sys.exit(1)          # tmux が断った形（セッションを作れない・問い合わせも失敗）
if mode == "hang":       # tmux が返事をしない形（合図まで、何もしないで待つ。検査対象が、期限で止めるはず）
    with open(os.path.join(T, "hang.pid"), "w") as f:
        f.write("%d\n" % os.getpid())
    held(os.path.join(T, "release-hang"))
    sys.exit(1)
if args[0] == "new-session" and mode:
    start = args.index("--") + 1
    end = args.index(";")
    work = args[args.index("--tmux-pane") + 1]
    if mode == "hold":       # 画面の中の親を、テストが合図のファイル（release-pane）を作るまで動かさない
        wait = ("n=0; while [ ! -e \"$0\" ] && [ ! -e \"${0%/*}/release-all\" ] && [ -d \"${0%/*}\" ] && [ \"$n\" -lt 6000 ]; "
                "do sleep 0.1; n=$((n + 1)); done; exec \"$@\"")
        args[start:end] = ["/bin/sh", "-c", wait, os.path.join(T, "release-pane")] + args[start:end]
    elif mode == "swap":     # 呼び出し元が起動ログを開いた後・読み口を開く前に、起動ログを別のファイルへ置き換える
        os.replace(os.path.join(T, "private.txt"), os.path.join(T, "swap.log"))
    elif mode.startswith("pane:"):   # 画面の中の親の代わりに、相手役を置く
        args[start:end] = [PYTHON, "-I", "-S", os.path.join(T, "fake-pane.py"), T, work, mode[5:]]
os.execve(REAL_TMUX, [REAL_TMUX, b"-S", SOCK, b"-f", b"/dev/null"] + [os.fsencode(a) for a in args], env)
EOF_ENTRY
  } > "$T/tmux-entry.py"
  # 包み（検査対象の写しの「tmux の候補」）。最初の一歩は、環境を書き換えない perl: 渡された環境変数の名前を、何かが足す前に控えてから、
  # 入口へ移る（/bin/sh は PWD・SHLVL・_ を、python3 は LC_CTYPE などを足すので、最初に通すと、検査対象が渡したものと見分けられない）
  {
    print -r -- '#!/usr/bin/perl'
    print -r -- "my (\$t, \$python) = map { pack(\"H*\", \$_) } (\"$hex_t\", \"$hex_python\");"
    cat <<'EOF_WRAP'
open(my $f, ">", "$t/calls/names.$$") or exit 125;
print $f "$_\n" for sort keys %ENV;
close($f) or exit 125;
exec { $python } $python, "-I", "-S", "$t/tmux-entry.py", "subject", @ARGV;
exit 125;
EOF_WRAP
  } > "$T/wrap/tmux"
  chmod +x "$T/wrap/tmux"
  # 用意の確認（どれも、サーバーを立ち上げない呼び出しだけで行う。この時点で、専用のソケットにサーバーは無い）
  #  a. 入口は、接続先を指す引数の付いた呼び出し・許していない操作を、本物の tmux を呼ばずに断る
  refused() {   # <test|subject> <引数...>
    local who="$1" r=0; shift
    rm -f -- "$T/entry.violation"
    if [[ "$who" == test ]]; then py "$T/tmux-entry.py" test "$@" > /dev/null 2>&1 || r=$?
    else /usr/bin/env -i /usr/bin/perl "$T/wrap/tmux" "$@" > /dev/null 2>&1 || r=$?; fi
    [[ "$r" == 97 && -s "$T/entry.violation" ]] || fail "本物の tmux への入口が、断るはずの呼び出し（$who・先頭の引数 $1）を断らない（rc=$r。用意が誤り）"
    rm -f -- "$T/entry.violation"
  }
  refused subject -S "$T/other.sock" has-session -t '=none'
  refused subject -L lanes-test-none has-session -t '=none'
  refused subject -f "$T/other.conf" has-session -t '=none'
  refused subject has-session -t '=none' -S "$T/other.sock"
  refused subject kill-server
  refused subject attach-session -t '=none'
  refused test -S "$T/other.sock" has-session -t '=none'
  refused test attach-session -t '=none'
  [[ ! -e "$sock" && ! -e "$T/other.sock" ]] || fail "入口の確かめで、ソケットができた（用意が誤り）"
  #  b. 包みの最初の一歩は、環境変数を足さない（空の環境から呼んで、控えた名前が空であること）
  reset_calls
  /usr/bin/env -i /usr/bin/perl "$T/wrap/tmux" has-session -t '=none' > /dev/null 2>&1 || true
  if [[ ! -e "$CALLS/0.env" || -s "$CALLS/0.env" ]]; then
    partial="テスト用の包みの最初の一歩（/usr/bin/perl）が、動かない・空の環境に環境変数を足すので、--tmux の起動（7〜17）は確かめていない"
  fi
  entry_ok
  reset_calls
fi
if [[ -n "$partial" ]]; then
  print -r -- "LANES_PARTIAL: $partial"
  print -r -- "合格 $count 件"
  exit 0
fi
# このテストの tmux の呼び出しは、すべて入口を通す（専用のソケット・設定なし・空の環境）
tm() { py "$T/tmux-entry.py" test "$@"; }
has() { tm has-session -t "=$1" 2>/dev/null; }
hasnt() { ! tm has-session -t "=$1" 2>/dev/null; }
sessions() { tm list-sessions -F '#{session_name}' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' || true; }
screen_has() { tm capture-pane -p -J -t "=$1:" 2>/dev/null | grep -qF -- "$2"; }     # <セッション> <語>: 画面にその語が出ているか
screen_tail() { tm capture-pane -p -J -t "=$1:" 2>/dev/null | grep -v '^$' | tail -3 || true; }
pane_pid() { tm list-panes -t "=$1" -F '#{pane_pid}' 2>/dev/null | head -1; }
# <親の pid> <子の pid>: 親の下に居る子プロセスが、その 1 つだけか（番号だけを見る）
only_child() { [[ "$(ps -ax -o ppid=,pid= | awk -v p="$1" '$1 == p { print $2 }' | tr '\n' ' ')" == "$2 " ]]; }
mkcopy copy-wrap "$T/wrap/tmux"; DR="$REPLY"
# 期限だけを置き換えた写し（長い = 止める合図のテストが、期限と競わない。短い = 外から止めなくても、期限で終わることを見る）
mkedit copy-wrap-long "$DR" "$HANDSHAKE_LINE" 'HANDSHAKE_SECONDS = 600'; DR_LONG="$REPLY"
mkedit copy-wrap-short "$DR" "$HANDSHAKE_LINE" 'HANDSHAKE_SECONDS = 3'; DR_SHORT="$REPLY"

# ---- 7. tmux へ渡すもの（サーバーがまだ無い所から。この起動が立ち上げる）----
# 起動する対象のリポジトリの模型: PATH は印を書く偽物だけ・HOME と設定の場所とシェルは対象の中・作業場所と PYTHONPATH に偽モジュール
W="$T/target"
mkdir -p "$W/.git" "$W/pylib" "$W/conf/tmux" "$T/socks"
for f in tmux python3 python zsh sh bash env mkdir cat sleep perl; do mkfake "$W/.venv/bin/$f"; done
for d in "$W" "$W/pylib"; do
  for m in fcntl os stat sys subprocess pathlib pwd signal socket time sitecustomize; do
    print -r -- 'open(__file__ + ".ran", "w").close()' > "$d/$m.py"
  done
done
# tmux の設定ファイルのつもりのもの（読まれたら印を書く。入口は「設定なし」で呼ぶので、ここでは読まれない。設定の場所を決める HOME が
# 呼び出し元の値でないことは、下で値の指紋を比べて確かめる）と、-f なしの zsh が読むもの
print -r -- "run-shell 'echo tmux-conf >> ${(q)MARKS}'" > "$W/.tmux.conf"
cp "$W/.tmux.conf" "$W/conf/tmux/tmux.conf"
print -r -- "print -r -- zshenv >> ${(qq)MARKS}" > "$W/.zshenv"
target_env=(PATH="$W/.venv/bin" HOME="$W" XDG_CONFIG_HOME="$W/conf" SHELL="$W/.venv/bin/zsh" ZDOTDIR="$W" PYTHONPATH="$W/pylib"
  VIRTUAL_ENV="$W/.venv" TMUX="$T/socks/other,1,0" TMUX_PANE=%99 TERM=fake-term LC_ALL=fake_LC LANG=fake_LANG.UTF-8 TMUX_TMPDIR="$T/socks")
[[ ! -e "$sock" ]] || fail "専用のソケットがもうある（用意が誤り）"
run "$DR" "$W" "${target_env[@]}" -- --tmux lt-first --linger 600 "$T/logs/first.log" /usr/bin/touch "$T/started-7"
launched "サーバーが無い所からの起動"; finished "サーバーが無い所からの起動"
[[ -f "$T/started-7" ]] || fail "サーバーが無い所からの起動: コマンドが動いていない"
no_marks "サーバーが無い所からの起動"
[[ -S "$sock" ]] || fail "この起動が、専用のソケットにサーバーを立ち上げていない（用意が誤り）"
[[ "$(ncalls)" == 1 ]] || fail "ふつうの起動で tmux を呼ぶ回数が 1 回でない（$(ncalls) 回）"
call_args 0
work="${reply[10]:-}"
expect=(new-session -d -s lt-first -- /bin/zsh -f "$DR" --tmux-pane "$work" ";" set-option -w remain-on-exit off)
[[ "${(pj:\0:)reply}" == "${(pj:\0:)expect}" ]] \
  || fail "tmux へ渡した引数が、決まった形（new-session -d -s <名前> -- /bin/zsh -f <入口> --tmux-pane <フォルダ> ; set-option -w remain-on-exit off）でない"
[[ "$work" == "$TMPD/lanes-detach-"[0-9a-f](#c16) ]] || fail "受け渡しのフォルダが、TMPDIR の下の決まった名前でない"
[[ "$(<"$CALLS/0.cwd")" == / ]] || fail "tmux を呼ぶ作業場所が / でない（サーバーが、起動する対象の作業ツリーを掴み続ける）"
# 環境変数の名前は、包みの最初の一歩が控えたもの（何も足されていない）を、決めた 6 つとそのまま比べる。1 つでも多ければ赤
want=(HOME LANG LOGNAME PATH TMUX_TMPDIR USER)
got=("${(@f)$(<"$CALLS/0.env")}")
[[ "${(pj:\0:)want}" == "${(pj:\0:)got}" ]] \
  || fail "tmux へ渡した環境変数が、名前を挙げた 6 つと違う（名前だけ出す。決めたもの: ${(j: :)want} / 渡ったもの: ${(j: :)got}）"
# 値は指紋で比べる。HOME・USER・LOGNAME は OS のユーザー情報のもの（呼び出し元の HOME = 対象の中、ではない）。PATH は決め打ち
py -c 'import hashlib, os, pwd, sys
me = pwd.getpwuid(os.getuid())
for name, value in (("HOME", me.pw_dir), ("USER", me.pw_name), ("LOGNAME", me.pw_name)):
    print(name, hashlib.sha256(os.fsencode(value)).hexdigest())' > "$T/values.want"
print -r -- "PATH $(sha "$T/wrap:/usr/bin:/bin:/usr/sbin:/sbin")"$'\n'"LANG $(sha fake_LANG.UTF-8)"$'\n'"TMUX_TMPDIR $(sha "$T/socks")" >> "$T/values.want"
cmp -s "$T/values.want" "$CALLS/0.values" \
  || fail "tmux へ渡した環境変数の値が違う（HOME・USER・LOGNAME は OS のユーザー情報・PATH は決め打ち・LANG と TMUX_TMPDIR は呼び出し元のもの、のはず。違う名前: $(diff "$T/values.want" "$CALLS/0.values" | sed -n 's/^< \([A-Z_]*\) .*/\1/p' | tr '\n' ' ')）"
[[ "$(sed -n 's/^HOME //p' "$CALLS/0.values")" != "$(sha "$W")" ]] || fail "tmux へ、呼び出し元の HOME（対象の中）を渡した"
# この起動が立ち上げたサーバーの既定の環境（利用者が後で開くウィンドウへ渡るもの）: 照会の成功と、名前の一覧を別々に見る
# （値はファイルに書かない。名前だけを取り出す）。入口は、控えた名前の変数だけを本物の tmux へ渡しているので、そのまま比べられる
tm show-environment -g > /dev/null || fail "立ち上がったサーバーの既定の環境を照会できない"
server=("${(@f)$(tm show-environment -g | sed 's/=.*//' | LC_ALL=C sort)}")
(( ${server[(Ie)HOME]} && ${server[(Ie)PATH]} )) || fail "立ち上がったサーバーの既定の環境が取れていない（用意が誤り）"
extra=(${server:|want}); extra=(${extra:#PWD})
(( ! ${#extra} )) || fail "立ち上がったサーバーの既定の環境に、決めた名前のほかのものが入っている（名前だけ出す）: ${(j: :)extra}"
[[ "$(tm show-options -gv default-shell)" != "$W/.venv/bin/zsh" ]] || fail "サーバーの既定のシェルが、呼び出し元の SHELL（対象の中）になった"
pass "tmux へ渡すもの（サーバーが無い所から）: 実行ファイルは決めた候補だけ・操作は 1 回・接続先の指定なし・作業場所は /・環境変数は名前を挙げた 6 つだけ（HOME・USER・LOGNAME は OS のユーザー情報、PATH は決め打ち）。対象の中の偽物・偽モジュールは動かない（設定ファイルの場所と既定のシェルは、呼び出し元の値で決まらない）。立ち上がったサーバーの既定にも、呼び出し元の変数は入らない"
# ここから先は、サーバーを残す（セッションが無くなるとサーバーが終わる）。利用者の設定のつもりで、「終わった画面を残す」・
# 既定のシェル（通ったら印を書く）・サーバーの環境変数を入れておく
tm new-session -d -s keeper -- /bin/sleep 900 || fail "サーバーを残すセッションを作れない（用意が誤り）"
print -r -- "#!/bin/sh"$'\n'"echo default-shell >> ${(qq)MARKS}"$'\n'"exec /bin/sh \"\$@\"" > "$T/fake-shell"; chmod +x "$T/fake-shell"
tm set-option -g remain-on-exit on; tm set-option -g default-shell "$T/fake-shell"; tm set-environment -g FAKE_SERVER_MARK from-server
# パイプの容量を超える大きさの、サーバーの環境（tmux の 1 回の命令には長さの上限があるので、分けて入れる）
for i in {1..12}; do tm set-environment -g "FAKE_SERVER_BIG_$i" "${(l:8000::x:):-}"; done
tm new-session -d -s shell-check "true"; wait_for "$LIMIT" test -s "$MARKS" || fail "既定のシェルの印が効いていない（用意が誤り）"
tm kill-session -t '=shell-check'; rm -f -- "$MARKS"
tm kill-session -t '=lt-first'

# ---- 8. 起動したコマンドから見えるものは、付けないときと同じ ----
mkdir -p "$T/cwd8" "$T/wt-plain/.git" "$T/wt-tmux/.git"
# そのまま渡りにくい形の変数（スクリプトの中の名前と同じになりうるもの・空の値・改行と = と日本語・長い値）と、tmux が画面に足す名前
t8_env=(k=呼び出し元の値 log=呼び出し元の値 FAKE_EMPTY= FAKE_TEXT=$'1 行目\n2 行目 = 日本語' FAKE_BIG="${(l:100000::x:):-}"
  TMUX=fake-tmux TMUX_PANE=fake-pane TERM=fake-term SHELL=/fake/shell)
# 起動の直前に、テストが自分で決める umask と、無視にするシグナル（起動元の設定には頼らない）
origin_pre='umask 027; trap "" HUP USR1'
run_pre="$origin_pre; exec 5</dev/null 9</dev/null"
run "$DR" "$T/cwd8" "${t8_env[@]}" -- "$T/wt-plain/logs/launch.log" "$REAL" -I -S "$T/probe.py" "$T/probe.plain" 日本語 $'a\xffb' 'sp ace' ''
launched "付けない起動（基準）"; finished "付けない起動（基準）"
[[ ! -s "$T/err" ]] || fail "付けない起動（基準）: 標準エラーに出力がある"
run "$DR" "$T/cwd8" "${t8_env[@]}" -- --tmux lt-same --linger 600 "$T/wt-tmux/logs/launch.log" "$REAL" -I -S "$T/probe.py" "$T/probe.tmux" 日本語 $'a\xffb' 'sp ace' ''
launched "--tmux の起動"; finished "--tmux の起動"
run_pre=':'
[[ ! -s "$T/err" ]] || { cat "$T/err" >&2; fail "--tmux の起動: 標準エラーに出力がある"; }
[[ -s "$T/probe.plain" && -s "$T/probe.tmux" ]] || fail "起動したコマンドが、見えたものを書き出していない"
# 用意の確認: 基準には、テストが決めた umask・無視にしたシグナル（HUP=1 が先頭）・作り物の変数が見えている
grep -qx 'umask 27' "$T/probe.plain" && grep -q '^ignored 1,' "$T/probe.plain" && grep -qx 'fds -' "$T/probe.plain" \
  && grep -qx 'stdout same-as-stderr write-only append' "$T/probe.plain" || { cat "$T/probe.plain" >&2; fail "基準の起動で、umask・無視にしたシグナル・出力先が見えていない（用意が誤り）"; }
grep -v '^pid \|^ppid ' "$T/probe.plain" > "$T/probe.plain.cmp"; grep -v '^pid \|^ppid ' "$T/probe.tmux" > "$T/probe.tmux.cmp"
cmp -s "$T/probe.plain.cmp" "$T/probe.tmux.cmp" \
  || fail "--tmux で起動したコマンドから見えるものが、付けないときと違う（違う行の名前: $(diff "$T/probe.plain.cmp" "$T/probe.tmux.cmp" | sed -n 's/^< \([a-z-]*\) .*/\1/p' | tr '\n' ' ')）"
[[ "$(sed -n 's/^pid //p' "$T/probe.tmux")" == "$pid" ]] || fail "--tmux が標準出力に出した pid が、起動したコマンドの pid でない"
[[ "$(sed -n 's/^ppid //p' "$T/probe.tmux")" == "$(pane_pid lt-same)" && -n "$(pane_pid lt-same)" ]] || fail "--tmux で起動したコマンドの親が、tmux の画面のプロセスでない"
cmp -s "$T/wt-plain/logs/launch.log" "$T/wt-tmux/logs/launch.log" && [[ "$(<"$T/wt-tmux/logs/launch.log")" == "$HEADER" ]] \
  || fail "--tmux の起動ログ（見出し）が、付けないときと違う"
cmp -s "$T/wt-plain/logs/.lanes-records" "$T/wt-tmux/logs/.lanes-records" && grep -qxF 'file:launch.log' "$T/wt-tmux/logs/.lanes-records" \
  || fail "--tmux の起動で、台帳（logs/.lanes-records）が付けないときと違う"
[[ ! -e "$MARKS" ]] || fail "画面の中の親の起動が、tmux の既定のシェルを通った: $(<"$MARKS")"
tm kill-session -t '=lt-same'
# 消した作業場所からでも、付けないときと同じに起動できる（作業場所は fd で渡す。入口と一時フォルダが絶対パスなら、今の場所を調べない）
mkdir -p "$T/gone8"; run_pre='rmdir "$T/gone8"'
run "$DR" "$T/gone8" -- --tmux lt-gone --linger 0 "$T/logs/gone.log" /usr/bin/touch "$T/started-8-gone"
run_pre=':'
launched "消した作業場所からの --tmux"; finished "消した作業場所からの --tmux"
[[ ! -d "$T/gone8" && -f "$T/started-8-gone" ]] || fail "消した作業場所からの --tmux: コマンドが動いていない（または作業場所を消せていない）"
# 入口・一時フォルダ・tmux のサーバーの置き場（TMUX_TMPDIR）を相対パスで渡しても起動できる（tmux と画面の中の親は / で動くので、
# 今の場所につないで絶対にして渡す。相対のまま渡すと、tmux は / を基準に読み、その場所が無ければ黙って既定の場所へ倒れる）
reset_calls
run "./${DR:t}" "$T" TMPDIR=tmp TMUX_TMPDIR=socks -- --tmux lt-rel --linger 0 logs/rel.log /usr/bin/touch "$T/started-8-rel"
launched "相対パスの入口・一時フォルダ・サーバーの置き場"; finished "相対パスの入口・一時フォルダ・サーバーの置き場"
call_args 0
[[ -f "$T/started-8-rel" && "${reply[8]}" == "$T/./${DR:t}" && "${reply[10]}" == "$T/tmp/lanes-detach-"[0-9a-f](#c16) ]] \
  || fail "相対パスの入口と一時フォルダ: コマンドが動いていない・tmux へ渡したパスが、今の場所につないだ絶対パスでない"
[[ "$(sed -n 's/^TMUX_TMPDIR //p' "$CALLS/0.values")" == "$(sha "$T/socks")" ]] \
  || fail "相対パスの TMUX_TMPDIR を、今の場所につないだ絶対パスにして tmux へ渡していない（tmux は / で動くので、別のサーバーを指す）"
# 空の TMUX_TMPDIR は、空のまま渡す（tmux は、無いのと同じに扱う）
reset_calls
run "$DR" "$CWD" TMUX_TMPDIR= -- --tmux lt-empty --linger 0 "$T/logs/empty.log" /usr/bin/touch "$T/started-8-empty"
launched "空の TMUX_TMPDIR"; finished "空の TMUX_TMPDIR"
[[ -f "$T/started-8-empty" && "$(sed -n 's/^TMUX_TMPDIR //p' "$CALLS/0.values")" == "$(sha '')" ]] \
  || fail "空の TMUX_TMPDIR: コマンドが動いていない・空のまま tmux へ渡していない"
pass "起動したコマンドから見えるもの（環境変数の名前と指紋・作業場所・umask・標準入力・出力先・fd・セッション・無視にしたシグナル・引数）は、付けないときと同じ。違うのは親（tmux の画面のプロセス）だけ。pid の出力・起動ログ・台帳も同じ。既定のシェルを通らない。消した作業場所からでも、入口・一時フォルダ・サーバーの置き場が相対パスでも起動できる"

# ---- 9. 画面に pid・起動ログの続き・終了コードを出し、--linger のあとで閉じる ----
# コマンドは、テストが合図のファイルを作るまで待つ（動いている間の確かめを、秒数と競わせない）。--linger は長くして、テストが自分で閉じる
run "$DR" "$CWD" -- --tmux lt-screen --linger 600 "$T/logs/screen.log" "$T/steps.sh" "$T/go-9" 1 "$T/mark-9" 7
launched "画面の確かめ"
wait_for "$LIMIT" screen_has lt-screen "lanes: 起動した pid $pid$SCREEN_HEAD_REST$pid）。以下は起動ログの続き" || fail "画面に起動した pid が出ていない: $(screen_tail lt-screen)"
wait_for "$LIMIT" screen_has lt-screen 'steps: 1 段目' || fail "画面に起動ログの続きが出ていない: $(screen_tail lt-screen)"
# 画面の中の親の下に居るのは、起動したコマンドだけ（入口のシェルが残した子が、終わったまま・待ったままで残っていない。
# サーバーの環境が大きくても。tmux の画面のプロセスを一覧にする道具に、余分なものを見せない）
pp="$(pane_pid lt-screen)"; [[ "$pp" == <1-> ]] || fail "画面のプロセスが分からない（用意が誤り）"
wait_for "$LIMIT" only_child "$pp" "$pid" \
  || fail "画面の中の親の下に、起動したコマンドのほかの子プロセス（終わったまま・待ったままのもの）が残っている"
: > "$T/go-9.1"
finished "画面の確かめ"
wait_for "$LIMIT" screen_has lt-screen '=== 終了: 終了コード 7。この画面は 600 秒後に閉じる ===' || fail "画面に終了コードが出ていない: $(screen_tail lt-screen)"
screen_has lt-screen 'steps: 終了' || fail "終わる直前の出力が画面に出ていない"
sleep 1
has lt-screen || fail "--linger の間なのに、セッションが閉じた"
tm kill-session -t '=lt-screen'
run "$DR" "$CWD" -- --tmux lt-now --linger 0 "$T/logs/screen.log" /bin/sh -c 'kill -TERM $$'
launched "--linger 0"; finished "--linger 0"
wait_for "$LIMIT" hasnt lt-now || fail "--linger 0 なのに、コマンドが終わってもセッションが閉じない（利用者の設定は「終わった画面を残す」）"
# 同じ起動ログへ追記する 2 回目: 画面に流すのは今回の分だけ（前の回の出力と、見出しは流さない）
run "$DR" "$CWD" -- --tmux lt-again --linger 600 "$T/logs/screen.log" /bin/sh -c 'echo "2 回目の出力"'
launched "同じ起動ログへの 2 回目"; finished "同じ起動ログへの 2 回目"
wait_for "$LIMIT" screen_has lt-again '2 回目の出力' || fail "2 回目の起動で、画面に今回の出力が出ていない: $(screen_tail lt-again)"
if screen_has lt-again 'steps: ' || screen_has lt-again '=== detach-run ==='; then fail "画面に、前の回の出力か見出し（今回の分より前）を流した"; fi
[[ "$(grep -c '^=== detach-run ===$' "$T/logs/screen.log")" == 3 ]] || fail "同じ起動ログへ追記していない（見出しが 3 回分でない）"
tm kill-session -t '=lt-again'
# 読み終わらない起動ログ（/dev/zero。起動ログに使える文字デバイスで、いくら読んでも終わらない）: 画面には流さず、そう断る。
# コマンドが終われば、終了コードを出して、--linger どおりに閉じる
run "$DR" "$CWD" -- --tmux lt-zero --linger 600 /dev/zero "$T/steps.sh" "$T/go-9z" 1 "$T/mark-9z" 5
launched "読み終わらない起動ログ"
wait_for "$LIMIT" screen_has lt-zero "lanes: 起動した pid $pid$SCREEN_HEAD_REST$pid）。$SCREEN_NOFOLLOW" \
  || fail "普通のファイルでない起動ログ（/dev/zero）のとき、画面に「続きは流さない」と出ていない: $(screen_tail lt-zero | cut -c1-200)"
: > "$T/go-9z.1"
finished "読み終わらない起動ログ"
wait_for "$LIMIT" screen_has lt-zero '=== 終了: 終了コード 5。この画面は 600 秒後に閉じる ===' \
  || fail "読み終わらない起動ログ（/dev/zero）のとき、コマンドが終わっても、画面に終了コードが出ない: $(screen_tail lt-zero | cut -c1-200)"
tm kill-session -t '=lt-zero'
run "$DR" "$CWD" -- --tmux lt-zero-now --linger 0 /dev/zero /usr/bin/true
launched "読み終わらない起動ログ・--linger 0"; finished "読み終わらない起動ログ・--linger 0"
wait_for "$LIMIT" hasnt lt-zero-now || fail "読み終わらない起動ログ（/dev/zero）のとき、コマンドが終わってもセッションが閉じない"
pass "画面に pid・起動ログの続き・終了コードを出し、--linger の間は残して、0 ならすぐ閉じる（利用者の設定が「終わった画面を残す」でも）。同じ起動ログへの 2 回目は今回の分だけを流す。画面の中の親の下に居るのは、起動したコマンドだけ。読み終わらない起動ログ（/dev/zero）は流さず、コマンドが終われば終了コードを出して閉じる"

# ---- 10. 画面でキーを押しても、セッションを閉じても、コマンドは最後まで動く ----
run "$DR" "$CWD" -- --tmux lt-keys --linger 600 "$T/logs/keys.log" "$T/steps.sh" "$T/go-10" 2 "$T/keys.mark"
launched "画面のキーとセッションを閉じる確かめ"
wait_for "$LIMIT" screen_has lt-keys 'steps: 1 段目' || fail "画面に起動ログの続きが出ていない（用意が誤り）"
# キーを 1 つずつ送り（送れなければ赤）、端末に届いたことを、画面に出る ^C・^Z・^\ で確かめる（届いた時点で、画面の中の親へ
# シグナルが出ている）
for key in 'C-c ^C' 'C-z ^Z' 'C-\ ^\'; do
  tm send-keys -t '=lt-keys:' "${key% *}" || fail "画面へキー（${key% *}）を送れない"
  wait_for "$LIMIT" screen_has lt-keys "${key#* }" || fail "送ったキー（${key% *}）が、画面の端末に届いていない: $(screen_tail lt-keys)"
done
# キーが届いた後で、コマンドを次の段へ進める。その新しい出力が画面に届けば、画面の中の親は動き続けている（止まっていれば届かない）
: > "$T/go-10.1"
wait_for "$LIMIT" screen_has lt-keys 'steps: 2 段目' \
  || fail "画面でキー（Ctrl-C・Ctrl-Z・Ctrl-\\）を押した後、新しい出力が画面に届かない（画面の中の親が止まった・終わった）: $(screen_tail lt-keys)"
alive "$pid" && has lt-keys || fail "画面のキーで、コマンドかセッションが止まった"
tm kill-session -t '=lt-keys'
hasnt lt-keys || fail "セッションを閉じられない（用意が誤り）"
alive "$pid" || fail "セッションを閉じたら、起動したコマンドも止まった"
: > "$T/go-10.2"
wait_for "$LIMIT" test -e "$T/keys.mark" || fail "セッションを閉じた後、コマンドが最後まで動いていない"
grep -q 'steps: 終了' "$T/logs/keys.log" || fail "セッションを閉じた後の出力が、起動ログに届いていない"
pass "画面で Ctrl-C・Ctrl-Z・Ctrl-\\ を押しても、画面の中の親は動き続け（押した後の出力が画面に届く）、セッションを閉じても、起動したコマンドは最後まで動き、起動ログに書き続ける"

# ---- 11. 同じ名前のセッションがあれば <名前>-2 ----
run "$DR" "$CWD" -- --tmux keeper --linger 0 "$T/logs/same.log" "$T/steps.sh" "$T/go-11" 1 "$T/same.mark"
launched "同じ名前があるとき"
[[ "$(<"$T/err")" == "$MSG_NOTE2" ]] || { cat "$T/err" >&2; fail "同じ名前があるとき、標準エラーが決まった 1 行でない"; }
has keeper && has keeper-2 || fail "同じ名前があるとき、keeper-2 を作っていない・元の keeper が無い（今あるもの: $(sessions)）"
[[ "$(ps -o ppid= -p "$pid" | tr -d ' ')" == "$(pane_pid keeper-2)" ]] || fail "keeper-2 の画面から起動していない"
: > "$T/go-11.1"
finished "同じ名前があるとき"; wait_for "$LIMIT" hasnt keeper-2 || fail "keeper-2 が閉じない"
has keeper || fail "元からあった同じ名前のセッションに触った"
tm new-session -d -s "$long100" -- /bin/sleep 900 || fail "100 字の名前のセッションを作れない（用意が誤り）"
run "$DR" "$CWD" -- --tmux "$long100" --linger 0 "$T/logs/same.log" /usr/bin/true
launched "100 字の名前で、同じ名前があるとき"; finished "100 字の名前で、同じ名前があるとき"
tm kill-session -t "=$long100"
for i in 2 3 4 5 6 7 8 9; do tm new-session -d -s "keeper-$i" -- /bin/sleep 900 || fail "keeper-$i を作れない（用意が誤り）"; done
run "$DR" "$CWD" -- --tmux keeper --linger 0 "$T/logs/same.log" /usr/bin/touch "$T/started-11"
stopped "同じ名前が 9 つとも埋まっている" 2 "$MSG_MANY" "$T/started-11"
[[ "$(sessions)" == "keeper keeper-2 keeper-3 keeper-4 keeper-5 keeper-6 keeper-7 keeper-8 keeper-9 " ]] \
  || fail "同じ名前が埋まっていて起動をやめたとき、元からあったセッションに触った（今あるもの: $(sessions)）"
for i in 2 3 4 5 6 7 8 9; do tm kill-session -t "=keeper-$i"; done
no_work || fail "同じ名前が埋まっていたとき、受け渡しの一時フォルダを残した"
pass "同じ名前のセッションがあれば <名前>-2 を使い（標準エラーに決まった 1 行）、元のセッションには触らない。100 字の名前でも同じ。9 つとも埋まっていれば exit 2"

# ---- 12. 失敗では、コマンドを始めず、セッションも一時フォルダも残さない ----
quiet() {   # <説明>: セッションが keeper だけで、受け渡しの一時フォルダが無いこと
  wait_for "$LIMIT" eval '[[ "$(sessions)" == "keeper " ]]' || fail "$1: セッションを残した（今あるもの: $(sessions)）"
  no_work || fail "$1: 受け渡しの一時フォルダを残した"
}
# 付けないときと同じ文言・終了コード（共通の失敗）
run "$DR" "$CWD" -- "$T/logs/12-plain.log" "$T/no-such-command" FAKE-ARG-MARK
stopped "付けない起動・無いコマンド（基準）" 2 "$MSG_SPAWN"
run "$DR" "$CWD" -- --tmux lt-fail --linger 0 "$T/logs/12-tmux.log" "$T/no-such-command" FAKE-ARG-MARK
stopped "--tmux・無いコマンド" 2 "$MSG_SPAWN"
cmp -s "$T/logs/12-plain.log" "$T/logs/12-tmux.log" && [[ "$(<"$T/logs/12-tmux.log")" == "$HEADER" ]] \
  || fail "--tmux・無いコマンド: 起動ログに見出しのほかのもの（引数・例外の本文）が出ている・付けないときと違う"
quiet "--tmux・無いコマンド"
reset_calls
print -r -- 'ファイル' > "$T/plain-file"
run "$DR" "$CWD" -- --tmux lt-fail "$T/plain-file/sub/e.log" /usr/bin/touch "$T/started-12"
stopped "--tmux・起動ログのフォルダを作れない" 1 "$MSG_MKDIR" "$T/started-12"
run "$DR" "$CWD" -- --tmux lt-fail "$T/logs" /usr/bin/touch "$T/started-12"
stopped "--tmux・起動ログがフォルダ" 2 "$MSG_OPEN" "$T/started-12"
ln -s "$T/link-target.log" "$T/logs/link.log"
run "$DR" "$CWD" -- --tmux lt-fail "$T/logs/link.log" /usr/bin/touch "$T/started-12"
stopped "--tmux・起動ログが symlink" 2 "$MSG_OPEN" "$T/started-12"
[[ ! -e "$T/link-target.log" ]] || fail "--tmux・起動ログが symlink: その先へ書いた"
# 一時フォルダを作れない: 別の場所（TEMP・TMP・作業場所）へ逃がさない
mkdir -p "$T/alt-tmp" "$T/cwd12"
run "$DR" "$T/cwd12" TMPDIR="$T/no-such-tmp/" TEMP="$T/alt-tmp" TMP="$T/alt-tmp" -- --tmux lt-fail "$T/logs/12.log" /usr/bin/touch "$T/started-12"
stopped "--tmux・一時フォルダを作れない" 2 "$MSG_WORK" "$T/started-12"
left=("$T"/alt-tmp/*(DN) "$T"/cwd12/*(DN)); (( ! ${#left} )) || fail "一時フォルダを作れないとき、別の場所へ逃がした"
# 作業場所を開けない（入ることはできるが、読めないフォルダ）。実際に読めなくなったときだけ判定する（管理者の権限で回すと、
# 権限を外しても読めるので、この場面にならない）
mkdir -p "$T/noread12"; chmod 300 "$T/noread12"
if [[ ! -r "$T/noread12" ]]; then
  run "$DR" "$T/noread12" -- --tmux lt-fail "$T/logs/12.log" /usr/bin/touch "$T/started-12"
  stopped "--tmux・読めない作業場所" 2 "$MSG_CWD" "$T/started-12"
fi
chmod 700 "$T/noread12"
[[ "$(ncalls)" == 0 ]] || fail "起動の前に分かる失敗（起動ログ・一時フォルダ・作業場所）なのに、tmux を呼んだ"
# セッションを作れない（tmux が断る）
wrap_mode refuse
run "$DR" "$CWD" -- --tmux lt-fail "$T/logs/12.log" /usr/bin/touch "$T/started-12"
wrap_mode
stopped "--tmux・セッションを作れない" 2 "$MSG_SESSION" "$T/started-12"
# 起動ログを読めない（書き込みだけ許したファイル）: 画面へ流せないので起動しない
print -rn -- '' > "$T/logs/writeonly.log"; chmod 200 "$T/logs/writeonly.log"
if [[ ! -r "$T/logs/writeonly.log" ]]; then
  run "$DR" "$CWD" -- --tmux lt-fail "$T/logs/writeonly.log" /usr/bin/touch "$T/started-12"
  stopped "--tmux・起動ログを読めない" 2 "$MSG_LOG" "$T/started-12"
fi
chmod 600 "$T/logs/writeonly.log"
quiet "失敗の後"
# 本体が tmux に頼む操作は、セッションを作る・同じ名前があるか聞く、の 2 つだけ（閉じる・ほかのセッションを指す操作をしない）。
# 接続先を指す引数（-S・-L）を付けない（付けていたら、入口が本物の tmux を呼ぶ前に断って、上の run が赤にしている）
n=0
for f in "$CALLS"/*.args(N); do
  n=$(( n + 1 )); call_args "${f:t:r}"
  [[ "${reply[1]}" == (new-session|has-session) ]] || fail "本体が tmux に、決めた 2 つのほかの操作を頼んだ: ${reply[1]}"
  [[ "${reply[1]}" != has-session || "${(j: :)reply}" == "has-session -t =lt-fail" ]] || fail "本体が、自分の名前のほかのセッションを指した"
  (( ! ${reply[(Ie)-S]} && ! ${reply[(Ie)-L]} )) || fail "本体が tmux に、接続先を指す引数（-S・-L）を付けた"
done
(( n >= 2 )) || fail "tmux の呼び出しの記録が無い（用意が誤り）"
pass "失敗（無いコマンド・起動ログが使えない・読めない・一時フォルダを作れない・読めない作業場所・セッションを作れない）では、付けないときと同じ文言と終了コードか、決まった文言で exit 2。コマンドを始めず、セッションも一時フォルダも残さない。tmux に頼む操作は new-session と has-session だけ"

# ---- 13. 起動ログを開いた後で別のファイルへ置き換えられたら、起動しない・その中身を画面へ流さない ----
print -r -- "PRIVATE-SWAP" > "$T/private.txt"
wrap_mode swap
run "$DR" "$CWD" -- --tmux lt-swap --linger 30 "$T/swap.log" /bin/sh -c 'echo child-output; : > "$0"' "$T/started-13"
wrap_mode
[[ ! -e "$T/private.txt" && "$(<"$T/swap.log")" == PRIVATE-SWAP ]] || fail "起動ログが置き換わっていない・置き換えた先へ書いた（用意が誤り、または照合の前に書いた）"
if has lt-swap && screen_has lt-swap PRIVATE-SWAP; then fail "起動ログを置き換えた先（子が書いていないファイル）の中身を、画面へ流した"; fi
stopped "起動ログを開いた後で置き換えられた" 2 "$MSG_LOG" "$T/started-13"
quiet "起動ログを開いた後で置き換えられた"
pass "起動ログを開いた後で別のファイルへ置き換えられたら、起動せず（exit 2）、その中身を画面へ流さない"

# ---- 14. 画面の中の親が動き出す前に、呼び出し元を止める・期限が来る ----
# 画面の中の親は、テストが合図のファイル（release-pane）を作るまで動かさない（包みの hold）。止める合図のテストは、期限だけを長くした
# 写しで回す（終わる理由が、止める合図だけになる。期限と競わない）
release_pane() {   # <セッション>: 遅らせていた画面の中の親を動かして、セッションが自分で閉じるのを待つ
  : > "$T/release-pane"
  wait_for "$LIMIT" hasnt "$1" || fail "$1: 画面の中の親が動き出した後、セッションが自分で閉じない"
  rm -f -- "$T/release-pane"
}
wrap_mode hold
run_bg "$DR_LONG" "$CWD" -- --tmux lt-term --linger 0 "$T/logs/14.log" /usr/bin/touch "$T/started-14"
wait_for "$LIMIT" has lt-term || fail "セッションができない（用意が誤り）"
job_running "$caller" || fail "呼び出し元が、画面の中の親を待たずに終わった（用意が誤り）"
kill -TERM "$caller"
end_bg "$LIMIT" "止める合図（TERM）"
stopped "止める合図（TERM）" 2 "$MSG_STOP" "$T/started-14"
no_work || fail "止める合図（TERM）: 受け渡しの一時フォルダを片付けていない"
release_pane lt-term
run_bg "$DR_LONG" "$CWD" -- --tmux lt-kill --linger 0 "$T/logs/14.log" /usr/bin/touch "$T/started-14"
wait_for "$LIMIT" has lt-kill || fail "セッションができない（用意が誤り）"
job_running "$caller" || fail "呼び出し元が、画面の中の親を待たずに終わった（用意が誤り）"
kill -KILL "$caller"
end_bg "$LIMIT" "強制終了（KILL）"
release_pane lt-kill
sleep 0.3
[[ ! -e "$T/started-14" && ! -s "$T/out" ]] || fail "呼び出し元を止めた・強制終了したのに、コマンドが始まった・pid を出した"
# 強制終了では片付けられない（空のフォルダとソケットが 1 つ残る。文書に書いた、残る場面）。ここで消す
left=("$TMPD"/lanes-detach-*(N)); (( ${#left} <= 1 )) || fail "強制終了の後に、受け渡しの一時フォルダが 2 つ以上残っている"
rm -rf -- "$TMPD"/lanes-detach-*(N)
# 外から止めなくても、期限で終わる（期限だけを短くした写し）。相手は、返事をしないまま
#  a. セッションはできたが、画面の中の親がつながってこない
run_bg "$DR_SHORT" "$CWD" -- --tmux lt-late --linger 0 "$T/logs/14.log" /usr/bin/touch "$T/started-14"
end_bg "$LIMIT" "つながってこない相手の期限"
stopped "つながってこない相手の期限" 2 "$MSG_TALK" "$T/started-14"
no_work || fail "つながってこない相手の期限: 受け渡しの一時フォルダを片付けていない"
release_pane lt-late
#  b. tmux そのものが返事をしない（包みが、合図まで何もしないで待つ）。検査対象が、期限で止めて片付ける
wrap_mode hang
run_bg "$DR_SHORT" "$CWD" -- --tmux lt-hang --linger 0 "$T/logs/14.log" /usr/bin/touch "$T/started-14"
end_bg "$LIMIT" "返事をしない tmux の期限"
wrap_mode
stopped "返事をしない tmux の期限" 2 "$MSG_TALK" "$T/started-14"
no_work || fail "返事をしない tmux の期限: 受け渡しの一時フォルダを片付けていない"
[[ -s "$T/hang.pid" ]] || fail "返事をしない tmux の役が動いていない（用意が誤り）"
wait_for "$LIMIT" gone "$(<"$T/hang.pid")" || { : > "$T/release-hang"; fail "返事をしない tmux を、期限の後も残した（止めていない）"; }
quiet "期限の後"
pass "利用者が受け取る pid へ止める合図（TERM）を送ると、exit 2 で pid を出さず、一時フォルダを片付け、コマンドは始まらない。強制終了（KILL）でも、コマンドは始まらず、セッションは自分で閉じる。外から止めなくても、画面の中の親がつながってこない・tmux が返事をしないときは、期限で exit 2 になり、片付ける"

# ---- 15. 呼び出し元の側: テストが相手役（画面の中の親）になる ----
# 相手役: fake-pane.py <一時領域> <受け渡しのフォルダ> <場面>。つないで中身を受け取り、場面ごとに返事をする。受け取ったことは名前だけ記録する
cat > "$T/fake-pane.py" <<'EOF_PANE'
import os, socket, sys
T, work, scene = sys.argv[1:4]
def note(text):
    with open(os.path.join(T, "pane.note"), "a") as f:
        f.write(text + "\n")
conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
os.chdir(work); conn.connect("s"); os.chdir("/")
mark, extra = conn.recvmsg(1, socket.CMSG_SPACE(12))[:2]
if not mark:
    note("request none")      # 相手（呼び出し元）が、何も送らずに口を閉じた
    sys.exit(0)
def recv_exact(size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            note("request cut")
            sys.exit(0)
        data += chunk
    return data
parts = recv_exact(int(recv_exact(20))).split(b"\0")
note("request mark=%s fds=%d fields=%s env-has-mark=%s" % (
    mark.decode(), len(extra[0][2]) // 4 if extra else 0, b" ".join(parts[:4]).decode(), any(p.startswith(b"FAKE_SECRET_MARK=") for p in parts)))
if scene == "close-before-pid":
    sys.exit(0)
if scene == "hold":
    # pid を返さずに、相手が口を閉じる（か、合図を書く）まで待つ。期限は置かない（相手が居なくなれば、口が閉じる）
    note("gate %s" % (conn.recv(1).decode() or "closed"))
    sys.exit(0)
conn.sendall(b"%020d" % 424242)
if scene == "close-after-pid":
    sys.exit(0)
note("gate %s" % (conn.recv(1).decode() or "closed"))
conn.sendall({"passed": b"G", "failed": b"GF", "vanished": b""}[scene])
EOF_PANE
# 中身の頭の期待値: 「--linger の秒・umask（10 進）・無視にしたシグナル・コマンドの語の数」。umask はテストが決めた 027（= 23）。
# 無視にしたシグナルは、同じ起動のしかた（同じ run・同じ直前の用意）で動かした小さいスクリプトに、検査対象と同じ式で数えさせる
# （起動元がもともと無視にしているシグナルがあっても、同じだけ入る）
print -r -- 'import signal'$'\n''print(",".join(str(s) for s in range(1, signal.NSIG) if signal.getsignal(s) == signal.SIG_IGN and s not in (signal.SIGPIPE, signal.SIGXFSZ)))' > "$T/sigbase.py"
print -r -- '#!/bin/zsh -f'$'\n''exec "$1" -I -S "$2"' > "$T/sigbase.zsh"
run_pre="$origin_pre"
run "$T/sigbase.zsh" "$CWD" -- "$REAL" "$T/sigbase.py"
run_pre=':'
ignored_want="$(<"$T/out")"
[[ "$rc" == 0 && ",$ignored_want," == *,1,* ]] || fail "無視にしたシグナルの基準を採れない（用意が誤り）"
pane_scene() {   # <場面> [入口（省くと、候補を包みに置き換えた写し）]
  rm -f -- "$T/pane.note"
  wrap_mode "pane:$1"
  run_pre="$origin_pre"
  run "${2:-$DR}" "$CWD" "${t8_env[@]}" -- --tmux lt-pane --linger 7 "$T/logs/15.log" /usr/bin/touch "$T/started-15" 引数
  run_pre=':'
  wrap_mode
}
requested() {   # <場面>: 相手役が、決まった形の中身を受け取っていること
  [[ "$(sed -n 1p "$T/pane.note" 2>/dev/null)" == "request mark=F fds=3 fields=7 23 $ignored_want 3 env-has-mark=True" ]] \
    || { cat "$T/pane.note" >&2 2>/dev/null || true; fail "相手役（$1）が、決まった形の中身（fd 3 つ・--linger・umask・無視にしたシグナル・コマンドの語の数・環境変数）を受け取っていない"; }
}
for scene in close-before-pid close-after-pid; do
  pane_scene "$scene"; requested "$scene"; stopped "相手役の画面の中の親（$scene）" 2 "$MSG_TALK" "$T/started-15"
done
pane_scene vanished; requested vanished; stopped "相手役の画面の中の親（通った印が無いまま口が閉じた）" 2 "$MSG_TALK" "$T/started-15"
grep -qx 'gate A' "$T/pane.note" || fail "pid を受け取ったのに、門を開ける合図を書いていない（用意が誤り）"
pane_scene failed; requested failed; stopped "相手役の画面の中の親（失敗の印）" 2 "$MSG_SPAWN" "$T/started-15"
pane_scene passed; requested passed
launched "相手役の画面の中の親（通った印）"
[[ "$pid" == 424242 && ! -s "$T/err" ]] || fail "通った印が返ったのに、受け取った pid をそのまま出していない・標準エラーに出力がある"
# 相手が同じ利用者だと OS が言わないとき（「相手の利用者番号を返す行」だけを置き換えた写し。確かめる行そのものは、検査対象のまま）:
# 環境変数・コマンド・fd を送らずに、決まった文言で exit 2。相手役は、頼まれれば最後まで進める役（passed）なので、確かめが無ければ
# 成功（pid を出して exit 0）になる
mkedit copy-wrap-peer-other "$DR" "$PEER_LINE" '    return os.geteuid() + 1'; DR_OTHER="$REPLY"
mkedit copy-wrap-peer-none "$DR" "$PEER_LINE" '    return None'; DR_NOPEER="$REPLY"
for v in "$DR_OTHER" "$DR_NOPEER"; do
  pane_scene passed "$v"
  stopped "相手が同じ利用者だと確かめられない（${v:t:r}）" 2 "$MSG_PEER" "$T/started-15"
  wait_for "$LIMIT" test -s "$T/pane.note" || fail "相手役が動いていない（用意が誤り。${v:t:r}）"
  [[ "$(<"$T/pane.note")" == 'request none' ]] \
    || fail "相手が同じ利用者だと確かめる前に、環境変数・コマンド・fd を送った・門を開けた（${v:t:r}）: $(tr '\n' ' ' < "$T/pane.note" | cut -c1-80)"
  quiet "相手が同じ利用者だと確かめられない（${v:t:r}）"
done
# pid を返さない相手に、止める合図: 門を開ける合図を書かずに終わる（相手役から見ると、合図が来ないまま口が閉じる）。
# 期限だけを長くした写しで回す（終わる理由が、止める合図だけになる）
rm -f -- "$T/pane.note"; wrap_mode pane:hold
run_bg "$DR_LONG" "$CWD" -- --tmux lt-pane --linger 0 "$T/logs/15.log" /usr/bin/touch "$T/started-15"
wait_for "$LIMIT" grep -q '^request ' "$T/pane.note" || fail "相手役（hold）が中身を受け取っていない（用意が誤り）"
job_running "$caller" || fail "呼び出し元が、pid を待たずに終わった（用意が誤り）"
no_work || fail "画面の中の親がつながった後も、受け渡しの一時フォルダが残っている（つながったら、すぐ消す。この後で強制終了されても残さない）"
kill -TERM "$caller"
end_bg "$LIMIT" "pid を待っている間の止める合図"
stopped "pid を待っている間の止める合図" 2 "$MSG_STOP" "$T/started-15"
wait_for "$LIMIT" grep -qx 'gate closed' "$T/pane.note" || { cat "$T/pane.note" >&2; fail "止める合図を受けた呼び出し元が、門を開ける合図を書いた（または口を閉じていない）"; }
quiet "pid を待っている間の止める合図の後"
# 外から止めなくても、期限で終わる（期限だけを短くした写し）: つながった相手が、pid を返さないまま
rm -f -- "$T/pane.note"
run_bg "$DR_SHORT" "$CWD" -- --tmux lt-pane --linger 0 "$T/logs/15.log" /usr/bin/touch "$T/started-15"
end_bg "$LIMIT" "pid を返さない相手の期限"
wrap_mode
stopped "pid を返さない相手の期限" 2 "$MSG_TALK" "$T/started-15"
no_work || fail "pid を返さない相手の期限: 受け渡しの一時フォルダを片付けていない"
quiet "pid を返さない相手の期限の後"
if grep -qx 'gate A' "$T/pane.note" 2>/dev/null; then fail "pid を返さない相手に、門を開ける合図を書いた"; fi
pass "呼び出し元の側: pid の前後で口が閉じた・通った印が無い・失敗の印 → exit 2（コマンドは始まっていない文言）。通った印 → pid を出して exit 0。相手が同じ利用者だと OS が言わない（別の利用者の番号・取れない）ときは、何も送らずに exit 2。pid を返さない相手には、止める合図でも期限でも、門を開ける合図を書かずに終わる"

# ---- 16. chk-run.sh の直後に --tmux で起動したレビューが、親の記録を使い回す ----
# test-review-reuse-launch.sh の 1 と同じ形（偽の CLI の本物の起動）。空の環境と作り物の変数だけで回す
STUBS="$LANES_DIR/tests/stubs"
mkdir -p "$T/reuse" "$T/reuse-home"
cat > "$T/reuse.zsh" <<'EOF_REUSE'
#!/bin/zsh -f
set -euo pipefail
source "$LANES_DIR/tests/_git-isolate.sh"; lanes_test_git_isolate
R="$TMPDIR"; R="${R%/}"
fail() { print -u2 -- "FAIL: $*"; exit 1; }
base="$R/wt-base"; wt="$R/wt"
git init -q -b main "$base"; lanes_test_assert_repo "$base"
print -r -- $'node_modules/\ndist/\nlogs/' > "$base/.gitignore"
mkdir -p "$base/src"; print -r -- 'export const a = 1' > "$base/src/a.ts"
git -C "$base" add -A
git -C "$base" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'test: 初期化'
git -C "$base" worktree add -q -b feat/wt "$wt"
git -C "$wt" update-ref refs/remotes/origin/develop HEAD
print -r -- 'export const b = 2' > "$wt/src/b.ts"; git -C "$wt" add -A
git -C "$wt" -c user.name="Test User" -c user.email=you@example.com -c commit.gpgSign=false commit -qm 'feat: b を足す'
mkdir -p "$wt/node_modules/pkg" "$wt/dist"
print -r -- '{"name":"pkg","version":"1.0.0"}' > "$wt/node_modules/pkg/package.json"; print -r -- built > "$wt/dist/a.js"
print -r -- '担当の確認だけを行う。' > "$R/prompt.md"
out="$(bash "$LANES_DIR/chk-run.sh" "$wt" 49995 "$R/chk-out" 2>&1)" || { print -u2 -r -- "$out"; fail "chk-run.sh が失敗"; }
[[ "$out" == *'recorded=tree '* ]] || fail "chk-run.sh が記録しない"
[[ "$(bash "$LANES_DIR/chk-run.sh" "$wt" --query 2>/dev/null || true)" == reuse=yes* ]] || fail "直後の問い合わせが reuse=yes にならない（用意が誤り）"
pid="$(zsh -f "$DR" --tmux lt-reuse --linger 0 "$wt/logs/launch.log" zsh -f "$LANES_DIR/run-review.sh" "$wt" "$R/prompt.md" rev-tmux-r1 --base origin/develop --round 1)" \
  || fail "--tmux でレビューを起動できない"
n=0
while kill -0 "$pid" 2>/dev/null; do
  n=$(( n + 1 )); (( n <= 600 )) || fail "レビューが 60 秒で終わらない（番号 $pid のプロセスが居る。止めていない）"
  sleep 0.1
done
grep -qx 'EXIT:0' "$wt/logs/rev-tmux-r1.done" || { cat "$wt/logs/launch.log" >&2; fail "レビューが失敗で終わった"; }
grep -q '^- 必須検証: 親の chk-run の記録を使用（head ' "$wt/logs/rev-tmux-r1.evidence.md" \
  || { grep '必須検証' "$wt/logs/rev-tmux-r1.evidence.md" >&2 || true; fail "証跡が記録の使用になっていない"; }
grep -q '親が同じ中身で実施済み' "$wt/logs/rev-tmux-r1.prompt.md" || fail "指示書に「回さないこと」が入っていない"
if grep -q '記録は使わない' "$wt/logs/rev-tmux-r1.evidence.md"; then fail "証跡に「使わない」が残っている"; fi
EOF_REUSE
partial=""
if [[ "$T" == *$'\n'* ]]; then
  # chk-run.sh は、改行を含む作業ツリーのパスでは、--tmux を付けない起動でも記録を使い回せない（test-review-reuse-launch.sh も同じ所で止まる）
  partial="一時領域の名前に改行があるので、chk-run.sh の記録の使い回し（16）は確かめていない（chk-run.sh の側の制限。--tmux とは別の件）"
else
  rc=0
  /usr/bin/env -i HOME="$T/reuse-home" LOGNAME=fake-user PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" LANES_DIR="$LANES_DIR" DR="$DR" \
    LANES_CONF="$T/no-such.conf" LANES_NOTIFY=0 LANES_TOOLS="claude codex" LANES_SCRATCH_ROOT="$T/reuse/scratch" TMPDIR="$T/reuse/" LANES_SCRATCH="$T/reuse" \
    XDG_STATE_HOME="$T/reuse/state" CLAUDE_BIN="$STUBS/claude" CODEX_BIN="$STUBS/codex" CHK_CACHE="$T/reuse/chk-cache/passed.tsv" LANES_CHECK_CMD=/usr/bin/true \
    PYTHONPYCACHEPREFIX="$T/reuse/pycache" /bin/zsh -f "$T/reuse.zsh" > "$T/reuse.out" 2>&1 || rc=$?
  (( rc == 0 )) || { cat "$T/reuse.out" >&2; fail "chk-run.sh の直後に --tmux で起動したレビューが、親の記録を使い回さない（rc=$rc）"; }
  wait_for "$LIMIT" hasnt lt-reuse || fail "レビューのセッションが閉じない"
  pass "chk-run.sh の直後に --tmux で起動したレビュー（偽の CLI の本物の起動）が、親の記録を使い回す"
fi

# ---- 17. 後片付けの確かめ ----
wait_for "$LIMIT" hasnt lt-pane || fail "相手役のセッションが閉じない"
entry_ok
[[ "$(sessions)" == "keeper " ]] || fail "セッションが残っている（今あるもの: $(sessions)）"
no_work || fail "受け渡しの一時フォルダが残っている"
tm capture-pane -p -J -t '=keeper:' > /dev/null || fail "サーバーに問い合わせできない（用意が誤り）"
rc=0; grep -rqaF -D skip -- "$SECRET" "$T" 2>/dev/null || rc=$?      # ソケットなどは読まない
[[ "$rc" == 1 ]] || fail "一時領域のどこかに、環境変数の値（鍵のつもりの印）が書かれた・確かめられない（grep rc=$rc）"
tm show-environment -g > /dev/null || fail "サーバーの既定の環境を照会できない"
if tm show-environment -g | grep -qaF -- "$SECRET"; then fail "tmux のサーバーの既定の環境に、呼び出し元の環境変数の値が入った"; fi
pass "セッションと受け渡しの一時フォルダを残さない。一時領域のどこにも、tmux のサーバーの環境にも、環境変数の値を書いていない"

[[ -z "$partial" ]] || print -r -- "LANES_PARTIAL: $partial"
print -r -- "合格 $count 件"
