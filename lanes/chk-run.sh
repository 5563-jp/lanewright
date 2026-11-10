#!/bin/bash
# chk-run.sh — 統合先（LANES_BASE_BRANCH）に入れる直前の最終 head で回す手元確認の共通本体。同じ確認を繰り返さない
# 使い方: chk-run.sh <worktree> <port> <outdir> [--merge <ref>] [--force]
#         chk-run.sh <worktree> --query   （回さずに、確認済みの記録を使い回せるかだけ答える。下の「問い合わせ」）
#   回す確認コマンドは次の順で決める（どちらも無ければ exit 2 で設定方法を出す）:
#     1) 対象リポの .lanes/check.sh（あれば優先。bash で worktree を作業場所にして実行）
#     2) 設定キー LANES_CHECK_CMD（例: pnpm lint && pnpm typecheck && pnpm build。bash -c で実行）
#   確認コマンドには LANES_CHECK_PORT（<port>。画面確認用のサーバーを立てるならこの番号を使う）と
#   LANES_CHECK_OUTDIR（<outdir>）を渡す。出力の行は head= / check= / recorded= の形。通ったのに記録しないときは
#   record=no reason=<uncommitted|unresolvable>（理由の説明）を出す（黙って記録しないままにしない）
#   確認コマンドは共通監督役（_common.sh の LANES_PROCESS_GUARD）の下で起動し、裏で立てたサーバー等の孫まで回収する
# 省くもの:
#   同じ中身（git tree）かつ同じ実行環境・依存状態・確認コマンドを前に通していたら、何も回さない（skip=same-tree）
#   確認コマンドは、コマンド文字列（.lanes/check.sh なら中身）と、各コマンドの先頭の実行ファイル（PATH で解決した先と
#   その #! の解釈系）の中身の指紋まで比べる。確実に解決できない書き方（PATH の付け替え・cd・exec/env 等の包み・
#   関数・source・eval・サブシェル・パイプ・コマンド置換・変数で組み立てた名前など）が 1 つでもあれば回すだけで記録しない
#   ファイル名だけでは一括読み込み・生成コードの依存を否定できないため、差分があれば全部回す。
#   --force で必ず全部回す。追跡・未追跡ファイルに未 commit の変更があるとき、変更検知を省略する設定
#   （assume-unchanged / skip-worktree）があるときは記録も省略もしない。追跡ファイルは内容も照合する
#   サブモジュールの中（checkout した commit・追跡・未追跡・無視対象）も入力に含める。共有依存のリンクや
#   読めないファイルがあると再利用だけ止め、検証前後の入力照合は続ける
#   ランチャの記録（作業ツリー直下の logs/ の直下に、ランチャと detach-run.sh が書くファイル）は入力に数えない。
#   レーンを起動・終了するたびに増えるので、数えると「chk-run の直後にレビューを起動する」だけで記録が使えなくなる
#   （起動ログ logs/launch.log を detach-run.sh が先に書くため）。名前が記録に似ているだけでは外さない。数えないのは、
#   ランチャが書く前に台帳（logs/.lanes-records）へ載せた持ち主の、決まった名前のファイルだけ（下の「ランチャの記録」の説明）。
#   台帳に無い名前（確認コマンドが読む logs/input.json など）・logs/ の中のフォルダ・リンク・追跡ファイルは今までどおり入力
#   生成物（dist/ など）の定義は _common.sh の LANES_GENERATED_DIRS / LANES_GENERATED_SUFFIXES（cleanup-after-merge.sh と同じもの）
# 確認済みの記録: ${CHK_CACHE:-${LANES_RUNS_ROOT:-~/dev/_runs}/_chk-cache/passed.tsv}
#   （tree<TAB>head<TAB>full<TAB>日時<TAB>worktree<TAB>input_fp<TAB>port<TAB>outdir）。port と outdir は問い合わせが同じ条件で照合し直すために残す
# 問い合わせ（--query）: 確認コマンドを一切実行せず、記録も出力先も作らない（fetch もしない）。skip=same-tree になる条件
#   （tree・入力の指紋・確認コマンドの指紋）をそのまま使い、記録に残した port と outdir で指紋を計算し直して照合する。
#   使い回せる: 1 行目 reuse=yes、続けて head= / recorded= / check=（.lanes/check.sh か LANES_CHECK_CMD）を出して exit 0
#   使えない  : reuse=no reason=<理由> を出して exit 1（no-check / no-record / cache-link / uncommitted / unresolvable / input-changed / state-error）
#   使い方の誤り（worktree が無い・git でない・他の引数と組み合わせた）は exit 2
#   指紋には環境変数も入るので、親が chk-run.sh を回したのと同じ環境から呼ぶ（レビューランチャは起動直後に呼ぶ）
set -u
# 設定ファイル（LANES_CONF）の LANES_CHECK_CMD / LANES_RUNS_ROOT などを受け取るため、最初の 1 回だけ zsh で
# lanes.env を読み（設定キーが export される）、そのまま bash で自分を起動し直す。環境変数で渡した値は設定ファイルに勝つ
if [ -z "${LANES_CHK_ENV_LOADED:-}" ] && [ -f "$(dirname "$0")/lanes.env" ]; then
  export LANES_CHK_ENV_LOADED=1
  exec zsh -fc 'source "$1" || exit 2; shift; exec bash "$@"' chk-run "$(dirname "$0")/lanes.env" "$0" "$@"
fi
usage="使い方: chk-run.sh <worktree> <port> <outdir> [--merge <ref>] [--force] / chk-run.sh <worktree> --query"
query=0
if [ $# -ge 2 ] && [ "$2" = "--query" ]; then
  # 問い合わせは他の引数と組み合わせない（--merge・--force は回すときだけの指定）
  [ $# -eq 2 ] && [ -n "$1" ] || { echo "$usage" >&2; exit 2; }
  query=1; wt=$1; port=""; o=""; shift 2
else
  [ $# -ge 3 ] || { echo "$usage" >&2; exit 2; }
  wt=$1; port=$2; o=$3; shift 3
  [ -n "$wt" ] && [ -n "$port" ] && [ -n "$o" ] || { echo "$usage" >&2; exit 2; }
  case "$port" in
    ''|*[!0-9]*) echo "不正な port: $port" >&2; exit 2 ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "不正な port: $port" >&2; exit 2
  fi
fi
merge=""; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --merge) [ $# -ge 2 ] && [ -n "$2" ] || { echo "--merge に値が無い" >&2; exit 2; }; merge=$2; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
done
# レビューの入口・ランチャだけが持つ制御の値は、確認コマンドに渡さない（渡すと結果を変えられるのに、指紋の比較から外しているため）。
# 回すときも問い合わせ（--query）のときも同じに消すので、指紋の比較から外しても確認の結果とずれない
unset LANES_ENTRY_PREFLIGHT LANES_REVIEW_REUSE_CHECKS
cache=${CHK_CACHE:-${LANES_RUNS_ROOT:-$HOME/dev/_runs}/_chk-cache/passed.tsv}
lanes_dir=$(cd "$(dirname "$0")" && pwd -P) || exit 2
if [ "$query" = 1 ]; then
  # 問い合わせは何も作らない。記録のフォルダが無ければ記録も無い（照合の段で no-record）
  cache_dir=$(cd "$(dirname "$cache")" 2>/dev/null && pwd -P) || cache_dir=""
  [ -z "$cache_dir" ] || cache="$cache_dir/$(basename "$cache")"
else
  mkdir -p "$o" "$(dirname "$cache")" && touch "$cache" || { echo "出力先またはキャッシュを作成できない" >&2; exit 2; }
  o=$(cd "$o" && pwd -P) || { echo "出力先を解決できない: $o" >&2; exit 2; }
  cache_dir=$(cd "$(dirname "$cache")" && pwd -P) || { echo "キャッシュ先を解決できない: $cache" >&2; exit 2; }
  cache="$cache_dir/$(basename "$cache")"
fi
cd "$wt" || { echo "worktree が無い: $wt" >&2; exit 2; }
wt=$(pwd -P) || exit 2
if [ -e "$wt/.git" ]; then
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "git 作業ツリーではない: $wt" >&2; exit 2; }
# 確認コマンドを決める。.lanes/check.sh が優先、無ければ LANES_CHECK_CMD。どちらも無ければ何も回さず止める
pick_check() {
  if [ -f "$wt/.lanes/check.sh" ] && [ ! -L "$wt/.lanes/check.sh" ]; then
    check_src=".lanes/check.sh"
    check_cmd='exec bash ./.lanes/check.sh'
  elif [ -n "${LANES_CHECK_CMD:-}" ]; then
    check_src="LANES_CHECK_CMD"
    check_cmd=$LANES_CHECK_CMD
  else
    {
      echo "確認コマンドが設定されていない。次のどちらかを用意する:"
      echo "  1) 対象リポに .lanes/check.sh を置く（例: pnpm lint && pnpm typecheck && pnpm build を書く）"
      echo "  2) 設定ファイル（\${LANES_CONF:-~/.config/lanewright/lanes.conf}）か環境変数で LANES_CHECK_CMD=\"pnpm lint && pnpm typecheck && pnpm build\" を指定する"
    } >&2
    return 2
  fi
}
if [ "$query" = 1 ]; then
  pick_check 2>/dev/null || { echo "reuse=no reason=no-check"; exit 1; }
else
  pick_check || exit 2
fi
# 出力先がソースと同じ場所でも、自身の出力ファイルだけを扱う。
output_names=(fetch.log merge.log check.log check-state.json)
check_outputs() {
python3 - "$wt" "$o" "$cache" "${output_names[@]}" <<'PY_OUTPUT'
import os, subprocess, sys
wt, outdir, cache = sys.argv[1:4]
def collect_tracked(root_dir, visited=None):
    if visited is None:
        visited = set()
    real_root = os.path.realpath(root_dir)
    if real_root in visited:
        return set()
    visited.add(real_root)
    found = set()
    for raw in subprocess.check_output(["git", "ls-files", "-z"], cwd=root_dir).split(b"\0"):
        if not raw:
            continue
        full = os.path.abspath(os.path.join(root_dir, os.fsdecode(raw)))
        found.add(full)
        if os.path.isdir(full) and not os.path.islink(full) and os.path.exists(os.path.join(full, ".git")):
            found.update(collect_tracked(full, visited))
    return found
tracked = collect_tracked(wt)
for path in [cache] + [os.path.join(outdir, name) for name in sys.argv[4:]]:
    if path in tracked or os.path.islink(path):
        print("出力先に追跡済みファイルまたはリンクがあるため停止する", file=sys.stderr)
        sys.exit(2)
PY_OUTPUT
}
[ "$query" = 1 ] || check_outputs || exit 2
if [ "$query" = 0 ] && git remote get-url origin >/dev/null 2>&1; then
  git fetch -q origin > "$o/fetch.log" 2>&1 || { echo "fetch=FAIL"; tail -5 "$o/fetch.log" 2>/dev/null; exit 1; }
fi
if [ -n "$merge" ]; then
  git merge --no-edit "$merge" > "$o/merge.log" 2>&1 || { echo "merge=FAIL"; tail -5 "$o/merge.log"; exit 1; }
  # 取り込んだ履歴が出力先を追跡対象にしていても、検証ログでソースを上書きしない。
  check_outputs || exit 2
  # 取り込んだ履歴で .lanes/check.sh が増減していれば選び直す
  pick_check || exit 2
fi
head=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "HEAD の取得に失敗" >&2; exit 1; }
tree=$(git rev-parse --verify 'HEAD^{tree}' 2>/dev/null) || { echo "tree の取得に失敗" >&2; exit 1; }
[ "$query" = 1 ] || echo "head=${head:0:7}"

# 生成物の定義は _common.sh に 1 か所だけある（cleanup-after-merge.sh と同じものを使う）。
# 1 行目 = 作業ツリー直下のフォルダ名、2 行目 = ファイルの語尾（どちらもスペース区切り）
generated_def=$(LANES_DIR="$lanes_dir" zsh -fc 'source "$LANES_DIR/_common.sh"; print -r -- "${LANES_GENERATED_DIRS[*]}"; print -r -- "${LANES_GENERATED_SUFFIXES[*]}"' 2>/dev/null) || generated_def=""
if [ -z "$generated_def" ]; then
  if [ "$query" = 1 ]; then echo "reuse=no reason=state-error"; exit 1; fi
  echo "生成物の定義（_common.sh の LANES_GENERATED_DIRS）を読めない" >&2; exit 2
fi

# 未追跡ファイルを含む作業ツリー状態と、実行環境・導入済み依存の同一性フィンガープリントを計算する
read_state() {
python3 - "$wt" "$o" "$cache" "$lanes_dir" "$port" "$generated_def" "${output_names[@]}" <<'PY'
import hashlib, os, shutil, stat, subprocess, sys

wt, outdir, cache_path = [os.path.realpath(x) for x in sys.argv[1:4]]
top_tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=wt).split(b"\0")) - {b""}
outputs = {os.path.join(outdir, name) for name in sys.argv[7:]} | {cache_path}

def is_internal_artifact(rel_path):
    return (os.fsencode(rel_path) not in top_tracked
            and os.path.abspath(os.path.join(wt, rel_path)) in outputs)

def hash_file_hex(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

# 再利用（記録・省略）を止めた理由。人が読む説明で、最初の数件だけを出力の why= に出す（通ったのに黙って記録しないままにしない）
no_reuse = []
dirty_why = ""
def stop_reuse(why):
    global reusable
    reusable = False
    if why not in no_reuse:
        no_reuse.append(why)

def show_path(path):
    # 作業ツリーの中なら相対パスで出す
    try:
        if os.path.commonpath([wt, path]) == wt:
            return os.path.relpath(path, wt)
    except ValueError:
        pass
    return path

def file_token(path):
    # 読めない・走査中に消えたファイルで状態取得ごと失敗させない。内容を証明できないので再利用だけ止め、
    # 読めなかった事実と属性は入力に含めて検証前後の照合は続ける。
    try:
        return hash_file_hex(path)
    except OSError as error:
        stop_reuse(f"読めないファイル: {show_path(path)}")
        try:
            st = os.lstat(path)
            return f"unreadable:{error.errno}:{st.st_size}:{st.st_mtime_ns}"
        except OSError:
            return f"unreadable:{error.errno}:missing"

dirty = 0
reusable = True
h = hashlib.sha256()
# ポートは確認コマンドへ渡す LANES_CHECK_PORT を変える入力。
h.update(f"port:{sys.argv[5]}\0".encode())
# 出力先（正規化済み）も確認コマンドへ渡す LANES_CHECK_OUTDIR を変える入力。出力先 A で通った記録を B で流用しない。
h.update(b"outdir:" + os.fsencode(outdir) + b"\0")
# 確認コマンドの出どころ（.lanes/check.sh か LANES_CHECK_CMD）。中身は作業ツリーと環境変数の照合に含まれる。
h.update(f"check_src:{os.environ.get('CHK_CHECK_SRC', '')}\0".encode())
# 判定処理が変わったとき、旧条件で作った成功記録を流用しない。
for name in ("chk-run.sh", "_common.sh"):
    with open(os.path.join(sys.argv[4], name), "rb") as source:
        h.update(source.read() + b"\0")
IGNORE_ENV = {"PWD", "CHK_CHECK_SRC", "OLDPWD", "SHLVL", "_", "RANDOM", "SECONDS", "LINENO", "EPOCHSECONDS", "EPOCHREALTIME",
              # 監督役が起動ごとに振る識別子と、端末・SSH の接続ごとに変わる値。確認結果には影響しない。
              "LANES_PROCESS_TOKEN", "TERM_SESSION_ID", "ITERM_SESSION_ID", "SECURITYSESSIONID",
              "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY", "TMUX_PANE", "WINDOWID",
              # レビューの入口・ランチャだけが持つ制御の値。chk-run.sh の冒頭で消すので確認コマンドには届かない（念のため比較からも外す）
              "LANES_ENTRY_PREFLIGHT", "LANES_REVIEW_REUSE_CHECKS"}
for k in sorted(os.environ.keys()):
    if k in IGNORE_ENV:
        continue
    h.update(f"env:{k}={os.environ[k]}\0".encode("utf-8", errors="surrogateescape"))

# 確認コマンドが呼ぶ実行ファイル。コマンド文字列そのもの（.lanes/check.sh なら中身）と、
# 各コマンドの先頭の実行ファイル（PATH で解決した先）の中身の指紋を入力に含める。リポの外の実行ファイルを
# 差し替えたのに前の成功記録を使い回さないため。確実に解決できない書き方（下の一覧）が
# 1 つでもあれば同一性を証明できないので、再利用だけ止める（検証前後の入力照合は続ける）。
# 見るのは先頭の実行ファイルとその #! の解釈系まで。そこから先で読み込まれるものは追わない。
import re
# 確実に解決できない書き方。次のどれかが 1 つでもあれば、実際に呼ばれる実行ファイルを
# 特定できないので再利用を止める（回すが記録しない）:
#   PATH の付け替え（前置の代入・export 等）/ 作業場所の移動（cd 等）/ 引数のコマンドを起動する包み（exec・env・
#   command・xargs 等）/ 関数・alias の定義 / source・. / eval / サブシェル「( )」/ パイプ「|」/
#   コマンド置換「$( )」「` `」/ プロセス置換 / ヒアドキュメント「<<」/ シェルの -c / 変数・~・ワイルドカードで
#   組み立てた名前 / 閉じていない引用符
SH_SKIP = {"echo", "printf", "exit", "return", "export", "set", "unset", "local", "readonly", "declare",
           "typeset", "true", "false", ":", "read", "shift", "wait", "test", "[", "[[", "]]", "]",
           "umask", "ulimit", "type", "break", "continue", "for", "select", "fi", "done", "esac", "}", "in",
           "getopts", "let"}
SH_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{"}
SH_UNSURE = {"cd", "pushd", "popd", "exec", "env", "command", "builtin", "source", ".", "alias", "unalias",
             "eval", "hash", "enable", "shopt", "function", "time", "trap", "nohup", "nice", "xargs", "sudo",
             "timeout", "coproc"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SEPARATORS = {";", "&", "&&", "||"}
OPS = sorted([";;&", ";;", ";&", "&&", "||", "|&", "&>>", "&>", ">>", "<<<", "<<-", "<<", ">&", "<&", ">|", "<>",
              ";", "&", "|", "(", ")", "<", ">"], key=len, reverse=True)
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
PATH_WORD = re.compile(r"^PATH(\+?=|$)")
def split_words(text):
    # シェルの字句に分ける。行の境界を保ったまま、改行は「;」の区切りとして出す。「#」は語の先頭のときだけ
    # 行末までのコメント（次の行は読む）。返り値は ([(種類, 字句)], 確実に読めたか)。種類は w（語）か op（演算子）
    toks, word, sure, i, n = [], None, True, 0, len(text)
    def end():
        nonlocal word
        if word is not None:
            toks.append(("w", word))
            word = None
    while i < n:
        c = text[i]
        if c == "\\":
            if i + 1 >= n:
                return toks, False
            if text[i + 1] != "\n":  # 「\」+改行は行の継続
                word = (word or "") + text[i + 1]
            i += 2
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                return toks, False
            word = (word or "") + text[i + 1:j]
            i = j + 1
        elif c == '"':
            j, buf = i + 1, ""
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    if text[j + 1] != "\n":
                        buf += text[j:j + 2]
                    j += 2
                    continue
                if text[j] == "`" or text.startswith("$(", j):
                    sure = False
                buf += text[j]
                j += 1
            if j >= n:
                return toks, False
            word = (word or "") + buf
            i = j + 1
        elif c == "`" or text.startswith(("$(", "$'"), i) or (c in "<>" and text.startswith("(", i + 1)):
            sure = False  # コマンド置換・プロセス置換の中で何が呼ばれるかは追わない。$'…' の引用規則も追わない
            word = (word or "") + c
            i += 1
        elif c == "#" and word is None:
            j = text.find("\n", i)
            i = n if j < 0 else j  # 改行そのものは残し、次の行を区切りとして読む
        elif c in " \t\r":
            end()
            i += 1
        elif c == "\n":
            end()
            toks.append(("op", ";"))
            i += 1
        else:
            op = next((x for x in OPS if text.startswith(x, i)), None)
            if op is None:
                word = (word or "") + c
                i += 1
                continue
            if word is not None and word.isdigit() and op[0] in "<>":
                word = None  # 2>&1 の 2 はファイル記述子の番号で、コマンド名ではない
            end()
            toks.append(("op", op))
            i += len(op)
    end()
    return toks, sure
def exe_token(path, label):
    try:
        real = os.path.realpath(path)
        st = os.stat(real)
    except OSError:
        return False
    h.update(f"check_exe:{label}:".encode("utf-8", errors="surrogateescape") + os.fsencode(real)
             + f":{st.st_mode}:{file_token(real)}\0".encode())
    return True
def resolve_exe(word):
    if "/" in word:
        cand = word if os.path.isabs(word) else os.path.join(wt, word)
        return cand if os.path.isfile(cand) and os.access(cand, os.X_OK) else ""
    return shutil.which(word) or ""
def fingerprint_check_cmd(text, origin):
    h.update(f"check_cmd:{origin}:".encode() + text.encode("utf-8", errors="surrogateescape") + b"\0")
    def unsure(what, why="呼ぶ実行ファイルを確実に決められない書き方"):
        # 理由には、その語（#! の解釈系のときは台本の名前）だけを出す。引数・ほかの代入の値は出さない
        shown = what.split("#!", 1)[0]
        stop_reuse(f"確認コマンド（{origin}）の「{shown[:60]}」: {why}")
        h.update(f"check_exe:{what}:unresolved\0".encode("utf-8", errors="surrogateescape"))
    tokens, sure = split_words(text)
    if not sure:
        stop_reuse(f"確認コマンド（{origin}）に、コマンド置換・$'…'・閉じていない引用符など、読み切れない書き方がある")
        h.update(b"check_exe:<syntax>:unresolved\0")
    at_cmd, skip_next, cmd = True, False, ""
    # case 文の分岐の型（a|b) など）はコマンドではないので読み飛ばす
    case_depth, case_head, in_pattern = 0, False, False
    for kind, tok in tokens:
        if skip_next:
            skip_next = False
            continue
        if case_head:
            if kind == "w" and tok == "in":
                case_head, in_pattern = False, True
            continue
        if in_pattern:
            if kind == "w" and tok == "esac":
                case_depth, in_pattern, at_cmd = case_depth - 1, False, False
            elif kind == "op" and tok == ")":
                in_pattern, at_cmd = False, True
            continue
        if kind == "op":
            if tok in (";;", ";&", ";;&") and case_depth:
                in_pattern = True
            elif tok in SEPARATORS:
                at_cmd, cmd = True, ""
            elif tok in ("|", "|&", "(", "<<", "<<-"):
                unsure(tok)  # パイプ・サブシェル・関数の定義・ヒアドキュメント
                at_cmd, cmd = True, ""
            elif tok == ")":
                at_cmd, cmd = False, ""
            else:
                skip_next = True  # リダイレクトの行き先のファイル名
            continue
        if PATH_WORD.match(tok):
            unsure(tok)  # PATH の付け替え（前置の代入・export PATH=… など）
            continue
        if cmd in SHELLS and tok.startswith("-") and not tok.startswith("--") and "c" in tok[1:]:
            unsure(f"{cmd} {tok}")  # bash -c '…' の中のコマンドは追わない
            continue
        if not at_cmd:
            continue
        if tok == "esac" and case_depth:
            case_depth, at_cmd = case_depth - 1, False
            continue
        if tok == "case":
            case_depth, case_head, at_cmd = case_depth + 1, True, False
            continue
        if ASSIGN.match(tok) or tok in SH_KEYWORDS:
            continue
        at_cmd = False
        if tok in SH_UNSURE:
            unsure(tok)
            continue
        if tok in SH_SKIP:
            continue
        if any(ch in tok for ch in "$`*?[") or tok.startswith("~") or not tok:
            unsure(tok)  # 変数・~・ワイルドカードで組み立てた名前は解決できない
            continue
        path = resolve_exe(tok)
        if not path or not exe_token(path, tok):
            stop_reuse(f"確認コマンド（{origin}）の「{tok[:60]}」: 実行ファイルが見つからない")
            h.update(f"check_exe:{tok}:missing\0".encode("utf-8", errors="surrogateescape"))
            continue
        cmd = os.path.basename(tok)
        # #!（シバン）で動く台本なら、その解釈系も含める（/usr/bin/env node なら node）
        try:
            with open(path, "rb") as stream:
                first = stream.readline(512)
        except OSError:
            first = b""
        if first.startswith(b"#!"):
            # 解釈系を確実に特定できないとき（env のオプション -S・-i など・PATH などの代入付き・解決失敗）は
            # 実際に使われるファイルを比べられないので、結果を保存・再利用しない
            parts = first[2:].decode("utf-8", errors="replace").split()
            if not parts:
                unsure(f"{tok}#!<empty>", "#! の解釈系を確実に決められない")
                continue
            interp = parts[0]
            if os.path.basename(interp) == "env":
                if not exe_token(interp, f"{tok}#!env"):
                    unsure(f"{tok}#!env", "#! の解釈系を確実に決められない")
                    continue
                rest = parts[1:]
                if not rest or rest[0].startswith("-") or ASSIGN.match(rest[0]) or ("/" in rest[0] and not os.path.isabs(rest[0])):
                    unsure(f"{tok}#!env-args", "#! の解釈系を確実に決められない")
                    continue
                interp = rest[0] if os.path.isabs(rest[0]) else (shutil.which(rest[0]) or "")
                if not interp:
                    unsure(f"{tok}#!{rest[0]}", "#! の解釈系を確実に決められない")
                    continue
            if not exe_token(interp, f"{tok}#!"):
                unsure(f"{tok}#!{interp}", "#! の解釈系を確実に決められない")
check_src = os.environ.get("CHK_CHECK_SRC", "")
if check_src == ".lanes/check.sh":
    try:
        with open(os.path.join(wt, ".lanes", "check.sh"), encoding="utf-8", errors="surrogateescape") as stream:
            fingerprint_check_cmd(stream.read(), check_src)
    except OSError:
        stop_reuse(".lanes/check.sh を読めない")
else:
    fingerprint_check_cmd(os.environ.get("LANES_CHECK_CMD", ""), check_src)

for bin_name in ("node", "npm", "npx", "pnpm", "yarn", "bun", "bash"):
    resolved = shutil.which(bin_name) or ""
    if resolved and os.path.exists(resolved):
        st = os.stat(resolved)
        h.update(f"bin:{bin_name}:{os.path.realpath(resolved)}:{st.st_mode}:{st.st_size}:{st.st_mtime_ns}\0".encode("utf-8"))
    else:
        h.update(f"bin:{bin_name}:missing\0".encode("utf-8"))

# 生成物の定義（_common.sh の LANES_GENERATED_DIRS / LANES_GENERATED_SUFFIXES を呼び出し側が渡す）
_generated_def = sys.argv[6].split("\n")
generated_dirs = tuple(name + "/" for name in _generated_def[0].split())
generated_suffixes = tuple(_generated_def[1].split()) if len(_generated_def) > 1 else ()
if not generated_dirs:
    sys.exit(2)
other_files = []
generated_files = []

# ランチャの記録（作業ツリー直下の logs/ の直下に、ランチャと detach-run.sh が書くファイル）は入力に数えない。
# 名前が記録に似ているだけでは外さない（確認コマンドが読む logs/input.json を外すと、中身を変えても古い成功の記録を使い回してしまう）。
# 外すのは、ランチャが書く前に台帳（logs/.lanes-records。_common.sh の lanes_records_claim と detach-run.sh が載せる）へ載せた
# 持ち主の、決まった名前のファイルだけ:
#   label:<label> … <label>.<下の LANE_LABEL_SUFFIXES のどれか>（その label のランチャが書く名前の組）
#   file:<名前>   … その名前そのもの（detach-run.sh の起動ログ・qa-case.md・qa-deps-<名前>.log・.<系列>.review-state・
#                   <系列>.followups.md・.review-reuse-blocked）
# と、その回転した前回分（<名前>.prev-<日時>[-<n>].<拡張子>）・置き換え用の一時ファイル（.<名前>.<pid>.<英数字>.tmp と <名前>.tmp.<pid>）。
# 台帳そのものも数えない。台帳に無い名前は入力のまま。
# ランチャが label ごとに書く名前を足したら LANE_LABEL_SUFFIXES にも足し、label で決まらない名前を足したら、書く前に台帳へ載せる
# （tests/test-review-reuse-launch.sh が、各ランチャを実際に回した後も記録を使い回せることを確かめている）
LANE_RECORDS_NAME = ".lanes-records"
LANE_LABEL_SUFFIXES = ("pid", "done", "lock", "log", "stderr.log", "json", "prompt.md", "dry-run.prompt.md", "evidence.md",
                       "last.md", "completion.json", "try1.json", "try1.stderr.log", "verify.log", "meta.txt")
# label は英数で始まり、英数と . _ - だけ（_common.sh の lanes_require_label）
LANE_LABEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
LANE_RECORD_PREV_RE = re.compile(r"\.prev-[0-9]{8}-[0-9]{6}(?:-[0-9]+)?(?=\.[A-Za-z0-9-]+$)")
LANE_RECORD_TMP_RES = (re.compile(r"\.(.+)\.[0-9]+\.[0-9a-f]+\.tmp"), re.compile(r"(.+)\.tmp\.[0-9]+"))
lane_records = frozenset()   # 台帳から決まる記録の名前（logs/ の直下の名前）。scan_repo が最上位のリポの一覧を取った後で読む

def load_lane_records():
    # 台帳を symlink を辿らずに読む。symlink・ハードリンク・普通のファイルでない台帳は使わない（何も外さない）
    names = set()
    try:
        fd = os.open(os.path.join(wt, "logs", LANE_RECORDS_NAME), os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                return frozenset()
            data = stream.read()
    except OSError:
        return frozenset()
    for line in data.decode("utf-8", errors="surrogateescape").split("\n"):
        kind, sep, name = line.partition(":")
        if not sep or not name or "/" in name:
            continue
        if kind == "label" and LANE_LABEL_RE.fullmatch(name):
            names.update(f"{name}.{suffix}" for suffix in LANE_LABEL_SUFFIXES)
        elif kind == "file":
            names.add(name)
    return frozenset(names)

def lane_record_name(name):
    # 台帳そのもの・台帳に載っている持ち主の名前・その回転した前回分・置き換え用の一時ファイルか
    if name == LANE_RECORDS_NAME or LANE_RECORD_PREV_RE.sub("", name) in lane_records:
        return True
    for pattern in LANE_RECORD_TMP_RES:
        found = pattern.fullmatch(name)
        if found and found.group(1) in lane_records:
            return True
    return False

def is_lane_record(rel, is_ignored):
    # 作業ツリー直下の logs/ の直下にあり、git が無視していて、台帳に載っている持ち主の記録（か台帳そのもの）。
    # logs/ の中のフォルダ・台帳に無い名前のファイルは入力のまま（logs/ に置いた入力で照合をすり抜けさせない）。
    # symlink・ハードリンク・特殊ファイルも入力のまま（ランチャ自身も logs/ にそれらがあると起動しない）
    if not is_ignored or not rel.startswith("logs/"):
        return False
    name = rel[len("logs/"):]
    if "/" in name or not lane_record_name(name):
        return False
    try:
        st = os.lstat(os.path.join(wt, rel))
    except FileNotFoundError:
        return True  # 一覧を取った後に消えた記録（書きかけの一時ファイル・回転の途中）
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_nlink == 1

def inside_worktree(real):
    # 作業ツリーの中（.git の中は除く）に収まる実体か。npm の node_modules/.bin/* のように
    # 作業ツリー内を指すリンクは、リンク先の中身を下でハッシュするので再利用を止めなくてよい。
    if real == wt:
        return False
    try:
        if os.path.commonpath([wt, real]) != wt:
            return False
    except ValueError:
        return False
    # .git の中は除く。大文字小文字を区別しないファイルシステム（.GIT など）でも抜けないよう、
    # 名前ではなく実体（st_dev / st_ino）で .git の配下かを確かめる
    try:
        git_st = os.stat(os.path.join(wt, ".git"))
    except OSError:
        git_st = None
    cur = real
    while cur != wt:
        try:
            if git_st is not None and os.path.samestat(os.stat(cur), git_st):
                return False
        except OSError:
            return False
        parent = os.path.dirname(cur)
        if parent == cur:
            return False
        cur = parent
    return True

def record_symlink(path, label, visited=None):
    shown = label.split(":", 1)[1] if label.startswith(("tracked:", "other:")) else label
    lst = os.lstat(path)
    target = os.readlink(path)
    h.update(f"symlink:{label}:{lst.st_mode}:".encode("utf-8", errors="surrogateescape") + os.fsencode(target) + b"\0")
    try:
        real = os.path.realpath(path)
        tst = os.stat(path)
    except OSError:
        # 行き先の無いリンクは中身を証明できないので再利用しない
        stop_reuse(f"行き先の無いリンク: {shown}")
        h.update(f"symlink_target:{label}:missing\0".encode("utf-8", errors="surrogateescape"))
        return
    # 作業ツリーの外（共有依存など）を指すリンクは、外側の変化を追い切れないので再利用だけ止める
    if not inside_worktree(real):
        stop_reuse(f"作業ツリーの外（か .git の中）を指すリンク: {shown}")
    h.update(f"symlink_real:{label}:".encode("utf-8", errors="surrogateescape") + os.fsencode(real) + b"\0")
    if os.path.isfile(real):
        h.update(f"symlink_file:{label}:{tst.st_mode}:{file_token(real)}\0".encode("utf-8", errors="surrogateescape"))
    elif os.path.isdir(real):
        if visited is None:
            visited = set()
        if real in visited:
            h.update(f"symlink_loop:{label}\0".encode("utf-8", errors="surrogateescape"))
            return
        visited = visited | {real}
        h.update(f"symlink_dir:{label}:{tst.st_mode}\0".encode("utf-8", errors="surrogateescape"))
        entries = []
        for root_dir, dirs, files in os.walk(real):
            dirs.sort()
            files.sort()
            rel_root = os.path.relpath(root_dir, real)
            prefix_rel = "" if rel_root == "." else rel_root + "/"
            for d in dirs:
                dp = os.path.join(root_dir, d)
                if os.path.islink(dp):
                    record_symlink(dp, f"{label}/{prefix_rel}{d}", visited)
            for fname in files:
                entries.append((f"{prefix_rel}{fname}", os.path.join(root_dir, fname)))
        full_hash_target = len(entries) <= 5000
        for sub_rel, fp in entries:
            if os.path.islink(fp):
                record_symlink(fp, f"{label}/{sub_rel}", visited)
            elif os.path.isfile(fp):
                fst = os.lstat(fp)
                base = os.path.basename(sub_rel)
                if full_hash_target or base in ("package.json", ".package-lock.json", ".modules.yaml", ".yarn-integrity"):
                    h.update(f"symlink_entry:{label}/{sub_rel}:{fst.st_mode}:{file_token(fp)}\0".encode("utf-8", errors="surrogateescape"))
                else:
                    h.update(f"symlink_stat:{label}/{sub_rel}:{fst.st_mode}:{fst.st_size}:{fst.st_mtime_ns}\0".encode("utf-8", errors="surrogateescape"))

def walk_plain_dir(dir_path):
    for root_dir, dirs, files in os.walk(dir_path):
        dirs.sort()
        files.sort()
        rel_root = os.path.relpath(root_dir, wt)
        prefix_rel = "" if rel_root == "." else rel_root + "/"
        for d in list(dirs):
            dp = os.path.join(root_dir, d)
            drel = f"{prefix_rel}{d}"
            if is_internal_artifact(drel):
                dirs.remove(d)
                continue
            if os.path.islink(dp):
                dirs.remove(d)
                other_files.append(drel)
        for fname in files:
            frel = f"{prefix_rel}{fname}"
            if not is_internal_artifact(frel):
                other_files.append(frel)

def scan_repo(repo_dir, rel_prefix="", visited_repos=None):
    global dirty, dirty_why, lane_records
    if visited_repos is None:
        visited_repos = set()
    real_repo = os.path.realpath(repo_dir)
    if real_repo in visited_repos:
        return
    visited_repos.add(real_repo)

    repo_tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=repo_dir).split(b"\0")) - {b""}
    def is_repo_internal(sub_path):
        return (os.fsencode(sub_path) not in repo_tracked
                and is_internal_artifact(rel_prefix + sub_path))

    r = subprocess.run(
        ["git", "status", "--porcelain", "-z", "--untracked-files=all", "--ignore-submodules=none"],
        cwd=repo_dir, capture_output=True
    )
    if r.returncode != 0:
        sys.exit(2)
    entries = [e.decode("utf-8", errors="surrogateescape") for e in r.stdout.split(b"\0") if e]
    i = 0
    while i < len(entries):
        item = entries[i]
        path = item[3:] if len(item) > 3 else ""
        if item and item[0] in ("R", "C") and i + 1 < len(entries):
            i += 1
        if path and not is_repo_internal(path):
            dirty = 1
            dirty_why = dirty_why or f"未 commit の変更か未追跡のファイルがある: {rel_prefix}{path}"
            break
        i += 1

    # 変更検知を省略する設定（assume-unchanged / skip-worktree）があると、書き換えても git status に出ない。
    # 未保存変更の有無を証明できないので、記録も省略もしない。
    flags = subprocess.run(["git", "ls-files", "-v", "-z"], cwd=repo_dir, capture_output=True)
    if flags.returncode != 0:
        sys.exit(2)
    if any(e[:1].islower() or e[:1] == b"S" for e in flags.stdout.split(b"\0") if e):
        dirty = 1
        dirty_why = dirty_why or "変更検知を省く設定（assume-unchanged / skip-worktree）のファイルがある"

    # サブモジュールは検出した HEAD も入力に含める（索引の gitlink とずれた checkout を同一視しない）。
    # 最上位の HEAD は含めない。記録は tree 単位で、tree が同じ別 commit（release 枝等）でも省略するため。
    # 最上位の HEAD の前後一致は呼び出し側（after_head）で別に照合している。
    if rel_prefix:
        head_res = subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=repo_dir, capture_output=True)
        if head_res.returncode != 0:
            sys.exit(2)
        h.update(f"repo_head:{rel_prefix}:".encode("utf-8", errors="surrogateescape") + head_res.stdout)
    # 未保存変更が同じ M のまま書き換わっても検出する。本文は出力しない。
    h.update(f"repo_diff:{rel_prefix}:".encode("utf-8", errors="surrogateescape")
             + subprocess.check_output(["git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"], cwd=repo_dir) + b"\0")
    h.update(f"repo_stage:{rel_prefix}:".encode("utf-8", errors="surrogateescape")
             + subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=repo_dir) + b"\0")

    # 追跡ファイルは権限だけでなく実際の内容も照合する。サブモジュールも内部入力まで再帰的に走査する。
    for raw in sorted(repo_tracked):
        sub_rel = os.fsdecode(raw)
        name = rel_prefix + sub_rel
        tp = os.path.join(repo_dir, sub_rel)
        if os.path.islink(tp):
            record_symlink(tp, f"tracked:{name}")
        elif os.path.isfile(tp):
            h.update(f"tracked:{name}:{os.lstat(tp).st_mode}:{file_token(tp)}\0".encode("utf-8", errors="surrogateescape"))
        elif os.path.isdir(tp):
            h.update(f"tracked:{name}:{os.lstat(tp).st_mode}\0".encode("utf-8", errors="surrogateescape"))
            if os.path.exists(os.path.join(tp, ".git")):
                scan_repo(tp, name + "/", visited_repos)
            else:
                # 未初期化のサブモジュール等。中の実ファイルは入力に含めるので、再利用は止めない。
                walk_plain_dir(tp)
        elif os.path.exists(tp):
            stop_reuse(f"普通のファイルでもフォルダでもリンクでもない追跡ファイル: {name}")
            h.update(f"tracked:{name}:{os.lstat(tp).st_mode}\0".encode("utf-8", errors="surrogateescape"))
        else:
            h.update(f"tracked:{name}:missing\0".encode("utf-8", errors="surrogateescape"))

    # git で無視されているファイルや node_modules を含む作業ツリー内の非追跡入力を走査
    others = subprocess.run(["git", "ls-files", "--others", "-z"], cwd=repo_dir, capture_output=True)
    if others.returncode != 0:
        sys.exit(2)
    ignored = set()
    if not rel_prefix:
        ignored = set(subprocess.check_output(
            ["git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z"], cwd=repo_dir).split(b"\0"))
        # 台帳は一覧を取った後で読む（ランチャは書く前に載せるので、一覧にある記録は必ず台帳に載っている）
        lane_records = load_lane_records()
    for raw in others.stdout.split(b"\0"):
        if not raw:
            continue
        sub_rel = raw.decode("utf-8", errors="surrogateescape")
        rel = rel_prefix + sub_rel
        if is_internal_artifact(rel):
            continue
        # ランチャの記録は入力に数えない（最上位のリポの logs/ の直下だけ。サブモジュールの中の logs/ は入力のまま）
        if not rel_prefix and is_lane_record(rel, raw in ignored):
            continue
        fp = os.path.join(repo_dir, sub_rel.rstrip("/"))
        if sub_rel.endswith("/") or (not os.path.islink(fp) and os.path.isdir(fp)):
            walk_plain_dir(fp)
            continue
        if not rel_prefix and raw in ignored and (rel.startswith(generated_dirs) or rel.endswith(generated_suffixes)):
            generated_files.append(rel)
        else:
            other_files.append(rel)

try:
    scan_repo(wt)
    other_files = sorted(set(other_files))
    full_hash_all = len(other_files) <= 5000
    for rel in other_files:
        fp = os.path.join(wt, rel)
        if os.path.islink(fp):
            # 作業ツリーの外を指すリンク・行き先の無いリンクがある場合は成功記録の再利用だけ止め、検証前後の入力照合は維持する。
            record_symlink(fp, f"other:{rel}")
        elif os.path.isfile(fp):
            lst = os.lstat(fp)
            base = os.path.basename(rel)
            in_nm = rel.startswith("node_modules/") or "/node_modules/" in rel
            if full_hash_all or not in_nm or base in ("package.json", ".package-lock.json", ".modules.yaml", ".yarn-integrity"):
                h.update(f"file:{rel}:{lst.st_mode}:{file_token(fp)}\0".encode("utf-8", errors="surrogateescape"))
            else:
                h.update(f"stat:{rel}:{lst.st_mode}:{lst.st_size}:{lst.st_mtime_ns}\0".encode("utf-8", errors="surrogateescape"))
        elif os.path.exists(fp):
            lst = os.lstat(fp)
            h.update(f"other:{rel}:{lst.st_mode}\0".encode("utf-8", errors="surrogateescape"))
        else:
            h.update(f"other:{rel}:missing\0".encode("utf-8", errors="surrogateescape"))
    fp_hex = h.hexdigest()[:32]
    # 生成物は検証前後の入力比較から外すが、再利用には現在の出力の一致も要求する。
    cache_fp = ""
    if reusable:
        try:
            generated_hash = hashlib.sha256()
            for rel in sorted(set(generated_files)):
                path = os.path.join(wt, rel)
                if os.path.islink(path) or not os.path.isfile(path):
                    stop_reuse(f"生成物がリンクか、普通のファイルでない: {rel}")
                    break
                lst = os.lstat(path)
                generated_hash.update(os.fsencode(rel) + b"\0" + f"{lst.st_mode}\0".encode("ascii") + bytes.fromhex(hash_file_hex(path)))
            if reusable:
                cache_fp = fp_hex + ":" + generated_hash.hexdigest()[:32]
        except OSError:
            cache_fp = ""
            stop_reuse("生成物を読めない")
except Exception:
    sys.exit(2)

# 記録・省略できない理由（1 行）。未 commit の変更が先（問い合わせの理由の順と同じ）。記録できるときは空
why = ""
if dirty:
    why = dirty_why or "未 commit の変更がある"
elif not cache_fp:
    why = "; ".join(no_reuse[:3]) + (f"（ほか {len(no_reuse) - 3} 件）" if len(no_reuse) > 3 else "")
why = "".join(ch if ch.isprintable() else "?" for ch in why)
sys.stdout.buffer.write(f"dirty={dirty}\nfp={fp_hex}\ncache_fp={cache_fp}\nwhy={why}\n".encode("utf-8", errors="replace"))
PY
}
export CHK_CHECK_SRC="$check_src"
# 問い合わせ: 同じ tree の記録ごとに、その記録の port・outdir で指紋を計算し直し、skip=same-tree と同じ条件で照合する
if [ "$query" = 1 ]; then
  [ -n "$cache_dir" ] && [ -f "$cache" ] || { echo "reuse=no reason=no-record"; exit 1; }
  [ ! -L "$cache" ] || { echo "reuse=no reason=cache-link"; exit 1; }
  # 新しい記録から順に、port と outdir の組を重ねずに最大 5 組（旧形式の 6 列の記録は照合できないので使わない）
  cands=$(awk -F'\t' -v t="$tree" '$1==t && $3=="full" && NF>=8 {r[++n]=$7 "\t" $8} END{for(i=n;i>=1;i--) if(!s[r[i]]++) print r[i]}' "$cache" | head -5)
  [ -n "$cands" ] || { echo "reuse=no reason=no-record"; exit 1; }
  while IFS=$'\t' read -r port o; do
    case "$port" in ''|*[!0-9]*) continue ;; esac
    [ -n "$o" ] || continue
    state_info=$(read_state) || { echo "reuse=no reason=state-error"; exit 1; }
    [ "$(printf '%s\n' "$state_info" | sed -n 's/^dirty=//p' | head -1)" = 0 ] || { echo "reuse=no reason=uncommitted"; exit 1; }
    cache_fp=$(printf '%s\n' "$state_info" | sed -n 's/^cache_fp=//p' | head -1)
    [ -n "$cache_fp" ] || { echo "reuse=no reason=unresolvable"; exit 1; }
    hit=$(awk -F'\t' -v t="$tree" -v fp="$cache_fp" -v p="$port" -v d="$o" '$1==t && $3=="full" && $6==fp && $7==p && $8==d {l=$0} END{print l}' "$cache")
    if [ -n "$hit" ]; then
      [ "$(git rev-parse --verify HEAD 2>/dev/null)" = "$head" ] || { echo "reuse=no reason=input-changed"; exit 1; }
      # 答える直前に入力（未 commit の変更・依存・確認コマンドの指紋）を取り直し、最初に取ったものと同じかを確かめる
      # （skip=same-tree が検証の前後で入力を取り直すのと同じ考え方。途中で変わっていたら使い回さない）
      state_again=$(read_state) || { echo "reuse=no reason=state-error"; exit 1; }
      [ "$state_again" = "$state_info" ] || { echo "reuse=no reason=input-changed"; exit 1; }
      echo "reuse=yes"
      echo "head=$(printf '%s' "$hit" | cut -f2 | cut -c1-12)"
      echo "recorded=$(printf '%s' "$hit" | cut -f4)"
      echo "check=$check_src"
      echo "fp=$cache_fp"
      exit 0
    fi
  done <<EOF_CANDS
$cands
EOF_CANDS
  echo "reuse=no reason=input-changed"
  exit 1
fi
state_info=$(read_state) || { echo "作業ツリー状態の取得に失敗" >&2; exit 1; }

dirty=$(printf '%s\n' "$state_info" | sed -n 's/^dirty=//p' | head -1)
[ "$dirty" = "0" ] && dirty=""
input_fp=$(printf '%s\n' "$state_info" | sed -n 's/^fp=//p' | head -1)
cache_fp=$(printf '%s\n' "$state_info" | sed -n 's/^cache_fp=//p' | head -1)
# 検証の前後で比べる入力。生成物は確認コマンドが作り直すので、生成物で決まる行（cache_fp と、記録できない理由の why）は比べない
input_state=$(printf '%s\n' "$state_info" | sed '/^cache_fp=/d; /^why=/d')
if [ -z "$input_fp" ]; then
  echo "作業ツリー状態の取得に失敗" >&2
  exit 1
fi

skipall() { echo "check=0 SKIP($1)"; }

# ビルド入力の証明がない差分は、省略せず全検証する。
if [ "$force" = 0 ] && [ -z "$dirty" ] && [ -n "$input_fp" ] && [ -n "$cache_fp" ]; then
  hit=$(awk -F'\t' -v t="$tree" -v fp="$cache_fp" '$1==t && $3=="full" && $6==fp{l=$0} END{print l}' "$cache")
  if [ -n "$hit" ]; then
    hh=$(printf '%s' "$hit" | cut -f2); hd=$(printf '%s' "$hit" | cut -f4)
    echo "skip=same-tree tree=${tree:0:12} は ${hh:0:7} で確認済み（${hd}）。回すなら --force"
    if [ "$(git rev-parse HEAD)" != "$head" ] || [ "$(read_state)" != "$state_info" ]; then
      echo "検証省略の判定中に入力が変化した" >&2; exit 1
    fi
    skipall same-tree; exit 0
  fi

fi

fail=0
# 共通監督役だけに停止を依頼する。確認コマンドが立てたサーバー等の孫まで、開始時刻を照合して回収する。
guard=$(LANES_DIR="$lanes_dir" zsh -fc 'source "$LANES_DIR/_common.sh"; print -r -- "$LANES_PROCESS_GUARD"') || exit 1
pp=""; pp_start=""
# 監督役の開始時刻。起動直後や高負荷時の ps の一時失敗で空になるので、生きている間は少し待って取り直す。
read_pp_start() {
  local n=0 s=""
  while [ $n -lt 30 ]; do
    s=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pp" 2>/dev/null | xargs)
    [ -n "$s" ] && { pp_start=$s; return 0; }
    kill -0 "$pp" 2>/dev/null || return 1
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}
stop_check() {
  [ -n "$pp" ] || return 0
  [ -n "$pp_start" ] || read_pp_start || true
  if [ -z "$pp_start" ]; then
    echo "確認コマンドの監督役の開始時刻を確認できない。停止・回収未確認" >&2
    return 1
  fi
  python3 -c "$guard" stop-supervisor "$pp" "$pp_start" || return 1
  local stopped_rc=0
  wait "$pp" 2>/dev/null || stopped_rc=$?
  pp=""
  [ "$stopped_rc" = 0 ] || [ "$stopped_rc" = 143 ]
}
trap 'stop_check || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

: > "$o/check-state.json" || exit 1
LANES_CHECK_PORT=$port LANES_CHECK_OUTDIR=$o \
  python3 -c "$guard" supervise-state "$o/check-state.json" bash -c "$check_cmd" > "$o/check.log" 2>&1 < /dev/null & pp=$!
read_pp_start || true
r=0
wait "$pp" || r=$?
# 監督役は孫の回収まで済ませてから終わる。回収未確認は 3 で返る
pp=""
echo "check=${r}（${check_src}）"
[ $r = 0 ] || { fail=1; echo "  ログ: $o/check.log"; }
# 検証中に履歴・作業ツリー・環境・依存が変わった結果を古い入力へ結び付けない。
why=""
if [ $fail = 0 ]; then
  after_state=$(read_state) || { echo "検証後の作業ツリー状態の取得に失敗したため記録しない" >&2; fail=1; }
  after_head=$(git rev-parse --verify HEAD 2>/dev/null) || fail=1
  after_tree=$(git rev-parse --verify 'HEAD^{tree}' 2>/dev/null) || fail=1
  after_fp=$(printf '%s\n' "$after_state" | sed -n 's/^fp=//p' | head -1)
  if [ -z "$after_fp" ] || [ "$after_head" != "$head" ] || [ "$after_tree" != "$tree" ] || [ "$(printf '%s\n' "$after_state" | sed '/^cache_fp=/d; /^why=/d')" != "$input_state" ]; then
    echo "検証中に入力が変化したため記録しない。再実行する" >&2
    fail=1
  fi
  cache_fp=$(printf '%s\n' "$after_state" | sed -n 's/^cache_fp=//p' | head -1)
  why=$(printf '%s\n' "$after_state" | sed -n 's/^why=//p' | head -1)
fi
if [ $fail = 0 ] && [ -z "$dirty" ] && [ -n "$input_fp" ] && [ -n "$cache_fp" ]; then
  kind=full
  if printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tree" "$head" "$kind" "$(date '+%Y-%m-%d %H:%M %Z')" "$wt" "$cache_fp" "$port" "$o" >> "$cache"; then
    echo "recorded=tree ${tree:0:12}（${kind}）"
  else
    echo "確認済みの記録を書けない: $cache" >&2
    fail=1
  fi
elif [ $fail = 0 ]; then
  # 通ったが記録しない。黙って終わらず、理由を出す（次に同じ中身で呼んでも省かない。レビューの問い合わせ --query は no-record になる）。
  # 理由の語は問い合わせと同じ（uncommitted = 未 commit の変更など / unresolvable = 確認コマンドや依存を確実に照合できない）
  if [ -n "$dirty" ]; then reason=uncommitted; else reason=unresolvable; fi
  echo "record=no reason=${reason}（通ったが記録しない。次も省かずに回し、レビューも親の記録を使い回せない。理由: ${why:-不明}）"
fi
exit "$fail"
