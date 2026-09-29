import os, re, sqlite3, subprocess, time, signal, threading, asyncio
import select as pselect
import urllib.parse
from pathlib import Path

BASE_DIR = Path("/opt/cctv"); DB_PATH = BASE_DIR / "app" / "cctv.db"
ARCHIVE_DIR = BASE_DIR / "storage" / "archive"; LIVE_DIR = BASE_DIR / "storage" / "live"
LOG_DIR = BASE_DIR / "storage" / "logs"; PREVIEW_DIR = BASE_DIR / "storage" / "previews"
SMTP_PORT = 2525
procs = {}; configs = {}; live_logs = {}
detectors = {}; det_frames = {}; recorders = {}; rec_logs = {}
last_motion = {}; rec_started = {}; onvif_threads = {}
running = True; loops = 0

def handle_signal(signum, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, handle_signal); signal.signal(signal.SIGINT, handle_signal)

def mlog(cid, msg):
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_DIR / f"camera_{cid}.log", "ab") as f:
            f.write(f"[motion] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n".encode())
    except Exception:
        pass

def get_settings():
    s = {"motion_threshold": "0.06", "motion_grace": "45"}
    try:
        conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
        for row in conn.execute("SELECT key, value FROM setting").fetchall():
            if row["key"] in s and row["value"]:
                s[row["key"]] = row["value"]
        conn.close()
    except Exception:
        pass
    return s

def get_cameras():
    if not DB_PATH.exists(): return []
    try:
        conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
        try:
            rows = [dict(r) for r in conn.execute(
                "SELECT id, rtsp_url, recording_enabled, recording_mode, motion_zone, onvif_url FROM camera WHERE active=1")]
        except sqlite3.OperationalError:
            try:
                rows = [dict(r) for r in conn.execute(
                    "SELECT id, rtsp_url, recording_enabled, recording_mode, motion_zone FROM camera WHERE active=1")]
            except sqlite3.OperationalError:
                rows = [dict(r) for r in conn.execute(
                    "SELECT id, rtsp_url, recording_enabled, recording_mode FROM camera WHERE active=1")]
        conn.close()
        return rows
    except sqlite3.Error:
        return []

def rtsp_creds(url):
    p = urllib.parse.urlsplit(url)
    return (p.hostname or ""), (urllib.parse.unquote(p.username or "")), (urllib.parse.unquote(p.password or ""))

def onvif_params(cam):
    url = (cam.get("onvif_url") or "").strip()
    r_host, r_user, r_pw = rtsp_creds(cam["rtsp_url"])
    if not url:
        return r_host, 80, r_user, r_pw
    if "://" not in url:
        url = "http://" + url
    p = urllib.parse.urlsplit(url)
    host = p.hostname or r_host
    port = p.port or 80
    user = urllib.parse.unquote(p.username or "") or r_user
    pw = urllib.parse.unquote(p.password or "") or r_pw
    return host, port, user, pw

def camera_config(cam, settings):
    return (cam["rtsp_url"], bool(cam["recording_enabled"]),
            cam.get("recording_mode") or "continuous",
            cam.get("motion_zone") or "",
            settings.get("motion_threshold", "0.06"),
            cam.get("onvif_url") or "",
            settings.get("motion_grace", "45"))

def onvif_loop(cid, host, port, user, pw, evt):
    try:
        from onvif import ONVIFCamera
        cam = ONVIFCamera(host, port, user, pw)
        evts = cam.create_events_service()
        evts.CreatePullPointSubscription()
        mlog(cid, f"ONVIF subscription ok ({host}:{port})")
        while not evt.is_set():
            try:
                res = evts.PullMessages({"Timeout": "PT5S", "MessageLimit": 20})
            except Exception:
                time.sleep(3); continue
            for nm in getattr(res, "NotificationMessage", []) or []:
                topic = ""
                try:
                    t = nm.Topic
                    topic = t if isinstance(t, str) else str(getattr(t, "_value_1", t))
                except Exception:
                    pass
                if any(k in topic for k in ("Motion", "CellMotion", "Detector", "Alarm")):
                    last_motion[cid] = time.time()
    except Exception as e:
        mlog(cid, f"ONVIF error ({host}:{port}): {e}")
    onvif_threads.pop(cid, None)

def ensure_onvif(cid, cam):
    t = onvif_threads.get(cid)
    if t and t[0].is_alive(): return
    host, port, user, pw = onvif_params(cam)
    if not host: return
    evt = threading.Event()
    th = threading.Thread(target=onvif_loop, args=(cid, host, port, user, pw, evt), daemon=True)
    onvif_threads[cid] = (th, evt)
    th.start()

def stop_onvif(cid):
    t = onvif_threads.pop(cid, None)
    if t:
        t[1].set()

def smtp_server_thread():
    try:
        from aiosmtpd.controller import Controller
        class H:
            async def handle_DATA(self, server, session, envelope):
                for addr in list(envelope.rcpt_tos or []) + [envelope.mail_from or ""]:
                    m = re.search(r"cam[_-]?(\d+)", addr or "")
                    if m:
                        last_motion[int(m.group(1))] = time.time()
                return "250 Message accepted for delivery"
        ctrl = Controller(H(), hostname="0.0.0.0", port=SMTP_PORT)
        ctrl.start()
        while running:
            time.sleep(1)
        ctrl.stop()
    except Exception as e:
        try:
            with open(LOG_DIR / "smtp.log", "ab") as f:
                f.write(f"[smtp] error: {e}\n".encode())
        except Exception:
            pass

def log_handle(cid):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    p = LOG_DIR / f"camera_{cid}.log"
    if p.exists() and p.stat().st_size > 5 * 1024 * 1024:
        p.unlink()
    return open(p, "ab", buffering=0)

def start_live(cam, with_segments):
    cid = cam["id"]
    live_dir = LIVE_DIR / f"camera_{cid}"; archive_dir = ARCHIVE_DIR / f"camera_{cid}"
    live_dir.mkdir(parents=True, exist_ok=True); archive_dir.mkdir(parents=True, exist_ok=True)
    lf = log_handle(cid); live_logs[cid] = lf
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning", "-rtsp_transport", "tcp", "-i", cam["rtsp_url"]]
    if with_segments:
        cmd += ["-map", "0:v", "-c:v", "copy", "-an",
                "-f", "segment", "-segment_time", "300", "-reset_timestamps", "1", "-strftime", "1",
                str(archive_dir / "%Y-%m-%d_%H-%M-%S.mp4")]
    cmd += ["-map", "0:v", "-c:v", "copy", "-an", "-f", "hls",
            "-hls_time", "6", "-hls_list_size", "6", "-hls_flags", "delete_segments",
            str(live_dir / "index.m3u8")]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=lf)

def stop_live(cid):
    proc = procs.pop(cid, None)
    if proc is not None:
        try:
            proc.terminate(); proc.wait(timeout=5)
        except Exception:
            try: proc.kill()
            except Exception: pass
    lf = live_logs.pop(cid, None)
    if lf is not None:
        try: lf.close()
        except Exception: pass

def zone_vf_prefix(zone):
    if not zone: return ""
    try:
        x1, y1, x2, y2 = [float(v) for v in zone.split(",")]
        w = max(0.05, x2 - x1); h = max(0.05, y2 - y1)
        return f"crop=iw*{w:.4f}:ih*{h:.4f}:iw*{x1:.4f}:ih*{y1:.4f},"
    except Exception:
        return ""

def start_detector(cam, cfg):
    rtsp, rec, mode, zone, thr, onvif_url, grace = cfg
    vf = zone_vf_prefix(zone) + f"select='gt(scene,{thr})'"
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "info",
           "-rtsp_transport", "tcp", "-i", rtsp,
           "-vf", vf, "-vsync", "0", "-f", "null", "-"]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            text=True, errors="ignore")

def detector_motion(cid):
    d = detectors.get(cid)
    if d is None or d.poll() is not None: return False
    if pselect.select([d.stderr], [], [], 0.15)[0]:
        line = d.stderr.readline()
        m = re.search(r"frame=\s*(\d+)", line or "")
        if m:
            n = int(m.group(1))
            if n > det_frames.get(cid, 0):
                det_frames[cid] = n
                return True
    return False

def stop_detector(cid):
    d = detectors.pop(cid, None)
    if d is not None:
        try:
            d.kill(); d.wait(timeout=3)
        except Exception:
            pass
    det_frames.pop(cid, None)

def start_recorder(cam):
    cid = cam["id"]
    out_dir = ARCHIVE_DIR / f"camera_{cid}"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{time.strftime('%Y-%m-%d_%H-%M-%S')}.mp4"
    lf = log_handle(cid); rec_logs[cid] = lf
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning",
           "-rtsp_transport", "tcp", "-i", cam["rtsp_url"],
           "-map", "0:v", "-c:v", "copy", "-an", "-movflags", "+faststart", str(out)]
    rec_started[cid] = time.time()
    mlog(cid, f"recorder start -> {out.name}")
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=lf)

def stop_recorder(cid, reason=""):
    r = recorders.pop(cid, None)
    if r is not None:
        try:
            r.terminate(); r.wait(timeout=5)
        except Exception:
            try: r.kill()
            except Exception: pass
        dur = int(time.time() - rec_started.get(cid, time.time()))
        mlog(cid, f"recorder stop (длительность события ~{dur} с) {reason}")
    rec_started.pop(cid, None)
    lf = rec_logs.pop(cid, None)
    if lf is not None:
        try: lf.close()
        except Exception: pass

def snap_thumbs(cams):
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for cam in cams:
        out = PREVIEW_DIR / f"thumb_{cam['id']}.jpg"
        tmp = PREVIEW_DIR / f".thumb_{cam['id']}.tmp.jpg"
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-rtsp_transport", "tcp",
               "-i", cam["rtsp_url"], "-frames:v", "1", "-y", str(tmp)]
        try:
            r = subprocess.run(cmd, timeout=10, capture_output=True)
            if r.returncode == 0 and tmp.exists() and tmp.stat().st_size > 0:
                os.replace(tmp, out)
            elif tmp.exists():
                tmp.unlink()
        except Exception:
            if tmp.exists():
                try: tmp.unlink()
                except Exception: pass

def cleanup_archives():
    try:
        conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
        for row in conn.execute("SELECT id FROM camera").fetchall():
            cid = row["id"]
            days = conn.execute("SELECT MAX(t.archive_days) AS d FROM camera_access ca JOIN user u ON u.id=ca.user_id JOIN tariff t ON t.id=u.tariff_id WHERE ca.camera_id=? AND ca.enabled=1", (cid,)).fetchone()["d"]
            days = days or 7
            cutoff = time.time() - days * 86400
            d = ARCHIVE_DIR / f"camera_{cid}"
            if d.exists():
                for f in d.glob("*.mp4"):
                    if f.stat().st_mtime < cutoff: f.unlink()
        conn.close()
    except Exception:
        pass

threading.Thread(target=smtp_server_thread, daemon=True).start()

while running:
    settings = get_settings()
    cameras = get_cameras(); active_ids = set()
    now = time.time()
    try:
        grace = max(5.0, min(300.0, float(settings.get("motion_grace", "45"))))
    except ValueError:
        grace = 45.0
    for cam in cameras:
        cid = cam["id"]; active_ids.add(cid)
        cfg = camera_config(cam, settings)
        rtsp, rec, mode, zone, thr, onvif_url, grace_s = cfg
        proc = procs.get(cid)
        if proc is not None and configs.get(cid) != cfg:
            stop_live(cid); proc = None
        if proc is None or proc.poll() is not None:
            if proc is not None:
                proc.wait(); stop_live(cid)
            procs[cid] = start_live(cam, rec and mode == "continuous")
            configs[cid] = cfg
        if mode == "onvif":
            if rec: ensure_onvif(cid, cam)
            else: stop_onvif(cid)
        else:
            stop_onvif(cid)
        if rec and mode == "motion":
            d = detectors.get(cid)
            if d is None or d.poll() is not None:
                stop_detector(cid)
                d = start_detector(cam, cfg); detectors[cid] = d; det_frames[cid] = 0
            if detector_motion(cid):
                last_motion[cid] = now
        else:
            stop_detector(cid)
        if rec and mode in ("motion", "onvif", "smtp"):
            silent_for = now - last_motion.get(cid, 0)
            gate = silent_for < grace
            r = recorders.get(cid)
            if r is not None and r.poll() is not None:
                stop_recorder(cid, "(поток сам оборвался)"); r = None
            if gate and r is None and last_motion.get(cid):
                recorders[cid] = start_recorder(cam)
            elif not gate and r is not None:
                stop_recorder(cid, f"(тишина в зоне {int(silent_for)} с >= хвоста {int(grace)} с)")
        else:
            if recorders.get(cid):
                stop_recorder(cid, "(режим сменился)")
            if mode == "continuous":
                last_motion.pop(cid, None)
    for cid in list(procs.keys()):
        if cid not in active_ids:
            stop_live(cid); configs.pop(cid, None)
            stop_detector(cid); stop_recorder(cid, "(камера отключена)"); stop_onvif(cid); last_motion.pop(cid, None)
    loops += 1
    if loops % 30 == 1: snap_thumbs(cameras)
    if loops % 900 == 0: cleanup_archives()
    time.sleep(2)

for cid in list(procs.keys()): stop_live(cid)
for cid in list(detectors.keys()): stop_detector(cid)
for cid in list(recorders.keys()): stop_recorder(cid, "(остановка воркера)")
for cid in list(onvif_threads.keys()): stop_onvif(cid)