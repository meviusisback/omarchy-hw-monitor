#!/usr/bin/python3
"""Top-N processi per memoria RSS o CPU, opzionalmente raggruppati per app.

Uso: proc_top.py [--top N] [--sort ram|cpu] [--group]
Output: {"groupedBy": "none"|"scope"|"comm", "procs": [{"pid": 1234,
  "name": "firefox", "count": 12, "cpu": 12.3, "rssKib": 1234567,
  "memPct": 5.3}]}
Pipeline: collect -> group -> sum -> sort -> cut. CPU normalizzata sul totale
sistema (100% = tutti i core), calcolata su due letture a ~400 ms.
Raggruppamento: identità systemd dal token più profondo (scope/service,
contenitori come app-graphical.slice esclusi, pretty pulito); fallback per
comm uguale; unione sep-prefix ("orca" assorbe "orca-ide"). Senza identità:
singole o per-comm. Niente espansione figli.
Errori: {} su stdout, una riga su stderr, exit 0 (refuse-softly).
Solo stdlib, nessuna rete, nessuna scrittura.
"""

import json
import os
import re
import sys
import time

TOP_DEFAULT = 6
TOP_MIN = 3
TOP_MAX = 12
PID_CAP = 4096
NAME_MAX = 48
SNAP_GAP_S = 0.4
SORTS = ("ram", "cpu")
GROUPEDS = ("none", "scope", "comm")

# Identità app dal cgroup (verità misurata su host Hyprland/systemd, non presunta):
# - token più profondo che termina .scope/.service (es. app-Hyprland-zen\x2dbin-
#   XXXX.scope, app-orca-3236.scope, orca-daemon-UUID.scope, *.service in app.slice)
# - saltati i contenitori: app-graphical.slice, app-dbus-*, app-glib-*, unità con
#   '@' (sessioni, es. wayland-wm@*.service) — raggrupparli unirebbe il desktop.
# - pretty: unescape \\xNN, via `app-`, via un `Hyprland-` iniziale (launcher),
#   via suffisso `-esadecimale{4,}`, ultimo segmento puntato, sanitize esistente.
CONTAINER_EXACT = ("app-graphical.slice",)
CONTAINER_PREFIX = ("app-dbus-", "app-glib-")
# Mai identità: contenitori systemd generici superstiti allo strip.
GENERIC_BASES = ("app", "user", "system", "init", "session")


def unescape_unit(text):
    def sub(match):
        try:
            return chr(int(match.group(1), 16))
        except ValueError:
            return "?"
    return re.sub(r"\\x([0-9a-fA-F]{2})", sub, text)


def app_identity(cgline):
    if not cgline:
        return ""
    for seg in reversed(cgline.strip().split("/")):
        if "@" in seg:
            continue
        if seg in CONTAINER_EXACT or seg.startswith(CONTAINER_PREFIX):
            continue
        # Solo token con identità: prefisso app- o unità scope/service.
        # `app.slice`/`user.slice`/`session.slice` non iniziano per app- e
        # non sono scope/service: scartati qui, senza arrivare al pretty.
        if not (seg.startswith("app-") or seg.endswith((".scope", ".service"))):
            continue
        if seg.endswith(".scope") or seg.endswith(".service"):
            base = seg.rsplit(".", 1)[0]
        elif seg.endswith(".slice"):
            base = seg[:-len(".slice")]
        else:
            continue
        base = unescape_unit(base)
        if base.startswith("app-"):
            base = base[len("app-"):]
        if base.startswith("Hyprland-"):
            base = base[len("Hyprland-"):]
        base = re.sub(r"(-[0-9a-fA-F]{4,})+$", "", base)
        if "." in base:
            base = base.split(".")[-1]
        if base in GENERIC_BASES:
            continue
        pretty = sanitize_name(base)
        if pretty and pretty != "?":
            return pretty
    return ""

# Spazio e parens sono legittimi nei nomi reali (es. "Isolated Web Co").
NAME_OK = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "._+:@/ -()")


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


def read_cgroup_first(pid):
    try:
        with open("/proc/%d/cgroup" % pid, "r", encoding="utf-8",
                  errors="replace") as fh:
            return fh.readline().strip()
    except OSError:
        return ""


def snapshot_pids(want_cgroup):
    """Ritorna {pid: (utime+stime, rss_pages, comm, ppid, cgroupline)}."""
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
            ppid = int(tail[1])
            utime = int(tail[11])
            stime = int(tail[12])
            rss_pages = int(tail[21])
            with open("/proc/%d/comm" % pid, "r", encoding="utf-8",
                      errors="replace") as fh:
                comm = fh.read().strip()
        except (OSError, ValueError, IndexError):
            continue
        cg = read_cgroup_first(pid) if want_cgroup else ""
        snap[pid] = (utime + stime, rss_pages, comm, ppid, cg)
    return snap


def merge_key(name):
    return name.lower()


def mergeable(shorter, longer):
    if shorter == longer:
        return True
    return any(longer.startswith(shorter + sep) for sep in ("-", "_", "."))


def build_rows(snap_a, snap_b, sys_delta, mem_total, page_kib, group):
    per_pid = []
    for pid, (cpu_b, rss_b, comm, _ppid, cg) in snap_b.items():
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
        per_pid.append({
            "pid": pid,
            "comm": sanitize_name(comm),
            "ident": app_identity(cg) if group else "",
            "cpu": cpu,
            "rssKib": rss_kib,
        })

    grouped_by = "none"
    if not group:
        rows = [{
            "pid": p["pid"],
            "name": p["comm"],
            "count": 1,
            "cpu": round(p["cpu"], 1),
            "rssKib": int(p["rssKib"]),
            "memPct": 0.0,
        } for p in per_pid]
    else:
        identified = [p for p in per_pid if p["ident"]]
        grouped_by = "scope" if identified else "comm"
        # Secchi per chiave (identità systemd se c'è, altrimenti comm), poi
        # unione sep-prefix: "orca" assorbe "orca-ide", senza falsi merge
        # su estensioni alfanumeriche ("pi" non assorbe "pipewire").
        buckets = {}
        for p in per_pid:
            label = p["ident"] if p["ident"] else p["comm"]
            buckets.setdefault(merge_key(label), []).append((label, p))
        canon = {}
        for key in sorted(buckets, key=len):
            target = None
            for done in canon:
                if mergeable(done, key):
                    target = done
                    break
            if target is None:
                target = key
            buckets[target].extend(buckets[key] if target != key else [])
            ident_labels = [lab for lab, m in buckets[target] if m["ident"]]
            canon[target] = ident_labels[0] if ident_labels else buckets[target][0][0]
        rows = []
        for key, members in buckets.items():
            if key not in canon:
                continue
            display = canon[key]
            procs = [m for _lab, m in members]
            if len(procs) == 1:
                m = procs[0]
                rows.append({
                    "pid": m["pid"],
                    "name": m["comm"],
                    "count": 1,
                    "cpu": round(m["cpu"], 1),
                    "rssKib": int(m["rssKib"]),
                    "memPct": 0.0,
                })
            else:
                rows.append({
                    "pid": max(procs, key=lambda m: m["rssKib"])["pid"],
                    "name": display,
                    "count": len(procs),
                    "cpu": round(sum(m["cpu"] for m in procs), 1),
                    "rssKib": int(sum(m["rssKib"] for m in procs)),
                    "memPct": 0.0,
                })

    for r in rows:
        r["cpu"] = max(0.0, min(100.0, r["cpu"]))
        mem_pct = (100.0 * r["rssKib"] / mem_total) if mem_total > 0 else 0.0
        r["memPct"] = round(max(0.0, min(100.0, mem_pct)), 1)
    return rows, grouped_by


def main(argv):
    top_n = TOP_DEFAULT
    sort = "ram"
    group = False
    i = 1
    while i < len(argv):
        if argv[i] == "--top" and i + 1 < len(argv):
            try:
                top_n = int(argv[i + 1])
            except ValueError:
                top_n = TOP_DEFAULT
            i += 2
        elif argv[i] == "--sort" and i + 1 < len(argv):
            cand = argv[i + 1].strip().lower()
            sort = cand if cand in SORTS else "ram"
            i += 2
        elif argv[i] == "--group":
            group = True
            i += 1
        else:
            i += 1
    top_n = max(TOP_MIN, min(TOP_MAX, top_n))

    try:
        page_kib = os.sysconf("SC_PAGE_SIZE") // 1024
    except (OSError, ValueError):
        page_kib = 4
    mem_total = read_mem_total_kib()

    sys_a = read_sys_total()
    snap_a = snapshot_pids(group)
    time.sleep(SNAP_GAP_S)
    sys_b = read_sys_total()
    snap_b = snapshot_pids(group)
    sys_delta = sys_b - sys_a

    rows, grouped_by = build_rows(snap_a, snap_b, sys_delta, mem_total,
                                  page_kib, group)
    key = (lambda r: r["rssKib"]) if sort == "ram" else (lambda r: r["cpu"])
    rows.sort(key=key, reverse=True)
    sys.stdout.write(json.dumps({"groupedBy": grouped_by,
                                 "procs": rows[:top_n]},
                                ensure_ascii=True) + "\n")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except BrokenPipeError:
        pass
    except Exception as exc:  # refuse-softly: mai traceback rumoroso
        sys.stderr.write("proc_top: %s\n" % exc)
        sys.stdout.write("{}\n")
