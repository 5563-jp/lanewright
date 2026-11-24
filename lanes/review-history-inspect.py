#!/usr/bin/env python3
"""レビュー範囲（<比較起点>..HEAD）の各 commit の変更パスを並べ、混入を点検する（Gemini レビューの指示書に埋め込む）。

見るのは、各 commit の変更パス（git log -z の生のパス）・変更後の大きさ・変更パスの親フォルダの一覧（木）・その commit の時点の
.gitignore・HEAD の木だけ。ファイルの内容と作者は見ない（.gitignore の規則だけは、照合のために一時フォルダへ写す）。
- マージ commit は、すべての親と違うパス（マージ自体で生じた変更。git log -c）を載せて点検する。表示と点検は同じ一覧を使う。
- パスは NUL 区切りで得た実名のまま照合する（前後の空白を削らない。Git の表示用の引用・変換を通さない）。表示するときだけ引用する。
- 結果は 3 つに分ける: 規則に反する混入（その commit の時点の .gitignore で無視されるパスを新しく持ち込んだ）と、
  要確認候補（名前・大きさで選んだもの、前から追跡している無視対象・秘密らしい名前のファイルの変更）と、判定できなかったもの。
  .gitignore の例外（! の規則）で許可されたパスは、名前では候補にしない。秘密らしい名前（.env*・鍵の拡張子など）は内容を開かない。
- 削除だけの変更は混入に数えない（新しく持ち込んだパス＝すべての親に無いパスと、削除以外の変更の中身だけを見る）。
- .gitignore の有無と種類は、その commit の親フォルダの木で確かめる（無い・フォルダ・リンクは規則なし。Git はリンクの .gitignore を
  読まない）。通常ファイルの .gitignore の中身を取得できない（部分 clone など）ときは「判定できなかったもの」に分ける。
- 大文字・小文字の扱いは、対象リポジトリで有効な core.ignoreCase に合わせる（照合用の一時リポの値を使わない）。
- 新しく持ち込んだパスが HEAD に無ければ、その事実を添える（HEAD の木で確かめる。範囲の中の削除の有無からは推定しない）。
- 照合に失敗したもの（.gitignore を読めない・大きさが分からない など）は「判定できなかったもの」に分け、「該当なし」にしない。
- git の呼び出しは、パスの数によらず 6 回まで（変更一覧・大きさ・木と .gitignore の中身・core.ignoreCase・一時リポの作成・無視の判定）。
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
# 名前による候補は、パスの最後の名前で判定する（re.S: 名前の途中に改行があっても途切れない。ルート直下も下のフォルダも同じ）
SECRET_EXT = (".pem", ".key", ".p8", ".p12", ".pfx", ".keystore")   # 鍵の拡張子（大文字・小文字を区別しない endswith）
SECRET_NAME = re.compile(r"\.env(?:\..+)?|id_(?:rsa|dsa|ecdsa|ed25519)|(?:credentials|service-account.*)\.json", re.I | re.S)
RUNSH = re.compile(r"run-.+\.sh", re.I | re.S)
HEX = re.compile(rb"[0-9a-f]{40,64}")
MODE = re.compile(rb"[0-7]{6}")
STATUS = re.compile(rb"[ACDMTUX]+")
TREE_MODE = re.compile(rb"[0-7]{5,6}")
GITLINK = "160000"


class Change:
    """1 commit の 1 パスの変更。path は生のバイト列、name は照合・表示用の文字列（復号できないバイトはそのまま持つ）。"""

    def __init__(self, sha, status, mode, oid, path):
        self.sha, self.status, self.mode, self.oid, self.path = sha, status, mode, oid, path
        self.name = path.decode("utf-8", "surrogateescape")
        self.new = all(ch == "A" for ch in status)   # すべての親に無かったパス（新しく持ち込んだ）
        self.deleted = mode == "000000"
        self.gone = False      # HEAD の時点で、このパスが無い（途中で消した）
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
    """範囲の commit（新しい順）と変更を 1 回の git log で読む。(commit の並び, HEAD の commit) を返す。
    HEAD は、範囲の中でどの commit の親でもない唯一の commit（範囲の commit はすべて HEAD の祖先なので 1 つに決まる）。
    読めない・形が違うときは None。"""
    r = run(["git", "-C", wt, "log", "-z", "--no-color", "--no-show-signature", "--no-notes", "--no-renames",
             "--no-ext-diff", "--root", "-c", "--raw", "--no-abbrev", "--format=%x01%H %P", start + "..HEAD", "--"],
            env=env)
    if r is None or r.returncode != 0:
        return None
    toks = r.stdout.split(b"\0")
    commits, parents, cur, i = [], set(), None, 0
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
            parents.update(x.decode() for x in f[1:])
            continue
        if cur is None or not tok.startswith(b":") or i >= len(toks) or not toks[i]:
            return None
        meta = parse_meta(tok, cur[1])
        if meta is None:
            return None
        cur[2].append(Change(cur[0], meta[0], meta[1], meta[2], toks[i]))
        i += 1
    tips = [c[0] for c in commits if c[0] not in parents]
    return commits, (tips[0] if len(tips) == 1 else None)


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


def cat_batch(wt, names, env):
    """名前（<commit>:<パス>）ごとの (oid, 種類, 中身) の並び。見つからない・取得できないものは None。
    git が失敗した・出力の形が違うときは全体が None。"""
    if not names:
        return []
    r = run(["git", "-C", wt, "cat-file", "--batch"], b"".join(n + b"\n" for n in names), env)
    if r is None or r.returncode != 0:
        return None
    out, pos, buf = [], 0, r.stdout
    for _ in names:
        end = buf.find(b"\n", pos)
        if end < 0:
            return None
        head, pos = buf[pos:end], end + 1
        f = head.split(b" ")
        if len(f) == 3 and HEX.fullmatch(f[0]) and f[2].isdigit():
            size = int(f[2])
            if buf[pos + size:pos + size + 1] != b"\n":
                return None
            out.append((f[0].decode(), f[1], buf[pos:pos + size]))
            pos += size + 1
        elif head.endswith((b" missing", b" ambiguous")):
            out.append(None)
        else:
            return None
    return out if pos == len(buf) else None


def tree_entries(obj):
    """木の応答 → {名前: (mode（数値）, oid（16 進））}。木でない・取得できない・形が違えば None。"""
    if obj is None or obj[1] != b"tree":
        return None
    oid, _, body = obj
    n, out, pos = len(oid) // 2, {}, 0
    while pos < len(body):
        sp = body.find(b" ", pos)
        nul = body.find(b"\0", sp + 1) if sp > pos else -1
        if nul < 0 or nul + 1 + n > len(body) or not TREE_MODE.fullmatch(body[pos:sp]):
            return None
        out[body[sp + 1:nul]] = (int(body[pos:sp], 8), body[nul + 1:nul + 1 + n].hex())
        pos = nul + 1 + n
    return out


class Trees:
    """各 commit の木（変更パスの親フォルダ）と、そこにある .gitignore の中身を 1 回の git cat-file --batch で読む。
    項目の有無と種類は、親フォルダの木で確かめる（名前で引いた「missing」は、項目が無い場合と、部分 clone で中身を
    取得できない場合を区別できないため）。dirs: 木を読む (commit, フォルダ)、ignores: .gitignore を読む (commit, フォルダ)。"""

    def __init__(self, wt, dirs, ignores, env):
        tq, gq = sorted(set(dirs) | set(ignores)), sorted(set(ignores))
        got = cat_batch(wt, [c.encode() + b":" + d[:-1] for c, d in tq]
                        + [c.encode() + b":" + d + b".gitignore" for c, d in gq], env)
        self.read = got is not None
        got = got or []
        self.trees, self.blobs = dict(zip(tq, got[:len(tq)])), dict(zip(gq, got[len(tq):]))
        self.cache = {}

    def entries(self, c, d):
        if (c, d) not in self.cache:
            self.cache[(c, d)] = tree_entries(self.trees.get((c, d)))
        return self.cache[(c, d)]

    def gitignore(self, c, d):
        """c の時点の <d>.gitignore の規則: (中身, "")。規則なし（無い・フォルダ・リンク・サブモジュール）は (b"", "")。
        読めなければ (None, 理由)。Git はリンクの .gitignore を読まない（リンク先の名前を規則として扱わない）。"""
        if not self.read:
            return None, "その commit の時点の .gitignore を読めない（git cat-file が失敗）"
        ents = self.entries(c, d)
        if ents is None:
            return None, "その commit の時点のフォルダの一覧を読めない（部分 clone など）"
        e = ents.get(b".gitignore")
        if e is None or e[0] in (0o40000, 0o120000, 0o160000):
            return b"", ""
        obj = self.blobs.get((c, d))
        if e[0] not in (0o100644, 0o100755, 0o100664) or obj is None or obj[1] != b"blob" or obj[0] != e[1]:
            return None, "その commit の時点の .gitignore の中身を取得できない（部分 clone など）"
        return obj[2], ""

    def exists(self, c, path):
        """c の時点で path があるか: True / False / None（木を読めず分からない・照合に使えない形）。"""
        dirs = dirs_of(path)
        if dirs is None or not self.read:
            return None
        for i, d in enumerate(dirs):
            ents = self.entries(c, d)
            if ents is None:
                return None
            last = i == len(dirs) - 1
            e = ents.get(path[len(d):] if last else dirs[i + 1][len(d):-1])
            if e is None or (not last and e[0] != 0o40000):
                return False
        return True


def read_ignore_case(wt, env):
    """対象リポジトリで有効な core.ignoreCase（"true" / "false"。設定が無ければ Git の既定の "false"）。読めなければ None。"""
    r = run(["git", "-C", wt, "config", "--bool", "--get", "core.ignoreCase"], env=env)
    if r is None:
        return None
    if r.returncode == 1 and not r.stdout:
        return "false"
    v = r.stdout.strip()
    return v.decode() if r.returncode == 0 and v in (b"true", b"false") else None


def fold(d):
    """大文字・小文字と Unicode の正規化だけが違うフォルダを同じものとして扱う鍵（一時フォルダの上で取り違えないため）。"""
    return unicodedata.normalize("NFC", d.decode("utf-8", "surrogateescape")).casefold()


def check_ignores(wt, targets, trees, tmp_parent, env):
    """削除以外の変更のパスを、その commit の時点の .gitignore（最上位と、パスの親フォルダのもの）で照合する。
    規則の組ごとに一時フォルダの r<番号>/ の下へ .gitignore だけを写し、1 回の git check-ignore で全部を問い合わせる。
    大文字・小文字の扱いは、一時リポではなく対象リポジトリで有効な core.ignoreCase に合わせる。"""
    if not targets:
        return
    ignore_case = read_ignore_case(wt, env)
    per_commit = {}   # commit → {フォルダ: .gitignore の中身}（規則のあるフォルダだけ）
    for ch in targets:
        dirs = dirs_of(ch.path)
        if dirs is None:
            ch.why_unknown = "パスの形を照合に使えない（空・.・..・.git・改行を含むフォルダ）"
            continue
        if ignore_case is None:
            ch.why_unknown = "対象リポジトリの core.ignoreCase を読めない"
            continue
        rules = per_commit.setdefault(ch.sha, {})
        for d in dirs:
            body, why = trees.gitignore(ch.sha, d)
            if body is None:
                ch.why_unknown = why
                break
            if body:
                rules[d] = body
    rulesets, which = {}, {}
    for sha, rules in per_commit.items():
        which[sha] = rulesets.setdefault(tuple(sorted(rules.items())), len(rulesets))
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
                     "-c", "core.ignoreCase=" + ignore_case, "check-ignore", "--no-index", "-v", "-n", "-z", "--stdin"],
                    b"\0".join(qs) + b"\0", genv)
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
                place = show(src.split(b"/", 1)[-1].decode("utf-8", "surrogateescape")) + " " + line.decode("ascii", "replace") + " 行目"
                ch.ignore = ("x", pattern.decode("utf-8", "surrogateescape"), place)
    except OSError:
        for ch in targets:
            if ch.ignore is None:
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
    """名前による要確認の理由。パスを / で分けた各部分（前後の空白を除き NFC にそろえる。前後に空白を足した名前もすり抜けさせない）の、
    最後の名前と途中のフォルダ名で判定する（名前の途中に改行などがあっても途切れない。大文字・小文字は区別しない。内容は開かない）。"""
    parts = [unicodedata.normalize("NFC", p).strip() for p in name.split("/")]
    base = parts[-1]
    out = []
    if base.casefold().endswith(SECRET_EXT) or SECRET_NAME.fullmatch(base):
        out.append(("秘密らしい名前", "秘密らしい名前"))
    if RUNSH.fullmatch(base):
        out.append(("run-*.sh", "名前が run-*.sh（手書きのランチャ・一時スクリプトの可能性）"))
    if any(p.casefold() == "logs" for p in parts[:-1]):
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
    got = read_changes(wt, start, env)
    if got is None:
        return 1
    commits, head = got
    changes = [ch for _, _, cs in commits for ch in cs]
    targets = [ch for ch in changes if not ch.deleted]
    # 木を読む (commit, フォルダ): 規則の照合には各変更の commit の親フォルダ、残っているかの確認には HEAD の親フォルダ
    ignores, dirs = set(), set()
    for ch in targets:
        ds = dirs_of(ch.path) or []
        ignores.update((ch.sha, d) for d in ds)
        if ch.new and head:
            dirs.update((head, d) for d in ds)
    trees = Trees(wt, dirs, ignores, env)
    # 新しく持ち込んだパスが HEAD に無いかは HEAD の木で確かめる（別の枝で同じ名前を足して消しても、HEAD に残っていれば印を付けない）
    for ch in targets:
        ch.gone = bool(ch.new and head) and trees.exists(head, ch.path) is False
    oids = sorted({ch.oid for ch in targets if ch.mode != GITLINK})
    sizes = blob_sizes(wt, oids, env)
    check_ignores(wt, targets, trees, tmp_parent, env)

    bad, maybe, unknown = [], [], []
    for ch in changes:
        if ch.deleted:
            continue   # 削除だけの変更は混入に数えない
        where = "commit " + ch.sha[:12] + " の " + ch.status + " " + show(ch.name)
        gone = "。HEAD には無い（途中で消したが、公開履歴に残る）" if ch.gone else ""
        size_r, why = [], []
        if ch.mode != GITLINK:
            if ch.oid not in sizes:
                why.append(("大きさが分からない", "大きさを確かめられない"))
            elif sizes[ch.oid] >= HUGE:
                size_r = [("巨大ファイル", "巨大ファイル（変更後 " + str(sizes[ch.oid]) + " バイト）")]
        if ch.ignore is None:
            why.append(("規則と照合できない", ch.why_unknown or "その commit の時点の .gitignore と照合できなかった"))
        if why:
            # 判定できなかった理由は、変更 1 件につき 1 回だけ数える（理由別の件数は理由ごとに 1）
            unknown.append(([k for k, _ in why], where + "（" + "・".join(t for _, t in why) + "）"))
        state = ch.ignore[0] if ch.ignore else None
        rule = "その commit の .gitignore の規則 " + show(ch.ignore[1]) + "（" + ch.ignore[2] + "）で無視される" if state == "x" else ""
        # .gitignore の例外（! の規則）で明示的に許可された名前は、名前では候補にしない
        names = [] if state == "!" else name_reasons(ch.name)
        if ch.new and state == "x":
            reasons = [("規則で無視", rule)] + names + size_r
            bad.append(([k for k, _ in reasons], where + "（" + "・".join(t for _, t in reasons) + gone + "）"))
            continue
        if not ch.new:
            # それより前から追跡しているファイルの変更は、規則に反する混入には数えない。ただし無視されるファイル・秘密らしい名前の
            # ファイルの変更は、新しい中身が履歴に入るので要確認候補にする（run-*.sh・logs/ の名前だけでは候補にしない）
            names = [("秘密らしい名前", "秘密らしい名前のファイルを変更した") for k, _ in names if k == "秘密らしい名前"]
            if state == "x":
                names.insert(0, ("無視されるファイルの変更", rule + "ファイルを変更した（それより前の commit から追跡している）"))
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
    out.append("- 混入の点検（ランチャが、上の一覧と同じ変更・変更後の大きさ・親フォルダの一覧・その commit の時点の .gitignore・HEAD の木だけを見た。"
               "内容・作者は見ていない。"
               "点検は全件で行い、ここには分類ごとの件数・理由別の件数・代表箇所（各 " + str(MAX_SHOW) + " 件まで）を載せる）: commit "
               + str(len(commits)) + " 件・変更 " + str(len(changes)) + " 件（うち新しく持ち込んだパス " + str(n_new) + " 件）を点検した。")
    out.append("")
    out += section("規則に反する混入（その commit の時点の .gitignore で無視されるパスを、新しく持ち込んだ）", bad,
                   "1 件ずつ指摘に書く:")
    out.append("")
    out += section("要確認候補（規則に反する新しい持ち込みではない。名前・大きさ、または前から追跡している無視対象・秘密らしい名前のファイルの変更で選んだ）", maybe,
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
