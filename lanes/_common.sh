# zsh から source する共通処理（bash では使わない）。呼び出し側が LANES_DIR を設定し、set -euo pipefail 済みであること。
# 役割: 設定読み込み / 構成（使える道具）の点検 / サブスク確認 / API キー無害化 / ログ回転 / git 要約
# zsh 固有の構文や設定を読み込む前に、別のシェルからの読み込みを止める。
if [ -z "${ZSH_VERSION:-}" ]; then
  printf '%s\n' 'ERROR: _common.sh は zsh から source すること' >&2
  return 2 2>/dev/null || exit 2
fi
source "$LANES_DIR/lanes.env"

# サブスク限定ルール: API キー経由で起動させない（従量課金の API キーではなく、各 CLI のサブスクのログインで動かす）
# 一覧の 2 行目（ANTHROPIC_AUTH_TOKEN 以降）は、Claude の認証経路を API キー / 第三者基盤へ逸らす env（auth status の門は
# ANTHROPIC_API_KEY を検知できないので unset が実質の担保）
# 3 行目の接続先（ANTHROPIC_BASE_URL・OPENAI_BASE_URL）も外す。司令塔のシェルをローカルのモデルや中継に向けていても、
# そこから起動したレーンはサブスクの正規の窓口へつなぐ（レーンはサブスク限定）
typeset -ga LANES_AUTH_ENV_NAMES=(OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY RESEND_API_KEY XAI_API_KEY GROK_API_KEY
  ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_PROFILE
  ANTHROPIC_BASE_URL OPENAI_BASE_URL)
# 外す前の値（export されていたものだけ）を、export しない変数に持つ。使うのは chk-run.sh --query を親が chk-run.sh を回したのと
# 同じ環境で呼ぶとき（指紋に環境変数が入る）と、レビューの入口がランチャへ同じ環境を渡すときだけ（lanes_with_caller_auth_env）。
# CLI の子には渡さない・表示しない
typeset -gA LANES_SAVED_AUTH_ENV=()
for _lanes_k in "${LANES_AUTH_ENV_NAMES[@]}"; do
  [[ "${parameters[$_lanes_k]-}" == *export* ]] && LANES_SAVED_AUTH_ENV[$_lanes_k]="${(P)_lanes_k}"
done
unset _lanes_k
unset "${LANES_AUTH_ENV_NAMES[@]}"
# 外す前の環境に戻す（今のシェルで export する。exec の直前か、$(...) / ( ) の子シェルの中だけで使う。CLI の子には使わない）
lanes_restore_caller_auth_env() {
  local k
  for k in "${(@k)LANES_SAVED_AUTH_ENV}"; do export "$k=${LANES_SAVED_AUTH_ENV[$k]}"; done
}
# 外す前の環境に戻してコマンドを実行する（同じく子シェルの中で使う）
lanes_with_caller_auth_env() { lanes_restore_caller_auth_env; "$@"; }

lanes_die() { print -u2 -- "ERROR: $*"; lanes_record_early_failure "$*"; exit 2; }

# ---- 生成物（確認コマンドのビルド・テストが作る出力）の定義 ----
# chk-run.sh（成功の記録の指紋）と cleanup-after-merge.sh（マージ後の後片付け）が同じ定義を使う。直すのはここ 1 か所だけ。
# 対象は git が無視しているもののうち、作業ツリー直下のこの名前のフォルダの中と、この語尾のファイル（どの深さでも）。
# 名前に空白を入れない（chk-run.sh へスペース区切りで渡す）
typeset -ga LANES_GENERATED_DIRS=(dist build out .next .turbo coverage test-results playwright-report)
typeset -ga LANES_GENERATED_SUFFIXES=(.tsbuildinfo)

# ---- Claude のレビュー・QA の読み取り専用の担保（外から上書きできない部分）----
# 拒否の固定の一覧。lanes.env の CLAUDE_REVIEW_DENY は「足す」ものだけで、この一覧は環境変数や設定ファイルでは外せない。
# 編集系ツール・サブエージェント・Bash 経由の履歴操作・別エージェントの起動・秘密の取得・作業ツリーの外への副作用（PR のマージ・
# デプロイ・DB の push・ref の操作・publish）。Bash(...) はコマンド先頭一致（詳しくは lanes.env の説明）
typeset -g LANES_CLAUDE_REVIEW_DENY_BASE='Task,Edit,Write,MultiEdit,NotebookEdit,Agent,Bash(git commit*),Bash(git push*),Bash(git stash*),Bash(git reset*),Bash(git rebase*),Bash(git merge*),Bash(git switch*),Bash(git worktree add*),Bash(git worktree remove*),Bash(git worktree prune*),Bash(git worktree move*),Bash(git worktree lock*),Bash(git worktree unlock*),Bash(git worktree repair*),Bash(git clean*),Bash(git checkout -b*),Bash(git checkout -B*),Bash(git branch -D*),Bash(git branch -d*),Bash(git branch -m*),Bash(git branch --delete*),Bash(git branch --move*),Bash(git branch -f*),Bash(git cherry-pick*),Bash(git revert*),Bash(git apply*),Bash(git am*),Bash(claude *),Bash(codex *),Bash(grok *),Bash(cursor *),Bash(agy *),Bash(op *),Bash(git tag*),Bash(git update-ref*),Bash(git config*),Bash(git remote add*),Bash(git remote remove*),Bash(git remote rm*),Bash(git remote rename*),Bash(git remote set-url*),Bash(git remote prune*),Bash(git notes*),Bash(git branch --force*),Bash(git replace*),Bash(gh pr merge*),Bash(gh pr close*),Bash(gh pr create*),Bash(gh pr edit*),Bash(gh pr ready*),Bash(gh release*),Bash(gh repo*),Bash(gh api*),Bash(vercel *),Bash(supabase db push*),Bash(supabase db reset*),Bash(supabase migration up*),Bash(supabase link*),Bash(npm publish*),Bash(pnpm publish*)'
# 使えるツールの集合に入れてはいけないもの（入っていたら起動しない）
typeset -ga LANES_CLAUDE_REVIEW_TOOLS_FORBIDDEN=(Edit Write MultiEdit NotebookEdit Agent Task)
# CLAUDE_REVIEW_TOOLS を確かめ、渡す値を LANES_CLAUDE_REVIEW_TOOLS / LANES_CLAUDE_REVIEW_DENY に入れる。
# 使えるツール: カンマ区切りのツール名（英数字と _）だけ。編集系・サブエージェントが入っていたら lanes_die（exit 2）。
# 拒否: 固定の一覧 + CLAUDE_REVIEW_DENY（重ねて書いたものは 1 つにまとめる）
lanes_claude_review_resolve() {
  setopt localoptions extendedglob
  local -a tools extra deny
  local t
  tools=("${(@s:,:)${CLAUDE_REVIEW_TOOLS:-Bash,Read,Glob,Grep}}")
  tools=("${(@)tools##[[:space:]]##}"); tools=("${(@)tools%%[[:space:]]##}"); tools=(${tools:#})
  (( ${#tools} )) || lanes_die "CLAUDE_REVIEW_TOOLS が空"
  for t in "${tools[@]}"; do
    [[ "$t" =~ '^[A-Za-z][A-Za-z0-9_]*$' ]] || lanes_die "CLAUDE_REVIEW_TOOLS にツール名でないものがある: '$t'（カンマ区切りのツール名だけ書く）"
    (( ${LANES_CLAUDE_REVIEW_TOOLS_FORBIDDEN[(Ie)$t]} == 0 )) || lanes_die "CLAUDE_REVIEW_TOOLS に編集系かサブエージェントのツールがある: $t（レビュー・QA は読み取り専用。外して起動し直す）"
  done
  deny=("${(@s:,:)LANES_CLAUDE_REVIEW_DENY_BASE}")
  extra=("${(@s:,:)${CLAUDE_REVIEW_DENY:-}}")
  extra=("${(@)extra##[[:space:]]##}"); extra=("${(@)extra%%[[:space:]]##}"); extra=(${extra:#})
  for t in "${extra[@]}"; do
    (( ${deny[(Ie)$t]} )) || deny+=("$t")
  done
  typeset -g LANES_CLAUDE_REVIEW_TOOLS="${(j:,:)tools}" LANES_CLAUDE_REVIEW_DENY="${(j:,:)deny}"
}

# ---- 排他を取る前の誤りも「今回の失敗」として残す ----
# 引数の誤り・--base の形の誤りなどで lanes_mark_start（label の排他）より前に止まると、同じ label の前回の .done が残ったままになり、
# lanes-status.sh が前回の DONE を返して、起動していないのに成功と取り違える。
# ランチャは label が決まった時点で lanes_early_target を呼ぶ。以後 lanes_mark_start までの lanes_die は、
# その label の排他を取れたときだけ .pid / .done を回転して今回の .done（EXIT:2・VERDICT: NONE・note=起動前の誤り）を書く。
# 排他を取れない（同じ label が実行中）・前回の子が生きているときは、その旨を出して前回の記録には触らない。
# logs/ が無い（worktree が無い・一度も起動していない）ときは前回の記録も無いので何も作らない。dry-run は記録しない。
# 下の内部の変数は外から持ち込ませない（呼び出し元の環境に同じ名前があっても、この起動の誤りとして扱わない）
unset LANES_DEFERRED_ERROR LANES_EARLY_LABEL LANES_EARLY_LOGDIR LANES_CHECKS_PRESENT
# 1 = 必須検証（typecheck / lint / unit）は親の chk-run.sh の記録で済んでいる（レビューランチャが問い合わせて決める）。
# 判定（lanes_parse_review）へ引数で渡す。環境から持ち込ませない（export しない・ここで 0 に戻す）
typeset -g +x LANES_REVIEW_CHECKS_REUSED=0
lanes_defer_die() {   # 引数の誤りを label が決まるまで保留する（最初の 1 件だけ覚える）
  [[ -n "${LANES_DEFERRED_ERROR:-}" ]] || typeset -g LANES_DEFERRED_ERROR="$*"
}
# 設定値の誤り（lanes.env が LANES_CONFIG_ERROR に残したもの。ランチャから読んだときだけ）も同じく保留し、
# label が決まった時点で今回の失敗（EXIT:2）として .done に残す
[[ -z "${LANES_CONFIG_ERROR:-}" ]] || lanes_defer_die "設定の誤り: $LANES_CONFIG_ERROR"
lanes_unknown_opt_width() {   # <不明なオプション> [次の語...]。読み捨てる語の数（1 か 2）を REPLY に入れる
  # label は指示書の直後に置くきまり。値を取るつもりの書き方（--mode full）の値 full を label と取り違えないよう、
  # 次の語が - で始まらなければ、そのオプションの値として一緒に読み捨てる（--name=value の形は値が同じ語にあるので読み捨てない）
  typeset -g REPLY=1
  if [[ "$1" != *=* ]] && (( $# >= 2 )) && [[ "$2" != -* ]]; then REPLY=2; fi
}
lanes_early_target() {   # <worktree> <label> <dry-run なら 1>。保留中の引数の誤りがあれば、ここで止める（記録してから exit 2）
  local wt="$1" label="$2" dry="${3:-0}"
  if [[ "$dry" != 1 && "$label" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' && -n "$wt" && -d "$wt/logs" && ! -L "$wt/logs" ]]; then
    typeset -g LANES_EARLY_LOGDIR="${wt:A}/logs" LANES_EARLY_LABEL="$label"
  fi
  [[ -z "${LANES_DEFERRED_ERROR:-}" ]] || lanes_die "$LANES_DEFERRED_ERROR"
}
lanes_record_early_failure() {
  (( ZSH_SUBSHELL )) && return 0
  [[ -n "${LANES_EARLY_LABEL:-}" && -n "${LANES_EARLY_LOGDIR:-}" ]] || return 0
  [[ -z "${LANES_DONEFILE:-}" ]] || return 0   # 排他を取った後は TRAPEXIT が .done を書く
  local logdir="$LANES_EARLY_LOGDIR" label="$LANES_EARLY_LABEL" msg="${1//$'\n'/ }" fd=""
  unset LANES_EARLY_LABEL LANES_EARLY_LOGDIR   # ここから先の lanes_die で再び記録しない
  local pidfile="$logdir/$label.pid" donefile="$logdir/$label.done"
  [[ -d "$logdir" && ! -L "$logdir" ]] || return 0
  # logs/ の中に外を指すファイル（symlink・ハードリンクなど）があれば、辿って書かないよう記録をあきらめる
  lanes_logdir_entries_ok "$logdir" 2>/dev/null || { print -u2 -- "NOTE: logs/ の中に symlink などがあるので、失敗の記録（$label.done）は書かない"; return 0; }
  zmodload zsh/system 2>/dev/null || return 0
  ( : >> "$logdir/$label.lock" ) 2>/dev/null || return 0
  if ! zsystem flock -t 0 -f fd "$logdir/$label.lock" 2>/dev/null; then
    print -u2 -- "NOTE: 同じ label が実行中のため、前回の記録（$label.done）には触らない。lanes-status.sh はその実行の状態を返す"
    return 0
  fi
  if [[ -f "$pidfile" ]] && { lanes_pid_alive "$pidfile" || lanes_child_alive "$pidfile"; }; then
    print -u2 -- "NOTE: 同じ label の前回のプロセスが生きているため、前回の記録（$label.done）には触らない"
    return 0
  fi
  lanes_rotate_log "$pidfile"; lanes_rotate_log "$donefile"
  {
    print -- "EXIT:2"
    print -- "VERDICT: NONE"
    print -- "finished=$(lanes_now)"
    print -- "elapsed_min=0"
    print -- "note=起動前の誤り: $msg"
  } > "$donefile"
  print -u2 -- "NOTE: 今回の失敗を $donefile に残した（lanes-status.sh は FAILED を返す）"
}
lanes_now() { date '+%Y-%m-%d %H:%M:%S %Z'; }

# zsh -f は .zshrc を読まないので PATH は起動元の継承だけ。python3 は必須
command -v python3 >/dev/null 2>&1 || lanes_die "python3 が PATH に無い"

# バイナリが無ければ PATH から探す
lanes_resolve_bin() {
  local var="$1" name="$2"
  # -x はフォルダでも真になるので、ふつうのファイルであることも確かめる
  if [[ -z "${(P)var}" || ! -f "${(P)var}" || ! -x "${(P)var}" ]]; then
    local found; found="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$found" ]] || lanes_die "$name が見つからない（${var} にも PATH にも無い）。入れてから lanes-doctor.sh で確かめる"
    typeset -g "$var"="$found"
  fi
}

# 環境変数の effort が、設定ファイル（無ければ既定）と違う値で勝っているときだけ、注意を 1 行出す（stderr）。
# <キー> = CLAUDE_EFFORT / CODEX_EFFORT / GEMINI_EFFORT。各ランチャが、自分の使うキーについて起動時に 1 回呼ぶ。
# 経緯: アプリから起動したシェルが CLAUDE_EFFORT を環境変数として持っていて、設定ファイルに書いた値が黙って負けたことがあった。
# 勝つ順番（環境変数 > 設定ファイル > 既定）は変えない。知らせるだけで、CLI に渡す値も子の環境も変えない
lanes_effort_override_note() {
  local key="$1" now conf_value
  (( ${+LANES_EFFORT_FROM_ENV[$key]} )) || return 0   # 環境変数で渡されていない（lanes.env が控えを作る）
  now="${(P)key}"
  # 環境変数が無かったら何になるか（設定ファイル、無ければ既定）を、子シェルで設定を読み直して確かめる。今のシェルの値は変えない
  conf_value="$( { unset CLAUDE_EFFORT CODEX_EFFORT GEMINI_EFFORT LANES_DEFER_CONFIG_ERROR
                   source "$LANES_DIR/lanes.env" && print -r -- "value:${(P)key}" } 2>/dev/null )" || return 0
  conf_value="${conf_value##*$'\n'}"   # 設定ファイルが何か出力していても、最後の 1 行だけを見る
  [[ "$conf_value" == value:* ]] || return 0
  conf_value="${conf_value#value:}"
  [[ "$now" != "$conf_value" ]] || return 0
  print -u2 -- "注意: $key は環境変数の値「${now:-（空＝付けない）}」で動く。設定ファイル（無ければ既定）の値「${conf_value:-（空＝付けない）}」は使われない（環境変数が設定ファイルより勝つ）。設定の値に固定するなら、設定ファイルに $key=\"$conf_value\" と値をそのまま書く（docs/config.md）"
}

# 今の構成（LANES_TOOLS）にこの道具が入っているか。入っていなければ代わりの入口を案内して止める（exit 2）。
# mark_start の後に呼べば TRAPEXIT が .done（EXIT:2）を残す。<tool>=claude|codex|gemini <launcher>=呼び出し元の名前
lanes_require_tool() {
  local tool="$1" launcher="${2:-このランチャ}"
  # 役割の判定は使うときだけ読み込む（_common.sh だけを使うスクリプトに lanes-roles.sh を要求しない）
  if (( ! ${+functions[lanes_roles_resolve]} )); then
    [[ -f "$LANES_DIR/lanes-roles.sh" ]] || lanes_die "lanes-roles.sh が無い: $LANES_DIR"
    source "$LANES_DIR/lanes-roles.sh"
  fi
  lanes_roles_resolve || lanes_die "$LANES_ROLES_ERROR"
  lanes_roles_has_tool "$tool" && return 0
  lanes_die "この構成では使えない: $launcher は $tool を使うが、構成 $LANES_PROFILE（LANES_TOOLS=\"$LANES_TOOLS_NORMALIZED\"）に $tool が無い。代わりに run-impl.sh（実装）/ run-review.sh（レビュー）を使う"
}

# 入口（run-impl.sh / run-review.sh）から来たときだけ、構成全体の起動前点検（lanes-doctor.sh --quiet）をする。
# 入口は LANES_ENTRY_PREFLIGHT=1 を付けて振り分け先へ exec し、振り分け先が lanes_mark_start の後にこれを呼ぶ。
# こうすると点検の失敗も今回の .done（EXIT:2）として残り、同じ label の前回の成功（DONE）と取り違えない。
# 直接ランチャを呼んだときは何もしない（そのランチャ自身の道具の点検だけが走る）。子の CLI へ引き継がないよう外す。
lanes_entry_preflight() {
  [[ "${LANES_ENTRY_PREFLIGHT:-0}" == 1 ]] || return 0
  unset LANES_ENTRY_PREFLIGHT
  zsh -f "$LANES_DIR/lanes-doctor.sh" --quiet || lanes_die "起動前点検（lanes-doctor.sh）で足りないものがある → 起動しない"
}

# <worktree> <gitdir> <共通の管理フォルダ> → git の制御ファイルの指紋（子の実行の前後で比べる）。
# 子の実行中に書き換えられると、ランチャがサンドボックス（閉じ込め）の外で回す git（status・後の push・cleanup）が
# 任意のコマンドを動かし得るファイルが対象: worktree の .git ファイル・gitdir の commondir / gitdir / config / config.worktree、
# 共通の config / config.worktree・hooks の中身（下のフォルダも）。git は呼ばない（呼ぶ前に比べるため）。値は出さず指紋だけ出す。
# gitdir と共通の管理フォルダは、子を起動する前に git で確かめた値を渡す（子の後で git に聞き直さない）
lanes_git_ctl_fingerprint() {
  python3 - "$1/.git" "$2" "$3" <<'PY_GIT_CTL_FP'
import hashlib, os, pathlib, sys
dotgit, gitdir, common = (pathlib.Path(a) for a in sys.argv[1:4])
h = hashlib.sha256()
def add(p):
    h.update(os.fsencode(str(p)) + b'\0')
    try:
        if p.is_symlink(): h.update(b'link:' + os.fsencode(os.readlink(p)))
        elif p.is_file(): h.update(b'file:' + str(p.stat().st_mode).encode() + b':' + p.read_bytes())
        elif p.is_dir(): h.update(b'directory')
        else: h.update(b'missing')
    except OSError:
        h.update(b'unreadable')
for p in [dotgit, gitdir / 'commondir', gitdir / 'gitdir', gitdir / 'config', gitdir / 'config.worktree',
          common / 'config', common / 'config.worktree', common / 'hooks']:
    add(p)
hooks = common / 'hooks'
if hooks.is_dir() and not hooks.is_symlink():
    for root_dir, dirs, files in os.walk(hooks):
        dirs.sort()
        for name in sorted(dirs + files): add(pathlib.Path(root_dir) / name)
print(h.hexdigest())
PY_GIT_CTL_FP
}

# レビュー・QA の子プロセスから git の通信（push・fetch）をできなくする。読み取り専用の役なので通信は要らない。
# GIT_ALLOW_PROTOCOL に実在しない名前だけを入れると、git はすべての通信方式（ssh・https・ローカルのパスの file など）を拒否する。
# この環境変数は git の設定（-c protocol.allow=always など）より優先される。リモート名や pushurl の有無に関係なく効く。
# 子が環境変数そのものを外して git を動かす操作までは防げない（うっかりの push を止めるための仕組み）。
lanes_block_git_transport() {
  export GIT_ALLOW_PROTOCOL="lanes-no-transport"
}

lanes_require_worktree() {
  local wt="$1"
  [[ -d "$wt" ]] || lanes_die "worktree が無い: $wt"
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || lanes_die "git 作業ツリーじゃない: $wt"
  git -C "$wt" rev-parse --verify -q HEAD >/dev/null 2>&1 || lanes_die "commit が 1 つも無い（HEAD 無し）: $wt"
}

lanes_require_prompt() {
  local p="$1"
  [[ -s "$p" ]] || lanes_die "プロンプトが無いか空: $p"
  local bytes; bytes=$(wc -c < "$p" | tr -d ' ')
  # lanes.env が確かめ済みだが、計算に入れる直前にも数字だけかを見る（lanes.env を差し替えた環境でも値の中身を実行しない）
  [[ "${LANES_PROMPT_MAX_BYTES:-}" == <-> ]] || lanes_die "LANES_PROMPT_MAX_BYTES は整数で書く"
  (( bytes < LANES_PROMPT_MAX_BYTES )) || lanes_die "プロンプトが大きすぎる（${bytes} bytes）。diff を埋め込まず『自分で読め』と指示する"
}

# 既存ログを <name>.prev-<日時>.<ext> に退避。失敗したら止める（黙って上書きしない）
lanes_rotate_log() {
  local f="$1"; [[ -f "$f" || -L "$f" ]] || return 0
  local base="${f:t}" dir="${f:h}" ts dest n=0; ts="$(date +%Y%m%d-%H%M%S)"
  if [[ "$base" == *.* ]]; then dest="$dir/${base%.*}.prev-$ts.${base##*.}"; else dest="$f.prev-$ts"; fi
  while [[ -e "$dest" ]]; do n=$(( n + 1 )); if [[ "$base" == *.* ]]; then dest="$dir/${base%.*}.prev-$ts-$n.${base##*.}"; else dest="$f.prev-$ts-$n"; fi; done   # 同一秒でも上書きしない
  mv "$f" "$dest" || lanes_die "ログ回転に失敗: $f"
}

# ---- ログイン状態の判定（本文はエラー・引数・ログへ一切転記しない。結果は決まった語だけ）----
# Codex: subscription（ChatGPT でログイン）/ apikey（API キーでログイン）/ none（未ログイン）/ unknown（確認できない）
lanes_codex_auth_state() {
  local s rc=0; s="$("$CODEX_BIN" login status < /dev/null 2>&1)" || rc=$?
  # status には API キーの断片が含まれうる。完全一致だけを合格にする。
  if (( rc == 0 )) && [[ "$s" == "Logged in using ChatGPT" ]]; then print subscription
  elif [[ "$s" == *"API key"* || "$s" == *"api key"* || "$s" == *"API Key"* ]]; then print apikey
  elif [[ "$s" == *"Not logged in"* || "$s" == *"not logged in"* ]]; then print none
  else print unknown
  fi
}

# Claude: subscription（claude.ai サブスク）/ apikey（ほかの認証方式）/ none（未ログイン）/ unknown（確認できない）
lanes_claude_auth_state() {
  local s rc=0; s="$("$CLAUDE_BIN" auth status < /dev/null 2>/dev/null)" || rc=$?
  # JSON 本文をプロセス引数へ渡さず、標準入力だけで検査する。
  print -r -- "$s" | python3 -c '
import json, sys
rc = int(sys.argv[1])
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
if not isinstance(d, dict):
    print("unknown")
elif d.get("loggedIn") is False:
    print("none")
elif rc != 0 or d.get("loggedIn") is not True:
    print("unknown")
elif d.get("authMethod") == "claude.ai":
    print("subscription")
else:
    print("apikey")
' "$rc" || print unknown
}

# Gemini（agy）: ログインを確かめるサブコマンドが無いので、ログイン情報の置き場所の有無で見る（中身は読まない）
lanes_gemini_auth_state() {
  if [[ -d "$HOME/.gemini/antigravity-cli" ]]; then print subscription; else print none; fi
}

# Codex: ChatGPT サブスクでログインしているときだけ通す
lanes_check_codex_subscription() {
  lanes_resolve_bin CODEX_BIN codex
  [[ "$(lanes_codex_auth_state)" == subscription ]] || lanes_die "Codex の ChatGPT サブスク認証を確認できない → 起動禁止（codex login で ChatGPT にログインする。API キーは不可）"
}

# Claude: claude.ai サブスクでログインしているときだけ通す
lanes_check_claude_subscription() {
  lanes_resolve_bin CLAUDE_BIN claude
  local st; st="$(lanes_claude_auth_state)"
  [[ "$st" == unknown ]] && lanes_die "Claude のサブスク認証を確認できない → 起動禁止"
  [[ "$st" == subscription ]] || lanes_die "Claude が claude.ai サブスクでログインしていない → 起動禁止"
}

# <worktree>: 実行場所の設定も含めて列挙し、全 MCP を無効化する引数配列を返す。
# 呼び出し: lanes_codex_no_mcp_args "$wt"; cmd=("$CODEX_BIN" exec "${LANES_CODEX_NO_MCP_ARGS[@]}" ...)
# 設定本文と stderr はメモリ内でのみ扱う。失敗時は詳細を転記せず起動を拒否する。
lanes_codex_no_mcp_args() {
  (( $# == 1 )) && [[ -d "$1" ]] || lanes_die "MCP の確認対象 worktree を 1 つ指定すること"
  lanes_resolve_bin CODEX_BIN codex
  local overrides item
  overrides="$(python3 - "$CODEX_BIN" "$1" <<'PY'
import json, re, subprocess, sys
def servers(args):
    p = subprocess.run([sys.argv[1], *args, "mcp", "list", "--json"],
                       cwd=sys.argv[2], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=30)
    if p.returncode:
        raise ValueError()
    result = json.loads(p.stdout)
    if not isinstance(result, list) or any(
        not isinstance(s, dict) or not isinstance(s.get("name"), str)
        or not re.fullmatch(r"[A-Za-z0-9_-]+", s["name"])
        or not isinstance(s.get("enabled"), bool)
        or not isinstance(s.get("transport"), dict)
        or s["transport"].get("type") not in ("stdio", "streamable_http") for s in result
    ):
        raise ValueError()
    return result
try:
    values = ["features.apps=false"]
    base = servers(["-c", values[0]])
    for server in base:
        prefix = "mcp_servers." + server["name"]
        values.append(prefix + ".enabled=false")
        # 動的追加された stdio 接続は enabled だけだと不完全な設定になる。
        # 元のコマンド・引数・接続情報は転記せず、安全なダミーで設定の型を満たす。
        if server["transport"]["type"] == "stdio":
            values.append(prefix + '.command="/usr/bin/false"')
    args = [part for value in values for part in ("-c", value)]
    if any(s["enabled"] for s in servers(args)):
        raise ValueError()
    print("\n".join(values))
except Exception:
    sys.exit(1)
PY
)" || lanes_die "Codex の MCP 無効化を確認できない → 起動禁止"
  typeset -ga LANES_CODEX_NO_MCP_ARGS=()
  for item in "${(@f)overrides}"; do LANES_CODEX_NO_MCP_ARGS+=(-c "$item"); done
}

# Gemini（Antigravity CLI / agy）: サブスクのアカウントログインだけで動かす。
# API キー・ADC（アプリケーションのデフォルト認証）経由へ逸らす env を外し、ログイン情報の有無を確かめる（中身は読まない）
lanes_check_gemini_subscription() {
  lanes_resolve_bin GEMINI_BIN agy
  unset AGY_ADC_AUTH GOOGLE_APPLICATION_CREDENTIALS GOOGLE_GENAI_USE_VERTEXAI GOOGLE_CLOUD_PROJECT
  [[ "$(lanes_gemini_auth_state)" == subscription ]] || lanes_die "agy のログイン情報が無い（~/.gemini/antigravity-cli）→ 起動禁止。対話モードの agy でサブスクのアカウントにログインする"
}

# 「枝 @ HEAD (origin/<統合先の枝> @ SHA)」。統合先は LANES_BASE_BRANCH
lanes_git_summary() {
  local wt="$1" br head base ref="origin/${LANES_BASE_BRANCH:-develop}"
  br="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$br" ]] || br="(detached)"
  head="$(git -C "$wt" rev-parse --short=12 HEAD 2>/dev/null || echo '?')"
  base="$(git -C "$wt" rev-parse --short=12 --end-of-options "$ref" 2>/dev/null || echo '?')"
  print -- "$br @ $head ($ref @ $base)"
}

# 判定・指摘数は同じ解析器で読む。コード例・引用・表を判定として採用しない。
# P0/P1（P2 も従来どおり）は CLEAN より優先。自由文だけの「問題なし」は完了の証拠にならない。
# NONE の呼び出し側は EXIT:3 等の非正常終了へ変換する（解析関数自体は文字列を返す）。
# 対象の作業ツリーに、必須検証（typecheck / lint / unit）の仕組みがあるかを機械的に見る。
# レビュー役が「該当なし（未導入）」（NA）と書いても、仕組みがある項目なら判定でその NA を受け付けない（自己申告だけを根拠にしない）。
# 出力（スペース区切り）: typecheck / lint / unit … package.json の scripts にその項目がある
#                        all … LANES_CHECK_CMD が設定されているか .lanes/check.sh がある（3 項目すべてを NA にはできない）
# 判定の呼び出し（lanes_parse_review）の前に LANES_CHECKS_PRESENT へ入れて渡す。中身（scripts の本文）は出さない
lanes_checks_present() {   # <worktree>
  python3 -I - "$1" <<'PYCHECKS'
import json, os, sys
wt = sys.argv[1]
try:
    with open(os.path.join(wt, "package.json"), encoding="utf-8") as f:
        scripts = json.load(f).get("scripts") or {}
except (OSError, ValueError, AttributeError):
    scripts = {}
if not isinstance(scripts, dict):
    scripts = {}
def has(*names):
    # npm init の既定（"no test specified" で失敗するだけの test）は仕組みとして数えない
    return any(isinstance(scripts.get(n), str) and scripts[n].strip() and "no test specified" not in scripts[n] for n in names)
out = []
if has("typecheck", "type-check", "typecheck:all", "check-types", "tsc"): out.append("typecheck")
if has("lint"): out.append("lint")
if has("test", "test:unit", "unit", "test:ci"): out.append("unit")
if os.environ.get("LANES_CHECK_CMD", "").strip() or os.path.isfile(os.path.join(wt, ".lanes", "check.sh")): out.append("all")
print(" ".join(out))
PYCHECKS
}

LANES_FINDING_RE='^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+)?(\*\*)?\[P'
lanes_parse_review() {   # <log> <extract|infer|codex|checks|resolved|followups|P0|P1|P2|P3> [完了証明]
  python3 - "$1" "$2" "${3:-}" "${LANES_REVIEW_CHECKS_REUSED:-0}" <<'PYREVIEW'
import hashlib, json, os, pathlib, re, sys
mode = sys.argv[2]
# 必須検証を親の chk-run.sh の記録で済ませたレビュー。未実施・省略の報告は不足に数えず、失敗の報告だけ不足にする
reused = len(sys.argv) > 4 and sys.argv[4] == "1"
# 完了証明のハッシュは書き手（codex-review-output.py）と同じくバイト列で取る。
# read_text の改行変換（\r → \n）を挟むと、完了していても照合が外れる。
try:
    raw_bytes = pathlib.Path(sys.argv[1]).read_bytes()
    raw = raw_bytes.decode("utf-8")
except (OSError, UnicodeError):
    raw_bytes, raw = b"", ""
lines, validation_lines, fence, width = [], [], None, 0
for line in raw.splitlines():
    stripped = line.strip()
    marker = re.match(r"^(`{3,}|~{3,})(.*)$", stripped)
    if marker:
        token, suffix = marker.groups()
        if fence is None:
            fence, width = token[0], len(token)
        elif token[0] == fence and len(token) >= width and not suffix.strip():
            fence = None
        continue
    if fence is not None or line.startswith(("    ", "\t")) or stripped.startswith(">"):
        continue
    if stripped.startswith("|"):
        # 表の判定文字列は採用しないが、テンプレ指定の検証結果表は不足の判定に使う。
        cells = [cell.strip().strip("*`") for cell in stripped.strip("|").split("|")]
        if len(cells) >= 2:
            validation_lines.append(cells[0] + ": " + " ".join(cells[1:]))
        continue
    if stripped:
        lines.append(stripped)
        validation_lines.append(stripped)
findings = [0, 0, 0, 0]
verdicts = []
blocks = []
block = None
for line in lines:
    content = re.sub(r"^(?:[-*+]|[0-9]+[.)])\s+", "", line)
    finding = re.match(r"^(?:\*\*)?\[P([0-3])\](?:\*\*)?(?:\s|$)", content)
    if finding:
        findings[int(finding[1])] += 1
        block = [int(finding[1]), [line]]
        blocks.append(block)
    elif block is not None:
        if re.match(r"^(?:[-*+]\s+)?(?:VERDICT:|#{1,6}\s|----)", line):
            block = None
        else:
            block[1].append(line)
    # 番号付きリストの判定例は採用しない。従来の箇条書き・太字・行内コードは許可する。
    candidate = re.sub(r"^[-*+]\s+", "", line)
    for wrapper in ("**", "`"):
        if candidate.startswith(wrapper) and candidate.endswith(wrapper):
            candidate = candidate[len(wrapper):-len(wrapper)].strip()
    match = re.fullmatch(r"VERDICT:\s*(CLEAN|NEEDS_FIX|PASS)", candidate)
    if match:
        verdicts.append((line, "CLEAN" if match[1] == "PASS" else match[1]))
if re.fullmatch(r"P[0-3]", mode):
    print(findings[int(mode[1])])
    sys.exit(0)
if mode == "followups":
    saved = ["\n".join(body) for level, body in blocks if level >= 2]
    if not saved:
        sys.exit(1)
    print("\n\n".join(saved))
    sys.exit(0)
text = "\n".join(lines)
# 前回の未解決指摘の解消宣言。コード例・引用・表・閉じていないコード領域の中は採用しない。
# 否定（NO）が 1 行でもあれば解消扱いにしない。
if mode == "resolved":
    marks = [re.fullmatch(r"RESOLVED_PREVIOUS_FINDINGS:[ \t]*(YES|NO)", line) for line in lines]
    marks = [m[1] for m in marks if m]
    print("YES" if fence is None and marks and all(m == "YES" for m in marks) else "NO")
    sys.exit(0)
# 指摘の重大度とは別に、必須検証が完了したかを判定する。
# build はレビュー段階では回さない（統合先（LANES_BASE_BRANCH）に入れる直前の最終 head の chk-run と CI で 1 回だけ担保）。
# build だけの「未実施・省略」は正当な報告として受理し、build の「失敗」と、他の項目の未実施は従来どおり不足とする。
# 対象リポジトリにその仕組み自体が無い項目は、成功行で NA（該当なし（未導入））として受理する。本文の「該当なし（未導入）」は未実施に数えない。
build_name = r"(?:build|ビルド)"
check_name = r"(?:typecheck|型検査|型チェック|lint|unit(?:[ \t]+tests?)?|単体テスト|build|ビルド)"
check_group = check_name + r"(?:[ \t]*(?:[/・、,&]|and)[ \t]*" + check_name + r")*"
not_checked = r"(?:未実施|未実行|未完了|未検証|省略|できません|できなかった|できない|できず|行っていない|実行していない|失敗|not (?:run|performed|executed|completed)|skip(?:ped)?|fail(?:ed)?|pending|blocked)"
build_failed = r"(?:失敗|fail(?:ed)?)"
# 指摘の説明（例: ビルド失敗時の処理）や、省略を許可された E2E は状態報告と区別する。
missing_re = re.compile(
    r"^(?:[-*+][ \t]+)?(?P<group>" + check_group + r"|必須検証|検証)[ \t]*(?:は|が|を|に)?[ \t]*[:：]?[ \t]*"
    + r"(?P<state>" + not_checked + r")(?=[ \t]*(?:[。.!（(]|$))"
    + r"|^(?:[-*+][ \t]+)?(?:did not|could not|cannot|unable to)[ \t]+(?:run|execute|complete)[ \t]+(?P<name>" + check_name + r")",
    re.I | re.M)
def is_build_only(names):
    parts = [p for p in re.split(r"[ \t]*(?:[/・、,&]|and)[ \t]*", names or "", flags=re.I) if p]
    return bool(parts) and all(re.fullmatch(build_name, p, re.I) for p in parts)
def counts_as_missing(m):
    if reused:
        return m["group"] is not None and re.fullmatch(build_failed, m["state"], re.I) is not None
    if m["group"] is not None:
        return not (is_build_only(m["group"]) and not re.fullmatch(build_failed, m["state"], re.I))
    return not is_build_only(m["name"])
# 項目名の太字・行内コード（`**lint**: 未実施`、`` `lint`: 該当なし ``）は、表のセルと同じく飾りを外してから判定する。
validation_text = "\n".join(re.sub(r"\*\*|`", "", line) for line in validation_lines)
checks_missing = any(counts_as_missing(m) for m in missing_re.finditer(validation_text))
check_lines = [line for line in lines if line.startswith("CHECKS:")]
# 該当なし（NA）の自己申告を、ランチャが機械的に見た仕組みの有無（LANES_CHECKS_PRESENT。lanes_checks_present）と突き合わせる。
# 仕組みがある項目の NA、汎用の仕組み（LANES_CHECK_CMD・.lanes/check.sh）があるのに 3 項目すべて NA は、未実施と同じ扱い。
present = set(os.environ.get("LANES_CHECKS_PRESENT", "").split())
def canon(name):
    if re.fullmatch(r"typecheck|型検査|型チェック", name, re.I): return "typecheck"
    if re.fullmatch(r"lint", name, re.I): return "lint"
    if re.fullmatch(r"unit(?:[ \t]+tests?)?|単体テスト", name, re.I): return "unit"
    return ""
na_items = set()
for line in check_lines:
    na_items |= set(re.findall(r"\b(typecheck|lint|unit)=NA\b", line))
na_re = re.compile(r"^(?:[-*+][ \t]+)?(?P<group>" + check_group + r")[ \t]*(?:は|が)?[ \t]*[:：]?[ \t]*(?:該当なし|N/?A\b|未導入|導入されていない|導入していない|仕組みが(?:無い|ない|ありません))", re.I | re.M)
for m in na_re.finditer(validation_text):
    for part in re.split(r"[ \t]*(?:[/・、,&]|and)[ \t]*", m["group"], flags=re.I):
        if canon(part): na_items.add(canon(part))
na_blocked = bool(na_items & present) or ("all" in present and {"typecheck", "lint", "unit"} <= na_items)
checks_complete = (len(check_lines) == 1
                   and re.fullmatch(r"CHECKS: typecheck=(?:PASS|NA) lint=(?:PASS|NA) unit=(?:PASS|NA) build=(?:PASS|SKIP)", check_lines[0]) is not None
                   and not checks_missing and not na_blocked and fence is None)
if reused:
    # 成功行は求めない（記録で済んでいる）。NA の自己申告も問わない。成功行に FAIL があれば失敗の報告として扱う
    checks_missing = checks_missing or any(re.search(r"=FAIL\b", line) for line in check_lines)
    na_blocked = False
    checks_complete = not checks_missing and fence is None
if mode == "checks":
    print("COMPLETE" if checks_complete else "INCOMPLETE")
    sys.exit(0)
# 「確認できなかった点はない」のように、直後で否定された言い回しはレビュー不能の報告として扱わない。
# 「…ないとは言えない」「…ないわけではない」「…ないか」のような打ち消し・疑問は否定として扱わない（安全側）。
ja_negated = (r"(?![ \t]*(?:点|こと|もの|箇所|項目|部分|範囲)?[ \t]*(?:は|も)?[ \t]*(?:ない|無い|なし|無し|ありません|ございません)"
              r"(?![ \t]*(?:とは|と言|といえ|わけ|か|かも|のでは)))")
unavailable = re.search(
    r"(?:レビュー|review).{0,40}(?:できません|できなかった|できない|できず|行えません|行えなかった|行えない|未実施|未完了)" + ja_negated +
    r"|(?:unable to|could not|cannot|failed to)\s+(?:complete |perform |run )?(?:the )?review"
    r"|review (?:was not|not) (?:performed|completed)"
    r"|review (?:was )?(?:interrupted|aborted|incomplete)"
    r"|(?:レビュー|review).{0,40}(?:中断|途中終了)" + ja_negated, text, re.I)
completed = False
if mode == "codex" and sys.argv[3]:
    try:
        proof = json.loads(pathlib.Path(sys.argv[3]).read_text())
        completed = proof.get("completed") is True and proof.get("sha256") == hashlib.sha256(raw_bytes).hexdigest()
    except (OSError, ValueError, AttributeError):
        pass
# Codex は完了イベントと最終本文を別々に返す。肯定の成功文も両方揃う場合だけ採用する。
success = re.search(
    r"\bno (?:actionable )?(?:issues|bugs|findings) (?:were )?(?:found|identified)\b"
    r"|\bdid not find any (?:discrete, actionable )?(?:bugs|issues)\b"
    r"|(?:修正が必要な(?:具体的な)?(?:不具合|問題)|新たな不具合|変更に問題|不具合|問題)は?"
    r"(?:確認できなかった|見つかりませんでした|見つからなかった)", text, re.I)
if unavailable or fence is not None:
    verdict = "NONE"
elif mode == "codex" and sys.argv[3] and not completed:
    verdict = "NONE"
elif checks_missing or na_blocked or (check_lines and not checks_complete):
    verdict = "NEEDS_FIX"
elif any(findings[:3]):
    verdict = "NEEDS_FIX"
elif mode != "infer" and verdicts and verdicts[-1][0] == lines[-1]:
    verdict = "NEEDS_FIX" if any(v == "NEEDS_FIX" for _, v in verdicts) else verdicts[-1][1]
elif completed and success and not verdicts:
    verdict = "CLEAN"
else:
    verdict = "NONE"
print("VERDICT: " + verdict)
PYREVIEW
}
lanes_extract_verdict() { lanes_parse_review "$1" extract; }
lanes_count_findings() { lanes_parse_review "$1" "$2"; }
lanes_infer_verdict() { lanes_parse_review "$1" infer; }
lanes_codex_verdict() { lanes_parse_review "$1" codex "${2:-}"; }

# ---- 起動の事実と生死をファイルで残す（lanes-status.sh が読む）----
# <label>.pid  : 起動時。pid= / lstart=（プロセス開始時刻。pid 再利用の誤判定防止）/ started= / started_epoch= / lane= / worktree= / child_pid=
# <label>.done : 終了時。EXIT:n / VERDICT: ... / finished= / elapsed_min= / note=
# ランチャは worktree 確認の直後（プロンプト・サブスク等の前提チェックより前）に mark_start する。
# 以後どこで落ちても TRAPEXIT が .done を書くので、同じ label の古い DONE が status に残らない

# label は英数と . _ - だけ（logs/ の外に書かせない）
lanes_require_label() {
  [[ "$1" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || lanes_die "label は英数と . _ - のみ（先頭は英数。渡されたのは '$1'）。第 3 引数で label を指定する"
}

# プロセス開始時刻。ps の lstart は TZ とロケールで表記が変わるので固定して取る（起動側と status 側で環境が違っても一致させる）
lanes_ps_lstart() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

# 同一性不明は終了済みと区別する。削除・再起動は止め、停止信号は送らない。
lanes_process_state() {
  python3 - "$1" "$2" <<'PY'
import os, subprocess, sys
try:
    pid = int(sys.argv[1])
    if pid <= 1:
        print("dead"); sys.exit()
    os.kill(pid, 0)
except ProcessLookupError:
    print("dead"); sys.exit()
except (ValueError, PermissionError, OSError):
    print("unknown"); sys.exit()
try:
    p = subprocess.run(["ps", "-o", "lstart=,stat=", "-p", str(pid)],
                       env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
                       capture_output=True, text=True, timeout=3)
    fields = p.stdout.split()
    if p.returncode or len(fields) != 6:
        raise ValueError()
    current, state = " ".join(fields[:5]), fields[5]
    expected = " ".join(sys.argv[2].split())
    print("dead" if state.startswith("Z") or (expected and expected != current)
          else "alive" if expected else "unknown")
except (ValueError, OSError, subprocess.SubprocessError):
    print("unknown")
PY
}
lanes_process_alive() {
  [[ "$(lanes_process_state "$1" "$2")" != dead ]]
}
lanes_pid_alive() {
  local f="$1" pid started
  [[ -f "$f" ]] || return 1
  pid="$(sed -n 's/^pid=//p' "$f" | head -1)"
  started="$(sed -n 's/^lstart=//p' "$f" | head -1)"
  lanes_process_alive "$pid" "$started"
}
lanes_child_alive() {
  local f="$1" pid started
  [[ -f "$f" ]] || return 1
  pid="$(sed -n 's/^child_pid=//p' "$f" | head -1)"
  started="$(sed -n 's/^child_lstart=//p' "$f" | head -1)"
  [[ -n "$pid" ]] && lanes_process_alive "$pid" "$started"
}

# ランチャが子を起動した直後に呼ぶ。開始時刻はメモリにも保持する。
# .pid に子の記録を書く。子は起動直後から logs/ を触れるので、.pid をパスのまま追記しない。
# 起動時に書いた中身（LANES_PIDFILE_BASE）＋子の記録を、名前の分からない一時ファイルに書いてから置き換える
# （置き換えは名前の付け替えなので、.pid が symlink に差し替えられていてもその先は書き換えない）。再実行でも今の子だけが残る
lanes_record_child() {
  typeset -g LANES_CHILD_LSTART="$(lanes_ps_lstart "$1" || true)"
  [[ -n "${LANES_PIDFILE:-}" ]] || return 0
  # logs/ を symlink を辿らずに開き、その中で一時ファイルを O_EXCL|O_NOFOLLOW で作って開いたまま書き、
  # 名前の付け替え（rename）で .pid を置き換える。パスで開き直さないので、作ってから書くまでの隙に差し替えられても外へ書かない。
  # rename は宛先の symlink を辿らず、その名前ごと置き換える（mv と違い、宛先がフォルダへのリンクでもその中へ移さない）
  print -r -- "${LANES_PIDFILE_BASE:-}"$'\n'"child_pid=$1"$'\n'"child_lstart=$LANES_CHILD_LSTART" \
    | python3 -I -c 'import os,sys
d=os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
name=sys.argv[2]; tmp=f".{name}.{os.getpid()}.{os.urandom(6).hex()}.tmp"
fd=os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=d)
try:
    with os.fdopen(fd, "wb") as f: f.write(sys.stdin.buffer.read())
    os.replace(tmp, name, src_dir_fd=d, dst_dir_fd=d)
except BaseException:
    try: os.unlink(tmp, dir_fd=d)
    except OSError: pass
    raise' "${LANES_PIDFILE:h}" "${LANES_PIDFILE:t}" || lanes_die "子の記録を .pid に書けない"
}

# 専用のプロセス集団を監督する。監督役が最後まで残るので、親コマンド終了後の孫も回収できる。
# 通常は番号・親番号・集団番号・開始時刻・状態を追跡し、独立した孫は環境の識別子を内部照合する。
# 環境本文は出力・保存しない。各送信直前にも開始時刻を照合する。
LANES_PROCESS_GUARD='
import json, os, pathlib, re, signal, subprocess, sys, time, uuid

def snapshot():
    p = subprocess.Popen(["ps", "-axo", "pid=,ppid=,pgid=,lstart=,stat="],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace",
                         env={**os.environ, "LC_ALL": "C", "TZ": "UTC"})
    try:
        output, _ = p.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        raise RuntimeError("プロセス一覧を取得できない")
    if p.returncode:
        raise RuntimeError("プロセス一覧を取得できない")
    result = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 9 and int(fields[0]) != p.pid:
            result[int(fields[0])] = (int(fields[1]), int(fields[2]), " ".join(fields[3:8]), fields[8])
    if os.getpid() not in result:
        raise RuntimeError("プロセス一覧が不完全")
    return result

def same(table, pid, start):
    row = table.get(pid)
    return row is not None and row[2] == start and not row[3].startswith("Z")

class Family:
    def __init__(self, root, start, exclude=0, token=None, baseline=None):
        self.root, self.exclude = root, exclude
        self.known = {root: " ".join(start.split())}
        self.token = token
        self.checked = {pid: row[2] for pid, row in (baseline or {}).items()}
    def belongs(self, pid, start):
        # 別集団へ移って親を失った子も、継承した識別子で見つける。
        # 環境の本文はメモリ内で照合するだけで、出力・保存・例外への転記をしない。
        p = subprocess.run(["ps", "eww", "-p", str(pid), "-o", "command="],
                           capture_output=True, text=True, errors="replace", timeout=3)
        if p.returncode:
            # 自然終了と取得障害を区別する。生存中の取得失敗は未確認のまま保持する。
            if same(snapshot(), pid, start):
                raise RuntimeError("子の所属を確認できない")
            return False
        return re.search(
            r"(?:^|\s)LANES_PROCESS_TOKEN=" + re.escape(self.token) + r"(?:\s|$)", p.stdout) is not None
    def collect(self):
        table = snapshot()
        live = {pid for pid, start in self.known.items() if same(table, pid, start)}
        # 自分が作った集団だけを取り込む。既知の生存者がない集団番号は信用しない。
        anchored = any(table[pid][1] == self.root for pid in live)
        if anchored:
            for pid, row in table.items():
                if row[1] == self.root and pid not in self.known:
                    self.known[pid] = row[2]
                    live.add(pid)
        changed = True
        while changed:
            changed = False
            for pid, row in table.items():
                if row[0] in live and pid not in self.known:
                    self.known[pid] = row[2]
                    live.add(pid)
                    changed = True
        if self.token:
            for pid, row in table.items():
                if pid in live or self.checked.get(pid) == row[2] or row[3].startswith("Z"):
                    continue
                if self.belongs(pid, row[2]):
                    self.known[pid] = row[2]
                    live.add(pid)
                self.checked[pid] = row[2]
        return {pid: self.known[pid] for pid in live if pid > 1 and pid != self.exclude}
    def send(self, sig):
        for pid, start in self.collect().items():
            # 一覧取得から送信までに終了・番号再利用されていたら送らない。
            if same(snapshot(), pid, start):
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
    def stop(self, child=None):
        self.send(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while self.collect() and time.monotonic() < deadline:
            if child is not None:
                child.poll()
            time.sleep(0.1)
        self.send(signal.SIGKILL)
        if child is not None:
            child.wait()
        deadline = time.monotonic() + 2
        while self.collect() and time.monotonic() < deadline:
            self.send(signal.SIGKILL)
            time.sleep(0.1)
        return not self.collect()

def main():
    if sys.argv[1] == "owns-child":
        root, start = int(sys.argv[2]), " ".join(sys.argv[3].split())
        table = snapshot()
        state = json.loads(pathlib.Path(sys.argv[4]).read_text())
        if not same(table, root, start) or state.get("root") != root or state.get("phase") != "running":
            return 1
        # 監督役が内部で起動した ps をサーバー本体と数えない。
        return 0 if same(table, state["pid"], state["start"]) else 1
    if sys.argv[1] == "owns-port":
        root, start, port = int(sys.argv[2]), " ".join(sys.argv[3].split()), sys.argv[4]
        table = snapshot()
        if not same(table, root, start):
            return 1
        p = subprocess.run(["lsof", "-nP", "-iTCP:" + port, "-sTCP:LISTEN", "-t"],
                           capture_output=True, text=True, timeout=3)
        listeners = [int(pid) for pid in p.stdout.split()]
        if p.returncode or not listeners:
            return 1
        for pid in listeners:
            seen, cur = set(), pid
            while cur != root and cur in table and cur not in seen:
                seen.add(cur)
                cur = table[cur][0]
            if cur != root or not same(snapshot(), pid, table[pid][2]):
                return 1
        return 0
    if sys.argv[1] == "stop-supervisor":
        root, start = int(sys.argv[2]), " ".join(sys.argv[3].split())
        if same(snapshot(), root, start):
            try:
                os.kill(root, signal.SIGTERM)
            except ProcessLookupError:
                return 0
        # 監督役だけが、既に独立した孫の追跡情報も持っている。外側から先に KILL しない。
        deadline = time.monotonic() + 12
        while same(snapshot(), root, start) and time.monotonic() < deadline:
            time.sleep(0.1)
        return 3 if same(snapshot(), root, start) else 0
    if sys.argv[1] == "stop":
        root, start = int(sys.argv[2]), " ".join(sys.argv[3].split())
        if not same(snapshot(), root, start):
            return 0
        return 0 if Family(root, start).stop() else 3
    os.setsid()
    requested = []
    def stopping(sig, frame):
        if not requested:
            requested.append(sig)
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, stopping)
    root = os.getpid()
    baseline = snapshot()
    token = uuid.uuid4().hex
    family = Family(root, baseline[root][2], exclude=root, token=token, baseline=baseline)
    child = None
    failed = False
    state_path = pathlib.Path(sys.argv[2]) if sys.argv[1] == "supervise-state" else None
    command = sys.argv[3:] if state_path else sys.argv[2:]
    def record_state(phase):
        if state_path:
            row = snapshot().get(child.pid) if child is not None and phase == "running" else None
            temporary = state_path.with_name(state_path.name + ".tmp." + str(root))
            temporary.write_text(json.dumps(dict(root=root, phase=phase,
                                                pid=child.pid if child else 0,
                                                start=row[2] if row else "")) + "\n")
            os.replace(temporary, state_path)
    try:
        if requested:
            return 128 + requested[0]
        record_state("starting")
        child = subprocess.Popen(command, env={**os.environ, "LANES_PROCESS_TOKEN": token})
        record_state("running")
        # ps の一時失敗（高負荷時の 3 秒タイムアウト等）で健全な子まで止めない。
        # 取り逃した孫は継承した識別子で後から見つかるので、連続失敗が長く続くときだけ打ち切る。
        failing_since = None
        while child.poll() is None and not requested:
            try:
                family.collect()
                failing_since = None
            except Exception:
                now = time.monotonic()
                if failing_since is None:
                    failing_since = now
                elif now - failing_since > 60:
                    raise
            # 平常時の見回り間隔。ps -axo は 1 回あたりの CPU が重く、0.1 秒間隔だと並列レーンで常時負荷になる。
            # 親を失った孫は継承した識別子で後から見つかるので、0.5 秒でも取り逃さない（停止処理中の確認は 0.1 秒のまま）。
            time.sleep(0.5)
    except Exception:
        failed = True
    finally:
        try:
            record_state("stopping")
        except Exception:
            failed = True
        # 一覧取得障害で監督役だけ消えると、実子・独立した孫を見失う。
        # 回収を証明できるまで監督役と .pid の生存情報を保持して再試行する。
        warned = False
        while True:
            try:
                cleaned = family.stop(child)
                if cleaned:
                    break
            except Exception:
                pass
            failed = True
            if not warned:
                print("ERROR: 子の回収未確認。監督を維持して再確認する", file=sys.stderr, flush=True)
                warned = True
            time.sleep(0.5)
    if failed:
        return 3
    if not cleaned:
        return 3
    if requested:
        return 128 + requested[0]
    return child.returncode if child.returncode >= 0 else 128 - child.returncode

try:
    sys.exit(main())
except Exception:
    # コマンド引数や例外本文には秘密が入りうるため、固定文言だけを出す。
    print("ERROR: 子プロセスの起動・回収を確認できない", file=sys.stderr)
    sys.exit(3)
'

# 呼び出し元の標準入出力を保って背景起動する。LANES_CHILD を wait すれば孫の回収まで完了する。
lanes_start_child() {
  python3 -c "$LANES_PROCESS_GUARD" supervise "$@" <&0 &
  typeset -g LANES_CHILD=$!
  typeset -g LANES_MANAGED_CHILD_PID="$LANES_CHILD"
  lanes_record_child "$LANES_CHILD"
}

# 同じ label が実行中なら起動しない（ログとマーカーが混ざる）。前回の .pid / .done は .prev-<日時> に回転
lanes_mark_start() {
  local logdir="$1" label="$2" lane="$3" wt="$4"
  local pidfile="$logdir/$label.pid" donefile="$logdir/$label.done"
  # ここから先の誤りは自分で理由（実行中など）を出し、排他を取った後の失敗は TRAPEXIT が .done に残す
  unset LANES_EARLY_LABEL LANES_EARLY_LOGDIR
  mkdir -p "$logdir"
  # logs/ が symlink だと、記録をリポの外へ書いてしまう。起動時に本物のフォルダか確かめ、その識別子（dev:inode）を覚える
  [[ -d "$logdir" && ! -L "$logdir" ]] || lanes_die "logs/ が本物のフォルダではない（symlink など）→ 起動禁止: $logdir"
  typeset -g LANES_LOGDIR="$logdir" LANES_LOGDIR_ID="$(lanes_logdir_id "$logdir")"
  [[ -n "$LANES_LOGDIR_ID" ]] || lanes_die "logs/ の識別子を取れない: $logdir"
  lanes_logdir_entries_ok "$logdir" || lanes_die "logs/ の中に symlink・ハードリンク・特殊ファイルがある（上に一覧）→ 起動禁止。中身を確かめてから消す: $logdir"
  # ファイルを消すと別 inode に別のロックを取れてしまうため、.lock は削除・回転しない。
  # カーネルがシェル終了時に解放するので、強制終了後の残骸も次回起動を妨げない。
  [[ -z "${LANES_LOCK_FD:-}" ]] || lanes_die "このランチャは既に label を取得している"
  zmodload zsh/system || lanes_die "排他ロックを利用できない → 起動禁止"
  ( : >> "$logdir/$label.lock" ) || lanes_die "ロックファイルを作れない"
  typeset -g LANES_LOCK_FD
  zsystem flock -t 0 -f LANES_LOCK_FD "$logdir/$label.lock" || lanes_die "同じ label が実行中（排他ロック取得不可）: $label"
  if [[ -f "$pidfile" ]] && lanes_pid_alive "$pidfile"; then
    lanes_die "同じ label が実行中（pid $(sed -n 's/^pid=//p' "$pidfile" | head -1)）。別 label にするか終了を待つ: $pidfile"
  fi
  # ランチャが止まっていても前回の子（codex / claude）が生きていれば二重走行になるので拒否（.done の有無に関係なく）
  if lanes_child_alive "$pidfile"; then
    lanes_die "前回の子 pid $(sed -n 's/^child_pid=//p' "$pidfile" | head -1) が生存または同一性不明。所有者と終了を確認してから再起動: $pidfile"
  fi
  lanes_rotate_log "$pidfile"; lanes_rotate_log "$donefile"
  # .pid を書く前にグローバルを用意する（.pid が存在する時点からシグナルが来ても .done を書けるように）
  typeset -g LANES_PIDFILE="$pidfile" LANES_DONEFILE="$donefile" LANES_DONE_WRITTEN=0 LANES_LABEL="$label" LANES_T0="$(date +%s)"
  typeset -g LANES_PIDFILE_BASE="pid=$$
lstart=$(lanes_ps_lstart $$)
started=$(lanes_now)
started_epoch=$LANES_T0
lane=$lane
worktree=$wt"
  print -r -- "$LANES_PIDFILE_BASE" > "$pidfile"
}

# 子が書ける場所（scratch など）にランチャが書く前に呼ぶ。前からある物（子や前回の実行が置いた symlink・ハードリンク）を消し、
# 続く `>` が必ず新しい普通のファイルを作るようにする。子が生きている間に使うと、消してから書くまでの隙に置き直されうるので、
# 子の起動前か、子（と孫）の回収が済んだ後だけで使う
lanes_fresh_file() {
  rm -f -- "$1" 2>/dev/null || true
  [[ ! -e "$1" && ! -L "$1" ]] || lanes_die "書き込み先を空けられない（フォルダなど）: $1"
}

# logs/ の識別子（dev:inode）。symlink は辿らない
lanes_logdir_id() {
  python3 -I -c 'import os,sys
s=os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$1" 2>/dev/null
}

# logs/ の直下に、ランチャが辿ってしまう物（symlink・ハードリンク（リンク数 2 以上の普通のファイル）・FIFO などの特殊ファイル）が無いか。
# 0 = 無い。1 = ある（名前を stderr に出す）。ランチャは子の後に logs/<label>.* をパスのまま書くので、
# ファイル 1 つでも外を指していると、サンドボックスの外にいるランチャが外のファイルを書き換えてしまう
lanes_logdir_entries_ok() {
  python3 -I -c 'import os,stat,sys
bad=[]
with os.scandir(sys.argv[1]) as it:
    for e in it:
        s=e.stat(follow_symlinks=False)
        if stat.S_ISLNK(s.st_mode) or (stat.S_ISREG(s.st_mode) and s.st_nlink > 1) or not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)):
            bad.append(e.name)
for n in sorted(bad): print("  logs/" + n, file=sys.stderr)
sys.exit(1 if bad else 0)' "$1"
}

# 子（エージェント・確認コマンド）が logs/ を symlink や別のフォルダに差し替えていないか、中に外を指すファイルを置いていないか。
# 0 = 起動時と同じ本物のフォルダで、中身も安全
lanes_logdir_intact() {
  [[ -n "${LANES_LOGDIR:-}" ]] || return 0
  [[ -d "$LANES_LOGDIR" && ! -L "$LANES_LOGDIR" && "$(lanes_logdir_id "$LANES_LOGDIR")" == "${LANES_LOGDIR_ID:-}" ]] || return 1
  lanes_logdir_entries_ok "$LANES_LOGDIR"
}

# 子が終わった直後に呼ぶ。差し替えられていたら、そこへは何も書かずに止める（.done も書かない → lanes-status は DEAD）
lanes_logdir_check() {
  lanes_logdir_intact && return 0
  print -u2 -- "error: 実行中に logs/ が差し替えられた（logs/ 自体の symlink・別フォルダ、または中の symlink・ハードリンク・特殊ファイル）。記録を書かずに止める: $LANES_LOGDIR"
  LANES_DONE_WRITTEN=1
  exit 5
}

# 終了を記録。$1=終了コード $2=VERDICT 行 $3=補足（任意）。二重書きしない。
# zsh は関数形式の TRAPEXIT を `$(...)` の子シェル終了時にも走らせるので、子シェル（ZSH_SUBSHELL>0）からは絶対に書かない
lanes_mark_done() {
  local rc="$1" verdict="${2:-VERDICT: NONE}" note="${3:-}"
  (( ZSH_SUBSHELL )) && return 0
  [[ -n "${LANES_DONEFILE:-}" ]] || return 0
  (( ${LANES_DONE_WRITTEN:-1} )) && return 0
  LANES_DONE_WRITTEN=1
  if ! lanes_logdir_intact; then
    print -u2 -- "error: logs/ が差し替えられているので .done を書かない: $LANES_LOGDIR"
    return 0
  fi
  local elapsed=$(( ($(date +%s) - LANES_T0) / 60 ))
  {
    print -- "EXIT:$rc"
    print -- "$verdict"
    print -- "finished=$(lanes_now)"
    print -- "elapsed_min=$elapsed"
    [[ -n "$note" ]] && print -- "note=$note"
  } > "$LANES_DONEFILE"
  lanes_notify "$rc" "$verdict"
}

# ランチャが途中で死んでも .done を残す（DEAD と FAILED を区別する）。kill -9 だけは残せない → lanes-status は DEAD と出す
# zsh の注意: (1) 関数内の `trap ... EXIT` は関数終了時に発火する → トップレベル（この source 時）に TRAPxxx 関数で定義する
#            (2) 関数形式の TRAPEXIT は `$(...)` の子シェル終了時にも走る → ZSH_SUBSHELL で弾く（lanes_mark_done 側でも弾く）
#            (3) 関数内で set -e が発火すると TRAPEXIT は走らない → TRAPZERR も定義する
#            (4) `(( n++ ))` は n=0 で rc=1（set -e で死ぬ）。`n=$(( n + 1 ))` を使う
# シグナル時は記録した開始時刻を照合し、子とその配下へ TERM → 最大 5 秒 → KILL を送る。
# さらに最大 2 秒、消滅を確認してから .done を書く。lanes_start_child は通常終了でも同じ回収を行う。
lanes_kill_child() {
  [[ "${LANES_CHILD:-}" == <-> ]] || return 0
  local started="${LANES_CHILD_LSTART:-}"
  if [[ -z "$started" && -f "${LANES_PIDFILE:-}" ]]; then
    started="$(sed -n 's/^child_lstart=//p' "$LANES_PIDFILE" | head -1)"
  fi
  [[ -n "$started" ]] || { [[ "$(lanes_process_state "$LANES_CHILD" "")" == dead ]]; return $?; }
  local mode=stop
  [[ "${LANES_MANAGED_CHILD_PID:-}" == "$LANES_CHILD" ]] && mode=stop-supervisor
  python3 -c "$LANES_PROCESS_GUARD" "$mode" "$LANES_CHILD" "$started" || return $?
}

lanes_finish_after_stop() {
  typeset -g LANES_FINISH_RC="$1"
  local note="$2"
  if ! lanes_kill_child; then
    LANES_FINISH_RC=3
    note+=" / 子の回収未確認（生存確認してから再起動）"
  fi
  lanes_mark_done "$LANES_FINISH_RC" "VERDICT: NONE" "$note"
}
TRAPEXIT() { local st=$?; (( ZSH_SUBSHELL )) && return 0; lanes_finish_after_stop "$st" "ランチャが途中終了（EXIT trap）"; }
# 関数の中で set -e が発火すると zsh は TRAPEXIT を走らせない（zsh 5.9 実測）。ERR_EXIT で exit する直前に走る ZERR で .done を書く
# （`|| true` / `if` / `&&` / `wait || rc=$?` では走らない。二重書きは lanes_mark_done のガードで防ぐ）
TRAPZERR() { local st=$?; (( ZSH_SUBSHELL )) && return 0; lanes_finish_after_stop "$st" "ランチャが途中終了（set -e: 直前のコマンドが rc=$st）"; }
TRAPHUP()  { (( ZSH_SUBSHELL )) && exit 129; lanes_finish_after_stop 129 "SIGHUP（起動元シェルが終了）"; exit "$LANES_FINISH_RC"; }
TRAPTERM() { (( ZSH_SUBSHELL )) && exit 143; lanes_finish_after_stop 143 "SIGTERM"; exit "$LANES_FINISH_RC"; }
TRAPINT()  { (( ZSH_SUBSHELL )) && exit 130; lanes_finish_after_stop 130 "SIGINT"; exit "$LANES_FINISH_RC"; }

# macOS 通知（失敗してもランチャは止めない。チャットへの自動投稿はしない）
lanes_notify() {
  [[ "${LANES_NOTIFY:-0}" == <-> ]] && (( LANES_NOTIFY )) || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  local rc="$1" verdict="$2" state="完了"; (( rc != 0 )) && state="失敗"
  local msg="${LANES_LABEL:-lane} EXIT:$rc $verdict"; msg="${msg//[\"\\]/}"
  osascript -e "display notification \"$msg\" with title \"lanes $state\"" >/dev/null 2>&1 || true
}

# ---- レーン専用の作業場所（scratch）----
# レビュー役が自分の検証で ~/Downloads に一時 DB・ビルド・ログを置いた事故があった（置き場所の指示が届いていなかった）。
# ランチャごとに <LANES_SCRATCH_ROOT>/<repo>/<label>/ を作り、TMPDIR と LANES_SCRATCH をそこへ向け、プロンプトでも明示する。
# 中に .lane（worktree= / branch= / label= / lane=）を置き、cleanup-after-merge.sh はこれで「そのレーンの scratch」を見つけて消す。
lanes_scratch_guard() {   # 消してよい scratch パスか（root 配下 2 段以上・$HOME/Downloads 等ではない）
  local d="${1:A}" root="${LANES_SCRATCH_ROOT:A}"
  [[ -n "$root" && "$root" != "/" && "$root" != "${HOME:A}" && "$root" != "${HOME:A}/Downloads"* ]] || return 1
  [[ "$d" == "$root"/?*/?* ]] || return 1
  return 0
}
lanes_scratch_toplevel() { local t; t="$(git -C "$1" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" || t="$1"; print -- "${t:A}"; }
lanes_scratch_repo() { local c; c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || c=""; c="${${c:h}:t}"; print -- "${c:-misc}"; }
# <wt> <label> → 使う scratch パスを表示（作らない。dry-run 用）
lanes_scratch_path() {
  local top base d n=1
  top="$(lanes_scratch_toplevel "$1")"
  base="$LANES_SCRATCH_ROOT/$(lanes_scratch_repo "$1")/$2"; d="$base"
  # 同じ label を別 worktree が使っていたら -2, -3 … にずらす（他レーンの scratch を消さない）。
  # .lane の無い既存のもの（LANES_SCRATCH_ROOT を広い場所にしたときの、レーンと関係ない同名のフォルダ・ファイル）も使わずにずらす。
  # 使うと .lane を書き込み、後片付けがそのフォルダを消してしまう
  while [[ -e "$d" || -L "$d" ]] && ! [[ -d "$d" && ! -L "$d" && -f "$d/.lane" && ! -L "$d/.lane" \
      && "$(sed -n 's/^worktree=//p' "$d/.lane" | head -1)" == "$top" ]]; do n=$(( n + 1 )); d="$base-$n"; done
  print -- "$d"
}
# <wt> <label> <lane>: scratch を作り、LANES_SCRATCH / TMPDIR を export。.pid にも scratch= を残す
lanes_scratch_prepare() {
  local wt="$1" label="$2" lane="$3" d top br
  d="$(lanes_scratch_path "$wt" "$label")"
  lanes_scratch_guard "$d" || lanes_die "scratch の置き場所が不正: $d（LANES_SCRATCH_ROOT=$LANES_SCRATCH_ROOT）"
  mkdir -p "$d" || lanes_die "scratch を作れない: $d"
  top="$(lanes_scratch_toplevel "$wt")"
  br="$(git -C "$wt" branch --show-current 2>/dev/null)"; [[ -n "$br" ]] || br="detached"
  # 同じ label の前回の実行が scratch に symlink などを残していても辿らない（子の起動前なので消してから書けば安全）
  lanes_fresh_file "$d/.lane"
  { print -- "worktree=$top"; print -- "branch=$br"; print -- "label=$label"; print -- "lane=$lane"; print -- "updated=$(lanes_now)"; } > "$d/.lane"
  typeset -gx LANES_SCRATCH="$d" TMPDIR="$d/"
  if [[ -n "${LANES_PIDFILE:-}" && -f "${LANES_PIDFILE:-}" ]]; then
    typeset -g LANES_PIDFILE_BASE="${LANES_PIDFILE_BASE:-}
scratch=$d"
    print -- "scratch=$d" >> "$LANES_PIDFILE"
  fi
  return 0
}
# プロンプトに足す置き場所の指示（Codex は developer_instructions、Claude はプロンプト先頭）
lanes_scratch_rule() {
  local d="$1"
  cat <<EOT
# 一時ファイルの置き場所（絶対）
- 検証で作るものは全部 \`$d\` の下に置く（環境変数 \`\$LANES_SCRATCH\` と \`\$TMPDIR\` も同じ場所）。対象: 一時 DB（initdb のデータ・ソケット）、ビルド出力、ログ、diff / patch、CSV、スクショ、clone・コピーした作業ツリー。
- \`mktemp -d\` はパスを付けずに使う（\`\$TMPDIR\` に作られる）。\`~/Downloads\`・\`\$HOME\` 直下・デスクトップ・\`/tmp\` には絶対に置かない。
- 一時 PostgreSQL は \`-k "\$LANES_SCRATCH"\` 等でソケットもこの下に置き、終わったら \`pg_ctl -D <データ> stop -m fast\` で止める（消すのは後片付けで自動）。
- このフォルダは ${LANES_BASE_BRANCH:-develop} へのマージ後の後片付けで丸ごと消える。残したい結論は最終報告に書く。
EOT
}
