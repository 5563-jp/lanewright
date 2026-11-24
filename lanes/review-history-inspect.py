#!/usr/bin/env python3
"""レビュー範囲（<比較起点>..HEAD）の各 commit の変更パスを並べ、混入を点検する（Gemini レビューの指示書に埋め込む）。

見るのは、各 commit の変更パス（git log -z の生のパス）・変更後の大きさ・その commit の時点の .gitignore だけ。
ファイルの内容と作者は見ない（.gitignore の規則だけは、照合のために一時フォルダへ写す）。
- マージ commit は、すべての親と違うパス（マージ自体で生じた変更。git log -c）を載せて点検する。表示と点検は同じ一覧を使う。
- パスは NUL 区切りで得た実名のまま照合する（前後の空白を削らない。Git の表示用の引用・変換を通さない）。表示するときだけ引用する。
- 混入は 2 つに分ける: 規則に反する混入（その commit の時点の .gitignore で無視されるパスを新しく持ち込んだ）と、
  名前・大きさによる要確認候補（規則には反しない）。.gitignore の例外（! の規則）で許可されたパスは、名前では候補にしない。
- 削除だけの変更は混入に数えない。新しく持ち込んだパス（すべての親に無い）と、変更後の大きさだけを見る。
- 照合に失敗したもの（.gitignore を読めない・大きさが分からない など）は「判定できなかったもの」に分け、「該当なし」にしない。
- git の呼び出しは、パスの数によらず 5 回まで（変更一覧・大きさ・.gitignore の中身・一時リポの作成・無視の判定）。
macOS 付属の python3（3.9）でも動く書き方にする（文字列の埋め込み式の中で外側と同じ引用符を使わない など）。

使い方: review-history-inspect.py <worktree> <比較起点の commit（16 進）> [一時フォルダの置き場所]
出力: 指示書に入れる Markdown（標準出力・UTF-8）。変更一覧を読めないときは何も出さず終了コード 1
（呼び出し側が「点検できなかった」と書く）。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

MAX_LIST = 200  # 変更パスの一覧に載せる行数（点検は全件で行う）
MAX_SHOW = 20   # 点検結果の分類ごとに載せる代表箇所の数
HUGE = 1048576  # 巨大ファイルとみなす大きさ（バイト）
SECRET = re.compile(
    r"(?:^|/)(?:\.env(?:\..+)?|id_(?:rsa|dsa|ecdsa|ed25519)|.+\.(?:pem|p12|pfx|keystore)|(?:credentials|service-account.*)\.json)$",
    re.I,
)
RUNSH = re.compile(r"(?:^|/)run-[^/]+\.sh$", re.I)
LOGS = re.compile(r"(?:^|/)logs/", re.I)
HEX = re.compile(rb"[0-9a-f]{40,64}")
MODE = re.compile(rb"[0-7]{6}")
STATUS = re.compile(rb"[ACDMTUX]+")
GITLINK = "160000"


class Change:
    """1 commit の 1 パスの変更。path は生のバイト列、name は照合・表示用の文字列（復号できないバイトはそのまま持つ）。"""

    def __init__(self, sha, status, mode, oid, path):
        self.sha, self.status, self.mode, self.oid, self.path = sha, status, mode, oid, path
        self.name = path.decode("utf-8", "surrogateescape")
        self.new = all(ch == "A" for ch in status)   # すべての親に無かったパス（新しく持ち込んだ）
        self.deleted = mode == "000000"
        self.gone = False      # あとの commit で消した
        self.ignore = None     # 無視の判定: None = 判定できない / ("", ...) = 規則なし / ("!", ...) = 例外で許可 / ("x", 規則, 場所)
        self.why_unknown = ""  # 無視の判定ができなかった理由


def run(args, data=None, env=None):
    try:
        return subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    except OSError:
        return None


def parse_meta(tok, parents):
    """--raw の 1 件（":<mode>... <oid>... <状態>"）から、状態・変更後の mode・変更後の oid を返す。形が違えば None。"""
    n = len(tok) - len(tok.lstrip(b":"))
    if n != max(parents, 1):
        return None
    f = tok[n:].split(b" ")
    if len(f) != 2 * n + 3:
        return None
    modes, oids, status = f[:n + 1], f[n + 1:2 * n + 2], f[-1]
    if not all(MODE.fullmatch(m) for m in modes) or not all(HEX.fullmatch(o) for o in oids):
        return None
    if not STATUS.fullmatch(status) or len(status) != n:
        return None
    return status.decode(), modes[-1].decode(), oids[-1].decode()


def read_changes(wt, start, env):
    """範囲の commit（新しい順）と変更を 1 回の git log で読む。読めない・形が違うときは None。"""
    r = run(["git", "-C", wt, "log", "-z", "--no-color", "--no-show-signature", "--no-notes", "--no-renames",
             "--no-ext-diff", "--root", "-c", "--raw", "--no-abbrev", "--format=%x01%H %P", start + "..HEAD", "--"],
            env=env)
    if r is None or r.returncode != 0:
        return None
    toks = r.stdout.split(b"\0")
    commits, cur, i = [], None, 0
    while i < len(toks):
        tok = toks[i].lstrip(b"\n")
        i += 1
        if not tok:
            continue
        if tok.startswith(b"\x01"):
            f = [x for x in tok[1:].split(b" ") if x]
            if not f or not all(HEX.fullmatch(x) for x in f):
                return None
            cur = (f[0].decode(), len(f) - 1, [])
            commits.append(cur)
            continue
        if cur is None or not tok.startswith(b":") or i >= len(toks) or not toks[i]:
            return None
        meta = parse_meta(tok, cur[1])
        if meta is None:
            return None
        cur[2].append(Change(cur[0], meta[0], meta[1], meta[2], toks[i]))
        i += 1
    return commits


def blob_sizes(wt, oids, env):
    """oid → 大きさ。読めなかったものは入れない（呼び出し側が「判定できなかった」に分ける）。"""
    if not oids:
        return {}
    r = run(["git", "-C", wt, "cat-file", "--batch-check=%(objectname) %(objectsize)"],
            ("\n".join(oids) + "\n").encode(), env)
    if r is None or r.returncode != 0:
        return {}
    sizes = {}
    for oid, line in zip(oids, r.stdout.split(b"\n")):
        f = line.split(b" ")
        if len(f) == 2 and f[0] == oid.encode() and f[1].isdigit():
            sizes[oid] = int(f[1])
    return sizes


def dirs_of(path):
    """パスの親フォルダ（b"" = 最上位、b"a/"、b"a/b/" …）。照合に使えない形（空・.・..・.git・改行）なら None。"""
    parts = path.split(b"/")[:-1]
    out, acc = [b""], b""
    for p in parts:
        if p in (b"", b".", b"..") or p.lower() == b".git" or b"\n" in p:
            return None
        acc += p + b"/"
        out.append(acc)
    return out


def read_gitignores(wt, queries, env):
    """[(commit, フォルダ)] → {(commit, フォルダ): その commit の <フォルダ>.gitignore の中身}。読めないときは None。"""
    if not queries:
        return {}
    data = b"".join(c.encode() + b":" + d + b".gitignore\n" for c, d in queries)
    r = run(["git", "-C", wt, "cat-file", "--batch"], data, env)
    if r is None or r.returncode != 0:
        return None
    found, pos, buf = {}, 0, r.stdout
    for c, d in queries:
        end = buf.find(b"\n", pos)
        if end < 0:
            return None
        head, pos = buf[pos:end], end + 1
        f = head.split(b" ")
        if len(f) == 3 and HEX.fullmatch(f[0]) and f[2].isdigit():
            size = int(f[2])
            if buf[pos + size:pos + size + 1] != b"\n":
                return None
            if f[1] == b"blob":
                found[(c, d)] = buf[pos:pos + size]
            pos += size + 1
        elif head != c.encode() + b":" + d + b".gitignore missing":
            return None
    return found


def fold(d):
    """大文字・小文字と Unicode の正規化だけが違うフォルダを同じものとして扱う鍵（一時フォルダの上で取り違えないため）。"""
    return unicodedata.normalize("NFC", d.decode("utf-8", "surrogateescape")).casefold()


def check_ignores(wt, commits, tmp_parent, env):
    """新しく持ち込んだパスを、その commit の時点の .gitignore（最上位と、パスの親フォルダのもの）で照合する。
    規則の組ごとに一時フォルダの r<番号>/ の下へ .gitignore だけを写し、1 回の git check-ignore で全部を問い合わせる。"""
    targets = [ch for _, _, changes in commits for ch in changes if ch.new]
    if not targets:
        return
    per_commit, queries = {}, []
    for ch in targets:
        dirs = dirs_of(ch.path)
        if dirs is None:
            ch.why_unknown = "パスの形を照合に使えない（空・.・..・.git・改行を含むフォルダ）"
            continue
        want = per_commit.setdefault(ch.sha, set())
        for d in dirs:
            if d not in want:
                want.add(d)
                queries.append((ch.sha, d))
    contents = read_gitignores(wt, queries, env)
    if contents is None:
        for ch in targets:
            ch.why_unknown = ch.why_unknown or "その commit の時点の .gitignore を読めない"
        return
    rulesets, which = {}, {}
    for sha, dirs in per_commit.items():
        key = tuple(sorted((d, contents[(sha, d)]) for d in dirs if (sha, d) in contents))
        which[sha] = rulesets.setdefault(key, len(rulesets))
    tmp = None
    try:
        tmp = tempfile.mkdtemp(prefix="history-inspect.", dir=tmp_parent)
        ok = write_rulesets(tmp, rulesets)
        clean = {k: v for k, v in env.items() if not k.startswith("GIT_")}
        genv = dict(clean, HOME=tmp, XDG_CONFIG_HOME=tmp, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        asked, qs = [], []
        for ch in targets:
            if ch.why_unknown:
                continue
            idx = which[ch.sha]
            if idx not in ok:
                ch.why_unknown = "その commit の .gitignore を照合用に写せない（大文字・小文字か Unicode の正規化だけが違うフォルダ）"
                continue
            if any(len(ok[idx].get(fold(d), {d})) > 1 or d not in ok[idx].get(fold(d), {d}) for d in dirs_of(ch.path)):
                ch.why_unknown = "大文字・小文字か Unicode の正規化だけが違うフォルダがあり、照合できない"
                continue
            asked.append(ch)
            qs.append(b"r%d/" % idx + ch.path)
        if not qs:
            return
        init = run(["git", "init", "-q", "--template=", tmp], env=genv)
        r = None
        if init is not None and init.returncode == 0:
            r = run(["git", "-C", tmp, "-c", "core.excludesFile=" + os.devnull, "-c", "core.precomposeUnicode=false",
                     "check-ignore", "--no-index", "-v", "-n", "-z", "--stdin"], b"\0".join(qs) + b"\0", genv)
        toks = r.stdout.split(b"\0") if r is not None and r.returncode in (0, 1) else []
        if len(toks) != 4 * len(qs) + 1 or any(toks[4 * k + 3] != qs[k] for k in range(len(qs))):
            for ch in asked:
                ch.why_unknown = "その commit の時点の .gitignore と照合できなかった（git check-ignore が失敗）"
            return
        for k, ch in enumerate(asked):
            src, line, pattern = toks[4 * k], toks[4 * k + 1], toks[4 * k + 2]
            if not pattern:
                ch.ignore = ("",)
            elif pattern.startswith(b"!"):
                ch.ignore = ("!",)
            else:
                place = src.split(b"/", 1)[-1].decode("utf-8", "surrogateescape") + " " + line.decode("ascii", "replace") + " 行目"
                ch.ignore = ("x", pattern.decode("utf-8", "surrogateescape"), place)
    except OSError:
        for ch in targets:
            ch.why_unknown = ch.why_unknown or "照合用の一時フォルダを作れない"
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


def write_rulesets(tmp, rulesets):
    """規則の組ごとに r<番号>/ の下へ .gitignore を写す。番号 → {鍵: 実際のフォルダの集合}（写せた組だけ）。"""
    ok = {}
    base = os.fsencode(tmp)
    for key, idx in rulesets.items():
        seen = {}
        try:
            for d, body in key:
                for a in dirs_of(d + b"x") or []:
                    seen.setdefault(fold(a), set()).add(a)
                where = os.path.join(base, b"r%d" % idx, d)
                os.makedirs(where, exist_ok=True)
                fd = os.open(os.path.join(where, b".gitignore"), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "wb") as f:
                    f.write(body)
            os.makedirs(os.path.join(base, b"r%d" % idx), exist_ok=True)
        except OSError:
            continue
        ok[idx] = seen
    return ok


def show(name):
    """表示用の名前。照合は生の名前で行い、表示だけ Git と同じ流儀で引用する（制御文字・引用符・\\・前後の空白・印字できない文字）。"""
    if name == name.strip() and name.isprintable() and '"' not in name and "\\" not in name:
        return name
    out = []
    for ch in name:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch in "\t\n\r":
            out.append({"\t": "\\t", "\n": "\\n", "\r": "\\r"}[ch])
        elif ch == " " or ch.isprintable():
            out.append(ch)
        else:
            out.extend("\\%03o" % b for b in ch.encode("utf-8", "surrogateescape"))
    return '"' + "".join(out) + '"'


def name_reasons(name):
    """名前による要確認の理由（照合は各部分の前後の空白を除いた名前で広めに行う。前後に空白を足した名前もすり抜けさせない）。"""
    norm = "/".join(unicodedata.normalize("NFC", p).strip() for p in name.split("/"))
    out = []
    if SECRET.search(norm):
        out.append(("秘密らしい名前", "秘密らしい名前"))
    if RUNSH.search(norm):
        out.append(("run-*.sh", "名前が run-*.sh（手書きのランチャ・一時スクリプトの可能性）"))
    if LOGS.search(norm):
        out.append(("logs/ の下", "logs/ の下"))
    return out


def section(title, items, tail):
    """分類ごとの件数・理由別の件数・代表箇所（MAX_SHOW 件まで）。items は [(理由の鍵の並び, 1 行の説明)]。"""
    counts = {}
    for keys, _ in items:
        for k in keys:
            counts[k] = counts.get(k, 0) + 1
    by = "・".join(k + " " + str(n) for k, n in counts.items())
    head = "- " + title + ": " + str(len(items)) + " 件"
    if by:
        head += "（理由別: " + by + "）"
    lines = [head + "。" + tail if items else head + "。"]
    if items:
        # 代表箇所は、理由ごとに最初の 1 件を先に選び、残りを新しい順に足す（多い理由が少ない理由を隠さない）
        firsts = sorted({next(j for j, (keys, _) in enumerate(items) if k in keys) for k in counts})[:MAX_SHOW]
        pick = firsts + [j for j in range(len(items)) if j not in firsts][:MAX_SHOW - len(firsts)]
        lines.append("")
        lines.extend("    " + items[j][1] for j in sorted(pick))
        if len(items) > MAX_SHOW:
            lines.append("    （ほか " + str(len(items) - MAX_SHOW) + " 件。点検は全件で行った）")
    return lines


def main():
    if len(sys.argv) < 3 or not re.fullmatch(r"[0-9a-f]{4,64}", sys.argv[2]):
        return 1
    wt, start = sys.argv[1], sys.argv[2]
    tmp_parent = sys.argv[3] if len(sys.argv) > 3 else ""
    if not (tmp_parent and os.path.isdir(tmp_parent) and not os.path.islink(tmp_parent)):
        tmp_parent = None
    # 部分 clone でも、点検のために外から取りに行かない（取れないものは「判定できなかった」に分ける）
    env = dict(os.environ, LC_ALL="C", GIT_NO_LAZY_FETCH="1", GIT_ALLOW_PROTOCOL="lanes-no-transport")
    commits = read_changes(wt, start, env)
    if commits is None:
        return 1
    # あとの commit（git log の新しい順で先に出る）で消したパスに印を付ける
    removed = set()
    for _, _, changes in commits:
        for ch in changes:
            if ch.new and ch.path in removed:
                ch.gone = True
        removed.update(ch.path for ch in changes if ch.deleted)
    changes = [ch for _, _, cs in commits for ch in cs]
    oids = sorted({ch.oid for ch in changes if not ch.deleted and ch.mode != GITLINK})
    sizes = blob_sizes(wt, oids, env)
    check_ignores(wt, commits, tmp_parent, env)

    bad, maybe, unknown = [], [], []
    for ch in changes:
        if ch.deleted:
            continue   # 削除だけの変更は混入に数えない
        where = "commit " + ch.sha[:12] + " の " + ch.status + " " + show(ch.name)
        gone = "。あとの commit で消したが、公開履歴に残る" if ch.gone else ""
        size_r = []
        if ch.mode != GITLINK:
            if ch.oid not in sizes:
                unknown.append((["大きさ"], where + "（大きさを確かめられない）"))
            elif sizes[ch.oid] >= HUGE:
                size_r = [("巨大ファイル", "巨大ファイル（変更後 " + str(sizes[ch.oid]) + " バイト）")]
        names = name_reasons(ch.name) if ch.new else []
        if ch.new and ch.ignore is None:
            unknown.append((["無視の規則"], where + "（" + (ch.why_unknown or "その commit の時点の .gitignore と照合できなかった") + "）"))
        if ch.new and ch.ignore is not None and ch.ignore[0] == "x":
            rule = ("規則で無視", "その commit の .gitignore の規則 " + show(ch.ignore[1]) + "（" + ch.ignore[2] + "）で無視される")
            reasons = [rule] + names + size_r
            bad.append(([k for k, _ in reasons], where + "（" + "・".join(t for _, t in reasons) + gone + "）"))
            continue
        if ch.new and ch.ignore is not None and ch.ignore[0] == "!":
            names = []   # .gitignore の例外（! の規則）で明示的に許可された名前は、名前では候補にしない
        reasons = names + size_r
        if reasons:
            maybe.append(([k for k, _ in reasons], where + "（" + "・".join(t for _, t in reasons) + gone + "）"))

    out = ["- 各 commit の変更パス（ランチャが git log の NUL 区切りの生のパスから作った。内容・作者なし。途中で追加して消したファイルも含む。"
           "マージ commit は、すべての親と違うパス（マージ自体で生じた変更）を載せる。状態は親ごとに A=追加・M=変更・D=削除・T=種類の変更。"
           "引用符で囲んだ名前は、制御文字・引用符・前後の空白などを Git と同じ流儀で書き換えて表示したもの）:", ""]
    rows = [ch.sha[:12] + " " + ch.status + " " + show(ch.name) for ch in changes]
    if rows:
        out.extend("    " + r for r in rows[:MAX_LIST])
        if len(rows) > MAX_LIST:
            out.append("    （ほか " + str(len(rows) - MAX_LIST) + " 行。点検は全件で行った）")
    else:
        out.append("    （変更なし）")
    out.append("")
    n_new = sum(1 for ch in changes if ch.new)
    out.append("- 混入の点検（ランチャが、上の一覧と同じ変更・変更後の大きさ・その commit の時点の .gitignore だけを見た。内容・作者は見ていない。"
               "点検は全件で行い、ここには分類ごとの件数・理由別の件数・代表箇所（各 " + str(MAX_SHOW) + " 件まで）を載せる）: commit "
               + str(len(commits)) + " 件・変更 " + str(len(changes)) + " 件（うち新しく持ち込んだパス " + str(n_new) + " 件）を点検した。")
    out.append("")
    out += section("規則に反する混入（その commit の時点の .gitignore で無視されるパスを、新しく持ち込んだ）", bad,
                   "1 件ずつ指摘に書く:")
    out.append("")
    out += section("名前・大きさによる要確認候補（リポジトリの規則には反しない。名前と大きさだけで選んだ）", maybe,
                   "正規のファイル・意図した見本なら指摘にしない。`.env*` や鍵の候補は中身を開かず、名前と変更の目的から判断し、"
                   "意図しない混入なら指摘に書く:")
    out.append("")
    out += section("判定できなかったもの（照合に失敗した。「該当なし」ではない）", unknown,
                   "判定できなかったことと対象を指摘に書く:")
    if not bad and not maybe and not unknown:
        out.append("")
        out.append("- 禁止・無視対象・巨大ファイルに当たるパスは見つからなかった（途中で追加して消したファイルも含め、全件を照合できた）。")
    sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8", "replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
