import json, re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

SHOT = "/opt/cctv/storage/previews/browser_shot.png"
M3U8 = r'https?://[^\s"\'\\]+\.m3u8[^\s"\'\\]*'
RTSP = r'rtsp://[^\s"\'\\]+'
STATUS = r'https?://[^\s"\'\\]+/recording_status\.json[^\s"\'\\]*'
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

class D:
    pw = None; browser = None; ctx = None; page = None; cands = []; url = ""

def add(u):
    u = u.replace("&amp;", "&")
    if u not in D.cands: D.cands.append(u)

def attach(page):
    def on_req(req):
        u = req.url
        if (".m3u8" in u) or u.startswith("rtsp://") or (".mpd" in u): add(u)
    def on_resp(resp):
        try:
            ct = resp.headers.get("content-type", "")
            if ("json" in ct) or ("javascript" in ct):
                b = resp.text()
                for m in re.findall(M3U8, b): add(m)
                for m in re.findall(RTSP, b): add(m)
                for m in re.findall(STATUS, b): add(m.replace("recording_status.json", "index.m3u8"))
        except Exception:
            pass
    page.on("request", on_req); page.on("response", on_resp)

def ensure_pw():
    if D.pw is None: D.pw = sync_playwright().start()
    return D.pw

def close_all():
    for attr in ("page", "ctx", "browser"):
        obj = getattr(D, attr)
        if obj is not None:
            try: obj.close()
            except Exception: pass
            setattr(D, attr, None)

def start(url, cookie):
    close_all(); D.cands = []; D.url = url
    pw = ensure_pw()
    D.browser = pw.chromium.launch(args=["--no-sandbox", "--disable-dev-shm-usage", "--ignore-certificate-errors"])
    D.ctx = D.browser.new_context(viewport={"width": 1280, "height": 800}, ignore_https_errors=True, user_agent=UA)
    if cookie:
        dom = urlparse(url).hostname or ""
        cookies = []
        for part in cookie.split(";"):
            if "=" in part:
                k, v = part.strip().split("=", 1)
                cookies.append({"name": k, "value": v, "domain": dom, "path": "/"})
        try: D.ctx.add_cookies(cookies)
        except Exception: pass
    D.page = D.ctx.new_page(); attach(D.page)
    try: D.page.goto(url, timeout=30000, wait_until="domcontentloaded")
    except Exception: pass
    D.page.wait_for_timeout(2500)
    D.page.screenshot(path=SHOT)
    return {"ok": True}

def action(act, x, y, text):
    if D.page is None: return {"ok": False, "error": "no session"}
    p = D.page
    try:
        if act == "click": p.mouse.click(int(x), int(y))
        elif act == "type": p.keyboard.type(text or "", delay=30)
        elif act == "enter": p.keyboard.press("Enter")
        elif act == "tab": p.keyboard.press("Tab")
        elif act == "back": p.go_back()
        elif act == "scroll": p.mouse.wheel(0, 400)
        p.wait_for_timeout(1800)
        p.screenshot(path=SHOT)
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def finish(extra_wait=3000):
    if D.page is None: return {"ok": False, "cands": []}
    try: D.page.wait_for_timeout(extra_wait)
    except Exception: pass
    cands = list(D.cands)[:12]
    close_all(); D.cands = []
    return {"ok": True, "cands": cands}

class H(BaseHTTPRequestHandler):
    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        ln = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(ln) or b"{}")
        cmd = body.get("cmd")
        try:
            if cmd == "start": self._send(start(body.get("url", ""), body.get("cookie", "")))
            elif cmd == "action": self._send(action(body.get("act"), body.get("x", 0), body.get("y", 0), body.get("text", "")))
            elif cmd == "finish": self._send(finish())
            elif cmd == "discover":
                start(body.get("url", ""), body.get("cookie", ""))
                D.page.wait_for_timeout(8000)
                self._send(finish(1000))
            elif cmd == "cancel":
                close_all(); D.cands = []; self._send({"ok": True})
            elif cmd == "status":
                self._send({"ok": True, "active": D.page is not None, "url": D.url})
            else: self._send({"ok": False, "error": "unknown cmd"})
        except Exception as e:
            self._send({"ok": False, "error": str(e)})
    def log_message(self, *a): pass

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8099), H).serve_forever()