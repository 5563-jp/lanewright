#!/bin/zsh -f
# Preview URL（公開前の確認用 URL）と観点ファイルを決め、画面 QA のプロンプト雛形を logs に書く。
# ブラウザ操作自体は司令塔（画面を操作できるエージェント）が行う。
# 使い方: prepare-screen-qa.sh <checkout> [label] [--url <preview-url>] [--viewpoints <観点ファイル>]
#   URL と観点ファイルは、引数 > 設定キー LANES_SCREEN_QA_MAP の対応表、の順で決める。
#   LANES_SCREEN_QA_MAP は改行区切りで「origin に含まれる文字列|Preview URL|観点ファイルのパス」（最初に一致した行を使う）。
#   観点ファイルの相対パスは checkout からの相対として読む。
#   URL が決まらない（対応表に無く --url も無い）ときは exit 2 で理由を出す。観点ファイルは無くてもよい。
set -euo pipefail
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"

usage="使い方: prepare-screen-qa.sh <checkout> [label] [--url <preview-url>] [--viewpoints <観点ファイル>]"
wt="${1:-}"; [[ -n "$wt" ]] || { print -u2 -- "$usage"; exit 2; }
shift
wt="${wt:A}"
label=""
url=""
viewpoints=""
while (( $# )); do
  case "$1" in
    --url) (( $# >= 2 )) && [[ -n "$2" ]] || { print -u2 -- "$usage"; exit 2; }; url="$2"; shift 2 ;;
    --viewpoints) (( $# >= 2 )) && [[ -n "$2" ]] || { print -u2 -- "$usage"; exit 2; }; viewpoints="$2"; shift 2 ;;
    --*) print -u2 -- "不明な引数: $1"; exit 2 ;;
    *) [[ -z "$label" ]] || lanes_die "label が 2 回: '$label' と '$1'"; label="$1"; shift ;;
  esac
done
[[ -n "$label" ]] || label="screen-qa"
lanes_require_label "$label"

# URL から認証情報やクエリを除き、接続先名（host/owner/repo 等）だけを取り出す
sanitize_origin_name() {
  python3 - "${1:-}" <<'PY'
import re, sys
from urllib.parse import urlsplit

raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if not raw:
    print("none")
    raise SystemExit(0)
raw = re.split(r"[?#]", raw, maxsplit=1)[0]
host = ""
path = ""
if "://" in raw or raw.startswith("//"):
    u = urlsplit(raw)
    host = u.hostname or ""
    if ":" in host:
        host = f"[{host}]"
    path = u.path or ""
elif ":" in raw and not raw.startswith(("/", ".", "~")):
    m = re.match(r"^(?:[^@/\s]+@)?(\[[^\]]+\]|[^:/\s]+):(.*)$", raw)
    if m:
        host, path = m.group(1), m.group(2)
    else:
        lhs, rhs = raw.split(":", 1)
        host = lhs.rsplit("@", 1)[-1]
        path = rhs
else:
    path = raw
segs = [s for s in path.replace("\\", "/").split("/") if s and s not in (".", "..") and "@" not in s and ":" not in s]
if segs:
    segs[-1] = re.sub(r"\.git$", "", segs[-1])
    segs = [s for s in segs if s]
if host:
    tail = "/".join(segs[-2:]) if segs else ""
    print(f"{host}/{tail}" if tail else host)
elif segs:
    print(segs[-1])
else:
    print("unknown")
PY
}

[[ -e "$wt/.git" ]] && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
lanes_require_worktree "$wt"
origin="$(git -C "$wt" remote get-url origin 2>/dev/null || true)"
head="$(git -C "$wt" rev-parse --short=12 HEAD)"
branch="$(git -C "$wt" branch --show-current 2>/dev/null || print detached)"

origin_name="$(sanitize_origin_name "$origin")"
project="$origin_name"
# 設定キー LANES_SCREEN_QA_MAP の対応表から、origin に含まれる文字列で行を選ぶ（引数で渡した値が優先）
map_hit=0
if [[ -n "$origin" && -n "${LANES_SCREEN_QA_MAP:-}" ]]; then
  for row in "${(@f)LANES_SCREEN_QA_MAP}"; do
    # 前後の空白を落とす
    row="${row#"${row%%[![:space:]]*}"}"; row="${row%"${row##*[![:space:]]}"}"
    [[ -n "$row" && "$row" != \#* ]] || continue
    needle="${row%%|*}"; rest="${row#*|}"
    [[ "$rest" != "$row" ]] || continue
    map_url="${rest%%|*}"; map_vp=""
    [[ "$rest" == *"|"* ]] && map_vp="${rest#*|}"
    [[ -n "$needle" && "$origin" == *"$needle"* ]] || continue
    map_hit=1
    [[ -n "$url" ]] || url="$map_url"
    [[ -n "$viewpoints" ]] || viewpoints="$map_vp"
    break
  done
fi
if (( ! map_hit )); then
  print -u2 -- "warn: LANES_SCREEN_QA_MAP に無い origin（$origin_name）。--url と --viewpoints で渡す"
fi
if [[ -z "$url" ]]; then
  print -u2 -- "error: Preview URL が決まらない。--url <preview-url> を渡すか、設定キー LANES_SCREEN_QA_MAP に「origin に含まれる文字列|Preview URL|観点ファイル」の行を足す"
  exit 2
fi
if [[ -n "$viewpoints" ]]; then
  [[ "$viewpoints" == "~/"* ]] && viewpoints="$HOME/${viewpoints#\~/}"
  [[ "$viewpoints" == /* ]] || viewpoints="$wt/$viewpoints"
  [[ -f "$viewpoints" ]] || print -u2 -- "warn: 観点ファイルが無い: $viewpoints"
fi

if [[ -n "$url" ]]; then
  url="$(python3 - "$url" <<'PY'
import re, sys
from urllib.parse import urlsplit, urlunsplit
raw = sys.argv[1].strip()
if "://" in raw or raw.startswith("//"):
    u = urlsplit(raw)
    host = u.hostname or ""
    if ":" in host:
        host = f"[{host}]"
    netloc = f"{host}:{u.port}" if u.port is not None else host
    print(urlunsplit((u.scheme, netloc, u.path, "", "")))
else:
    raw = re.split(r"[?#]", raw, maxsplit=1)[0]
    print(raw.rsplit("@", 1)[-1])
PY
)"
fi

logdir="$wt/logs"
[[ ! -L "$logdir" ]] || lanes_die "logs がシンボリックリンク: $logdir"
mkdir -p "$logdir"
logdir="${logdir:A}"
prompt="$logdir/${label}.prompt.md"
meta="$logdir/${label}.meta.txt"
[[ "${prompt:h:A}" == "$logdir" && "${prompt:t}" == "${label}.prompt.md" && ! -L "$prompt" ]] || lanes_die "保存先が logs/ 外: $prompt"
[[ "${meta:h:A}" == "$logdir" && "${meta:t}" == "${label}.meta.txt" && ! -L "$meta" ]] || lanes_die "保存先が logs/ 外: $meta"

{
  print -- "# 画面QA実行プロンプト（画面操作ができるエージェント向け）"
  print -- ""
  print -- "project: $project"
  print -- "checkout: $wt"
  print -- "branch: $branch"
  print -- "HEAD: $head"
  print -- "preview: $url"
  print -- "started_hint: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  print -- ""
  print -- "## 指示"
  print -- "1. 上記 Preview URL を開く（デプロイが HEAD とズレていれば報告）。"
  if [[ -n "$viewpoints" ]]; then
    print -- "2. 次の観点ファイルの BOT 項目をすべて実施する。"
  else
    print -- "2. 観点ファイルは無い。変更点に関わる画面と主要な導線を確認する。"
  fi
  print -- "3. Network で保存 API と AI API の **開始時刻** を取る（案件に AI がある場合）。"
  print -- "4. 最後に SCREEN_VERDICT: CLEAN または SCREEN_VERDICT: NEEDS_FIX を1行で出す。"
  print -- "5. コードは変更しない。"
  print -- ""
  print -- "## 観点ファイル"
  print -- "${viewpoints:-なし}"
  print -- ""
  if [[ -n "$viewpoints" && -f "$viewpoints" ]]; then
    print -- "---"
    cat "$viewpoints"
  fi
} > "$prompt"

{
  print -- "project=$project"
  print -- "preview=$url"
  print -- "head=$head"
  print -- "prompt=$prompt"
  print -- "viewpoints=$viewpoints"
} > "$meta"

print -- "preview=$url"
print -- "prompt=$prompt"
print -- "meta=$meta"
print -- "viewpoints=$viewpoints"
