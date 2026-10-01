def run_cut(job):
    cid = job["camera_id"]; day = job["day"]; precise = job["precise"]
    out_dir = CUTS_DIR / f"camera_{cid}"; out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / job["file"]
    lst = out_dir / f".list_{job['id']}.txt"
    try:
        f_sec = _hms_to_sec(job["from"]); t_sec = _hms_to_sec(job["to"])
        if t_sec <= f_sec:
            job["status"] = "error"; job["error"] = "конец раньше начала"; _update_job(job); return
        d = ARCHIVE_DIR / f"camera_{cid}"
        sources = []
        dayf = d / f"{day}.mp4"
        mmap_day = _load_day_map(d, day) if dayf.exists() else None
        if dayf.exists():
            if mmap_day:
                for m in mmap_day:
                    sources.append((dayf, m["a"], m["b"], m["o"]))
            else:
                sources.append((dayf, 0, probe_dur(dayf), 0))
        else:
            for p in sorted(d.glob(f"{day}_*.mp4"), key=lambda x: x.name):
                s = _chunk_start_sec(p.name)
                sources.append((p, s, s + probe_dur(p), 0))
        cov = [x for x in sources if x[1] < t_sec and x[2] > f_sec]
        if not cov:
            job["status"] = "error"; job["error"] = "в диапазоне нет записи"; _update_job(job); return
        enc = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"] if precise else ["-c", "copy"]
        paths = {x[0] for x in cov}

        if len(cov) == 1:
            path, a0, b0, o0 = cov[0]
            a = max(a0, f_sec); b = min(b0, t_sec)
            ss = o0 + (a - a0); dur = b - a
            cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-ss", f"{ss:.3f}", "-t", f"{dur:.3f}",
                   "-i", str(path)] + enc + ["-an", "-movflags", "+faststart", str(out)]
            r = subprocess.run(cmd, capture_output=True, timeout=7200)
            if r.returncode != 0 or not out.exists() or out.stat().st_size == 0:
                job["status"] = "error"
                job["error"] = (r.stderr.decode(errors="ignore")[:200] if r.stderr else "ошибка ffmpeg")
                _update_job(job); return
            job["status"] = "done"; job["map"] = [{"a": a, "b": b, "o": 0.0}]; job["base"] = a
            job["size_mb"] = round(out.stat().st_size / 1048576, 1)
            _update_job(job); return

        if len(paths) == 1:
            # склеенный день с картой: режем по входам карты отдельными trim-ами и concat'им
            temps = []; off = 0.0; mmap_out = []
            for i, (path, a0, b0, o0) in enumerate(cov):
                a = max(a0, f_sec); b = min(b0, t_sec)
                if b <= a: continue
                tmp = out_dir / f".tmp_{job['id']}_{i}.mp4"
                cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-ss", f"{o0 + (a - a0):.3f}",
                       "-t", f"{b - a:.3f}", "-i", str(path)] + enc + ["-an", str(tmp)]
                r = subprocess.run(cmd, capture_output=True, timeout=7200)
                if r.returncode != 0 or not tmp.exists() or tmp.stat().st_size == 0:
                    for t in temps:
                        try: t.unlink()
                        except Exception: pass
                    job["status"] = "error"
                    job["error"] = ("trim: " + (r.stderr.decode(errors="ignore")[:180] if r.stderr else "ошибка ffmpeg"))
                    _update_job(job); return
                temps.append(tmp); mmap_out.append({"a": a, "b": b, "o": off}); off += (b - a)
            with open(lst, "w") as fh:
                for t in temps:
                    fh.write(f"file '{t}'\n")
            r = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "concat", "-safe", "0",
                                "-i", str(lst), "-c", "copy", "-movflags", "+faststart", str(out)],
                               capture_output=True, timeout=7200)
            for t in temps:
                try: t.unlink()
                except Exception: pass
            try: lst.unlink()
            except Exception: pass
            if r.returncode != 0 or not out.exists() or out.stat().st_size == 0:
                job["status"] = "error"
                job["error"] = ("concat: " + (r.stderr.decode(errors="ignore")[:180] if r.stderr else "ошибка ffmpeg"))
                _update_job(job); return
            job["status"] = "done"; job["map"] = mmap_out; job["base"] = mmap_out[0]["a"]
            job["size_mb"] = round(out.stat().st_size / 1048576, 1)
            _update_job(job); return

        # несколько кусков: concat целиком + обрезка границ диапазона одной командой
        base = cov[0][1]
        off_from = max(0.0, f_sec - base)
        dur = min(cov[-1][2], float(t_sec)) - (base + off_from)
        if dur <= 0:
            job["status"] = "error"; job["error"] = "пустой диапазон"; _update_job(job); return
        with open(lst, "w") as fh:
            for (path, a0, b0, o0) in cov:
                fh.write(f"file '{path}'\n")
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-ss", f"{off_from:.3f}", "-t", f"{dur:.3f}",
               "-f", "concat", "-safe", "0", "-i", str(lst)] + enc + ["-an", "-movflags", "+faststart", str(out)]
        r = subprocess.run(cmd, capture_output=True, timeout=7200)
        try: lst.unlink()
        except Exception: pass
        if r.returncode != 0 or not out.exists() or out.stat().st_size == 0:
            job["status"] = "error"
            job["error"] = (r.stderr.decode(errors="ignore")[:200] if r.stderr else "ошибка ffmpeg")
            _update_job(job); return
        c_off = 0.0; mmap_out = []
        for (path, a0, b0, o0) in cov:
            a = max(a0, f_sec); b = min(b0, t_sec)
            if b > a:
                mmap_out.append({"a": a, "b": b, "o": c_off + (a - a0) - off_from})
            c_off += (b0 - a0)
        job["status"] = "done"; job["map"] = mmap_out; job["base"] = mmap_out[0]["a"]
        job["size_mb"] = round(out.stat().st_size / 1048576, 1)
    except Exception as e:
        job["status"] = "error"; job["error"] = str(e)[:200]
        try: lst.unlink()
        except Exception: pass
    _update_job(job)