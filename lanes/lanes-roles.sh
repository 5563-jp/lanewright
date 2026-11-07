#!/bin/zsh -f
# 道具の役割の割り振り。LANES_TOOLS（使える道具）から構成を 1 つに決め、実装役・レビュー役を出す。
# 使い方:
#   lanes-roles.sh --print   人が読める表示（③④ では「レビューの独立性が弱い」注意も出す）
#   lanes-roles.sh --env     KEY=value の形で出す（スクリプトや確認用）
#   source lanes-roles.sh    関数 lanes_roles_resolve を読み込む（_common.sh が使う）。呼ぶと次の変数を設定する
# 出す変数:
#   LANES_PROFILE            full / claude-codex / claude-gemini / claude-only
#   LANES_ROLE_IMPL          実装役（claude か "claude gemini"）
#   LANES_ROLE_REVIEW        レビュー役（codex か claude）
#   LANES_REVIEW_INDEPENDENT 1 = 実装と別系統の道具でレビュー / 0 = 同じ系統（独立性が弱い）
# 構成の表（docs/roles.md と同じ）:
#   ① full          claude codex gemini → 実装 Claude と Gemini / レビュー Codex
#   ② claude-codex  claude codex        → 実装 Claude            / レビュー Codex
#   ③ claude-gemini claude gemini       → 実装 Claude と Gemini / レビュー Claude（別セッション・読み取り専用）
#   ④ claude-only   claude              → 実装 Claude            / レビュー Claude（同上）
# 未設定・空文字（LANES_TOOLS=""）は既定の claude だけ（④ claude-only）として扱う。
# 未知の道具名・claude 抜き・区切り文字だけの値（" , " など）は exit 2（source した場合は lanes_roles_resolve が 2 を返す）。

# LANES_TOOLS を検査して役割の変数を設定する。誤りは理由を LANES_ROLES_ERROR に入れて 2 を返す（exit はしない）
lanes_roles_resolve() {
  local raw="${LANES_TOOLS:-claude}" t
  local -a tools
  typeset -g LANES_ROLES_ERROR=""
  # 区切りはスペース（タブ・改行・カンマも許す）。重複は 1 つにまとめる
  tools=(${(s: :)${raw//[,$'\t'$'\n']/ }})
  tools=(${(u)tools})
  if (( ${#tools} == 0 )); then
    LANES_ROLES_ERROR="LANES_TOOLS が空。claude を必ず含めて、codex / gemini を必要に応じて足す（例: LANES_TOOLS=\"claude codex\"）"
    return 2
  fi
  for t in "${tools[@]}"; do
    case "$t" in
      claude|codex|gemini) ;;
      *) LANES_ROLES_ERROR="LANES_TOOLS に知らない道具名: '$t'（使えるのは claude codex gemini）"; return 2 ;;
    esac
  done
  if (( ! ${tools[(Ie)claude]} )); then
    LANES_ROLES_ERROR="LANES_TOOLS に claude が無い（claude は必須。実装と、codex が無い構成のレビューを受け持つ）"
    return 2
  fi
  local has_codex=${tools[(Ie)codex]} has_gemini=${tools[(Ie)gemini]}
  typeset -g LANES_PROFILE LANES_ROLE_IMPL LANES_ROLE_REVIEW LANES_REVIEW_INDEPENDENT
  # 表示用に並びを決まった順へそろえる
  typeset -g LANES_TOOLS_NORMALIZED="claude"
  (( has_codex )) && LANES_TOOLS_NORMALIZED+=" codex"
  (( has_gemini )) && LANES_TOOLS_NORMALIZED+=" gemini"
  if (( has_codex && has_gemini )); then
    LANES_PROFILE=full; LANES_ROLE_IMPL="claude gemini"; LANES_ROLE_REVIEW=codex; LANES_REVIEW_INDEPENDENT=1
  elif (( has_codex )); then
    LANES_PROFILE=claude-codex; LANES_ROLE_IMPL=claude; LANES_ROLE_REVIEW=codex; LANES_REVIEW_INDEPENDENT=1
  elif (( has_gemini )); then
    LANES_PROFILE=claude-gemini; LANES_ROLE_IMPL="claude gemini"; LANES_ROLE_REVIEW=claude; LANES_REVIEW_INDEPENDENT=0
  else
    LANES_PROFILE=claude-only; LANES_ROLE_IMPL=claude; LANES_ROLE_REVIEW=claude; LANES_REVIEW_INDEPENDENT=0
  fi
  return 0
}

# 道具が今の構成に入っているか（入っていれば 0）。先に lanes_roles_resolve を呼んでおくこと
lanes_roles_has_tool() { [[ " $LANES_TOOLS_NORMALIZED " == *" $1 "* ]]; }

# 人が読める表示
lanes_roles_print() {
  local mark impl_line review_line
  case "$LANES_PROFILE" in
    full) mark="①" ;; claude-codex) mark="②" ;; claude-gemini) mark="③" ;; *) mark="④" ;;
  esac
  if [[ "$LANES_ROLE_IMPL" == "claude gemini" ]]; then
    impl_line="Claude と Gemini（run-impl.sh。既定は Claude = run-claude.sh、--engine gemini で run-gemini.sh）"
  else
    impl_line="Claude（run-impl.sh → run-claude.sh）"
  fi
  if [[ "$LANES_ROLE_REVIEW" == codex ]]; then
    review_line="Codex（run-review.sh → run-codex-review.sh）"
  else
    review_line="Claude の別セッション・読み取り専用（run-review.sh → run-claude-review.sh）"
  fi
  print -r -- "構成: $mark $LANES_PROFILE（道具: $LANES_TOOLS_NORMALIZED）"
  print -r -- "実装: $impl_line"
  print -r -- "レビュー: $review_line"
  if (( LANES_REVIEW_INDEPENDENT )); then
    print -r -- "レビューの独立性: あり（実装と別系統の道具で見る）"
  else
    print -r -- "レビューの独立性: 弱い"
    print -r -- "注意: レビューが実装と同じ系統の道具（Claude）なので独立性が弱い。同じ思い込みを見落としやすいので、人の目での確認や CI（自動テストの仕組み）を厚めにする。codex を足すと ② か ① になる"
  fi
}

# source されたときは関数だけ読み込んで戻る
if [[ "${zsh_eval_context:-}" == *file* ]]; then
  return 0
fi

# ---- 直接実行 ----
set -euo pipefail
LANES_DIR="${0:A:h}"
usage="使い方: lanes-roles.sh [--print | --env]"
mode="${1:---print}"
(( $# <= 1 )) || { print -u2 -- "ERROR: 引数が多い / $usage"; exit 2; }
case "$mode" in
  --print|--env) ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  *) print -u2 -- "ERROR: 不明なオプション: $mode / $usage"; exit 2 ;;
esac
source "$LANES_DIR/lanes.env"
lanes_roles_resolve || { print -u2 -- "ERROR: $LANES_ROLES_ERROR"; exit 2; }
if [[ "$mode" == --env ]]; then
  print -r -- "LANES_PROFILE=$LANES_PROFILE"
  print -r -- "LANES_ROLE_IMPL=\"$LANES_ROLE_IMPL\""
  print -r -- "LANES_ROLE_REVIEW=$LANES_ROLE_REVIEW"
  print -r -- "LANES_REVIEW_INDEPENDENT=$LANES_REVIEW_INDEPENDENT"
else
  lanes_roles_print
fi
