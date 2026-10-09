#!/usr/bin/python3
"""Top-N processi per memoria RSS. Legge solo /proc, una riga JSON su stdout.

Uso: proc_top.py [--top N]  (default 8, clamp 3-12)
Output: {"procs": [{"pid": 1234, "name": "firefox", "cpu": 12.3,
                    "rssKib": 1234567, "memPct": 5.3}]}
Ordinati per rssKib decrescente. CPU% normalizzata sul totale sistema
(100% = tutti i core), calcolata su due letture a ~400 ms.
Errori: {} su stdout, una riga su stderr, exit 0 (refuse-softly).
Solo stdlib, nessuna rete, nessuna scrittura.
"""

import json
import os
import sys
import time

TOP_DEFAULT = 8
TOP_MIN = 3
TOP_MAX = 12
PID_CAP = 4096
NAME_MAX = 48
SNAP_GAP_S = 0.4

# Spazio e parens sono legittimi nei nomi reali (es. "Isolated Web Co").
NAME_OK = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "._+:@/ -()"
)


def sanitize_name(raw):
    text = str(raw or "").strip().replace("\n", " ").replace("\t", " ")
    out = "".join(c if c in NAME_OK else "\u00b7" for c in text)
    out = " ".join(out.split())
    if len(out) > NAME_MAX:
        out = out[:NAME_MAX]
    return out if out else "?"


def read_mem_total_kib():
    try:
        with open("/proc/meminfo", "r", encoding="utf-8",
                  errors="replace") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def read_sys_total():
    try:
        with open("/proc/stat", "r", encoding="utf-8",
                  errors="replace") as fh:
            parts = fh.readline().split()
        if len(parts) >= 5 and parts[0] == "cpu":
            return sum(int(p) for p in parts[1:9])
    except (OSError, ValueError):
        pass
    return 0


def snapshot_pids():
    """Ritorna {pid: (utime+stime, rss_pages, comm)}."""
    snap = {}
    try:
        entries = os.listdir("/proc")
    except OSError:
        return snap
    count = 0
    for entry in entries:
        if not entry.isdigit():
            continue
        count += 1
        if count > PID_CAP:
            break
        pid = int(entry)
        try:
            with open("/proc/%d/stat" % pid, "r", encoding="utf-8",
                      errors="replace") as fh:
                stat = fh.read()
            tail = stat.rsplit(")", 1)[1].split()
            utime = int(tail[11])
            stime = int(tail[12])
            rss_pages = int(tail[21])
            with open("/proc/%d/comm" % pid, "r", encoding="utf-8",
                      errors="replace") as fh:
                comm = fh.read().strip()
        except (OSError, ValueError, IndexError):
            continue
        snap[pid] = (utime + stime, rss_pages, comm)
    return snap


def main(argv):
    top_n = TOP_DEFAULT
    if len(argv) >= 3 and argv[1] == "--top":
        try:
            top_n = int(argv[2])
        except ValueError:
            top_n = TOP_DEFAULT
    top_n = max(TOP_MIN, min(TOP_MAX, top_n))

    try:
        page_kib = os.sysconf("SC_PAGE_SIZE") // 1024
    except (OSError, ValueError):
        page_kib = 4
    mem_total = read_mem_total_kib()

    sys_a = read_sys_total()
    snap_a = snapshot_pids()
    time.sleep(SNAP_GAP_S)
    sys_b = read_sys_total()
    snap_b = snapshot_pids()
    sys_delta = sys_b - sys_a

    rows = []
    for pid, (cpu_b, rss_b, comm) in snap_b.items():
        old = snap_a.get(pid)
        if old is None:
            continue
        dproc = cpu_b - old[0]
        if sys_delta > 0 and dproc >= 0:
            cpu = 100.0 * dproc / sys_delta
        else:
            cpu = 0.0
        cpu = max(0.0, min(100.0, cpu))
        rss_kib = rss_b * page_kib
        mem_pct = (100.0 * rss_kib / mem_total) if mem_total > 0 else 0.0
        mem_pct = max(0.0, min(100.0, mem_pct))
        rows.append({
            "pid": pid,
            "name": sanitize_name(comm),
            "cpu": round(cpu, 1),
            "rssKib": int(rss_kib),
            "memPct": round(mem_pct, 1),
        })
    rows.sort(key=lambda r: r["rssKib"], reverse=True)
    sys.stdout.write(json.dumps({"procs": rows[:top_n]},
                                ensure_ascii=True) + "\n")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except BrokenPipeError:
        pass
    except Exception as exc:  # refuse-softly: mai traceback rumoroso
        sys.stderr.write("proc_top: %s\n" % exc)
        sys.stdout.write("{}\n")
