#!/bin/zsh -f
# Claude Code の Stop フック（Claude が返事を終えようとしたときに走る）用。司令塔のセッションが、5 分の見張り
# （lanes-watch.sh --until-wake）を付けないまま待ちに入るのを、仕組みで止める。
#
# 止める条件（全部そろったときだけ）:
#   1. このセッションのやりとりの記録（Stop フックに渡される transcript_path。1 行 1 JSON）の中に、Bash ツールで実際に実行した
#      コマンドとして `lanes-watch.sh` を起動し、その引数に `--until-wake` があるものがある＝このセッションが司令塔として見張りを使っている。
#      会話の文中で言及しただけ（説明を求めた・手順を読んだ）・grep などで中身を調べただけのセッションには何もしない。
#      パスを引用符で囲んだ実行も拾う
#   2. `lanes-watch.sh --check` が WATCH OK でない（見張りが止まった・古い）
#   3. 動いているレーンがある（LANES RUNNING が 1 以上）か、次工程待ちのレーンがある（直近 N 分 DONE が 1 以上）
# 止めるときは {"decision":"block","reason":...} を返し、見張りをかけ直すよう Claude に伝える。
# 止めたあとの 2 回目（stop_hook_active が true）は止めない（同じ理由で止め続けて抜けられなくなるのを防ぐ）。
# どこかで失敗したら止めない（フックの不具合でセッションを止めない）。
#
# 登録（~/.claude/settings.json または対象のリポの .claude/settings.json の "hooks"）:
#   "Stop": [{"hooks": [{"type": "command", "command": "zsh -f <kit>/lanes/hooks/claude-stop-watch-guard.sh"}]}]
# 見張りのスクリプトの場所は、このファイルの 1 つ上の lanes-watch.sh（LANES_WATCH_GUARD_WATCH で差し替え可。テスト用）。
emulate -L zsh
setopt pipe_fail
input="$(cat 2>/dev/null)" || exit 0
watch="${LANES_WATCH_GUARD_WATCH:-${0:A:h:h}/lanes-watch.sh}"
[[ -f "$watch" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
parsed="$(print -r -- "$input" | python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("1" if d.get("stop_hook_active") else "0")
print(d.get("transcript_path") or "")' 2>/dev/null)" || exit 0
active="${${(f)parsed}[1]}"; transcript="${${(f)parsed}[2]:-}"
[[ "$active" == 0 ]] || exit 0
[[ -n "$transcript" && -f "$transcript" && ! -L "$transcript" ]] || exit 0
python3 -I -c 'import json,os,re,shlex,sys
# コマンドを ; & | と改行で区切り（\ の行継続はつなぐ）、それぞれを shlex でシェルと同じに単語へ分ける。
# 実行するプログラム（前置きの変数の代入・env・exec・nohup・time と、zsh / bash / sh とそのオプションを飛ばした最初の単語）が
# lanes-watch.sh で、その後ろの引数に --until-wake があるものだけを「見張りの起動」とみなす。
# grep・cat などで lanes-watch.sh を調べただけの形（lanes-watch.sh が別のプログラムの引数）は拾わない
WRAP = {"env", "exec", "nohup", "time", "command", "builtin", "noglob"}
SHELLS = {"zsh", "bash", "sh"}
def runs_watch(cmd):
    cmd = re.sub(r"\\\r?\n[ \t]*", " ", cmd)
    for seg in re.split(r"&&|\|\||[;&|\n]", cmd):
        try:
            w = shlex.split(seg, comments=True)
        except ValueError:
            continue
        i = 0
        while i < len(w) and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", w[i]) or w[i] in WRAP):
            i += 1
        if i < len(w) and os.path.basename(w[i]) in SHELLS:
            i += 1
            while i < len(w) and w[i].startswith("-"):
                i += 1
        if i < len(w) and os.path.basename(w[i]) == "lanes-watch.sh" and "--until-wake" in w[i + 1:]:
            return True
    return False
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    c = (d.get("message") or {}).get("content") if isinstance(d, dict) else None
    if not isinstance(c, list):
        continue
    for b in c:
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
            cmd = (b.get("input") or {}).get("command")
            if isinstance(cmd, str) and runs_watch(cmd):
                sys.exit(0)
sys.exit(1)' "$transcript" 2>/dev/null || exit 0
out="$(zsh -f "$watch" --check 2>/dev/null)"; rc=$?
first="${${(f)out}[1]:-}"
[[ "$first" == "WATCH OK"* ]] && exit 0
# --check が全く動かない（出力が無い）ときは判断できないので止めない
[[ -n "$first" ]] || exit 0
running="$(print -r -- "$out" | sed -n 's/^LANES RUNNING \([0-9][0-9]*\).*/\1/p' | head -1)"
waiting="$(print -r -- "$out" | sed -n 's/^直近[0-9]*分 DONE（次工程待ち）: \([0-9][0-9]*\) 件.*/\1/p' | head -1)"
(( ${running:-0} > 0 || ${waiting:-0} > 0 )) || exit 0
python3 -I -c 'import json,sys
first, running, waiting, watch = sys.argv[1:5]
reason = (f"見張りが止まっている（{first}）のに、動いているレーンが {running} 本、次工程待ちが {waiting} 件ある。"
          f"返事を終える前に `zsh -f {watch} --until-wake` をバックグラウンドで起動し直し、"
          "次工程待ちのレーンがあれば次の作業へつなぐこと。")
print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))' "$first" "${running:-0}" "${waiting:-0}" "$watch" || exit 0
exit 0
