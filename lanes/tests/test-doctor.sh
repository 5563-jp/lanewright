#!/bin/zsh -f
# 起動前点検（lanes-doctor.sh）のテスト。本物の CLI は使わない。
# 一時 HOME と、偽の CLI と必須の道具（python3 / git / zsh）だけを置いた PATH で、足りない道具・未ログイン・API キーのログインを試す。
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h}/_git-isolate.sh"; lanes_test_git_isolate
LANES_DIR="${0:A:h:h}"
scratch_base="${LANES_SCRATCH:-${TMPDIR:-}}"
[[ -n "$scratch_base" && -d "$scratch_base" ]] || { print -u2 'LANES_SCRATCH か TMPDIR の既存ディレクトリが必要'; exit 2; }
T="$(mktemp -d "${scratch_base%/}/test-doctor.XXXXXX")"
trap 'st=$?; (( st != 0 )) || rm -rf -- "$T"' EXIT
STUBS="$LANES_DIR/tests/stubs"
for v in ${(k)parameters[(I)LANES_*]} CLAUDE_BIN CODEX_BIN GEMINI_BIN XDG_CONFIG_HOME XDG_STATE_HOME ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS AGY_ADC_AUTH ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
  unset "$v" 2>/dev/null || true
done
LANES_DIR="${0:A:h:h}"
H="$T/home"; mkdir -p "$H/.gemini/antigravity-cli"
# 必須の道具だけを置いた bin（本物の claude / codex / agy が同じ場所にあっても拾わないように、リンクで用意する）
base_bin="$T/base-bin"; mkdir -p "$base_bin"
for t in python3 git zsh; do ln -s "$(command -v "$t")" "$base_bin/$t"; done
stub_bin="$T/stub-bin"; mkdir -p "$stub_bin"
for t in claude codex agy; do ln -s "$STUBS/$t" "$stub_bin/$t"; done
# 外の CLI を拾わない最小の PATH（sed / grep などの基本コマンドは /usr/bin と /bin から）
export HOME="$H" LANES_CONF="$T/no-such.conf" PATH="$stub_bin:$base_bin:/usr/bin:/bin"
[[ -z "$(command -v claude codex agy gh 2>/dev/null | grep -v "^$stub_bin/")" ]] || { print -u2 '最小の PATH に外の CLI がある'; exit 2; }

count=0
pass() { count=$(( count + 1 )); print -r -- "ok $count $*"; }
fail() { print -u2 -- "FAIL: $*（$T）"; exit 1; }
doctor() {   # <期待 rc> [引数...]。出力は OUT
  local want="$1"; shift; local rc=0
  zsh -f "$LANES_DIR/lanes-doctor.sh" "$@" > "$T/out" 2>&1 || rc=$?
  OUT="$(< "$T/out")"
  (( rc == want )) || { print -r -- "$OUT" >&2; fail "lanes-doctor expected=$want got=$rc（$*）"; }
}
ng_count() { print -r -- "$OUT" | grep -c '^NG' || true; }

# ---- 1. 4 構成とも、全部そろえば exit 0 ----
for tools in "claude codex gemini" "claude codex" "claude gemini" "claude"; do
  LANES_TOOLS="$tools" doctor 0
  [[ "$OUT" == *"結果: そろっている"* && "$(ng_count)" == 0 ]] || fail "[$tools] でそろっていると出ない"
  for t in ${(s: :)tools}; do
    if [[ "$t" == gemini ]]; then
      [[ "$OUT" == *"ok   gemini: "*"ログイン情報の置き場所あり"* ]] || fail "[$tools] の gemini が ok にならない"
      # Gemini のログイン確認はフォルダの有無だけなので、通っても弱いと注意する
      [[ "$OUT" == *"注意 gemini: ログインの確認は弱い"* ]] || fail "[$tools] で Gemini のログイン確認が弱い注意が出ない"
    else
      [[ "$OUT" == *"ok   $t: "*"サブスクでログイン済み"* ]] || fail "[$tools] の $t が ok にならない"
    fi
  done
  [[ " $tools " == *" gemini "* || "$OUT" != *"ログインの確認は弱い"* ]] || fail "[$tools] で gemini の注意が出た"
  [[ "$OUT" == *"gh（GitHub の CLI）が無い"* ]] || fail "gh が無い注意が出ない"
  pass "[$tools] は全部そろえば exit 0（gh が無い注意だけ）"
done
# gemini を含む構成では端末サンドボックス（sandbox-exec）も点検する。無い・有効にできないなら NG
LANES_TOOLS="claude gemini" doctor 0
[[ "$OUT" == *"ok   gemini: 端末サンドボックス"* ]] || fail "gemini を含む構成で sandbox-exec を点検しない"
LANES_TOOLS="claude codex" doctor 0
[[ "$OUT" != *"端末サンドボックス"* ]] || fail "gemini の無い構成で sandbox-exec を点検した"
# macOS でない（sandbox-exec が使えない）環境を、偽の uname で作る。点検を飛ばす差し替えの変数は無い
mkdir -p "$T/linux-bin"; print -r -- $'#!/bin/sh\necho Linux' > "$T/linux-bin/uname"; chmod +x "$T/linux-bin/uname"
PATH="$T/linux-bin:$PATH" LANES_TOOLS="claude gemini" doctor 2
[[ "$OUT" == *"NG   gemini: 端末サンドボックス"*"が無い"* ]] || fail "sandbox-exec を使えない環境を NG にしない"
PATH="$T/linux-bin:$PATH" LANES_TOOLS="claude codex" doctor 0
pass "gemini を含む構成だけ端末サンドボックス（sandbox-exec）を使えるかも点検する"
LANES_TOOLS="claude codex" doctor 0 --quiet
[[ -z "$OUT" ]] || fail "--quiet で成功時に出力した"
pass "--quiet はそろっていれば何も出さない"
# 構成に入っていない道具は見ない（codex が未ログインでも claude-only なら通る）
STUB_CODEX_AUTH=none LANES_TOOLS="claude" doctor 0
! grep -qE '^(ok|NG)   codex:' <<< "$OUT" || fail "構成に無い codex を点検した"
pass "構成に入っていない道具は点検しない"

# ---- 2. 未ログイン・API キーのログインで止まる ----
STUB_CLAUDE_AUTH=none LANES_TOOLS="claude" doctor 2
[[ "$OUT" == *"NG   claude: ログインしていない"* ]] || fail "Claude の未ログインを NG にしない"
pass "Claude の未ログインは exit 2"
STUB_CLAUDE_AUTH=apikey LANES_TOOLS="claude" doctor 2
[[ "$OUT" == *"NG   claude: API キーでログイン"* ]] || fail "Claude の API キーを NG にしない"
pass "Claude のサブスク以外のログインは exit 2"
STUB_CODEX_AUTH=apikey LANES_TOOLS="claude codex" doctor 2
[[ "$OUT" == *"NG   codex: API キーでログイン"* && "$OUT" != *"stub-not-a-real-key"* ]] || fail "Codex の API キーを NG にしない / 本文を出した"
pass "Codex の API キーのログインは exit 2（status の本文は出さない）"
STUB_CODEX_AUTH=none LANES_TOOLS="claude codex gemini" doctor 2 --quiet
[[ "$OUT" == *"NG   codex: ログインしていない"* ]] || fail "Codex の未ログインを NG にしない（--quiet でも一覧を出す）"
pass "Codex の未ログインは exit 2（--quiet でも一覧を出す）"
rm -rf "$H/.gemini"
LANES_TOOLS="claude gemini" doctor 2
[[ "$OUT" == *"NG   gemini: ログインしていない"* ]] || fail "Gemini の未ログインを NG にしない"
pass "Gemini（agy）のログイン情報が無ければ exit 2"
mkdir -p "$H/.gemini/antigravity-cli"

# ---- 3. 足りないものは全部並べる ----
STUB_CLAUDE_AUTH=none STUB_CODEX_AUTH=apikey LANES_TOOLS="claude codex gemini" GEMINI_BIN="$T/no-such-agy" PATH="$base_bin:/usr/bin:/bin" doctor 2
[[ "$(ng_count)" == 3 ]] || fail "足りないものを全部並べない（NG $(ng_count) 件）"
[[ "$OUT" == *"claude が見つからない"* && "$OUT" == *"codex が見つからない"* && "$OUT" == *"agy が見つからない"* ]] || fail "見つからない道具の名前が出ない"
[[ "$OUT" == *"足りないもの 3 件"* ]] || fail "件数の要約が無い"
pass "CLI が全部無ければ 3 件とも並べて exit 2"
STUB_CLAUDE_AUTH=apikey STUB_CODEX_AUTH=none LANES_TOOLS="claude codex" doctor 2
[[ "$(ng_count)" == 2 ]] || fail "未ログインが複数でも全部並べない"
pass "未ログインが複数あれば全部並べて exit 2"
LANES_TOOLS="claude foo" doctor 2
[[ "$OUT" == *"知らない道具名"* ]] || fail "知らない道具名を NG にしない"
pass "知らない道具名は exit 2"
LANES_TOOLS="codex" doctor 2
[[ "$OUT" == *"claude が無い"* ]] || fail "claude 抜きを NG にしない"
pass "claude 抜きは exit 2"
CLAUDE_BIN="$STUBS/claude" LANES_TOOLS="claude" PATH="$base_bin:/usr/bin:/bin" doctor 0
pass "CLAUDE_BIN に書いたパスは PATH に無くても使う"
# フォルダは -x でも真になるので、CLI のパスとして使わず PATH から探し直す
mkdir -p "$T/a-dir"
CLAUDE_BIN="$T/a-dir" LANES_TOOLS="claude" doctor 0
[[ "$OUT" == *"ok   claude: $stub_bin/claude"* ]] || fail "CLAUDE_BIN のフォルダを CLI として使った"
pass "CLAUDE_BIN にフォルダを書いても CLI として使わない（PATH から探す）"

# ---- 4. API キーの環境変数は「外して起動する」と表示するだけ（値は出さない）----
secret="test-only-value-should-not-be-printed"
ANTHROPIC_API_KEY="$secret" OPENAI_API_KEY="$secret" GEMINI_API_KEY="$secret" LANES_TOOLS="claude codex gemini" doctor 0
[[ "$OUT" == *"ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY"* && "$OUT" == *"起動時にこれらを外して"* ]] || fail "API キーを外す案内が無い"
[[ "$OUT" != *"$secret"* ]] || fail "API キーの値を出した"
pass "API キーの環境変数は外して起動すると表示し、値は出さない"

# ---- 5. 必須の道具が無い・設定ファイル ----
nogit="$T/nogit-bin"; mkdir -p "$nogit"; ln -s "$(command -v python3)" "$nogit/python3"; ln -s "$(command -v zsh)" "$nogit/zsh"
for t in sed grep head cat date tr wc mkdir dirname basename; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$nogit/$t"
done
LANES_TOOLS="claude" PATH="$stub_bin:$nogit" doctor 2
[[ "$OUT" == *"NG   git が PATH に無い"* ]] || fail "git が無いことを NG にしない"
pass "git が無ければ exit 2"
print -r -- 'LANES_TOOLS="${LANES_TOOLS:-claude codex}"' > "$T/lanes.conf"
LANES_CONF="$T/lanes.conf" doctor 0
[[ "$OUT" == *"ok   設定ファイル: $T/lanes.conf"* && "$OUT" == *"claude-codex"* ]] || fail "設定ファイルを読まない"
pass "設定ファイルの LANES_TOOLS で点検する"
# 司令塔（LANES_COMMANDER）は運用の印。値に合わせた監視の回し方を表示し、知らない値は注意だけ（止めない）
LANES_TOOLS="claude" LANES_COMMANDER=claude doctor 0
[[ "$OUT" == *"ok   司令塔: claude"*"--until-wake"* ]] || fail "司令塔 claude の監視の回し方を表示しない"
LANES_TOOLS="claude" LANES_COMMANDER=grok doctor 0
[[ "$OUT" == *"ok   司令塔: grok"*"lanes-monitor.sh"* ]] || fail "司令塔 grok の監視の回し方を表示しない"
LANES_TOOLS="claude" LANES_COMMANDER=other-bot doctor 0
[[ "$OUT" == *"注意 司令塔の値が grok / claude のどちらでもない"* ]] || fail "知らない司令塔の値を注意しない"
pass "司令塔の種別に合わせて監視の回し方を表示する"
doctor 2 --bogus
pass "不明なオプションは exit 2"
# 設定値の誤りがあっても止まらず NG の 1 行として並べ、ほかの不足（claude が無い）も並べてから exit 2
noclaude="$T/noclaude-bin"; mkdir -p "$noclaude"; ln -s "$STUBS/codex" "$noclaude/codex"
LANES_TOOLS="claude codex" LANES_NOTIFY=abc PATH="$noclaude:$base_bin:/usr/bin:/bin" doctor 2
[[ "$OUT" == *"NG   設定の誤り: "*"LANES_NOTIFY"* ]] || fail "設定値の誤りを NG の 1 行に並べない"
[[ "$OUT" == *"NG   claude: claude が見つからない"* ]] || fail "設定値の誤りのときにほかの不足（claude が無い）を並べない"
[[ "$OUT" == *"ok   codex: "* && "$OUT" == *"結果: 足りないもの 2 件"* ]] || fail "設定値の誤りのときに残りの点検を続けない"
[[ "$(print -r -- "$OUT" | grep -c '^ERROR')" == 0 ]] || fail "設定値の誤りで ERROR を出して途中で止まった"
pass "設定値の誤りは NG の 1 行として並べ、ほかの不足も全部並べてから exit 2"

# ---- 6. 作業ツリーを渡すと logs/ が git に無視されているかも見る（任意引数）----
wt="$T/wt"; git init -q "$wt"
LANES_TOOLS="claude" doctor 0 "$wt"
[[ "$OUT" == *"注意 作業ツリーの logs/ が git に無視されていない"* && "$OUT" == *".gitignore に logs/ を足して"* ]] || fail "logs/ が無視されていない注意が出ない"
pass "logs/ が無視されていない作業ツリーは注意（exit 0 のまま）"
LANES_TOOLS="claude" doctor 0 --quiet "$wt"
[[ -z "$OUT" ]] || fail "--quiet で注意だけのときに出力した"
pass "--quiet では注意だけなら何も出さない"
print -r -- 'logs/' > "$wt/.gitignore"
LANES_TOOLS="claude" doctor 0 "$wt"
[[ "$OUT" == *"ok   作業ツリーの logs/ は git に無視されている"* && "$OUT" != *"注意 作業ツリーの logs/"* ]] || fail "logs/ を無視しているのに ok にならない"
pass "logs/ を .gitignore に書いた作業ツリーは ok"
mkdir -p "$T/not-git"
LANES_TOOLS="claude" doctor 2 "$T/not-git"
[[ "$OUT" == *"NG   作業ツリーが git の作業ツリーではない"* ]] || fail "git でないフォルダを NG にしない"
pass "git の作業ツリーでないフォルダは exit 2"
LANES_TOOLS="claude" doctor 2 "$wt" "$wt"
pass "作業ツリーを 2 つ渡すと exit 2"

print -r -- "PASS: $count 件 / EXIT:0"
