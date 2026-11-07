"""lanes-monitor.sh の本体。既定は外部サービスに書き込まない（既読状態はローカル保存）。標準ライブラリだけ。"""
import json, os, re, shutil, subprocess, sys, time, datetime, fcntl, tempfile, itertools

RUNS = os.path.abspath(os.path.expanduser(os.environ.get("LANES_RUNS_ROOT", "~/dev/_runs")))
SCRATCH = os.path.abspath(os.path.expanduser(os.environ.get("LANES_SCRATCH_ROOT", os.path.join(RUNS, "_scratch"))))
STATE = os.path.join(RUNS, ".lanes-monitor-state.json")
HIST = os.path.join(RUNS, "lanes-monitor-now.txt")
STATUS = os.environ.get("LANES_STATUS", os.path.join(os.path.dirname(__file__), "lanes-status.sh"))


def check_interval_minutes():
    """定期の確認の間隔（分）。設定キー LANES_CHECK_INTERVAL_MIN（既定 10）。数字だけで 1 以上のときだけ使う（lanes.env でも確かめる）"""
    raw = os.environ.get("LANES_CHECK_INTERVAL_MIN", "10")
    return int(raw) if raw.isdigit() and 0 < int(raw) <= 1440 else 10
NOW = time.time()
RECENT_ON_FIRST_RUN = 90 * 60        # 初回（状態なし）は直近 90 分の DONE を新着扱い
REMIND_PROBLEM_SEC = 30 * 60         # 停滞・死亡・失敗・状態不明は初回と 30 分ごとに起こす
MAX_LIST = 12

def jst(ts=None):
    # 実行環境の時間帯で、時間帯の名前も付けて書く（公開キットなので JST に固定しない）
    return datetime.datetime.fromtimestamp(ts or NOW).astimezone().strftime("%Y-%m-%d %H:%M %Z")

def hm(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M")

def kv(path):
    d = {}
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.rstrip("\n")
            if line.startswith("VERDICT:"):
                d["VERDICT"] = line
            elif line.startswith("EXIT:"):
                d["EXIT"] = line[5:].strip()
            elif "=" in line:
                k, v = line.split("=", 1); d[k.strip()] = v.strip()
    except OSError:
        pass
    return d

def is_worktree(p):
    return os.path.exists(os.path.join(p, ".git"))

def lane_status(wt, label):
    try:
        out = subprocess.run(["zsh", "-f", STATUS, wt, label], capture_output=True, text=True, timeout=20).stdout
    except subprocess.TimeoutExpired:
        return "TIMEOUT", ""
    except OSError:
        return "?", "状態確認を実行できない"
    line = out.strip().splitlines()[0] if out.strip() else ""
    m = re.match(r"^(RUNNING|STALLED|DONE|FAILED|DEAD|NONE)\s+\S+\s+(.*)$", line)
    return (m.group(1), m.group(2)) if m else ("?", line[:160])

def short_detail(detail):
    # 「経過 40分  最終出力 3秒前」だけ残す
    el = re.search(r"経過 (\S+)", detail); lo = re.search(r"最終出力 (\S+)", detail)
    return " ".join(x for x in [el and "経過" + el.group(1), lo and "最終出力" + lo.group(1)] if x)

_GH_READY = None

def gh_ready():
    # gh（GitHub の CLI）が無い・未ログインなら PR 照会を黙って飛ばす。結果は 1 回の実行の中で使い回す。
    global _GH_READY
    if _GH_READY is None:
        _GH_READY = False
        if shutil.which("gh"):
            try:
                r = subprocess.run(["gh", "auth", "status"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                _GH_READY = r.returncode == 0
            except Exception:
                _GH_READY = False
    return _GH_READY

def open_prs(repo):
    try:
        r = subprocess.run(["gh", "pr", "list", "--repo", repo, "--state", "open", "--json", "number,title,headRefName,isDraft", "--limit", "30"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return json.loads(r.stdout or "[]")
    except Exception:
        return None

def mtime(path):
    try:
        return os.stat(path, follow_symlinks=False).st_mtime if not os.path.islink(path) else 0
    except OSError:
        return 0


def discover_worktrees():
    # 作業場所は深さ・案件名に依存しない。保管領域・隠し領域・リンク先は巡回しない。
    # QA 専用 checkout だけは scratch 内も許可する。一時 DB や保管用の作業場所は拾わない。
    def scan_entries(path):
        try:
            with os.scandir(path) as entries:
                return list(entries)
        except OSError:
            # 後片付けと重なって消えた領域や読めない領域で、他レーンの探索まで止めない。
            return []

    roots = [RUNS]
    if not os.path.islink(SCRATCH) and os.path.isdir(SCRATCH):
        for project in scan_entries(SCRATCH):
            if project.name.startswith(("_", ".")) or not project.is_dir(follow_symlinks=False):
                continue
            for candidate in scan_entries(project.path):
                if (re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*-checkout", candidate.name)
                        and candidate.is_dir(follow_symlinks=False)
                        and os.path.isfile(os.path.join(candidate.path, ".git"))
                        and not os.path.islink(os.path.join(candidate.path, ".git"))):
                    roots.append(candidate.path)
    seen = set()
    for directory, dirs, _ in itertools.chain.from_iterable(os.walk(root, followlinks=False) for root in roots):
        if directory in seen:
            dirs[:] = []
            continue
        seen.add(directory)
        logdir = os.path.join(directory, "logs")
        labels = []
        if not os.path.islink(logdir):
            try:
                with os.scandir(logdir) as entries:
                    for entry in entries:
                        match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9._-]*)\.pid", entry.name)
                        if match and ".prev-" not in entry.name and entry.is_file(follow_symlinks=False):
                            labels.append(match[1])
            except OSError:
                pass
        if labels:
            yield directory, sorted(labels)
        if is_worktree(directory):
            dirs[:] = []
        else:
            dirs[:] = sorted(name for name in dirs if not name.startswith(("_", ".", "merged-cleanup-"))
                             and name not in ("logs", "node_modules")
                             and not os.path.islink(os.path.join(directory, name)))


def github_repo(wt):
    # 接続先の本文は表示しない。GitHub の通常形式だけからリポジトリ名を取り出す。
    try:
        result = subprocess.run(["git", "-C", wt, "config", "--get", "remote.origin.url"],
                                capture_output=True, text=True, timeout=5)
        if result.returncode:
            return None
        match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                             r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?", result.stdout.strip())
        return match[1] if match else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def watch_summary():
    # 定期の確認（既定 10 分ごと。LANES_CHECK_INTERVAL_MIN）は既読記録を書き換えず、PR 照会や外部書き込みも行わない。
    # 「直近 N 分に終わったレーン」の N はこの間隔に合わせる（前回の確認の後に終わって次工程を待つものを拾う）
    interval_min = check_interval_minutes()
    now = time.time()
    active, stalled, recent, problems = 0, 0, [], []
    for wt, labels in discover_worktrees():
        for label in labels:
            pidf, donef = (os.path.join(wt, "logs", label + suffix) for suffix in (".pid", ".done"))
            pm, dm = mtime(pidf), mtime(donef)
            if dm and dm >= pm:
                data = kv(donef)
                if 0 <= now - dm <= interval_min * 60 and data.get("EXIT") == "0" and data.get("VERDICT") != "VERDICT: NONE":
                    recent.append((dm, os.path.relpath(wt, RUNS) + "/" + label))
                elif 0 <= now - dm <= interval_min * 60:
                    problems.append("FAILED " + os.path.relpath(wt, RUNS) + "/" + label)
            elif is_worktree(wt):
                status, _ = lane_status(wt, label)
                if status in ("RUNNING", "STALLED"):
                    active += 1
                    stalled += status == "STALLED"
                if status in ("STALLED", "FAILED", "DEAD", "TIMEOUT", "?"):
                    problems.append(status + " " + os.path.relpath(wt, RUNS) + "/" + label)
    print(f"LANES RUNNING {active}（うち STALLED {stalled}）")
    print(f"直近{interval_min}分 DONE（次工程待ち）: {len(recent)} 件")
    for stamp, name in sorted(recent):
        print(f"- DONE {name} {hm(stamp)}")
    print(f"要対応: {len(problems)} 件")
    for problem in problems:
        print("- " + problem)


def monitor_once():
    state = {}
    if os.environ.get("LM_RESET") != "1":
        try:
            state = json.load(open(STATE, encoding="utf-8"))
        except Exception:
            state = {}
    first_run = not state
    seen = state.get("seen_done", {})
    problems_prev = state.get("problems", {})
    prs_prev = state.get("prs", {})

    running, problems, new_done = [], [], []
    problems_now = {}
    projects = {}
    for d, labels in discover_worktrees():
        relative = os.path.relpath(d, RUNS)
        proj = relative.split(os.sep)[0]
        repo = github_repo(d)
        if repo:
            projects[repo] = repo.split("/")[-1]
        logdir = os.path.join(d, "logs")
        for lb in labels:
            pidf, donef = os.path.join(logdir, lb + ".pid"), os.path.join(logdir, lb + ".done")
            pm = mtime(pidf)
            dm = mtime(donef)
            key = f"{relative}/{lb}"
            if dm and dm >= pm:
                if NOW - dm > 24 * 3600:
                    continue
                prev = seen.get(key)
                if prev is None and first_run:
                    is_new = NOW - dm <= RECENT_ON_FIRST_RUN
                else:
                    is_new = prev is None or dm > prev
                seen[key] = dm
                if is_new:
                    dk = kv(donef)
                    ex = dk.get("EXIT", "?")
                    st = "DONE" if ex == "0" and dk.get("VERDICT") != "VERDICT: NONE" else "FAILED"
                    extra = " ".join(x for x in [dk.get("VERDICT", ""), dk.get("note", "")] if x)
                    lane_tag = " [gemini]" if kv(pidf).get("lane", "").startswith("gemini") else ""
                    new_done.append((dm, f"{st} {proj} {lb}{lane_tag} {hm(dm)} EXIT:{ex} {extra}".strip()))
                continue
            if not pm:
                continue
            pk = kv(pidf)
            wt = d
            if not is_worktree(wt):
                continue
            st, detail = lane_status(wt, lb)
            lane = pk.get("lane", "?")
            if st == "RUNNING":
                running.append((lane, lb, short_detail(detail)))
            elif st in ("STALLED", "FAILED", "DEAD", "TIMEOUT", "?"):
                first = problems_prev.get(key, {}).get("first", NOW)
                last_wake = problems_prev.get(key, {}).get("wake", 0)
                wake = (problems_prev.get(key, {}).get("status") != st) or (NOW - last_wake >= REMIND_PROBLEM_SEC)
                problems_now[key] = {"first": first, "wake": NOW if wake else last_wake, "status": st}
                problems.append((wake, f"{st} {proj} {lb} {short_detail(detail) or detail[:120]}（初検知 {hm(first)}）"))

    # 24h より古い既読は捨てる
    seen = {k: v for k, v in seen.items() if NOW - v <= 26 * 3600}

    # PR の状態は、取得できなかった回（gh が無い・未ログイン・照会の失敗）は前回のものをそのまま残す。
    # 空で上書きすると比べる元が消え、その間にマージされた PR を復旧後に通知できなくなるため。
    # gh が使える回は、いま見つかったリポの分だけ残す（レーンの無くなったリポの古い状態を持ち続けない。従来どおり）
    ready = gh_ready()
    prs_now = {r: v for r, v in prs_prev.items() if r in projects} if ready else dict(prs_prev)
    pr_lines, pr_changes = [], []
    open_count = 0
    for repo, proj in (sorted(projects.items()) if ready else []):
        prs = open_prs(repo)
        if prs is None:
            pr_lines.append(f"{proj}: gh pr list 失敗")
            continue
        nums = sorted(p["number"] for p in prs)
        prs_now[repo] = nums
        open_count += len(nums)
        before = prs_prev.get(repo)
        if before is not None:
            opened = [n for n in nums if n not in before]; closed = [n for n in before if n not in nums]
            if opened: pr_changes.append(f"{proj} PR 新規 #" + " #".join(map(str, opened)))
            if closed: pr_changes.append(f"{proj} PR クローズ/マージ #" + " #".join(map(str, closed)))
        for p in prs[:MAX_LIST]:
            pr_lines.append(f"{proj} #{p['number']} {p['headRefName']}{' (draft)' if p.get('isDraft') else ''} {p['title'][:60]}")

    # Vercel Preview の「Git information retrieval failed」を 1 回だけ自動再デプロイ（vercel_autoredeploy.py。LANES_VERCEL_PROJECT が空なら無効）
    vercel_lines, vercel_wakes = [], []
    if os.environ.get("LM_ALLOW_REDEPLOY") == "1" and os.environ.get("LM_NO_VERCEL") != "1":
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import vercel_autoredeploy
            vercel_lines, vercel_wakes = vercel_autoredeploy.run()
        except Exception as e:
            vercel_lines = [f"Vercel 自動再デプロイ: 実行エラー（{type(e).__name__}）"]

    was_running = state.get("running_count", 0)
    reasons = []
    if new_done: reasons.append(f"新規終了 {len(new_done)}")
    wake_problems = [t for w, t in problems if w]
    if wake_problems: reasons.append(f"要対応 {len(wake_problems)}")
    if pr_changes: reasons.append("PR 変化")
    if was_running and not running: reasons.append("全レーン停止（稼働 0）")
    for w in dict.fromkeys(vercel_wakes): reasons.append(w)

    # .pid の lane= で数える
    claude = sum(1 for l, _, _ in running if l in ("claude", "claude-review"))
    codex_review = sum(1 for l, _, _ in running if l == "codex-review")
    gemini = sum(1 for l, _, _ in running if l.startswith("gemini"))   # Gemini の実装レーン（run-gemini.sh）
    summary = f"RUNNING {len(running)}（Claude {claude} / Gemini {gemini} / Codex レビュー {codex_review} / 他 {len(running) - claude - gemini - codex_review}）"
    out = [("WAKE: " + " / ".join(reasons)) if reasons else "QUIET", f"{jst()} {summary} / open PR {open_count}"]
    if new_done:
        out.append("## 新規終了（次工程を親が即起動）")
        out += ["- " + t for _, t in sorted(new_done)]
    if problems:
        out.append("## 要対応")
        out += ["- " + t for _, t in problems]
    if pr_changes:
        out.append("## PR 変化"); out += ["- " + t for t in pr_changes]
    if vercel_lines:
        out.append("## Vercel"); out += ["- " + t for t in vercel_lines[:MAX_LIST]]
    if running:
        out.append("## 稼働中")
        out += [f"- {lb}{' [gemini]' if lane.startswith('gemini') else ''} {d}" for lane, lb, d in sorted(running, key=lambda x: x[1])[:MAX_LIST]]
        if len(running) > MAX_LIST: out.append(f"- ほか {len(running) - MAX_LIST} 本")
    if pr_lines:
        out.append("## open PR"); out += ["- " + t for t in pr_lines[:MAX_LIST]]
    print("\n".join(out))

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=RUNS,
                                         prefix=".lanes-monitor-state.", delete=False) as stream:
            temporary = stream.name
            json.dump({"seen_done": seen, "problems": problems_now, "prs": prs_now, "running_count": len(running), "updated": jst()},
                      stream, ensure_ascii=False)
        os.replace(temporary, STATE)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    if os.environ.get("LM_APPEND") == "1":
        with open(HIST, "a", encoding="utf-8") as h:
            h.write(f"{jst()} [monitor] {out[0]} | {summary}" + (" | " + "; ".join(t for _, t in sorted(new_done)) if new_done else "") + (" | " + "; ".join(vercel_lines) if vercel_lines else "") + "\n")
    sys.exit(0)  # 判定は 1 行目（WAKE/QUIET）。Shell ツールが失敗扱いしないよう常に 0


def main():
    # 常駐監視と単発確認が重なっても、既読判定から保存までを一続きで処理する。
    # ロックを削除すると別の実体を同時取得できるため、終了後もファイルは残す。
    os.makedirs(RUNS, exist_ok=True)
    with open(STATE + ".lock", "a") as lock:
        fcntl.lockf(lock, fcntl.LOCK_EX)
        global NOW
        NOW = time.time()
        monitor_once()


if __name__ == "__main__":
    main()
