#!/bin/zsh -f
# キットの自己テスト。偽の CLI（lanes/tests/stubs）を PATH の先頭に置いた一時 HOME で、構成ごとにテストを回す（構成に左右されないテストは 1 回だけ）。
# 使い方: selftest.sh [--profile full|claude-codex|claude-gemini|claude-only|all]（既定 all） [--test <キットからの相対パス> ...] [--every-profile]
#   回すテスト: lanes/tests/test-*.sh と tests/test-*.sh の全部。--test を付けたときはそのテストだけ（複数指定可）
#   構成ごとに LANES_TOOLS を変える（① full = claude codex gemini / ② claude-codex / ③ claude-gemini / ④ claude-only）
#   構成によって結果が変わるテスト（先頭のコメントに「# selftest: 構成ごと」の行があるもの）だけを構成ごとに回す。
#   それ以外のテスト（呼び出し元の LANES_TOOLS を見ない。中で構成を自分で固定・切り替えるものを含む）は最初の構成で 1 回だけ回し、
#   ほかの構成の列には同じ結果を「＝」付きで流用する。--every-profile を付けると、全部のテストを構成ごとに回す（前の回し方）
#   所要時間の目安: 1 構成で約 10〜15 分。all（4 構成）で約 15〜20 分（--every-profile なら 40 分以上）
#   テストの終了コード: 0 = 緑 / 77 = 対象外（その構成では意味が無い。代わりに停止することを確かめ済み）/ それ以外 = 赤
#   緑のうち、出力に「LANES_PARTIAL: <理由>」の行があるものは「緑(一部)」と出す（その構成では一部を停止の確認だけにした）。理由は表の下に並べる
#   LANES_PRIVATE_DENYLIST=<禁止語ファイル> を付けて回すと、固有名の検査（tests/test-no-private.sh）にその禁止語も渡す
#   LANES_TEST_SOCKET_ROOT=<浅いフォルダ> を付けて回すと、一時 PostgreSQL のソケット（接続口のファイル）の逃がし先としてテストへ渡す
#   （付けなければ selftest の一時領域の浅い場所を渡す。/tmp などの一時領域の外へは逃がさない）
#   LANES_LINT_STRICT=1 を付けて回すと、tests/test-lint.sh で shellcheck が未導入なら赤にする
#   （ほかの LANES_* はテストに持ち込まない。この 3 つだけは例外）
# 本物の CLI・ネットワークには触らない（CLAUDE_BIN / CODEX_BIN / GEMINI_BIN をスタブに向け、PATH に偽の gh を置き、
# API キーと GitHub の認証関連の環境変数は外す）。
# 終了コード: 0 = 全部緑か対象外 / 1 = 赤がある / 2 = 使い方の誤り
# 一時領域は mktemp -d（$TMPDIR の下）に作る。全部緑なら消し、赤があればログを残して場所を出す。
# テストが本物のリポを書き換えていないことも確かめる: 実行前後でキットの HEAD・いまの枝・ref（リモート追跡・他の worktree の枝も）・
# stash・worktree・git status（無視対象を含む）・ファイルの中身と索引の指紋・git の設定ファイル・info/ と objects/info/alternates と
# hooks（下のフォルダも）を比べ、変わっていたら赤にする（比べるものの詳しい範囲は下の kit_state の説明）。
# 同じリポで並行して別の作業が枝・worktree を動かしたり fetch したりすると赤になるので、ほかの作業が動いているリポでは、clone した場所で回す。
# テストへ渡す環境では git の通信を file（ローカルのパスどうし）だけにする（GIT_ALLOW_PROTOCOL=file。各テストも同じ値を置き直す）。
# 一時領域（TMPDIR）がキットの中にあると、作業フォルダがキットの中にできて前後比較が赤になるので、使い方の誤り（exit 2）として止める。
set -euo pipefail
KIT="${0:A:h}"
usage="使い方: selftest.sh [--profile full|claude-codex|claude-gemini|claude-only|all] [--test <キットからの相対パス> ...] [--every-profile]"
profile=all
every_profile=0
typeset -a only
only=()
while (( $# )); do
  case "$1" in
    --profile) (( $# >= 2 )) || { print -u2 -- "ERROR: --profile に値が無い / $usage"; exit 2; }; profile="$2"; shift 2 ;;
    --test) (( $# >= 2 )) || { print -u2 -- "ERROR: --test に値が無い / $usage"; exit 2; }; only+=("$2"); shift 2 ;;
    --every-profile) every_profile=1; shift ;;
    -h|--help) print -r -- "$usage"; exit 0 ;;
    *) print -u2 -- "ERROR: 不明な引数: $1 / $usage"; exit 2 ;;
  esac
done
typeset -A tools_of
tools_of=(full "claude codex gemini" claude-codex "claude codex" claude-gemini "claude gemini" claude-only "claude")
typeset -a profiles
case "$profile" in
  all) profiles=(full claude-codex claude-gemini claude-only) ;;
  full|claude-codex|claude-gemini|claude-only) profiles=("$profile") ;;
  *) print -u2 -- "ERROR: --profile は full|claude-codex|claude-gemini|claude-only|all（渡されたのは '$profile'）"; exit 2 ;;
esac

stubs="$KIT/lanes/tests/stubs"
for s in claude codex agy; do [[ -x "$stubs/$s" ]] || { print -u2 -- "ERROR: スタブが無い: $stubs/$s"; exit 2; }; done
typeset -a tests
if (( ${#only} )); then
  tests=()
  for t in "${only[@]}"; do
    [[ -f "$KIT/$t" && "${t:t}" == test-*.sh ]] || { print -u2 -- "ERROR: --test のテストが無い（キットからの相対パスで test-*.sh を指定）: $t"; exit 2; }
    tests+=("$KIT/$t")
  done
else
  tests=("$KIT"/lanes/tests/test-*.sh(N) "$KIT"/tests/test-*.sh(N))
fi
(( ${#tests} )) || { print -u2 -- "ERROR: テストが見つからない"; exit 2; }
# 固有名の検査の禁止語ファイル（任意）。HOME を一時 HOME に替えて回すので、絶対パスに直して渡す
typeset -a deny_env
deny_env=()
if [[ -n "${LANES_PRIVATE_DENYLIST:-}" ]]; then
  [[ -f "$LANES_PRIVATE_DENYLIST" ]] || { print -u2 -- "ERROR: 禁止語ファイルが無い: $LANES_PRIVATE_DENYLIST"; exit 2; }
  deny_env=(LANES_PRIVATE_DENYLIST="${LANES_PRIVATE_DENYLIST:A}")
  print -r -- "禁止語ファイル: あり（固有名の検査に渡す）"
else
  print -r -- "禁止語ファイル: なし（固有名の検査は汎用のパターンだけ。公開前は LANES_PRIVATE_DENYLIST=<ファイル> を付けて回す）"
fi

# git の場所を差し替える環境変数（GIT_DIR など）を、この自己テスト自身からもテストからも外す。
# 外から入ったままだと、テストの一時リポ作成が本物のリポへ届く（キットの .git/config に core.worktree が書かれた事故があった）
typeset -a git_drop
git_drop=(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
          GIT_NAMESPACE GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM ${(k)parameters[(I)GIT_CONFIG*]})
for v in "${git_drop[@]}"; do unset "$v" 2>/dev/null || true; done

# キットのリポの状態。種類ごとに 1 つの文字列を返し、前後で比べる。値そのもの（設定の中身・ファイルの中身）は出さず、指紋だけにする
#   head      HEAD の commit
#   symref    いまの枝（同じ commit のまま枝だけ切り替えたのを見つける）
#   refs      枝・タグ・リモート追跡（refs/remotes/）などすべての ref の一覧（作った・消した・動かした）。他の worktree で今
#             checkout 中の枝も含む。リモートの名前を使った push はリモート追跡の ref を動かすので、ここで見つかる
#             （URL を直に書いた push は見えない。通信は file だけに絞ってあるので、外のリモートへは届かない）
#   stash     stash の一覧
#   worktrees worktree の場所の一覧（git worktree add / remove）
#   status    未保存の変更と未追跡・無視対象のファイルの一覧（git status --ignored。無視対象の logs/ や .lanes/ への新しい書き込みも見る）
#   content   追跡・未追跡・無視対象のファイルの中身の指紋（同じ「M」のまま中身が上書きされたのを見つける）。
#             無視対象のうち logs/ の下だけは中身を比べない（このキットをレーンで回すと、外側のランチャが自分のログを書き続けるため。
#             logs/ に新しいファイルを作った漏れは status で見つかる）
#   index     索引（git ls-files --stage と変更検知の省略の印）の指紋
#   config    共通の .git/config と worktree 用の config.worktree の指紋（鍵入りの URL などを表示しない）
#   hooks     info/ の下（exclude = 手元だけの無視の設定、attributes = 手元だけの属性 など）・objects/info/alternates（別の場所の
#             中身を借りる設定）・hooks（git の操作で動くスクリプト。下のフォルダも）の指紋
kit_kinds=(head symref refs stash worktrees status content index config hooks)
kit_state() {
  git -C "$KIT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { print -r -- "(git 管理外)"; return 0; }
  local common gd f
  case "$1" in
    head) git -C "$KIT" rev-parse HEAD 2>/dev/null || print -r -- "(HEAD 無し)" ;;
    symref) git -C "$KIT" symbolic-ref -q HEAD 2>/dev/null || print -r -- "(枝なし)" ;;
    refs) git -C "$KIT" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null || print -r -- "(ref 一覧に失敗)" ;;
    stash) git -C "$KIT" stash list --format='%H %gs' 2>/dev/null || print -r -- "(stash 失敗)" ;;
    worktrees) git -C "$KIT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | LC_ALL=C sort ;;
    status) git -C "$KIT" status --porcelain=v1 --untracked-files=all --ignored 2>/dev/null || print -r -- "(status 失敗)" ;;
    content)
      python3 -I - "$KIT" <<'PY_CONTENT' 2>/dev/null || print -r -- "(中身の指紋に失敗)"
import hashlib, os, subprocess, sys
kit = sys.argv[1]
def ls(*args):
    out = subprocess.run(["git", "-C", kit, "ls-files", "-z", *args], capture_output=True, check=True).stdout
    return sorted({p for p in out.split(b"\0") if p})
h = hashlib.sha256()
for kind, paths in (("tracked", ls()), ("untracked", ls("--others", "--exclude-standard")),
                    ("ignored", ls("--others", "--ignored", "--exclude-standard"))):
    for rel in paths:
        if kind == "ignored" and rel.startswith(b"logs/"):
            continue
        full = os.path.join(os.fsencode(kit), rel)
        h.update(kind.encode() + b"\0" + rel + b"\0")
        try:
            st = os.lstat(full)
        except FileNotFoundError:
            h.update(b"missing\0"); continue
        h.update(f"{st.st_mode}\0".encode())
        if os.path.islink(full):
            h.update(os.readlink(full) + b"\0")
        elif os.path.isfile(full):
            d = hashlib.sha256()
            with open(full, "rb") as stream:
                for chunk in iter(lambda: stream.read(1 << 20), b""):
                    d.update(chunk)
            h.update(d.digest())
print(h.hexdigest())
PY_CONTENT
      ;;
    index)
      { git -C "$KIT" ls-files --stage -z 2>/dev/null; git -C "$KIT" ls-files -v -z 2>/dev/null; } | shasum -a 256 | cut -d' ' -f1 ;;
    config|hooks)
      common="$(git -C "$KIT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
      gd="$(git -C "$KIT" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || gd=""
      if [[ "$1" == config ]]; then
        for f in "$common/config" "$gd/config.worktree"; do
          if [[ -f "$f" ]]; then print -r -- "${f:t} $(shasum -a 256 < "$f" | cut -d' ' -f1)"; else print -r -- "${f:t} (無し)"; fi
        done
      else
        for f in "$common/info"/**/*(DN) "$common/objects/info/alternates" "$common/hooks"/**/*(DN) "$gd/info"/**/*(DN); do
          if [[ -L "$f" ]]; then print -r -- "${f#$common/} -> $(readlink "$f")"
          elif [[ -f "$f" ]]; then print -r -- "${f#$common/} $(stat -f '%p' "$f") $(shasum -a 256 < "$f" | cut -d' ' -f1)"
          elif [[ -d "$f" ]]; then print -r -- "${f#$common/} (フォルダ)"
          elif [[ -e "$f" ]]; then print -r -- "${f#$common/} (ファイルではない)"
          fi
        done | LC_ALL=C sort -u
      fi ;;
  esac
}
# ソケットの逃がし先（任意）。キットの中だと前後比較が赤になり、無いフォルダには置けないので、使い方の誤りとして止める
sock_root_in="${LANES_TEST_SOCKET_ROOT:-}"
if [[ -n "$sock_root_in" ]]; then
  [[ -d "$sock_root_in" ]] || { print -u2 -- "ERROR: LANES_TEST_SOCKET_ROOT のフォルダが無い: $sock_root_in"; exit 2; }
  sock_root_in="${sock_root_in:A}"
  if [[ "$sock_root_in" == "${KIT:A}" || "$sock_root_in" == "${KIT:A}"/* ]]; then
    print -u2 -- "ERROR: LANES_TEST_SOCKET_ROOT がキットの中にある: $sock_root_in"; exit 2
  fi
fi
# 一時領域がキットの中にあると、作業フォルダ（とテストの一時リポ）がキットの中にでき、前後比較が誤って赤になる
tmp_base="${TMPDIR:-}"
if [[ -n "$tmp_base" && -d "$tmp_base" ]]; then
  tmp_real="${tmp_base:A}"
  if [[ "$tmp_real" == "${KIT:A}" || "$tmp_real" == "${KIT:A}"/* ]]; then
    print -u2 -- "ERROR: TMPDIR がキットの中にある: $tmp_base。キットの外の一時フォルダを TMPDIR に渡して回す"
    exit 2
  fi
fi
typeset -A kit_before
for k in "${kit_kinds[@]}"; do kit_before[$k]="$(kit_state $k)"; done

# macOS の mktemp はひな形を渡さないと $TMPDIR を見ないことがあるので、$TMPDIR があれば明示する
# パスは短くする（テストの一時 PostgreSQL の Unix ソケットのパスは 103 バイトまで。深いと PG の試験ができず赤になる）
if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then work="$(mktemp -d "${TMPDIR%/}/st.XXXXXX")"; else work="$(mktemp -d)"; fi
red=0
trap 'if (( red )); then print -r -- "ログ: $work"; else rm -rf -- "$work"; fi' EXIT
# テストの一時 PostgreSQL のソケットの逃がし先。構成ごとの一時領域（$work/<番号>/t/s.XXXXXX）より浅い $work 直下を既定にする
# （テストはその下に p.XXXXX を作る。一時領域の中なので後片付けで消える。それでも 103 バイトに収まらなければ、そのテストは対象外と理由を出す）
if [[ -n "$sock_root_in" ]]; then socket_root="$sock_root_in"; else socket_root="$work"; fi
# 偽の gh（GitHub の CLI）。テストが gh を呼んでも外部へ通信しない（未ログインと同じ終了コード 4 を返す）。
# スタブのフォルダとは分ける（gh が「無い」場合を試すテストが、gh のあるフォルダを PATH から外しても他のスタブを失わないため）
mkdir -p "$work/g"
print -r -- $'#!/bin/sh\necho "selftest の偽 gh: 外部へは通信しない（未ログイン扱い）" >&2\nexit 4' > "$work/g/gh"
chmod +x "$work/g/gh"

# テストに持ち込まない変数（呼び出し元の設定・レーンの作業場所・API キー・CLI のパスとモデル）
typeset -a drop
# CLAUDE_* / CODEX_* / GEMINI_* / CHK_* はまとめて外す（CLI のパス・モデル・前置きの省略・Gemini の待ち時間・chk-run のキャッシュの場所など。
# 本物のキャッシュへ書いたり、利用者の値で誤って赤になったりしないように。CLI のパスは下でスタブを置き直す）
drop=("${git_drop[@]}" ${(k)parameters[(I)LANES_*]} ${(k)parameters[(I)CLAUDE_*]} ${(k)parameters[(I)CODEX_*]}
      ${(k)parameters[(I)GEMINI_*]} ${(k)parameters[(I)CHK_*]} XDG_CONFIG_HOME XDG_STATE_HOME
      ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
      GOOGLE_APPLICATION_CREDENTIALS AGY_ADC_AUTH XAI_API_KEY GROK_API_KEY
      GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_CONFIG_DIR GH_REPO
      PYTHONPYCACHEPREFIX)
typeset -a unset_args
for v in "${drop[@]}"; do unset_args+=(-u "$v"); done
# 持ち込む設定（LANES_* はまとめて外すので、テストの動きを決めるものだけ明示して渡し直す）。
# LANES_LINT_STRICT=1: tests/test-lint.sh で shellcheck が未導入なら赤にする（公開前の確認など）
typeset -a keep_env
keep_env=()
[[ -z "${LANES_LINT_STRICT:-}" ]] || keep_env+=(LANES_LINT_STRICT="$LANES_LINT_STRICT")

# 表示名（キットのルートからの相対パス）
name_of() { print -r -- "${1#$KIT/}"; }
typeset -A result   # "<profile>|<test>" → 緑 / 対象外 / 赤(rc)。流用した結果は先頭に「＝」
total_ok=0; total_skip=0; total_red=0; total_partial=0; total_reused=0
# 構成によって結果が変わるテストか（先頭 15 行のコメントに「# selftest: 構成ごと」の行がある）
per_profile() { grep -qx '# selftest: 構成ごと' <<< "$(head -15 "$1")"; }   # pipefail 下の SIGPIPE を避けて変数で渡す
typeset -a partial_notes
partial_notes=()
n_profile=0
for p in "${profiles[@]}"; do
  # 構成ごとの領域は番号の 1 文字（構成名にするとパスが長くなる）。ログの名前には構成名を付ける
  n_profile=$(( n_profile + 1 ))
  base="$work/$n_profile"; home="$base/h"; tmp="$base/t"
  mkdir -p "$home/.gemini/antigravity-cli" "$home/.config" "$tmp"
  print -r -- "== 構成 $p（LANES_TOOLS=\"${tools_of[$p]}\"）"
  for t in "${tests[@]}"; do
    n="$(name_of "$t")"; log="$base/$p-${${n//\//_}%.sh}.log"
    k="$p|$n"
    # 構成に左右されないテストは最初の構成で 1 回だけ回し、2 つ目以降の構成には結果を流用する
    if (( n_profile > 1 && ! every_profile )) && ! per_profile "$t"; then
      result[$k]="＝${result[${profiles[1]}|$n]}"; total_reused=$(( total_reused + 1 ))
      print -r -- "  ${(r:8:)result[$k]} $n（${profiles[1]} の結果を流用）"
      continue
    fi
    # シェバン（先頭行）でシェルを選ぶ。zsh は -f（利用者の設定を読まない）
    first="$(head -1 "$t")"
    if [[ "$first" == *bash* ]]; then runner=(bash); else runner=(zsh -f); fi
    t0=$SECONDS; rc=0
    # PYTHONDONTWRITEBYTECODE: キットの Python を読み込むテストが、キットの中に __pycache__ を作らない（見張りの status で赤になるため）
    # GIT_ALLOW_PROTOCOL=file: テストの git の通信をローカルのパスどうしだけにする（各テストも置き直す。二重の守り）
    env "${unset_args[@]}" HOME="$home" PATH="$stubs:$work/g:$PATH" PYTHONDONTWRITEBYTECODE=1 GIT_ALLOW_PROTOCOL=file \
      LANES_TOOLS="${tools_of[$p]}" LANES_CONF="$home/.config/lanewright/lanes.conf" LANES_NOTIFY=0 \
      CLAUDE_BIN="$stubs/claude" CODEX_BIN="$stubs/codex" GEMINI_BIN="$stubs/agy" \
      TMPDIR="$tmp/" LANES_SCRATCH="$tmp" LANES_TEST_SOCKET_ROOT="$socket_root" "${deny_env[@]}" "${keep_env[@]}" \
      "${runner[@]}" "$t" < /dev/null > "$log" 2>&1 || rc=$?
    secs=$(( SECONDS - t0 ))
    case "$rc" in
      0)
        if grep -q '^LANES_PARTIAL: ' "$log"; then
          result[$k]="緑(一部)"; total_partial=$(( total_partial + 1 ))
          partial_notes+=("$p / $n: $(sed -n 's/^LANES_PARTIAL: //p' "$log" | head -1)")
        else
          result[$k]="緑"
        fi
        total_ok=$(( total_ok + 1 )) ;;
      77) result[$k]="対象外"; total_skip=$(( total_skip + 1 )) ;;
      *) result[$k]="赤($rc)"; total_red=$(( total_red + 1 )); red=1 ;;
    esac
    print -r -- "  ${(r:8:)result[$k]} $n（${secs} 秒）"
    if [[ "$rc" != 0 && "$rc" != 77 ]]; then
      tail -5 "$log" | sed 's/^/      | /'
    fi
  done
done

# テストの前後でキットのリポが変わっていないか（変わっていたら、どのテストかを特定するため 1 本ずつ --test で回し直す）
typeset -a kit_changed
kit_changed=()
for k in "${kit_kinds[@]}"; do
  [[ "$(kit_state $k)" == "${kit_before[$k]}" ]] || kit_changed+=("$k")
done
if (( ${#kit_changed} )); then
  red=1
  print -r -- ""
  print -r -- "== 赤: テストの前後でキットのリポが変わった（${(j:・:)kit_changed}）。テストが一時リポの外の git を書き換えた疑い"
  for k in "${kit_changed[@]}"; do
    case "$k" in
      head) print -r -- "  HEAD: ${kit_before[head]:0:12} → $(kit_state head | cut -c1-12)（作業枝に commit ができた）" ;;
      symref) print -r -- "  いまの枝が変わった（${kit_before[symref]} → $(kit_state symref)）" ;;
      refs) print -r -- "  枝・タグ・リモート追跡などの ref が変わった（リモートへの push を含む。git -C ${KIT} for-each-ref で確かめる）" ;;
      stash) print -r -- "  stash が変わった（git -C ${KIT} stash list で確かめる）" ;;
      worktrees) print -r -- "  worktree が増えた・減った（git -C ${KIT} worktree list で確かめる）" ;;
      status) print -r -- "  未保存の変更・未追跡や無視対象のファイルの一覧が変わった（git -C ${KIT} status --ignored で確かめる）" ;;
      content) print -r -- "  ファイルの中身が変わった（未保存の変更の上書きを含む。git -C ${KIT} diff で確かめる）" ;;
      index) print -r -- "  索引（git add した中身・変更検知の省略の印）が変わった（git -C ${KIT} diff --cached で確かめる）" ;;
      hooks) print -r -- "  info/・objects/info/alternates・hooks のどれかが変わった（.git/info・.git/objects/info・.git/hooks を確かめる）" ;;
      config) print -r -- "  git の設定ファイルが変わった（core.worktree などが書かれた疑い。git -C ${KIT} config --list --show-origin で確かめる）" ;;
    esac
  done
fi

# 結果の表（行 = テスト、列 = 構成）
print -r -- ""
print -r -- "== 結果（構成 × テスト）"
header="| テスト |"; sep="|---|"
for p in "${profiles[@]}"; do header+=" $p |"; sep+="---|"; done
print -r -- "$header"; print -r -- "$sep"
for t in "${tests[@]}"; do
  n="$(name_of "$t")"; row="| $n |"
  for p in "${profiles[@]}"; do k="$p|$n"; row+=" ${result[$k]} |"; done
  print -r -- "$row"
done
print -r -- ""
if (( ${#partial_notes} )); then
  print -r -- "緑(一部) の内訳:"
  for x in "${partial_notes[@]}"; do print -r -- "  - $x"; done
  print -r -- ""
fi
if (( total_reused )); then
  print -r -- "「＝」: 構成に左右されないテストなので、最初の構成（${profiles[1]}）の結果を流用した（全部回すなら --every-profile）"
fi
print -r -- "合計: 緑 $total_ok（うち一部 $total_partial）/ 対象外 $total_skip / 赤 $total_red / 流用 $total_reused（構成 ${#profiles} × テスト ${#tests}）"
(( ${#kit_changed} )) && print -r -- "キットのリポ: 変わった（${(j:・:)kit_changed}）→ 赤" || print -r -- "キットのリポ: 変化なし"
(( red )) && exit 1
exit 0
