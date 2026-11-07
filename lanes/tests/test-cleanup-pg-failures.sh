#!/bin/zsh -f
# PostgreSQL の起動失敗・ソケット長超過でも、既存の後片付け試験が最後まで走ることを確認する。
# ソケット長超過は、指定された逃がし先でも収まらなければソケットを作らず exit 77（対象外・理由付き）になることも確かめる。
# 逃がし先が指定されていないときに /tmp などの一時領域の外へソケットを作らないことも確かめる。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
TEST_DIR="${0:A:h}"
scratch_base="${LANES_SCRATCH:-$TMPDIR}"
T="$(mktemp -d "$scratch_base/pf.XXXXXX")"
kept=()
finish() { local d; for d in "${kept[@]}"; do [[ "$d/" == "${scratch_base:A}/"* ]] && rm -rf -- "$d"; done; rm -rf -- "$T"; }
trap finish EXIT
mkdir -p "$T/bin"
cat > "$T/bin/initdb" <<'MOCK'
#!/bin/zsh -f
if [[ "$PG_TEST_FAILURE" == init ]]; then print -u2 -- '試験用 initdb 起動失敗'; exit 1; fi
mkdir -p "$2"
MOCK
cat > "$T/bin/pg_ctl" <<'MOCK'
#!/bin/zsh -f
print -u2 -- '試験用 pg_ctl 起動失敗'
exit 1
MOCK
chmod +x "$T/bin/"*
# short-root で使う浅い逃がし先。入口（selftest.sh）から LANES_TEST_SOCKET_ROOT を渡されたらそれを尊重する
# （深い TMPDIR のときは $scratch_base だと 103 バイトに収まらない）。無ければ一時領域そのもの
short_root="${LANES_TEST_SOCKET_ROOT:-$scratch_base}"
# ソケット用のフォルダを作ってよい場所（一時領域の中か、指定された浅い逃がし先の中）
allowed_root() { [[ "$1" == "${scratch_base%/}/"* || "$1" == "${short_root%/}/"* ]]; }
short_partial=""
count=0
for kind in init start long noroot short-root; do
  test_base="$scratch_base"; socket_limit=100000; socket_root="$scratch_base"
  if [[ "$kind" == long || "$kind" == noroot || "$kind" == short-root ]]; then
    socket_limit=103
    test_base="$T/$(python3 -c 'print("l" * 110)')"; mkdir -p "$test_base"
    # long: 逃がし先も長い場所にして、逃がしても超える場合（ソケットを作らず対象外 77 で止まる経路）を試す
    # noroot: 逃がし先を指定しない（/tmp などへ勝手に逃がさず、対象外 77 で止まる）
    # short-root: 浅い逃がし先（一時領域の中）を指定すれば、その下にソケットを置いて試験を進める
    case "$kind" in
      long) socket_root="$test_base" ;;
      noroot) socket_root="" ;;
      short-root) socket_root="$short_root" ;;
    esac
  fi
  # 起動失敗は模擬なので、後片付け試験の完走だけを確かめる（本番の試験では PG 起動失敗は FAIL）。
  rc=0
  LANES_SCRATCH="$test_base" TMPDIR="$test_base/" LANES_TEST_PGBIN="$T/bin" LANES_TEST_SOCKET_LIMIT="$socket_limit" LANES_TEST_SOCKET_ROOT="$socket_root" PG_TEST_FAILURE="$kind" LANES_TEST_PG_FAILURE_EXPECTED=1 \
    zsh "$TEST_DIR/test-scratch-cleanup.sh" > "$T/$kind.log" 2>&1 || rc=$?
  if [[ "$kind" == short-root ]] && (( rc == 77 )) && grep -q '^SKIP: .*対象外' "$T/$kind.log"; then
    # 指定された逃がし先でも上限に収まらない環境（逃がし先そのものが深い）。赤にせず、一部だけ試したことを理由付きで出す
    grep -q 'ok 4 cleanup' "$T/$kind.log" || { cat "$T/$kind.log"; exit 1; }
    short_partial="short-root の逃がし先でもソケットのパスが上限に収まらない: $short_root"
  elif [[ "$kind" == long || "$kind" == noroot ]]; then
    # パス長は黙って緑にしない: 後片付け試験は完走し、対象外（77）と理由を出す
    (( rc == 77 )) && grep -q 'ok 4 cleanup' "$T/$kind.log" && grep -q '^SKIP: .*対象外' "$T/$kind.log" || { cat "$T/$kind.log"; exit 1; }
  else
    (( rc == 0 )) && grep -q 'PASS: 4 件' "$T/$kind.log" || { cat "$T/$kind.log"; exit 1; }
  fi
  diagnostics="$(sed -n 's/^原因調査用ログを保持: //p' "$T/$kind.log" | tail -1)"
  [[ -d "$diagnostics" ]] || { print -u2 -- "原因ログが消えた: $kind"; exit 1; }
  kept+=("${diagnostics:h}")
  case "$kind" in
    init) grep -q '試験用 initdb 起動失敗' "$diagnostics/initdb.log" ;;
    start) grep -q '試験用 pg_ctl 起動失敗' "$diagnostics/start.log" ;;
    long) grep -q '上限103' "$diagnostics/pg-reason.log" && grep -q '収まらない' "$diagnostics/pg-reason.log" ;;
    noroot) grep -q '上限103' "$diagnostics/pg-reason.log" && grep -q '未指定' "$diagnostics/pg-reason.log" ;;
    short-root)
      if [[ -n "$short_partial" ]]; then grep -q '上限103' "$diagnostics/pg-reason.log"
      else
        sock_dir="$(sed -n 's/^.*LANES_TEST_SOCKET_ROOT の下の専用フォルダに置く: //p' "$T/$kind.log")"
        # 浅い逃がし先の直下に作り、PG を止めたあと（ここでは起動失敗のあと）に消している
        [[ "$sock_dir" == "${short_root%/}"/p.* && ! -e "$sock_dir" ]] \
          && grep -q '試験用 pg_ctl 起動失敗' "$diagnostics/start.log"
      fi ;;
  esac || { print -u2 -- "期待した原因ログ・ソケットの置き場所でない: $kind"; cat "$T/$kind.log"; exit 1; }
  count=$((count+1)); print -- "ok $count $kind: 原因ログを保持し後片付け試験を完走"
done
# どの経路でも、ソケット用のフォルダは指定された一時領域の中だけに作る（/tmp などへ逃がさない）
# （/tmp の一覧の前後比較は、ほかの作業が同時に作るものと区別できないので、各経路の出力で確かめる）
for kind in init start long noroot short-root; do
  sed -n 's/^.*専用フォルダに置く: //p' "$T/$kind.log" | while IFS= read -r p; do
    allowed_root "$p" || { print -u2 -- "一時領域の外にソケット用のフォルダを作った: $kind: $p"; exit 1; }
  done
done
count=$((count+1)); print -- "ok $count ソケット用のフォルダは一時領域の外に作らない"
[[ -z "$short_partial" ]] || print -r -- "LANES_PARTIAL: $short_partial"
print -- "PASS: $count 件"
