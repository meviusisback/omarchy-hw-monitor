#!/usr/bin/python3
"""Top-N processi per memoria RSS o CPU, opzionalmente raggruppati per app.

Uso: proc_top.py [--top N] [--sort ram|cpu] [--group]
Output: {"groupedBy": "none"|"scope"|"comm", "procs": [{"pid": 1234,
  "name": "firefox", "count": 12, "cpu": 12.3, "rssKib": 1234567,
  "memPct": 5.3}]}
Pipeline: collect -> group -> sum -> sort -> cut. CPU normalizzata sul totale
sistema (100% = tutti i core), calcolata su due letture a ~400 ms (o rispetto
allo snapshot precedente in cache tmpfs).
Raggruppamento: identità systemd dal token più profondo (scope/service,
contenitori come app-graphical.slice esclusi, pretty pulito); fallback per
comm uguale; unione sep-prefix ("orca" assorbe "orca-ide"). Senza identità:
singole o per-comm. Niente espansione figli.
Senza --group i browser Chromium (brave/chrome/chromium/msedge/vivaldi) sono
disambiguati: ruolo dal cmdline ([main], [gpu], [ext], [zygote]...) oppure
dominio del tab letto dai segmenti anonimi di /proc/<pid>/mem (sola lettura,
budget di byte/tempo). L'host è quello più frequente in memoria: un CDN molto
usato può oscurare l'origin, quindi il dominio è un indizio, non una verità.
Stato su disco: /run/user/<uid>/hw_monitor_browser_cache.json (0600, tmpfs,
TTL 45 s / 10 s). Serve a non ripetere la scansione a ogni poll: se manca una
runtime dir dell'utente il caching si disattiva, senza scrivere altrove.
Errori: {} su stdout, una riga su stderr, exit 0 (refuse-softly).
Solo stdlib, nessuna rete.
"""

import json
import math
import os
import re
import stat
import sys
import tempfile
import time

TOP_DEFAULT = 6
TOP_MIN = 3
TOP_MAX = 12
PID_CAP = 4096
MERGE_CANDIDATES = 256
SCAN_HOSTS_CAP = 4096
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
GENERIC_BASES = (
    "app", "user", "system", "init", "session",
    "gtk-launch", "xdg-open", "sh", "bash", "zsh", "env",
)
SCRIPT_EXTS = (".sh", ".py", ".desktop", ".bin", ".run", ".appimage")


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
        for ext in SCRIPT_EXTS:
            if base.lower().endswith(ext):
                base = base[:-len(ext)]
                break
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
    "._+:@/ -()[]")


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
    os_open = os.open
    os_read = os.read
    os_close = os.close
    o_rdonly = os.O_RDONLY
    isdigit = str.isdigit
    try:
        proc_fd = os_open("/proc", o_rdonly)
    except OSError:
        return snap
    try:
        try:
            entries = os.listdir(proc_fd)
        except OSError:
            return snap
        count = 0
        for entry in entries:
            if not isdigit(entry):
                continue
            count += 1
            if count > PID_CAP:
                break
            pid = int(entry)
            try:
                fd = os_open(entry + "/stat", o_rdonly, dir_fd=proc_fd)
                try:
                    stat = os_read(fd, 512)
                finally:
                    os_close(fd)
                lp = stat.find(b"(")
                rp = stat.rfind(b")")
                if lp == -1 or rp == -1:
                    continue
                tail = stat[rp + 2:].split(None, 22)
                rss_pages = int(tail[21])
                cpu_ticks = int(tail[11]) + int(tail[12])
                if rss_pages == 0 and cpu_ticks == 0:
                    continue
                ppid = int(tail[1])
                comm = stat[lp + 1:rp].decode("utf-8", "replace").strip()
            except (OSError, ValueError, IndexError):
                continue
            cg = read_cgroup_first(pid) if (want_cgroup and rss_pages > 0) else ""
            snap[pid] = (cpu_ticks, rss_pages, comm, ppid, cg)
    finally:
        os_close(proc_fd)
    return snap


def merge_key(name):
    return name.lower()


def mergeable(shorter, longer):
    if shorter == longer:
        return True
    return any(longer.startswith(shorter + sep) for sep in ("-", "_", "."))


def build_rows(snap_a, snap_b, sys_delta, mem_total, page_kib, group):
    if not group:
        rows = []
        inv_sys = (100.0 / sys_delta) if sys_delta > 0 else 0.0
        inv_mem = (100.0 / mem_total) if mem_total > 0 else 0.0
        for pid, (cpu_b, rss_b, comm, _ppid, _cg) in snap_b.items():
            old = snap_a.get(pid)
            if old is None:
                continue
            dproc = cpu_b - old[0]
            cpu = dproc * inv_sys if (inv_sys > 0.0 and dproc > 0) else 0.0
            if cpu > 100.0:
                cpu = 100.0
            rss_kib = rss_b * page_kib
            mem_pct = rss_kib * inv_mem
            if mem_pct > 100.0:
                mem_pct = 100.0
            rows.append({
                "pid": pid,
                "name": comm,
                "count": 1,
                "cpu": round(cpu, 1),
                "rssKib": int(rss_kib),
                "memPct": round(mem_pct, 1),
            })
        return rows, "none"

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
    # Unione sep-prefix limitata: confrontare ogni chiave con tutte le
    # canoniche è O(B^2) — 4096 comm distinti valgono 3.8 s contro un
    # watchdog da 2 s. Oltre MERGE_CANDIDATES canoniche le chiavi restanti
    # restano secchi propri (stesso output del merge completo sui casi
    # reali, dove le identità distinte sono decine, non migliaia).
    for key in sorted(buckets, key=len):
        target = None
        if len(canon) < MERGE_CANDIDATES:
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


BROWSER_COMMS = ("brave", "chrome", "chromium", "msedge", "vivaldi")
BROWSER_CACHE_TTL_RESOLVED = 45.0
BROWSER_CACHE_TTL_EMPTY = 10.0
CACHE_NAME = "hw_monitor_browser_cache.json"
CACHE_VERSION = 2
CACHE_MAX_BYTES = 256 * 1024
SNAP_CACHE_MAX_AGE = 10.0
# Limiti della scansione di memoria: senza budget una singola mappatura
# sfortunata legge centinaia di MB dentro un watchdog da 2 s.
MEM_SCAN_MAX_BYTES = 8 * 1024 * 1024
MEM_SCAN_CHUNK = 512 * 1024
MEM_SCAN_MAX_REGIONS = 400
MEM_SCAN_BUDGET_S = 0.6

# Solo l'host: la path non discrimina (pesarla peggiorava le etichette reali).
# L'authority si cattura INTERA (`[^/?#\s"'<>]`, al massimo 255 byte: la lunghezza
# massima di un nome host) e l'host si estrae dopo, in `_authority_host`.
# Non si prova a esprimerlo in una sola regex: un gruppo opzionale
# `(?:userinfo@)?` seguito dall'host fa vincere il userinfo ogni volta che
# l'host vero NON è esprimibile come `a.b` — `@intranet`, `@localhost`,
# `@[::1]`, `@host_con_underscore` — perché il motore torna indietro alla
# chiocciola precedente e cattura la civetta. Cioè il difetto restava,
# solo spostato sui nomi a etichetta singola. Con la cattura strutturale
# ("l'host è ciò che segue l'ultima chiocciola") il userinfo non può più
# vincere per costruzione, non per effetto collaterale del backtracking.
# Gli esclusi `?`, `#`, `/` tengono lo scan dentro l'authority; una classe
# larga lasciava rientrare lo spoof dalla query string.
URL_AUTH_RE = re.compile(rb"https?://([^/?#\s\"'<>]{1,255})")
APP_AUTH_RE = re.compile(r"--app=(?:https?://)?([^/?#\s\"'<>]{1,255})")
# Match di PREFISSO, non ancorato a fine stringa: dopo l'host possono esserci
# byte legali nella cattura ma non in un host (`url(…com)`, NUL, `&`, `;`).
# Con il `$` finale quei casi perdevano l'etichetta del tutto; il match greedy
# prende il prefisso valido più lungo. Ma il prefisso vale solo se l'host
# FINISCE lì: se il byte successivo è ancora "da host" (`_`, `.`, `-`, `%`)
# allora non è un dominio pulito ma un host più lungo e illeggibile, e
# restituire il prefisso inventerebbe un dominio plausibile ma falso
# (`www.ex_ample.com` diventava `www.ex`, `banca.example_x` → `banca.example`).
# In quel caso si rinuncia all'etichetta. La garanzia "il userinfo non vince"
# la porta rsplit(b'@'), non l'ancora né il prefisso.
_URL_HOST_OK = re.compile(rb"[a-z0-9-]+(?:\.[a-z0-9-]+)+")
_HOSTISH_AFTER = re.compile(rb"[a-z0-9._\-%\x80-\xff]")
# Cioè la stessa classe della cattura: se il byte dopo l'authority sarebbe
# ANCORA potuto entrarci, la cattura si è fermata al tetto di 255 e va scartata.
# Un `not after not in b"/?#"` non basta: spazio, virgoletta e `<>` chiudono
# l'authority senza essere `/?#`, e con quella prova un'authority completa di
# 255 byte seguita da uno spazio perdeva l'etichetta.
_AUTH_MORE = re.compile(rb"[^/?#\s\"'<>]")
_AUTH_MORE_STR = re.compile(r"[^/?#\s\"'<>]")


def _authority_host(auth):
    """Host da un authority URL, oppure None. Il userinfo non vince mai.

    Strutturale: si tiene il segmento dopo l'ultima `@`, si toglie la porta,
    si valida. Se il risultato non è un dominio mostrabile si restituisce
    None — rinunciare all'etichetta è corretto, mostrare la civetta no.
    """
    host = auth.rsplit(b"@", 1)[-1]
    if host.startswith(b"["):
        return None                      # letterale IPv6: non è un dominio
    host = host.split(b":", 1)[0].lower().rstrip(b".")
    match = _URL_HOST_OK.match(host)
    if not match:
        return None
    after = host[match.end():match.end() + 1]
    if after and _HOSTISH_AFTER.match(after):
        return None                      # l'host continua: non è pulito
    return match.group(0)


CMD_TYPE_RE = re.compile(r"--type=([a-zA-Z][a-zA-Z0-9-]*)")
APP_ID_RE = re.compile(r"--app-id=([a-zA-Z0-9]+)")
UTIL_SUB_RE = re.compile(r"--utility-sub-type=([a-zA-Z0-9_.]+)")

IGNORE_BROWSER_HOSTS = {
    "www.w3.org", "w3.org", "schema.org", "www.chromium.org", "chromium.org",
    "developer.mozilla.org", "mozilla.org", "fonts.googleapis.com", "fonts.gstatic.com",
    "ajax.googleapis.com", "www.google.com", "apis.google.com", "accounts.google.com",
    "ssl.gstatic.com", "www.gstatic.com", "clients2.google.com", "chrome.google.com",
    "chromewebstore.google.com", "brave.com", "variations.brave.com", "static.cloudflareinsights.com",
    "cdn.jsdelivr.net", "unpkg.com", "cdnjs.cloudflare.com", "fontawesome.com",
    "raw.githubusercontent.com", "avatars.githubusercontent.com", "localhost", "127.0.0.1",
    "webawesome.com", "buy.paddle.com", "cdn.paddle.com", "clearcache.io", "darkreader.org",
    "browser-intake-us5-datadoghq.com", "accountcapabilities-pa.googleapis.com",
    "api.anthropic.com", "i.ytimg.com", "yt3.ggpht.com", "s.ytimg.com",
    "ic3.teams.office.com", "local.teams.office.com", "api.flightproxy.teams.microsoft.com",
    "api.spaces.skype.com", "schema.skype.com", "graph.microsoft.com", "substrate.office.com",
}

IGNORE_BROWSER_SUFFIXES = (
    ".crx", ".pak", ".bdic", ".ttf", ".woff2", ".js", ".css",
    ".png", ".svg", ".lencr.org", ".digicert.com", ".sectigo.com",
    ".googleapis.com", ".gstatic.com", ".static.microsoft",
    ".onecdn.static.microsoft", ".msauth.net", ".msftauth.net",
    ".office.net", ".msocdn.com", ".sfx.ms", ".gfx.ms",
    ".googlevideo.com", ".googleadservices.com", ".googlesyndication.com",
    ".doubleclick.net", ".googleusercontent.com", ".ytimg.com", ".ggpht.com",
    ".cloudflareinsights.com", ".datadoghq.com", ".sentry.io", ".cloudfront.net",
)


def _runtime_dir():
    """Directory di stato: solo la runtime dir dell'utente, mai /tmp.

    /tmp è scrivibile da chiunque: un nome prevedibile lì è una primitiva di
    sovrascrittura file via symlink (il temp file veniva aperto seguendo i
    link). Senza una runtime dir nostra il caching si disattiva — nessun
    degrado funzionale, solo un poll più lento.
    """
    uid = os.getuid()
    for cand in (os.environ.get("XDG_RUNTIME_DIR"), "/run/user/%d" % uid):
        if not cand or not os.path.isabs(cand):
            continue
        try:
            info = os.lstat(cand)
        except OSError:
            continue
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid:
            continue
        # Una dir scrivibile da gruppo/altri non è un posto sicuro per lo stato.
        if info.st_mode & 0o022:
            continue
        if not os.access(cand, os.W_OK | os.X_OK):
            continue
        return cand
    return ""


def _browser_cache_path():
    base = _runtime_dir()
    return os.path.join(base, CACHE_NAME) if base else ""


def _as_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_float(value, default=-1e9):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    # NaN/Infinity sopravvivono a JSON e non scadrebbero mai.
    return number if math.isfinite(number) else default


CACHE_KEY_RE = re.compile(r"^[1-9][0-9]*:[1-9][0-9]*$")


def _clean_cache(data):
    """Riporta la cache a una forma tipizzata, scartando il resto.

    Il file è stato esterno e mutabile: un campo col tipo sbagliato non deve
    poter rompere il collector (né lasciarlo rotto per sempre).
    """
    clean: dict = {"_v": CACHE_VERSION}
    snap = data.get("_snap")
    if isinstance(snap, dict) and isinstance(snap.get("cpus"), dict):
        def pids(mapping):
            out = {}
            for key, value in mapping.items():
                pid = _as_int(key)
                if pid > 0:
                    out[str(pid)] = max(0, _as_int(value))
            return out
        prev_cpus = snap.get("prev_cpus")
        clean["_snap"] = {
            "ts": _as_float(snap.get("ts")),
            "sys": max(0, _as_int(snap.get("sys"))),
            "prev_sys": max(0, _as_int(snap.get("prev_sys"))),
            "cpus": pids(snap["cpus"]),
            "prev_cpus": pids(prev_cpus) if isinstance(prev_cpus, dict) else {},
        }
    for key, entry in data.items():
        if not isinstance(key, str) or not CACHE_KEY_RE.match(key):
            continue
        if not isinstance(entry, dict):
            continue
        label = entry.get("label")
        if not isinstance(label, str):
            continue
        label = sanitize_name(label)
        if not label.strip("?· "):
            continue
        clean[key] = {"label": label,
                      "ts": _as_float(entry.get("ts")),
                      "resolved": entry.get("resolved") is True}
    return clean


def _load_browser_cache():
    path = _browser_cache_path()
    if not path:
        return {}
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return {}
        if info.st_size > CACHE_MAX_BYTES:
            return {}
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict) or data.get("_v") != CACHE_VERSION:
            return {}
        return _clean_cache(data)
    except Exception:
        # JSON profondamente annidato alza RecursionError, non ValueError: qui
        # si scarta il file (nostro, verificato sopra) così il prossimo poll
        # riparte pulito invece di restare vuoto per sempre.
        try:
            os.unlink(path)
        except OSError:
            pass
        return {}


def _save_browser_cache(cache, live_pids=None, now=None):
    if now is None:
        now = time.time()
    path = _browser_cache_path()
    if not path:
        return
    pruned = {"_v": CACHE_VERSION}
    for k, v in cache.items():
        if k == "_v":
            continue
        if k.startswith("_"):
            pruned[k] = v
            continue
        if not isinstance(v, dict):
            continue
        pid = _as_int(k.split(":", 1)[0])
        if pid <= 0:
            continue
        if live_pids is not None:
            if pid not in live_pids:
                continue
        elif not os.path.exists("/proc/%d" % pid):
            continue
        ttl = (BROWSER_CACHE_TTL_RESOLVED
               if v.get("resolved")
               else BROWSER_CACHE_TTL_EMPTY)
        if now - _as_float(v.get("ts")) < ttl:
            pruned[k] = v
    # mkstemp: O_EXCL + 0600 + nome non prevedibile, e nessun symlink seguito.
    tmp_path = ""
    tmp_fd = None
    try:
        tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path),
                                            prefix=".hw_monitor_cache.",
                                            suffix=".tmp")
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as fh:
            tmp_fd = None
            json.dump(pruned, fh, ensure_ascii=True)
        os.replace(tmp_path, path)
        tmp_path = ""
    except (OSError, TypeError, ValueError):
        pass
    finally:
        if tmp_fd is not None:
            try:
                os.close(tmp_fd)
            except OSError:
                pass
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def _pid_starttime(pid):
    try:
        with open("/proc/%d/stat" % pid, "rb") as fh:
            info = fh.read(1024)
        rp = info.rfind(b")")
        if rp != -1:
            return int(info[rp + 2:].split(None, 20)[19])
    except (OSError, ValueError, IndexError):
        pass
    return 0


def _fit_label(comm, tag):
    """`comm [tag]` entro NAME_MAX, accorciando il tag: la parentesi chiude.

    Un tag accorciato si taglia su un punto e si chiude con `·`, così un host
    troncato non si legge come un host completo: senza il segno, un prefisso
    tipo `banca.example.aaa.evil.examp` sembra un dominio vero. La `·` non è in
    NAME_OK, quindi sanitize_name la sostituisce con se stessa e sopravvive.
    """
    room = NAME_MAX - len(comm) - 3
    if room < 3:
        return sanitize_name(comm)
    if len(tag) > room:
        cut = tag[:max(1, room - 1)]
        dot = cut.rfind(".")
        # Sole soglia `dot > 0` collassava un host tipo `x.bbb…` a `x·`,
        # buttando via 40 caratteri informativi: serve un punto che lasci
        # almeno due caratteri di etichetta prima.
        if dot > 1:
            cut = cut[:dot]
        tag = cut + "\u00b7"
    return sanitize_name("%s [%s]" % (comm, tag))


# Nessun latch globale sull'accesso a /proc/<pid>/mem. La leggibilità è una
# proprietà del singolo processo: i figli Chromium chiamano
# PR_SET_PTRACER_ANY e sono leggibili anche con yama ptrace_scope=1, mentre
# main/zygote/gpu non lo sono. Un latch faceva sì che un solo renderer
# illeggibile sopprimesse l'etichetta di TUTTI gli altri. Un open() fallito
# costa una syscall, e il budget vero è già dentro _scan_hosts (byte,
# regioni, scadenza).
#
# Resta però un accoppiamento sull'ORDINE, di tipo diverso: la scadenza è una
# sola, creata prima del ciclo delle righe e condivisa da tutti i _scan_hosts.
# Un renderer ostile può bruciarla (misurato: ~21 ms per 512 KiB, quindi fino
# a ~0,35 s degli 0,6 s con un buffer da 8 MiB) e le righe scandite dopo
# ricevono `[tab]` con TTL 10 s pur essendo perfettamente leggibili. Il latch
# non c'è più, ma "l'ordine non decide più chi perde l'etichetta" non sarebbe
# vero: decide ancora, per tempo invece che per booleano. Effetto: un hint
# degrada al suo fallback documentato.


def _scan_hosts(pid, deadline):
    """Host più frequente nella memoria del renderer, e se la scansione è finita.

    Contare gli URL avvantaggia i CDN, e pesare le "path da pagina" (provato)
    peggiora sul campo: i beacon pubblicitari hanno path corte e vincono. Con
    i dati reali il conteggio semplice resta il male minore; il limite noto è
    che un host di subrisorse molto usato può oscurare l'origin del tab.
    Budget su byte, regioni e tempo: il watchdog del chiamante è a 2 s.
    `complete=False` = campione troncato: il chiamante non lo cache come certo.
    """
    counts = {}
    complete = True
    try:
        mem = open("/proc/%d/mem" % pid, "rb", 0)
    except PermissionError:
        return counts, False
    except OSError:
        return counts, False
    try:
        with open("/proc/%d/maps" % pid, "r", encoding="utf-8", errors="ignore") as maps:
            scanned = 0
            regions = 0
            failures = 0
            for line in maps:
                if deadline is not None and time.monotonic() > deadline:
                    complete = False
                    break
                parts = line.split()
                if len(parts) < 2 or "r" not in parts[1]:
                    continue
                if len(parts) >= 6 and parts[5].startswith((
                    "/opt/", "/usr/", "/lib", "/dev/", "/home/", "/var/", "/run/", "/etc/"
                )):
                    continue
                addr = parts[0].split("-")
                if len(addr) != 2:
                    continue
                try:
                    start, end = int(addr[0], 16), int(addr[1], 16)
                except ValueError:
                    continue
                size = end - start
                if size < 65536 or size > 32 * 1024 * 1024:
                    continue
                regions += 1
                if regions > MEM_SCAN_MAX_REGIONS:
                    complete = False
                    break
                try:
                    mem.seek(start)
                    chunk = mem.read(min(size, MEM_SCAN_CHUNK))
                except PermissionError:
                    complete = False
                    break
                except OSError:
                    # Una regione sparita/illeggibile non invalida le altre.
                    failures += 1
                    if failures > 3:
                        complete = False
                        break
                    continue
                scanned += len(chunk)
                for found in URL_AUTH_RE.finditer(chunk):
                    auth = found.group(1)
                    end = found.end(1)
                    # Un prefisso non nasce solo dal tetto di 255 byte: se la
                    # cattura finisce esattamente sul bordo del chunk, l'authority
                    # può continuare oltre la finestra (`https://decoy.example`
                    # tagliato prima del vero `@banca.example`), quindi `auth` è
                    # un prefisso anche quando è più corto del tetto. Entrambi i
                    # casi si scartano: un'etichetta in meno è meglio di una
                    # civetta.
                    if end >= len(chunk):
                        continue
                    # Troncamento dovuto al tetto: si vede solo se il byte dopo
                    # sarebbe ancora entrato nell'authority. Un delimitatore
                    # (`/`, `?`, `#`, spazio, virgoletta, `<>`) la chiude, quindi
                    # la cattura è completa e va tenuta.
                    if len(auth) == 255 and _AUTH_MORE.match(chunk[end:end + 1]):
                        continue
                    raw_host = _authority_host(auth)
                    if raw_host is None:
                        continue
                    host = raw_host.decode("ascii", "ignore")
                    if host in IGNORE_BROWSER_HOSTS or host.endswith(IGNORE_BROWSER_SUFFIXES):
                        continue
                    if host not in counts and len(counts) >= SCAN_HOSTS_CAP:
                        # Cardinalità limitata: un renderer ostile può piantare
                        # centinaia di migliaia di host distinti nel budget di
                        # byte; oltre il tetto il campione è troncato (TTL corto).
                        complete = False
                        continue
                    counts[host] = counts.get(host, 0) + 1
                if scanned >= MEM_SCAN_MAX_BYTES:
                    complete = False
                    break
    except OSError:
        complete = False
    finally:
        try:
            mem.close()
        except OSError:
            pass
    return counts, complete


def _is_browser(comm):
    """`brave` ma anche `brave-browser` (nome del binario su alcune distro)."""
    base = comm.lower()
    return base in BROWSER_COMMS or base.split("-", 1)[0] in BROWSER_COMMS


def enrich_browser_label(pid, comm, cache=None, now=None, deadline=None):
    if not _is_browser(comm):
        return comm
    if now is None:
        now = time.time()
    own_cache = cache is None
    if own_cache:
        cache = _load_browser_cache()

    starttime = _pid_starttime(pid)
    cache_key = "%d:%d" % (pid, starttime) if starttime else ""
    if cache_key and cache_key in cache:
        entry = cache[cache_key]
        if isinstance(entry, dict):
            ttl = (BROWSER_CACHE_TTL_RESOLVED
                   if entry.get("resolved")
                   else BROWSER_CACHE_TTL_EMPTY)
            if now - _as_float(entry.get("ts")) < ttl:
                # Sanificata anche in lettura: il file non è input fidato.
                label = entry.get("label")
                if isinstance(label, str) and label:
                    return sanitize_name(label)

    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            raw_cmdline = fh.read(4096)
        cmdline = raw_cmdline.decode("utf-8", "ignore").replace("\0", " ")
    except OSError:
        return comm

    label = None
    resolved = True

    app_match = APP_AUTH_RE.search(cmdline)
    if app_match:
        # Stessa regola dell'host di memoria: il userinfo non è l'host. Qui il
        # tetto della cattura è in CARATTERI (pattern str), quindi il test di
        # troncamento si fa sulla cmdline, non sui byte codificati.
        app_auth = app_match.group(1)
        end = app_match.end(1)
        tail = cmdline[end:end + 1]
        truncated = False
        if tail:
            # Al tetto: troncata solo se il carattere dopo sarebbe ancora
            # entrato nell'authority. Spazio o virgoletta la chiudono, quindi
            # è completa; `/`, `?`, `#` pure.
            truncated = len(app_auth) == 255 and bool(_AUTH_MORE_STR.match(tail))
        elif len(raw_cmdline) >= 4096:
            # Nessun carattere dopo e la lettura ha toccato i 4096 byte:
            # l'authority può continuare nel cmdline troncato. Vale anche sotto
            # il tetto di 255 — un prefisso corto è comunque un prefisso.
            truncated = True
        if not truncated:
            raw_app = _authority_host(app_auth.encode("utf-8", "ignore"))
            host = raw_app.decode("ascii", "ignore") if raw_app else ""
            if host:
                label = _fit_label(comm, host)

    if label is None:
        ctype = CMD_TYPE_RE.search(cmdline)
        ctype = ctype.group(1).lower() if ctype else ""
        if "--extension-process" in cmdline:
            label = _fit_label(comm, "ext")
        elif ctype == "gpu-process":
            label = _fit_label(comm, "gpu")
        elif ctype == "utility":
            m = UTIL_SUB_RE.search(cmdline)
            sub = m.group(1).split(".")[-1].replace("Service", "").lower() if m else "util"
            label = _fit_label(comm, sub or "util")
        elif not ctype:
            # Nessun --type=: è il processo browser principale (o una PWA).
            label = _fit_label(comm, "app" if APP_ID_RE.search(cmdline) else "main")
        elif not ctype.startswith("renderer"):
            # zygote, crashpad-handler, ppapi...: ruolo esplicito, non "[main]".
            label = _fit_label(comm, ctype)

    if label is None:
        counts, complete = _scan_hosts(pid, deadline)
        if not counts:
            label, resolved = _fit_label(comm, "tab"), False
        else:
            top_host = max(counts, key=lambda h: counts[h])
            label = _fit_label(comm, top_host)
            # Campione troncato: etichetta usata, ma con TTL corto.
            resolved = complete

    if cache_key:
        cache[cache_key] = {"label": label, "ts": now, "resolved": resolved}
        if own_cache:
            _save_browser_cache(cache, now=now)
    return label


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
            # Solo i flag sopra: argv arriva già allowlistato dal chiamante e
            # ogni altro token è rumore, non un secondo canale di configurazione.
            i += 1
    top_n = max(TOP_MIN, min(TOP_MAX, top_n))

    try:
        page_kib = os.sysconf("SC_PAGE_SIZE") // 1024
    except (OSError, ValueError):
        page_kib = 4
    mem_total = read_mem_total_kib()

    cache = _load_browser_cache()
    now = time.time()
    prev_snap = cache.get("_snap")
    used_cached_snap = False

    if isinstance(prev_snap, dict):
        snap_age = now - _as_float(prev_snap.get("ts"))
        if 0.0 <= snap_age <= SNAP_CACHE_MAX_AGE:
            sys_b = read_sys_total()
            snap_b = snapshot_pids(group)
            prev_sys = _as_int(prev_snap.get("sys"))
            prev_cpus = prev_snap.get("cpus") or {}
            prev_base_sys = _as_int(prev_snap.get("prev_sys"))
            prev_base_cpus = prev_snap.get("prev_cpus") or {}
            if sys_b - prev_sys < 5 and prev_base_sys and prev_base_cpus:
                base_sys = prev_base_sys
                base_cpus = prev_base_cpus
            else:
                base_sys = prev_sys
                base_cpus = prev_cpus
            if sys_b >= base_sys > 0 and isinstance(base_cpus, dict) and base_cpus:
                sys_delta = sys_b - base_sys
                snap_a = {_as_int(k): (_as_int(v), 0, "", 0, "")
                          for k, v in base_cpus.items()}
                # Pid nati dopo la baseline: 0% invece di sparire dal panel.
                for pid, values in snap_b.items():
                    if pid not in snap_a:
                        snap_a[pid] = (values[0], 0, "", 0, "")
                if snap_age >= 1.5:
                    cache["_snap"] = {
                        "ts": now,
                        "sys": sys_b,
                        "cpus": {str(pid): vals[0] for pid, vals in snap_b.items()},
                        "prev_sys": base_sys,
                        "prev_cpus": base_cpus,
                    }
                used_cached_snap = True

    if not used_cached_snap:
        sys_a = read_sys_total()
        snap_a = snapshot_pids(group)
        time.sleep(SNAP_GAP_S)
        now = time.time()
        sys_b = read_sys_total()
        snap_b = snapshot_pids(group)
        sys_delta = sys_b - sys_a
        # Stessa regola del ramo in cache: un processo appena nato compare a 0%.
        for pid, values in snap_b.items():
            if pid not in snap_a:
                snap_a[pid] = (values[0], 0, "", 0, "")
        cache["_snap"] = {
            "ts": now,
            "sys": sys_b,
            "cpus": {str(pid): vals[0] for pid, vals in snap_b.items()},
            "prev_sys": sys_a,
            "prev_cpus": {str(pid): vals[0] for pid, vals in snap_a.items()},
        }

    rows, grouped_by = build_rows(snap_a, snap_b, sys_delta, mem_total,
                                  page_kib, group)
    key = (lambda r: r["rssKib"]) if sort == "ram" else (lambda r: r["cpu"])
    rows.sort(key=key, reverse=True)
    top_rows = rows[:top_n]
    if not group:
        deadline = time.monotonic() + MEM_SCAN_BUDGET_S
        for r in top_rows:
            r["name"] = sanitize_name(r["name"])
            if r.get("count", 1) == 1:
                r["name"] = enrich_browser_label(r["pid"], r["name"],
                                                 cache=cache, now=now,
                                                 deadline=deadline)
    out_str = json.dumps({"groupedBy": grouped_by,
                          "procs": top_rows},
                         ensure_ascii=True) + "\n"
    # Prima l'output, poi lo stato: un guaio nella cache non deve azzerare il panel.
    sys.stdout.write(out_str)
    _save_browser_cache(cache, live_pids=set(snap_b.keys()), now=now)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except BrokenPipeError:
        pass
    except Exception as exc:  # refuse-softly: mai traceback rumoroso
        sys.stderr.write("proc_top: %s\n" % exc)
        sys.stdout.write("{}\n")
