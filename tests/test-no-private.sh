#!/bin/zsh -f
# キットの中に個人・案件固有の情報（ホームのパス・メール・ID・鍵の形をした文字列）が残っていないかを機械で確かめる。
# 使い方: [LANES_PRIVATE_DENYLIST=<禁止語ファイル>] tests/test-no-private.sh [キットのルート]
# 大事: 汎用のパターンだけでは拾えないものがある（ドメインだけの文字列・GitHub の組織名・人や案件の名前・UUID の形でない ID など）。
#   公開前の確認では、必ず禁止語ファイルを作って LANES_PRIVATE_DENYLIST で渡す（selftest.sh も、渡されていればこのテストへ渡す）。
#   禁止語ファイルは 1 行 1 パターン（grep -iE 相当。# で始まる行は注記）。固有名そのものなので、キットの外に置く。
#   渡さないときは汎用のパターンだけで調べ、その旨を出力する。LICENSE の著作者表記だけは検査対象外。
# 汎用のパターンで拾う形と、拾えない形:
#   - 40 桁の 16 進: git の commit SHA（コミットを表す番号）と見分けがつかないので、同じ行で直前 30 文字以内に
#     token / key / secret / password / bearer / auth などの語があるものだけ拾う。語の無い行の 40 桁は拾わない
#   - ~ で始まるパス: `~/…`（自分のホームの下）は手順書の一般的な書き方なので拾わない（`~/dev/<案件>` のような個人の
#     フォルダ名は禁止語ファイルで拾う）。他人のホームを名前で指す `~<名前>/…` の形だけ拾う
#   - macOS の利用者ごとの一時フォルダ（`/var/folders/<2 文字>/<ランダム>/…`。`/private` 付きも）は拾う
# 終了コード: 0 = 0 件 / 1 = 見つかった / 2 = 使い方の誤り
[ -n "${ZSH_VERSION:-}" ] || exec zsh -f "$0" "$@"
set -euo pipefail
# git の環境変数を外し、一時リポの外へ git が上っていかないようにする（本物のリポを書き換えない）
source "${0:A:h:h}/lanes/tests/_git-isolate.sh"; lanes_test_git_isolate
root="${1:-${0:A:h:h}}"
[[ -d "$root" ]] || { print -u2 -- "error: ディレクトリが無い: $root"; exit 2; }
deny="${LANES_PRIVATE_DENYLIST:-}"
if [[ -n "$deny" && ! -f "$deny" ]]; then print -u2 -- "error: 禁止語ファイルが無い: $deny"; exit 2; fi
exec python3 -I - "$root" "$deny" <<'PY'
import os, re, sys
root, deny = sys.argv[1], sys.argv[2]
# 汎用の禁止パターン（固有名を含まない形だけ）
generic = [
    ("ホームのパス", r"/(?:Users|home)/(?!example\b|you\b|USER\b|username\b|me\b)[A-Za-z0-9._-]+"),
    ("メールアドレス", r"[A-Za-z0-9._%+-]+@(?!example\.(?:com|org|net)\b)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"),
    ("UUID", r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"),
    ("32 桁の ID", r"(?<![0-9a-fA-F])[0-9a-f]{32}(?![0-9a-fA-F])"),
    ("API キーの形", r"\b(?:sk-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{8,}|rk_live_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})"),
    ("JWT の形", r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}"),
    ("秘密鍵", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("Supabase の接続先", r"\b[a-z]{20}\.supabase\.(?:co|in)\b"),
    ("Vercel の個別 URL", r"\b(?!example)[a-z0-9-]+\.vercel\.app\b"),
    ("鍵らしい 40 桁の 16 進", r"(?i)(?:token|secret|passw(?:or)?d|bearer|auth|api[_-]?key|\bkey)[^\n]{0,30}?(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])"),
    ("他人のホームの ~ のパス", r"(?<![\w$}])~(?!example\b|you\b|USER\b|username\b)[A-Za-z][A-Za-z0-9._-]*/"),
    ("macOS の一時フォルダ", r"(?:/private)?/var/folders/[A-Za-z0-9_+-]{2}/[A-Za-z0-9_+-]{6,}"),
]
pats = [(n, re.compile(p)) for n, p in generic]
if not deny:
    print("NOTE: 禁止語ファイル（LANES_PRIVATE_DENYLIST）が無いので、汎用のパターンだけで調べる。"
          "人や案件の名前・ドメインなどは拾えない。公開前は禁止語ファイルを作って渡す")
if deny:
    for line in open(deny, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            pats.append(("禁止語", re.compile(line, re.I)))
skip_dirs = {".git", "logs", "__pycache__", ".lanes"}
hits = 0
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in skip_dirs]
    for fn in fns:
        # worktree・サブモジュールでは .git がファイル（管理領域の場所を指す 1 行）になる。中身は git のもので、キットの内容ではない
        if fn == ".git":
            continue
        path = os.path.join(dp, fn)
        rel = os.path.relpath(path, root)
        for n, p in pats:
            if p.search(rel):
                print(f"{rel}: [ファイル名・{n}]"); hits += 1
        if rel == "LICENSE":
            continue
        try:
            data = open(path, "rb").read()
        except OSError:
            continue
        text = data.decode("utf-8", errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            for n, p in pats:
                m = p.search(line)
                if m:
                    # 見つけた文字列そのものは出さない（鍵だった場合に晒さないため）
                    print(f"{rel}:{i}: [{n}] {len(m.group(0))} 文字"); hits += 1
print(f"NO-PRIVATE: {hits} 件（禁止語ファイル: {'あり ' + str(len(pats) - len(generic)) + ' パターン' if deny else 'なし・汎用のパターンだけ'}）")
sys.exit(1 if hits else 0)
PY
