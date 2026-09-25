import os, sqlite3, subprocess, time, signal
from pathlib import Path

BASE_DIR = Path("/opt/cctv"); DB_PATH = BASE_DIR / "app" / "cctv.db"
ARCHIVE_DIR = BASE_DIR / "storage" / "archive"; LIVE_DIR = BASE_DIR / "storage" / "live"
LOG_DIR = BASE_DIR / "storage" / "logs"; PREVIEW_DIR = BASE_DIR / "storage" / "previews"
MOTION_THRESHOLD = "0.06"
procs = {}; configs = {}; log_files = {}; running = True; loops = 0

def handle_signal(signum, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, handle_signal); signal.signal(signal.SIGINT, handle_signal)

def get_cameras():
    if not DB_PATH.exists(): return []
    try:
        conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
        rows = [dict(r) for r in conn.execute(
            "SELECT id, rtsp_url, recording_enabled, recording_mode FROM camera WHERE active=1")]
        conn.close(); return rows
    except sqlite3.Error:
        return []

def camera_config(cam):
    return (cam["rtsp_url"], bool(cam["recording_enabled"]), cam.get("recording_mode") or "continuous")

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

def stop_camera(camera_id):
    proc = procs.pop(camera_id, None)
    if proc is not None:
        try:
            proc.terminate(); proc.wait(timeout=5)
        except Exception:
            try: proc.kill()
            except Exception: pass
    lf = log_files.pop(camera_id, None)
    if lf is not None:
        try: lf.close()
        except Exception: pass

def start_camera(cam):
    camera_id = cam["id"]
    recording_enabled = bool(cam["recording_enabled"])
    mode = cam.get("recording_mode") or "continuous"
    archive_dir = ARCHIVE_DIR / f"camera_{camera_id}"; live_dir = LIVE_DIR / f"camera_{camera_id}"
    LOG_DIR.mkdir(parents=True, exist_ok=True); archive_dir.mkdir(parents=True, exist_ok=True); live_dir.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / f"camera_{camera_id}.log"
    if log_path.exists() and log_path.stat().st_size > 5 * 1024 * 1024: log_path.unlink()
    lf = open(log_path, "ab", buffering=0); log_files[camera_id] = lf
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "warning", "-rtsp_transport", "tcp", "-i", cam["rtsp_url"]]
    if recording_enabled:
        if mode == "motion":
            cmd += ["-map", "0:v",
                    "-vf", f"select='gt(scene,{MOTION_THRESHOLD})'",
                    "-vsync", "0",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
                    "-an",
                    "-f", "segment", "-segment_time", "300", "-reset_timestamps", "1", "-strftime", "1",
                    str(archive_dir / "%Y-%m-%d_%H-%M-%S.mp4")]
        else:
            cmd += ["-map", "0:v", "-c:v", "copy", "-an",
                    "-f", "segment", "-segment_time", "300", "-reset_timestamps", "1", "-strftime", "1",
                    str(archive_dir / "%Y-%m-%d_%H-%M-%S.mp4")]
    cmd += ["-map", "0:v", "-c:v", "copy", "-an", "-f", "hls",
            "-hls_time", "6", "-hls_list_size", "6", "-hls_flags", "delete_segments",
            str(live_dir / "index.m3u8")]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=lf)

cams_now = []
while running:
    cameras = get_cameras(); cams_now = cameras; active_ids = set()
    for cam in cameras:
        cid = cam["id"]; active_ids.add(cid); cfg = camera_config(cam)
        proc = procs.get(cid)
        if proc is not None and configs.get(cid) != cfg:
            stop_camera(cid); proc = None
        if proc is None or proc.poll() is not None:
            if proc is not None:
                proc.wait()
                lf = log_files.pop(cid, None)
                if lf is not None:
                    try: lf.close()
                    except Exception: pass
            procs[cid] = start_camera(cam); configs[cid] = cfg
    for cid in list(procs.keys()):
        if cid not in active_ids:
            stop_camera(cid); configs.pop(cid, None)
    loops += 1
    if loops % 12 == 1: snap_thumbs(cameras)
    if loops % 300 == 0: cleanup_archives()
    time.sleep(5)

for cid in list(procs.keys()): stop_camera(cid)