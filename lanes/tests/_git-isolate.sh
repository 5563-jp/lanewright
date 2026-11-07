# テストの git を一時ディレクトリの中に閉じ込める共通処理（zsh -f / bash のどちらからも source できる書き方）。
# 経緯: 外から入った git の環境変数（GIT_DIR など）で、テストの一時リポ作成が本物のリポへ届き、
#       キットの共有 .git/config に core.worktree が書かれ、作業枝に作者 Test User の空 commit ができた事故があった。
# 使い方（テストの冒頭、set -euo pipefail の直後）:
#   source "<このファイル>"; lanes_test_git_isolate
#     → リポの場所を差し替える git の環境変数を外し、GIT_CEILING_DIRECTORIES（git がリポを探して上へ上がらない境目）を
#       一時領域（$LANES_SCRATCH か $TMPDIR）に置く。テストの一時ディレクトリはその直下に作るので、その親が境目になる。
#       git の通信の制限（GIT_ALLOW_PROTOCOL）は file（ローカルのパスどうし）だけに置き直す。レビュー・QA のランチャの中から
#       テストが回ると lanes-no-transport（すべて拒否）が残り、一時リポ間の push・clone まで失敗するため。
#       ssh・https は許さない（テストは外へ通信しない）。push を止めることを確かめるテストは、ランチャが付け直す値を見る。
#   一時リポを作った直後: lanes_test_assert_repo <一時リポ>
#     → git から見たリポの最上位がそのディレクトリでなければ、即失敗（exit 1）
# Python のテストの subprocess も、このシェルの環境（外した後）をそのまま受け継ぐ。

lanes_test_git_isolate() {
  # リポの場所・中身の置き場所・設定を差し替える変数（GIT_CONFIG で始まるものは下でまとめて外す）
  for _lt_v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
      GIT_SHALLOW_FILE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_NO_REPLACE_OBJECTS GIT_QUARANTINE_PATH \
      GIT_INTERNAL_SUPER_PREFIX GIT_TEMPLATE_DIR; do
    unset "$_lt_v" 2>/dev/null || true
  done
  # GIT_CONFIG / GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM / GIT_CONFIG_NOSYSTEM / GIT_CONFIG_PARAMETERS /
  # GIT_CONFIG_COUNT / GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> など（名前だけを取り出す。値は表示しない）
  for _lt_v in $(env | sed -n 's/^\(GIT_CONFIG[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$_lt_v" 2>/dev/null || true
  done
  unset _lt_v
  GIT_ALLOW_PROTOCOL="file"
  export GIT_ALLOW_PROTOCOL
  _lt_base="${1:-${LANES_SCRATCH:-${TMPDIR:-}}}"
  if [ -z "$_lt_base" ] || [ ! -d "$_lt_base" ]; then
    echo "FAIL: git を閉じ込める境目（LANES_SCRATCH か TMPDIR の既存ディレクトリ）が無い" >&2
    exit 1
  fi
  GIT_CEILING_DIRECTORIES="$(cd "$_lt_base" && pwd -P)"
  export GIT_CEILING_DIRECTORIES
  unset _lt_base
}

# <dir>: そこが git から見たリポの最上位であること（上位の別リポや、環境変数で差し替えたリポではないこと）
lanes_test_assert_repo() {
  _lt_want="$(cd "$1" 2>/dev/null && pwd -P)" || { echo "FAIL: 一時リポが無い: $1" >&2; exit 1; }
  _lt_top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || _lt_top=""
  [ -n "$_lt_top" ] && _lt_top="$(cd "$_lt_top" && pwd -P)"
  if [ "$_lt_top" != "$_lt_want" ]; then
    echo "FAIL: 一時リポの外の git に届いている（期待: $_lt_want / git の最上位: ${_lt_top:-なし}）。テストを止める" >&2
    exit 1
  fi
  unset _lt_want _lt_top
}
