sudo tee /opt/mirako_orangepi_report.py >/dev/null <<'PY'
#!/usr/bin/env python3
import os, re, json, time, socket, shutil, platform, subprocess
from urllib import request

ENDPOINT_BASE = os.getenv("MIRAKO_ENDPOINT", "https://sophia.mirako.org/orangepi").rstrip("/")
TIMEOUT = int(os.getenv("MIRAKO_TIMEOUT", "10"))
POST_URL = f"{ENDPOINT_BASE}/agent.php"
AGENT = "mirako-inventory/2.1"

IS_DARWIN = (platform.system().lower() == "darwin")

def run(cmd, shell=False):
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            shell=shell,
        )
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as e:
        return 255, "", str(e)

def read_first(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return None

def get_hostname():
    return socket.gethostname()

def get_kernel():
    return platform.release()

# ---------------------------
# DNS / Default Route (macOS)
# ---------------------------
def get_default_route_macos():
    rc, out, _ = run(["netstat", "-rn", "-f", "inet"])
    if rc == 0 and out:
        for ln in out.splitlines():
            ln = ln.strip()
            if not ln or ln.startswith("Destination"):
                continue
            parts = ln.split()
            if parts and parts[0] == "default" and len(parts) >= 6:
                gw = parts[1]
                iface = parts[-1]
                return {"gateway": gw, "dev": iface, "raw": out[:4000]}
    rc, out, _ = run(["route", "-n", "get", "default"])
    if rc == 0 and out:
        gw = None
        iface = None
        for ln in out.splitlines():
            ln = ln.strip()
            if ln.startswith("gateway:"):
                gw = ln.split(":", 1)[1].strip()
            if ln.startswith("interface:"):
                iface = ln.split(":", 1)[1].strip()
        if gw or iface:
            return {"gateway": gw, "dev": iface, "raw": out[:4000]}
    return None

def get_dns_macos():
    rc, out, _ = run(["scutil", "--dns"])
    if rc != 0 or not out:
        return None
    servers = []
    search = []
    for ln in out.splitlines():
        ln = ln.strip()
        m = re.search(r"nameserver\[\d+\]\s*:\s*(\S+)", ln)
        if m:
            servers.append(m.group(1))
        m = re.search(r"search domain\[\d+\]\s*:\s*(\S+)", ln)
        if m:
            search.append(m.group(1))

    def dedup(xs):
        seen = set()
        outl = []
        for x in xs:
            if x not in seen:
                seen.add(x)
                outl.append(x)
        return outl

    servers = dedup(servers)
    search = dedup(search)
    return {"nameservers": servers, "search": search} if (servers or search) else None

# ---------------------------
# Interfaces (macOS)
# ---------------------------
def parse_ifconfig_macos():
    rc, out, _ = run(["ifconfig", "-a"])
    if rc != 0 or not out:
        return []

    interfaces = []
    cur = None

    def mask_hex_to_prefix(nm_hex):
        # nm_hex: "0xffffff00"
        try:
            if not nm_hex.startswith("0x"):
                return None
            mask = int(nm_hex, 16)
            return bin(mask).count("1")
        except Exception:
            return None

    def flush():
        nonlocal cur
        if cur and cur.get("ifname") and cur["ifname"] != "lo0":
            if not cur.get("addrs"):
                cur["addrs"] = []
            interfaces.append(cur)
        cur = None

    for ln in out.splitlines():
        if not ln:
            continue

        m = re.match(r"^([a-zA-Z0-9_.:-]+):\s+flags=", ln)
        if m:
            flush()
            cur = {"ifname": m.group(1), "state": None, "mtu": None, "mac": None, "addrs": [], "stats": None}
            m2 = re.search(r"\bmtu\s+(\d+)", ln)
            if m2:
                cur["mtu"] = int(m2.group(1))
            continue

        if cur is None:
            continue

        s = ln.strip()

        m = re.match(r"^ether\s+([0-9a-f:]{17})", s, re.I)
        if m:
            cur["mac"] = m.group(1).lower()
            continue

        m = re.match(r"^status:\s+(\S+)", s, re.I)
        if m:
            cur["state"] = m.group(1)
            continue

        # ✅ IPv4 normal: inet A.B.C.D netmask 0xffffff00 ...
        # ✅ IPv4 point-to-point: inet A.B.C.D --> P.Q.R.S netmask 0xfffffffc
        m = re.match(r"^inet\s+(\d+\.\d+\.\d+\.\d+)(?:\s+-->\s+(\d+\.\d+\.\d+\.\d+))?\s+netmask\s+(\S+)", s)
        if m:
            ip = m.group(1)
            peer = m.group(2)
            nm = m.group(3)
            prefixlen = mask_hex_to_prefix(nm) if nm.startswith("0x") else None
            obj = {"family": "inet", "ip": ip, "prefixlen": prefixlen, "scope": None, "label": None, "broadcast": None}
            if peer:
                obj["peer"] = peer
            cur["addrs"].append(obj)
            continue

        m = re.match(r"^inet6\s+([0-9a-f:]+)(?:%[a-zA-Z0-9_.:-]+)?\s+prefixlen\s+(\d+)", s, re.I)
        if m:
            ip6 = m.group(1)
            pl = int(m.group(2))
            scope = "link" if ip6.lower().startswith("fe80:") else "global"
            cur["addrs"].append({"family": "inet6", "ip": ip6, "prefixlen": pl, "scope": scope, "label": None, "broadcast": None})
            continue

    flush()

    rc, ib, _ = run(["netstat", "-ib"])
    if rc == 0 and ib:
        lines = ib.splitlines()
        if lines:
            header = re.split(r"\s+", lines[0].strip())
            idx = {k: i for i, k in enumerate(header)}
            for ln in lines[1:]:
                cols = re.split(r"\s+", ln.strip())
                if not cols:
                    continue
                name = cols[0]
                def get_int(col):
                    try:
                        return int(cols[idx[col]]) if col in idx and idx[col] < len(cols) else None
                    except Exception:
                        return None
                st = {
                    "rx_packets": get_int("Ipkts"),
                    "tx_packets": get_int("Opkts"),
                    "rx_bytes": get_int("Ibytes"),
                    "tx_bytes": get_int("Obytes"),
                }
                if all(v is None for v in st.values()):
                    continue
                for iface in interfaces:
                    if iface.get("ifname") == name:
                        old = iface.get("stats") or {}
                        newst = {}
                        for k in ["rx_packets","tx_packets","rx_bytes","tx_bytes"]:
                            nv = st.get(k)
                            ov = old.get(k)
                            if nv is None:
                                newst[k] = ov
                            elif ov is None:
                                newst[k] = nv
                            else:
                                newst[k] = max(ov, nv)
                        iface["stats"] = newst
                        break

    return interfaces

def pick_primary_ip_from_interfaces(interfaces, want_dev=None):
    def first_ipv4(iface):
        for a in (iface.get("addrs") or []):
            if a.get("family") == "inet":
                ip = a.get("ip")
                if ip and ip != "127.0.0.1":
                    return ip
        return None

    if want_dev:
        for i in interfaces:
            if i.get("ifname") == want_dev:
                v = first_ipv4(i)
                if v:
                    return v
    for i in interfaces:
        v = first_ipv4(i)
        if v:
            return v
    return None

def get_mac_primary_from_interfaces(interfaces, want_dev=None):
    if want_dev:
        for i in interfaces:
            if i.get("ifname") == want_dev and i.get("mac"):
                return {"iface": want_dev, "mac": i["mac"]}
    for i in interfaces:
        mac = i.get("mac")
        if mac and mac != "00:00:00:00:00:00":
            return {"iface": i.get("ifname"), "mac": mac}
    return None

# ---------------------------
# CPU / Mem / Uptime (macOS)
# ---------------------------
def sysctl_value(key):
    rc, out, _ = run(["sysctl", "-n", key])
    if rc == 0 and out:
        return out.strip()
    return None

def get_cpu_info_macos():
    brand = sysctl_value("machdep.cpu.brand_string") or sysctl_value("hw.model")
    cores = sysctl_value("hw.ncpu")
    freq_hz = sysctl_value("hw.cpufrequency")
    freq_mhz = None
    try:
        if freq_hz and freq_hz.isdigit():
            freq_mhz = int(freq_hz) / 1_000_000.0
    except Exception:
        pass
    try:
        cores_i = int(cores) if cores and cores.isdigit() else None
    except Exception:
        cores_i = None
    return {"model": brand, "cores": cores_i, "freq_mhz": freq_mhz, "arch": platform.machine()}

def get_uptime_seconds_macos():
    rc, out, _ = run(["sysctl", "-n", "kern.boottime"])
    if rc != 0 or not out:
        return None
    m = re.search(r"sec\s*=\s*(\d+)", out)
    if not m:
        return None
    boot = int(m.group(1))
    return float(max(0, int(time.time()) - boot))

def get_loadavg_macos():
    try:
        la = os.getloadavg()
        return {"1m": float(la[0]), "5m": float(la[1]), "15m": float(la[2])}
    except Exception:
        return None

def get_mem_macos():
    memsize = sysctl_value("hw.memsize")
    total_kb = None
    try:
        if memsize and memsize.isdigit():
            total_kb = int(memsize) // 1024
    except Exception:
        total_kb = None

    rc, out, _ = run(["vm_stat"])
    if rc != 0 or not out:
        return {"mem_total_kb": total_kb}

    page_size = 4096
    mps = re.search(r"page size of (\d+) bytes", out)
    if mps:
        page_size = int(mps.group(1))

    pages = {}
    for ln in out.splitlines():
        m = re.match(r"^(.+?):\s+(\d+)\.", ln.strip())
        if not m:
            continue
        k = m.group(1).strip().lower()
        pages[k] = int(m.group(2))

    free_pages = pages.get("pages free", 0) + pages.get("pages speculative", 0)
    active_pages = pages.get("pages active", 0)
    inactive_pages = pages.get("pages inactive", 0)
    wired_pages = pages.get("pages wired down", 0)
    compressed_pages = pages.get("pages occupied by compressor", 0)

    free_kb = (free_pages * page_size) // 1024
    used_kb = ((active_pages + inactive_pages + wired_pages + compressed_pages) * page_size) // 1024

    return {
        "mem_total_kb": total_kb,
        "mem_free_kb": free_kb,
        "mem_available_kb": free_kb,
        "buffers_kb": None,
        "cached_kb": None,
        "swap_total_kb": None,
        "swap_free_kb": None,
        "mac_vm": {
            "page_size": page_size,
            "pages_free": free_pages,
            "pages_active": active_pages,
            "pages_inactive": inactive_pages,
            "pages_wired": wired_pages,
            "pages_compressed": compressed_pages,
            "used_kb_approx": used_kb,
        }
    }

def get_temp_c_macos():
    rc, out, _ = run(["bash", "-lc", "command -v osx-cpu-temp >/dev/null 2>&1 && osx-cpu-temp || true"])
    m = re.search(r"([\d.]+)\s*°?C", out or "")
    if m:
        try:
            return float(m.group(1))
        except Exception:
            return None
    return None

# ---------------------------
# Disk / Processes / Raw (common)
# ---------------------------
def get_disk():
    out = {"root": None, "mounts": []}
    try:
        u = shutil.disk_usage("/")
        out["root"] = {"total": u.total, "used": u.used, "free": u.free}
    except Exception:
        pass

    if IS_DARWIN:
        rc, dfout, _ = run(["df", "-k"])
        if rc == 0 and dfout:
            lines = dfout.splitlines()
            for ln in lines[1:]:
                parts = ln.split()
                if len(parts) < 9:
                    continue
                fs, total, used, avail, cap, mnt = parts[0], parts[1], parts[2], parts[3], parts[4], parts[-1]
                try:
                    out["mounts"].append({
                        "fs": fs,
                        "type": None,
                        "mount": mnt,
                        "total": int(total) * 1024,
                        "used": int(used) * 1024,
                        "avail": int(avail) * 1024,
                        "usep": cap,
                    })
                except Exception:
                    pass
    else:
        rc, dfout, _ = run(["df", "-B1", "-T"])
        if rc == 0 and dfout:
            lines = dfout.splitlines()
            for ln in lines[1:]:
                parts = ln.split()
                if len(parts) < 7:
                    continue
                fs, fstype, total, used, avail, usep, mnt = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]
                if fstype in ("tmpfs", "devtmpfs", "overlay", "squashfs"):
                    continue
                try:
                    out["mounts"].append({
                        "fs": fs,
                        "type": fstype,
                        "mount": mnt,
                        "total": int(total),
                        "used": int(used),
                        "avail": int(avail),
                        "usep": usep,
                    })
                except Exception:
                    pass

    return out

def get_top_processes(limit=25):
    cmd = ["ps", "-eo", "pid,user,pcpu,pmem,etime,comm,args", "--sort=-pcpu"]
    rc, out, _ = run(cmd)
    if rc != 0 or not out:
        rc, out, _ = run(["ps", "-axo", "pid,user,%cpu,%mem,etime,comm,args"])
        if rc != 0 or not out:
            return None

    lines = out.splitlines()
    procs = []
    for ln in lines[1:]:
        parts = ln.strip().split(None, 6)
        if len(parts) < 6:
            continue
        pid, user, pcpu, pmem, etime, comm = parts[:6]
        args = parts[6] if len(parts) >= 7 else ""
        try:
            procs.append({
                "pid": int(pid),
                "user": user,
                "cpu": float(pcpu),
                "mem": float(pmem),
                "etime": etime,
                "comm": comm,
                "args": args[:400],
            })
        except Exception:
            pass
        if len(procs) >= limit:
            break
    return procs

def get_raw_commands_snapshot():
    snap = {}
    if IS_DARWIN:
        rc, out, _ = run(["ifconfig", "-a"])
        if out: snap["ifconfig_or_ipaddr"] = out[:20000]
        rc, out, _ = run(["bash", "-lc", "top -l 1 -n 0 | head -n 120"])
        if out: snap["top_head"] = out[:20000]
        rc, out, _ = run(["bash", "-lc", "netstat -rn; echo '---'; netstat -rn -f inet6"])
        if out: snap["routes"] = out[:20000]
        rc, out, _ = run(["scutil", "--dns"])
        if out: snap["dns_scutil"] = out[:20000]
    else:
        rc, out, _ = run(["bash", "-lc", "command -v ifconfig >/dev/null 2>&1 && ifconfig -a || ip addr show"])
        if out: snap["ifconfig_or_ipaddr"] = out[:20000]
        rc, out, _ = run(["bash", "-lc", "top -b -n 1 | head -n 120"])
        if out: snap["top_head"] = out[:20000]
        rc, out, _ = run(["bash", "-lc", "ip route show; echo '---'; ip -6 route show"])
        if out: snap["routes"] = out[:20000]
    return snap or None

# ---------------------------
# Linux implementations
# ---------------------------
def get_os_release_linux():
    txt = read_first("/etc/os-release") or ""
    info = {}
    for line in txt.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k.strip()] = v.strip().strip('"')
    return info or None

def get_uptime_seconds_linux():
    s = read_first("/proc/uptime")
    if not s:
        return None
    try:
        return float(s.split()[0])
    except Exception:
        return None

def get_loadavg_linux():
    try:
        parts = (read_first("/proc/loadavg") or "").split()
        return {"1m": float(parts[0]), "5m": float(parts[1]), "15m": float(parts[2])}
    except Exception:
        return None

def get_cpu_info_linux():
    cpuinfo = read_first("/proc/cpuinfo") or ""
    model = None
    hardware = None
    cores = 0
    for line in cpuinfo.splitlines():
        low = line.lower()
        if low.startswith("model name"):
            model = line.split(":", 1)[1].strip()
        if low.startswith("hardware"):
            hardware = line.split(":", 1)[1].strip()
        if low.startswith("processor"):
            cores += 1
    freq = None
    for p in [
        "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq",
        "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq",
    ]:
        v = read_first(p)
        if v and v.isdigit():
            try:
                khz = int(v)
                freq = khz / 1000.0
                break
            except Exception:
                pass
    return {
        "model": model or hardware or platform.processor() or None,
        "cores": cores or None,
        "freq_mhz": freq,
        "arch": platform.machine(),
    }

def get_temp_c_linux():
    for p in ["/sys/class/thermal/thermal_zone0/temp", "/sys/class/thermal/thermal_zone1/temp"]:
        s = read_first(p)
        if not s:
            continue
        try:
            v = float(s)
            if v > 200:
                v /= 1000.0
            if 0 <= v <= 150:
                return v
        except Exception:
            pass
    return None

def get_mem_linux():
    mi = read_first("/proc/meminfo") or ""
    m = {}
    for line in mi.splitlines():
        if ":" not in line:
            continue
        k, rest = line.split(":", 1)
        parts = rest.strip().split()
        if not parts:
            continue
        try:
            m[k] = int(parts[0])
        except Exception:
            pass

    def kb(key): return m.get(key)

    return {
        "mem_total_kb": kb("MemTotal"),
        "mem_free_kb": kb("MemFree"),
        "mem_available_kb": kb("MemAvailable"),
        "buffers_kb": kb("Buffers"),
        "cached_kb": kb("Cached"),
        "swap_total_kb": kb("SwapTotal"),
        "swap_free_kb": kb("SwapFree"),
    }

def get_default_route_linux():
    rc, out, _ = run(["ip", "route", "show", "default"])
    if rc != 0 or not out:
        return None
    m = re.search(r"default via (\S+) dev (\S+)", out)
    if not m:
        return {"raw": out}
    return {"gateway": m.group(1), "dev": m.group(2), "raw": out}

def get_dns_linux():
    txt = read_first("/etc/resolv.conf") or ""
    servers = []
    search = []
    for ln in txt.splitlines():
        ln = ln.strip()
        if ln.startswith("nameserver"):
            parts = ln.split()
            if len(parts) >= 2:
                servers.append(parts[1])
        if ln.startswith("search"):
            parts = ln.split()
            search += parts[1:]
    return {"nameservers": servers, "search": search} if (servers or search) else None

def get_ip_addr_full_linux():
    rc, out, _ = run(["ip", "-j", "addr", "show"])
    if rc != 0 or not out:
        return None
    try:
        data = json.loads(out)
    except Exception:
        return None

    interfaces = []
    for iface in data:
        ifname = iface.get("ifname")
        if ifname == "lo":
            continue
        addrs = []
        for a in iface.get("addr_info", []):
            fam = a.get("family")
            local = a.get("local")
            if not local:
                continue
            addrs.append({
                "family": fam,
                "ip": local,
                "prefixlen": a.get("prefixlen"),
                "scope": a.get("scope"),
                "label": a.get("label"),
                "broadcast": a.get("broadcast"),
            })

        mac = read_first(f"/sys/class/net/{ifname}/address")
        mtu = iface.get("mtu")
        state = iface.get("operstate") or iface.get("state")

        stats = {}
        for k in ["rx_bytes","rx_packets","rx_errors","rx_dropped","tx_bytes","tx_packets","tx_errors","tx_dropped"]:
            v = read_first(f"/sys/class/net/{ifname}/statistics/{k}")
            if v and v.isdigit():
                stats[k] = int(v)

        interfaces.append({
            "ifname": ifname,
            "state": state,
            "mtu": mtu,
            "mac": mac,
            "addrs": addrs,
            "stats": stats or None,
        })
    return interfaces

# ---------------------------
# Payload builder
# ---------------------------
def build_payload():
    hostname = get_hostname()

    if IS_DARWIN:
        osr = {
            "pretty": f"macOS {platform.mac_ver()[0]}",
            "name": "macOS",
            "version": platform.mac_ver()[0],
            "id": "macos",
            "version_id": platform.mac_ver()[0],
        }

        dr = get_default_route_macos() or {}
        interfaces = parse_ifconfig_macos() or []
        ip_primary = pick_primary_ip_from_interfaces(interfaces, want_dev=dr.get("dev"))
        macp = get_mac_primary_from_interfaces(interfaces, want_dev=dr.get("dev"))

        uptime_s = get_uptime_seconds_macos()
        loadavg = get_loadavg_macos()
        cpu = get_cpu_info_macos()
        temp_c = get_temp_c_macos()
        mem = get_mem_macos()
        dns = get_dns_macos()

    else:
        osrl = get_os_release_linux() or {}
        osr = {
            "pretty": osrl.get("PRETTY_NAME"),
            "name": osrl.get("NAME"),
            "version": osrl.get("VERSION"),
            "id": osrl.get("ID"),
            "version_id": osrl.get("VERSION_ID"),
        }

        dr = get_default_route_linux() or {}
        interfaces = get_ip_addr_full_linux() or []
        ip_primary = pick_primary_ip_from_interfaces(interfaces, want_dev=dr.get("dev"))
        macp = get_mac_primary_from_interfaces(interfaces, want_dev=dr.get("dev"))

        uptime_s = get_uptime_seconds_linux()
        loadavg = get_loadavg_linux()
        cpu = get_cpu_info_linux()
        temp_c = get_temp_c_linux()
        mem = get_mem_linux()
        dns = get_dns_linux()

    if macp and macp.get("mac"):
        device_id = f"{hostname}-{macp['mac'].replace(':','')}"
    else:
        device_id = hostname

    payload = {
        "device_id": device_id,
        "hostname": hostname,
        "ts": int(time.time()),
        "status": "online",
        "agent": AGENT,

        "os": osr,
        "kernel": get_kernel(),
        "arch": platform.machine(),

        "ip": ip_primary,
        "interfaces": interfaces,
        "mac": macp,

        "default_route": dr if dr else None,
        "dns": dns,

        "uptime_s": uptime_s,
        "loadavg": loadavg,
        "cpu": cpu,
        "temp_c": temp_c,

        "mem": mem,
        "disk": get_disk(),

        "processes": get_top_processes(limit=25),

        "raw": get_raw_commands_snapshot(),
    }

    return payload

def post_json(url, payload):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json; charset=utf-8")
    req.add_header("User-Agent", AGENT)
    with request.urlopen(req, timeout=TIMEOUT) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
        return resp.status, raw

def main():
    payload = build_payload()
    try:
        code, raw = post_json(POST_URL, payload)
        if 200 <= code < 300:
            print(f"OK {code}: {raw}")
            return 0
        print(f"HTTP {code}: {raw}")
        return 2
    except Exception as e:
        print(f"ERROR: {e}")
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
PY







sudo tee /etc/systemd/system/mirako-orangepi-report.service >/dev/null <<'EOF'
[Unit]
Description=Mirako OrangePi inventory reporter (send hw/net info to VPS) every 5 minutes
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Environment="MIRAKO_ENDPOINT=https://sophia.mirako.org/orangepi"
Environment="MIRAKO_TIMEOUT=10"
ExecStart=/bin/bash -lc 'while true; do /usr/bin/python3 /opt/mirako_orangepi_report.py; sleep 300; done'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF






sudo systemctl daemon-reload
sudo systemctl enable --now mirako-orangepi-report.service
sudo systemctl status mirako-orangepi-report.service --no-pager
sudo journalctl -u mirako-orangepi-report.service -n 50 --no-pager





macOS





sudo nano /opt/mirako_orangepi_report.py


sudo /usr/bin/python3 - <<'PY'
import plistlib, os

path = "/Library/LaunchDaemons/org.mirako.orangepi.report.plist"

plist = {
  "Label": "org.mirako.orangepi.report",
  "ProgramArguments": ["/usr/bin/python3", "/opt/mirako_orangepi_report.py"],
  "EnvironmentVariables": {
    "MIRAKO_ENDPOINT": "https://sophia.mirako.org/orangepi",
    "MIRAKO_TIMEOUT": "10",
  },
  "StartInterval": 300,
  "RunAtLoad": True,
  "StandardOutPath": "/var/log/mirako-orangepi-report.log",
  "StandardErrorPath": "/var/log/mirako-orangepi-report.err",
  "ProcessType": "Background",
}

with open(path, "wb") as f:
  plistlib.dump(plist, f, fmt=plistlib.FMT_XML)

os.chown(path, 0, 0)      # root:wheel (wheel geralmente gid 0 no mac)
os.chmod(path, 0o644)

print("Wrote:", path)
PY

sudo chown root:wheel /Library/LaunchDaemons/org.mirako.orangepi.report.plist
sudo chmod 644 /Library/LaunchDaemons/org.mirako.orangepi.report.plist

plutil -lint /Library/LaunchDaemons/org.mirako.orangepi.report.plist



sudo launchctl bootstrap system /Library/LaunchDaemons/org.mirako.orangepi.report.plist
sudo launchctl enable system/org.mirako.orangepi.report
sudo launchctl kickstart -k system/org.mirako.orangepi.report





sudo launchctl print system/org.mirako.orangepi.report
tail -n 200 /var/log/mirako-orangepi-report.log
tail -n 200 /var/log/mirako-orangepi-report.err





