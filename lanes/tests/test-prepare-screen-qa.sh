#!/bin/zsh -f
# prepare-screen-qa.sh の対応表・引数での決定、IPv6 接続先保持・認証情報除去と chk-run.sh の実行権限変更検知の自己テスト
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR LANES_SCREEN_QA_MAP LANES_CHECK_CMD

L="${0:A:h:h}"
base_tmp="${LANES_SCRATCH:-${TMPDIR:-/tmp}}"
base_tmp="${base_tmp%/}"
[[ -d "$base_tmp" ]] || { print -u2 -- "一時領域の親ディレクトリが無い: $base_tmp"; exit 1; }
real_base="${base_tmp:A}"
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate "$real_base"

root="$(TMPDIR="$real_base" mktemp -d "$real_base/test-prepare-screen-qa.XXXXXX")"
real_root="${root:A}"
cleanup() {
  cd / 2>/dev/null || true
  case "${real_root:-}" in
    "$real_base"/test-prepare-screen-qa.*) rm -rf "$real_root" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT

export PYTHONPYCACHEPREFIX="$real_root/pycache"
pass=0
fail=0
ok() { pass=$((pass + 1)); print -- "ok   $1"; }
ng() { fail=$((fail + 1)); print -- "FAIL $1"; }
has() {
  if grep -qE "$3" <<< "$2"; then
    ok "$1"
  else
    ng "$1（'$3' が無い）"
    print -r -- "$2" | sed 's/^/     /'
  fi
}
hasnt() {
  if grep -qE "$3" <<< "$2"; then
    ng "$1（'$3' がある）"
  else
    ok "$1"
  fi
}

# 1. prepare-screen-qa.sh: IPv6 URL の角括弧保持・認証情報秘匿・ラベル検証
qa_repo="$real_root/qa-repo"
mkdir -p "$qa_repo"
git -C "$qa_repo" init -q
git -C "$qa_repo" config user.email q@q
git -C "$qa_repo" config user.name q
print -- q > "$qa_repo/a.txt"
git -C "$qa_repo" add a.txt
git -C "$qa_repo" commit -qm init
git -C "$qa_repo" remote add origin "https://user_placeholder:token_placeholder_123@example.com/org/unknown-repo.git?secret_param=999"

qa_v6_out="$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" ipv6-port --url "http://[::1]:4173/check" 2>/dev/null)"
has "IPv6 ポート付き URL の角括弧を保持する" "$qa_v6_out" '^preview=http://\[::1\]:4173/check$'
has "IPv6 URL が prompt にも角括弧付きで書かれる" "$(cat "$qa_repo/logs/ipv6-port.prompt.md")" '^preview: http://\[::1\]:4173/check$'
has "IPv6 URL が meta にも角括弧付きで書かれる" "$(cat "$qa_repo/logs/ipv6-port.meta.txt")" '^preview=http://\[::1\]:4173/check$'

qa_v6_noport="$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" ipv6-noport --url "http://user_placeholder:token_placeholder_123@[2001:db8::1]/check?secret_param=1#frag" 2>/dev/null)"
has "IPv6 ポートなし URL でも角括弧を保持し認証情報とクエリを除去する" "$qa_v6_noport" '^preview=http://\[2001:db8::1\]/check$'
hasnt "IPv6 URL から認証情報とクエリを除去する" "$qa_v6_noport" 'token_placeholder_123|user_placeholder|secret_param|frag'

git -C "$qa_repo" remote set-url origin "git@[::1]:org/unknown-repo.git"
qa_v6_origin_err="$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" ipv6-origin --url "http://[::1]:4173/check" 2>&1 >/dev/null)"
has "SCP 形式の IPv6 origin でも角括弧付き接続先名を出す" "$qa_v6_origin_err" '\[::1\]/org/unknown-repo'

git -C "$qa_repo" remote set-url origin "http://user_placeholder:token_placeholder_123@[::1]:8080/org/unknown-repo.git?secret_param=1"
qa_v6_http_origin_err="$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" ipv6-http-origin --url "http://[::1]:4173/check" 2>&1 >/dev/null)"
has "HTTP 形式の IPv6 origin でも角括弧付き接続先名を出す" "$qa_v6_http_origin_err" '\[::1\]/org/unknown-repo'
hasnt "HTTP 形式の IPv6 origin で認証情報を出さない" "$qa_v6_http_origin_err" 'token_placeholder_123|user_placeholder|secret_param'

# 1b. 対応表 LANES_SCREEN_QA_MAP と引数で URL・観点ファイルを決める
git -C "$qa_repo" remote set-url origin "https://example.com/owner/my-app.git"
mkdir -p "$qa_repo/qa"
print -- "- [BOT] トップが開く" > "$qa_repo/qa/screen.md"
print -- "- [BOT] 引数の観点" > "$real_root/arg-viewpoints.md"
qa_map=$'  # コメント行は飛ばす\nother-app|https://other.example.com|qa/other.md\nmy-app|https://preview.example.com/my-app|qa/screen.md\n'
qa_map_out="$(LANES_SCREEN_QA_MAP="$qa_map" zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" map-hit 2>&1)"
has "対応表に一致した行の URL を使う" "$qa_map_out" '^preview=https://preview\.example\.com/my-app$'
has "対応表の観点ファイルは checkout からの相対で読む" "$qa_map_out" "^viewpoints=$qa_repo/qa/screen.md\$"
hasnt "対応表に一致したら未知 origin の警告を出さない" "$qa_map_out" '^warn: LANES_SCREEN_QA_MAP に無い'
has "観点ファイルの中身を prompt に入れる" "$(cat "$qa_repo/logs/map-hit.prompt.md")" 'トップが開く'

qa_arg_out="$(LANES_SCREEN_QA_MAP="$qa_map" zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" map-arg --url https://arg.example.com --viewpoints "$real_root/arg-viewpoints.md" 2>&1)"
has "引数の URL が対応表より優先" "$qa_arg_out" '^preview=https://arg\.example\.com$'
has "引数の観点ファイルが対応表より優先" "$qa_arg_out" "^viewpoints=$real_root/arg-viewpoints.md\$"

set +e
qa_none_out="$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" map-none 2>&1)"; qa_none_rc=$?
set -e
[[ $qa_none_rc -eq 2 ]] && ok "対応表に無く --url も無ければ exit 2" || ng "対応表に無く --url も無いのに exit $qa_none_rc"
has "URL が決まらない理由を出す" "$qa_none_out" 'LANES_SCREEN_QA_MAP'
[[ ! -e "$qa_repo/logs/map-none.prompt.md" ]] && ok "URL が決まらなければ prompt を書かない" || ng "URL 未決定でも prompt を書いた"

qa_novp_out="$(zsh -f "$L/prepare-screen-qa.sh" "$qa_repo" map-novp --url https://arg.example.com 2>&1)"
has "観点ファイル無しでも --url だけで書ける" "$qa_novp_out" '^viewpoints=$'
has "観点ファイル無しを prompt に明記する" "$(cat "$qa_repo/logs/map-novp.prompt.md")" '観点ファイルは無い'

# 2. chk-run.sh: node_modules 内実行ファイルの実行権限変更（chmod -x）で skip=same-tree を再利用しない
chk_out="$(python3 - "$L" "$real_root" <<'PY'
import os, subprocess, sys

lanes_dir, root = sys.argv[1:3]
chk = os.path.join(lanes_dir, "chk-run.sh")
with open(chk, "r", encoding="utf-8") as f:
    src = f.read()
py_code = src.split("python3 - \"$wt\" \"$o\" \"$cache\" \"$lanes_dir\" \"$port\" \"${output_names[@]}\" <<'PY'\n", 1)[1].split("\nPY\n", 1)[0]

wt = os.path.join(root, "chk-wt")
out = os.path.join(root, "chk-out")
cache = os.path.join(root, "passed.tsv")
os.makedirs(wt); os.makedirs(out)
open(cache, "w").close()

subprocess.run(["git", "init", "-q"], cwd=wt, check=True)
assert os.path.realpath(subprocess.check_output(['git', '-C', str(wt), 'rev-parse', '--show-toplevel'], text=True).strip()) == os.path.realpath(str(wt)), '一時リポの外の git に届いている: ' + str(wt)   # 本物のリポを書き換えない
subprocess.run(["git", "config", "user.email", "t@t"], cwd=wt, check=True)
subprocess.run(["git", "config", "user.name", "t"], cwd=wt, check=True)
with open(os.path.join(wt, ".gitignore"), "w") as f:
    f.write("node_modules/\n")
with open(os.path.join(wt, "package.json"), "w") as f:
    f.write('{"name":"t","private":true}')
os.makedirs(os.path.join(wt, "node_modules", ".bin"))
tool = os.path.join(wt, "node_modules", ".bin", "cli")
with open(tool, "w") as f:
    f.write("#!/bin/sh\necho build_ok\n")
os.chmod(tool, 0o755)
subprocess.run(["git", "add", ".gitignore", "package.json"], cwd=wt, check=True)
subprocess.run(["git", "commit", "-qm", "init"], cwd=wt, check=True)
head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=wt, text=True).strip()
tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=wt, text=True).strip()

# LANES_CHK_ENV_LOADED=1: chk-run.sh が lanes.env を読み直さないようにし、指紋を先に計算したときと同じ環境で動かす
env = {**os.environ, "CHK_CACHE": cache, "LANES_CHECK_CMD": "./node_modules/.bin/cli", "CHK_CHECK_SRC": "LANES_CHECK_CMD", "LANES_CHK_ENV_LOADED": "1"}
output_names = ["fetch.log", "merge.log", "check.log", "check-state.json"]
r_fp = subprocess.run(
    ["python3", "-", wt, out, cache, lanes_dir, "4173", *output_names],
    input=py_code, text=True, capture_output=True, env=env, errors="replace"
)
assert r_fp.returncode == 0, r_fp.stderr
info = dict(line.split("=", 1) for line in r_fp.stdout.strip().splitlines())
with open(cache, "w") as f:
    f.write(f"{tree}\t{head}\tfull\t2026-11-06 05:59 JST\t{wt}\t{info['cache_fp']}\n")

r_skip = subprocess.run(["bash", chk, wt, "4173", out], env=env, text=True, capture_output=True, errors="replace")
assert r_skip.returncode == 0 and "skip=same-tree" in r_skip.stdout, f"expected skip: {r_skip.stdout}"

os.chmod(tool, 0o644)
r_noskip = subprocess.run(["bash", chk, wt, "4173", out], env=env, text=True, capture_output=True, errors="replace")
assert r_noskip.returncode == 1 and "skip=same-tree" not in r_noskip.stdout and "check=126" in r_noskip.stdout, f"expected check=126: {r_noskip.stdout} {r_noskip.stderr}"
print("CHK_MODE_INVALIDATION_OK")
PY
)"
has "node_modules 内実行ファイルの chmod -x で skip=same-tree を無効化し check=126 で失敗する" "$chk_out" '^CHK_MODE_INVALIDATION_OK$'

print -- "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
