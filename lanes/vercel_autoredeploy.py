"""lanes_monitor.py から呼ぶ（lanes-monitor.sh --allow-redeploy のときだけ）。設定した Vercel プロジェクトの
Preview デプロイが「Git information retrieval failed」で Error になったものを 1 回だけ自動で再デプロイする。

- 対象は設定キー LANES_VERCEL_PROJECT（プロジェクト名）と LANES_VERCEL_SCOPE（チームのスコープ。空なら --scope を付けない）。
  LANES_VERCEL_PROJECT が空なら何もせず「無効」と 1 行出す。
- Production（target=production）には絶対に再デプロイしない（ls と inspect の両方で確認）。
- それ以外の理由の Error は再デプロイせず WAKE（親を起こす合図）で知らせる（1 デプロイ 1 回）。
- 同じデプロイを二重に再デプロイしないよう ${LANES_RUNS_ROOT:-~/dev/_runs}/.vercel-autoredeploy.json に記録する。
- 同じコミットの後発デプロイが Ready/Building なら（手で直した等）何もしない。
- 再デプロイの結果は次回以降の監視で 1 行出す（Error ならもう一度 WAKE。再々デプロイはしない）。
戻り値: (出力行のリスト, WAKE 理由のリスト)。失敗しても例外は外に出さない。
"""
import datetime, fcntl, json, os, re, subprocess, threading, time

SCOPE = os.environ.get("LANES_VERCEL_SCOPE", "").strip()
PROJECT = os.environ.get("LANES_VERCEL_PROJECT", "").strip()
RUNS = os.path.abspath(os.path.expanduser(os.environ.get("LANES_RUNS_ROOT") or "~/dev/_runs"))
STATE = os.path.join(RUNS, ".vercel-autoredeploy.json")
LOOKBACK_SEC = 3 * 3600
GIT_FAIL = "Git information retrieval failed"
_THREAD_LOCK = threading.Lock()


def _hm(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%H:%M")


def _norm_url(u):
    if not u or not isinstance(u, str):
        return ""
    return re.sub(r"^https?://", "", u.strip()).rstrip("/")


def _vc(args, timeout=40):
    env = dict(os.environ)
    cwd = os.environ.get("LANES_SCRATCH") or os.environ.get("TMPDIR") or "/tmp"
    if not os.path.isdir(cwd):
        cwd = "/tmp"
    scope = ["--scope", SCOPE] if SCOPE else []
    r = subprocess.run(["vercel", *args, *scope], capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd)
    return r.returncode, r.stdout, r.stderr


def _list():
    rc, out, err = _vc(["ls", PROJECT, "--format", "json"])
    if rc != 0:
        raise RuntimeError("vercel ls 失敗")
    return json.loads(out).get("deployments", [])


def _inspect(url):
    rc, out, err = _vc(["inspect", url])
    if rc != 0:
        raise RuntimeError(f"vercel inspect 失敗 (exit {rc})")
    txt = re.sub(r"\x1b\[[0-9;]*m", "", out + "\n" + err)
    g = lambda k: (re.search(rf"^\s*{k}\s+(.+)$", txt, re.M) or [None, ""])[1].strip()
    return {"target": g("target"), "status": g("status"), "reason": g("reason")}


def _desc(d):
    m = d.get("meta") or {}
    pr = f" PR#{m['githubPrId']}" if m.get("githubPrId") else ""
    return f"{m.get('githubCommitRef', '?')} {(m.get('githubCommitSha') or '')[:7]}{pr}"


def _extract_redeploy_url(text, src_url):
    # Vercel の Preview URL は「<プロジェクト名>-<識別子>-<スコープ>.vercel.app」の形
    if PROJECT:
        tail = (r"-" + re.escape(SCOPE)) if SCOPE else ""
        m = re.search(r"https?://(" + re.escape(PROJECT) + r"-[a-z0-9-]+" + tail + r"\.vercel\.app)", text)
        if m:
            return m.group(1)
    cands = re.findall(r"https?://([A-Za-z0-9._-]+\.vercel\.app)", text)
    if not cands:
        cands = re.findall(r"\b([A-Za-z0-9._-]+\.vercel\.app)\b", text)
    src_norm = _norm_url(src_url)
    for c in cands:
        if _norm_url(c) != src_norm:
            return c
    return cands[0] if cands else None


def _load_state(state_path):
    try:
        with open(state_path, encoding="utf-8") as f:
            st = json.load(f)
            return st if isinstance(st, dict) else {}
    except Exception:
        return {}


def _save_state(state_path, st, rec, now_ms):
    # 古い記録は 2 日で捨てる
    st["handled"] = {
        k: v for k, v in rec.items()
        if isinstance(v, dict) and now_ms - v.get("at", now_ms) < 2 * 86400 * 1000
    }
    parent = os.path.dirname(os.path.abspath(state_path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = f"{state_path}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, state_path)


def run():
    lines, wakes = [], []
    if not PROJECT:
        return ["Vercel 自動再デプロイ: 無効（LANES_VERCEL_PROJECT が空）"], []
    state_path = os.path.expanduser(STATE)
    if not _THREAD_LOCK.acquire(blocking=False):
        return [], []
    lock_f = None
    try:
        parent = os.path.dirname(os.path.abspath(state_path))
        if parent:
            os.makedirs(parent, exist_ok=True)
        lock_f = open(state_path + ".lock", "a+", encoding="utf-8")
        try:
            fcntl.flock(lock_f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return [], []

        st = _load_state(state_path)
        rec = st.setdefault("handled", {})   # デプロイ url -> {action, new, at, result, ...}
        if not isinstance(rec, dict):
            rec = {}
            st["handled"] = rec

        now_ms = time.time() * 1000
        # 既存の再デプロイ先 URL も試行履歴キーへ補完し、再々デプロイを防ぐ
        backfilled = False
        for src, r in list(rec.items()):
            if not isinstance(r, dict):
                continue
            new_u = r.get("new")
            if new_u and new_u not in rec:
                rec[new_u] = {"action": "redeployed-target", "at": r.get("at", now_ms), "desc": r.get("desc", ""), "from": src}
                backfilled = True
        if backfilled:
            _save_state(state_path, st, rec, now_ms)

        try:
            deps = _list()
        except Exception as e:
            return [f"Vercel 自動再デプロイ: 確認できず（{type(e).__name__}）"], []

        by_url = {}
        for d in deps:
            u = d.get("url")
            if u:
                by_url[u] = d
                by_url[_norm_url(u)] = d

        # 1) 以前に再デプロイしたものの結果
        for src, r in list(rec.items()):
            if not isinstance(r, dict) or r.get("action") != "redeploy" or r.get("result"):
                continue
            new_u = r.get("new")
            nd = by_url.get(new_u) or by_url.get(_norm_url(new_u))
            state = nd.get("state") if nd else None
            if state == "READY":
                r["result"] = "READY"
                _save_state(state_path, st, rec, now_ms)
                lines.append(f"Vercel 自動再デプロイ 結果: {r['desc']} → Ready（{new_u}）")
            elif state in ("ERROR", "CANCELED"):
                r["result"] = state
                if new_u and new_u not in rec:
                    rec[new_u] = {"action": "redeployed-target", "at": r.get("at", now_ms), "desc": r.get("desc", ""), "from": src}
                _save_state(state_path, st, rec, now_ms)
                lines.append(f"Vercel 自動再デプロイ 結果: {r['desc']} → {state}（{new_u}）。再々デプロイはしない")
                wakes.append("Vercel 再デプロイも失敗")
            elif now_ms - r.get("at", now_ms) > 30 * 60 * 1000:
                r["result"] = "UNKNOWN"
                _save_state(state_path, st, rec, now_ms)
                lines.append(f"Vercel 自動再デプロイ 結果: {r['desc']} → 30 分たっても未確定（{new_u}）")
                wakes.append("Vercel 再デプロイ未確定")

        # 2) 新しい Error
        for d in deps:
            url = d.get("url")
            if not url or d.get("state") != "ERROR":
                continue
            norm_u = _norm_url(url)
            handled_norms = {_norm_url(k) for k in rec.keys()} | {
                _norm_url(v.get("new")) for v in rec.values() if isinstance(v, dict) and v.get("new")
            }
            if url in rec or norm_u in handled_norms:
                if url not in rec:
                    rec[url] = {"action": "redeployed-target", "at": now_ms, "desc": _desc(d)}
                    _save_state(state_path, st, rec, now_ms)
                continue
            if now_ms - (d.get("createdAt") or 0) > LOOKBACK_SEC * 1000:
                continue
            if d.get("target") == "production":
                rec[url] = {"action": "skip-production", "at": now_ms, "desc": _desc(d)}
                _save_state(state_path, st, rec, now_ms)
                lines.append(f"Vercel Production エラー {_hm(d['createdAt'])} {_desc(d)}（自動再デプロイはしない）")
                wakes.append("Vercel Production エラー")
                continue
            sha = (d.get("meta") or {}).get("githubCommitSha")
            later_ok = [x for x in deps if (x.get("meta") or {}).get("githubCommitSha") == sha and sha
                        and (x.get("createdAt") or 0) > d.get("createdAt", 0) and x.get("state") in ("READY", "BUILDING", "QUEUED", "INITIALIZING")]
            if later_ok:
                rec[url] = {"action": "superseded", "at": now_ms, "desc": _desc(d), "by": later_ok[0].get("url")}
                _save_state(state_path, st, rec, now_ms)
                continue
            try:
                info = _inspect(url)
            except Exception as e:
                lines.append(f"Vercel 自動再デプロイ: 照会失敗 {_desc(d)}（{type(e).__name__}）")
                continue
            if info["target"].lower() != "preview":   # inspect でも preview と確認できなければ触らない
                rec[url] = {"action": "skip-target", "at": now_ms, "desc": _desc(d), "target": info["target"]}
                _save_state(state_path, st, rec, now_ms)
                lines.append(f"Vercel エラー {_hm(d['createdAt'])} {_desc(d)} target={info['target'] or '?'}（自動再デプロイはしない）")
                wakes.append("Vercel エラー（Preview 以外）")
                continue
            if GIT_FAIL in info["reason"]:
                desc = _desc(d)
                # 実行予定を先に保存し、途中失敗や重複起動でも同じ対象へ再実行しない
                rec[url] = {"action": "redeploy-pending", "at": now_ms, "desc": desc, "sha": sha}
                _save_state(state_path, st, rec, now_ms)
                try:
                    rc, out, err = _vc(["redeploy", url, "--no-wait"], timeout=60)
                except Exception:
                    rc, out, err = 1, "", ""
                new = _extract_redeploy_url((out or "") + "\n" + (err or ""), url)
                if rc == 0 and new:
                    rec[url] = {"action": "redeploy", "at": now_ms, "desc": desc, "new": new, "sha": sha}
                    rec[new] = {"action": "redeployed-target", "at": now_ms, "desc": desc, "from": url, "sha": sha}
                    norm_new = _norm_url(new)
                    if norm_new and norm_new not in rec:
                        rec[norm_new] = {"action": "redeployed-target", "at": now_ms, "desc": desc, "from": url, "sha": sha}
                    _save_state(state_path, st, rec, now_ms)
                    lines.append(f"Vercel 自動再デプロイ: {_hm(d['createdAt'])} {desc} Git information retrieval failed → {new}")
                else:
                    rec[url] = {"action": "redeploy-failed", "at": now_ms, "desc": desc, "sha": sha}
                    if new:
                        rec[new] = {"action": "redeployed-target", "at": now_ms, "desc": desc, "from": url, "sha": sha}
                    _save_state(state_path, st, rec, now_ms)
                    lines.append(f"Vercel 自動再デプロイ 失敗: {desc}（exit {rc}）")
                    wakes.append("Vercel 自動再デプロイ失敗")
            else:
                rec[url] = {"action": "wake", "at": now_ms, "desc": _desc(d), "reason": info["reason"][:200]}
                _save_state(state_path, st, rec, now_ms)
                lines.append(f"Vercel Preview エラー {_hm(d['createdAt'])} {_desc(d)}: {info['reason'][:120] or '理由なし（ビルドエラーの可能性）'}（再デプロイせず）")
                wakes.append("Vercel Preview エラー")

        _save_state(state_path, st, rec, now_ms)
        return lines, wakes
    finally:
        if lock_f is not None:
            try:
                fcntl.flock(lock_f.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            lock_f.close()
        _THREAD_LOCK.release()
