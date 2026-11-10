#!/bin/zsh -f
# 起動前点検（doctor = 健康診断）。今の構成（LANES_TOOLS）で使う道具がそろっているかを確かめる。
# 使い方: lanes-doctor.sh [--quiet] [<worktree>]
#   --quiet     問題が無ければ何も出さない（run-impl.sh / run-review.sh が起動前に使う）。問題があれば同じ一覧を出す
#   <worktree>  （任意）レーンを走らせる作業ツリー。渡すと、ランチャが書く logs/ が git に無視されているかも見る
#               （無視されていなければ注意だけ。未追跡の logs/ が残り、誤って commit される原因になる）
# 見るもの:
#   - 構成: LANES_TOOLS が正しいか（lanes-roles.sh と同じ判定）
#   - 必須の道具: python3 / git / zsh。任意: gh（GitHub の CLI。無ければ注意だけ）
#   - 構成に入っている CLI ごとに「入っているか」「サブスクでログインしているか（API キーでのログインは不可）」
#       Claude: claude auth status が claude.ai のサブスク
#       Codex : codex login status が ChatGPT でのログイン
#       Gemini: agy にはログイン確認のサブコマンドが無いので、ログイン情報の置き場所（~/.gemini/antigravity-cli）の有無
#               （確認は弱いので、通っても注意を出す）。あわせて端末サンドボックス（/usr/bin/sandbox-exec）を有効にできるか
#   - ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY 等が設定されていても、ランチャは起動時に外す（表示だけ。失敗にはしない）
# 設定値の誤り（lanes.env が見つけたもの）も NG の 1 行として並べる（誤った値は既定に戻して残りを点検する）。
# 足りないものは全部並べてから exit 2。全部そろえば exit 0。ログイン状態の本文（鍵の断片が混ざりうる）は表示しない。
set -euo pipefail
LANES_DIR="${0:A:h}"
usage="使い方: lanes-doctor.sh [--quiet] [<worktree>]"
quiet=0
worktree=""
while (( $# )); do
  case "$1" in
    --quiet) quiet=1; shift ;;
    -h|--help) print -r -- "$usage"; exit 0 ;;
    -*) print -u2 -- "ERROR: 不明なオプション: $1 / $usage"; exit 2 ;;
    *)
      [[ -z "$worktree" ]] || { print -u2 -- "ERROR: 作業ツリーは 1 つだけ渡す / $usage"; exit 2; }
      worktree="$1"; shift ;;
  esac
done

typeset -a ok_lines ng_lines note_lines
ok()   { ok_lines+=("ok   $*"); }
ng()   { ng_lines+=("NG   $*"); }
note() { note_lines+=("注意 $*"); }

# API キーの有無は _common.sh が外す前に記録する（値は見ない・出さない）
typeset -a keys_set
for k in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS AGY_ADC_AUTH; do
  [[ -n "${(P)k:-}" ]] && keys_set+=("$k")
done

# ---- 必須・任意の道具 ----
have_python=0
for t in python3 git zsh; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t"
    [[ "$t" == python3 ]] && have_python=1
  else
    ng "$t が PATH に無い（必須。入れてから再実行する）"
  fi
done
if command -v gh >/dev/null 2>&1; then ok "gh（任意）"; else note "gh（GitHub の CLI）が無い。PR の作成・確認を手でやるなら無くてよい"; fi

# ---- 設定と構成 ----
# 設定値の誤りがあってもここで止めず、NG の 1 行として並べ、ほかの不足も全部並べてから exit 2 にする。
# 誤った値は lanes.env が既定に戻すので、残りの点検は既定値で続ける。export しない変数で頼む（lanes.env「設定の誤りの扱い」）
typeset +x LANES_DEFER_CONFIG_ERROR=1
source "$LANES_DIR/lanes.env"
[[ -z "${LANES_CONFIG_ERROR:-}" ]] || ng "設定の誤り: $LANES_CONFIG_ERROR（誤った値は既定に戻して残りを点検した。直してから再実行する）"
if [[ -f "$LANES_CONF" ]]; then ok "設定ファイル: $LANES_CONF"; else note "設定ファイルが無い（既定値で動く）: $LANES_CONF"; fi
# 司令塔（LANES_COMMANDER）は運用の印。ランチャや判定の動きは変えず、監視の回し方の案内だけを変える
case "$LANES_COMMANDER" in
  grok) ok "司令塔: grok（外の Bot。5 分ごとのルーティンで lanes-monitor.sh を回すか、lanes-watch.sh を detach-run.sh で 1 本だけ常駐させる。docs/commander-grok.md）" ;;
  claude) ok "司令塔: claude（Claude デスクトップの Code タブ。lanes-watch.sh --until-wake をバックグラウンドで回し、WAKE: で起きて次工程をつなぐ。docs/commander-claude.md）" ;;
  *) note "司令塔の値が grok / claude のどちらでもない: LANES_COMMANDER=\"$LANES_COMMANDER\"（動きは変わらないが、監視の回し方の案内が出ない。docs/config.md）" ;;
esac
source "$LANES_DIR/lanes-roles.sh"
roles_ok=1
if lanes_roles_resolve; then
  ok "構成: $LANES_PROFILE（LANES_TOOLS=\"$LANES_TOOLS_NORMALIZED\" / 実装 $LANES_ROLE_IMPL / レビュー $LANES_ROLE_REVIEW）"
  (( LANES_REVIEW_INDEPENDENT )) || note "レビューが実装と同じ系統の道具（Claude）なので独立性が弱い（lanes-roles.sh --print で詳しく）"
else
  roles_ok=0
  ng "$LANES_ROLES_ERROR"
fi

# ---- CLI ごとの点検 ----
if (( roles_ok )); then
  # ログイン判定の関数は _common.sh にある（ランチャと同じ判定を使う）。python3 が無いと読み込めない
  if (( have_python )); then
    # _common.sh も lanes.env を読み直す。上で並べた設定の誤りで止まらないよう、同じく保留を頼む
    typeset +x LANES_DEFER_CONFIG_ERROR=1
    source "$LANES_DIR/_common.sh"
    # 点検の途中で止まっても .done 等を書かない（_common.sh の終了処理はランチャ用）
    unfunction TRAPEXIT TRAPZERR 2>/dev/null || true
  fi
  # <tool> <変数名> <コマンド名> <ログインのやり直し方>
  check_cli() {
    local tool="$1" var="$2" name="$3" howto="$4" bin st
    bin="${(P)var:-}"
    # -x はフォルダでも真になるので、ふつうのファイルであることも確かめる
    if [[ -z "$bin" || ! -f "$bin" || ! -x "$bin" ]]; then
      bin="$(command -v "$name" 2>/dev/null || true)"
    fi
    if [[ -z "$bin" ]]; then
      ng "$tool: $name が見つからない（$var にも PATH にも無い）。入れるか $var にパスを書く"
      return 0
    fi
    typeset -g "$var"="$bin"
    if (( ! have_python )); then
      ng "$tool: python3 が無いのでログインを確かめられない"
      return 0
    fi
    st="$(lanes_${tool}_auth_state 2>/dev/null)" || st=unknown
    case "$st" in
      subscription)
        if [[ "$tool" == gemini ]]; then
          ok "$tool: $bin（ログイン情報の置き場所あり）"
          note "gemini: ログインの確認は弱い（~/.gemini/antigravity-cli の有無だけを見ている。ログアウト後もフォルダが残っていれば通る）。起動に失敗したら agy を対話で起動してログインし直す"
        else
          ok "$tool: $bin（サブスクでログイン済み）"
        fi ;;
      apikey) ng "$tool: API キーでログインしている（サブスクのログインだけ使える）。$howto" ;;
      none) ng "$tool: ログインしていない。$howto" ;;
      *) ng "$tool: ログイン状態を確かめられない（本文は表示しない）。$howto" ;;
    esac
  }
  for tool in ${(s: :)LANES_TOOLS_NORMALIZED}; do
    case "$tool" in
      claude) check_cli claude CLAUDE_BIN claude "claude を対話で起動して /login で claude.ai のサブスクにログインする" ;;
      codex)  check_cli codex CODEX_BIN codex "codex login で ChatGPT にログインする（--with-api-key は使わない）" ;;
      gemini)
        check_cli gemini GEMINI_BIN agy "agy を対話で起動してサブスクのアカウントにログインする"
        # run-gemini.sh は Mac の端末サンドボックス（sandbox-exec。書き込みなどを制限して動かす仕組み）を必須にしている。
        # 同じ確かめ（macOS か・あるか・実際に有効にできるか）をここでもして、起動の前に気づけるようにする
        sandbox_bin=/usr/bin/sandbox-exec
        if [[ "$(uname -s)" != Darwin || ! -f "$sandbox_bin" || ! -x "$sandbox_bin" ]]; then
          ng "gemini: 端末サンドボックス（$sandbox_bin）が無い。run-gemini.sh は macOS の sandbox-exec が無いと起動しない"
        elif ! "$sandbox_bin" -p '(version 1)(allow default)(deny file-write*)' /usr/bin/true 2>/dev/null; then
          ng "gemini: 端末サンドボックス（$sandbox_bin）を有効にできない。run-gemini.sh も起動しない"
        else
          ok "gemini: 端末サンドボックス（$sandbox_bin）を有効にできる"
        fi ;;
    esac
  done
  # 環境変数の effort が、設定ファイル（無ければ既定）と違う値で勝っているときは知らせる（ランチャも起動時に同じ注意を 1 行出す）
  if (( ${+functions[lanes_effort_override_note]} )); then
    for tool in ${(s: :)LANES_TOOLS_NORMALIZED}; do
      effort_note="$(lanes_effort_override_note "${(U)tool}_EFFORT" 2>&1)" || effort_note=""
      [[ -z "$effort_note" ]] || note "${effort_note#注意: }"
    done
  fi
fi

# ---- 作業ツリー（任意）: ランチャが書く logs/ が git に無視されているか ----
if [[ -n "$worktree" ]]; then
  if [[ ! -d "$worktree" ]] || ! git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ng "作業ツリーが git の作業ツリーではない: $worktree"
  elif git -C "$worktree" check-ignore -q --no-index logs/lanes-doctor.probe 2>/dev/null; then
    ok "作業ツリーの logs/ は git に無視されている: $worktree"
  else
    note "作業ツリーの logs/ が git に無視されていない: $worktree。ランチャの記録（logs/）が未追跡で残るので、対象リポジトリの .gitignore に logs/ を足して commit する"
  fi
fi

if (( ${#keys_set} )); then
  note "API キー系の環境変数が設定されている: ${(j:, :)keys_set}。ランチャは起動時にこれらを外してサブスクのログインで動かす（値は表示しない）"
fi

failed=${#ng_lines}
if (( quiet && ! failed )); then exit 0; fi
print -r -- "== lanes-doctor（起動前点検）"
(( ${#ok_lines} )) && print -rl -- "${ok_lines[@]}"
(( failed )) && print -rl -- "${ng_lines[@]}"
(( ${#note_lines} )) && print -rl -- "${note_lines[@]}"
if (( failed )); then
  print -r -- "結果: 足りないもの ${failed} 件 → 起動しない（上の NG を直してから再実行）"
  exit 2
fi
print -r -- "結果: そろっている"
exit 0
