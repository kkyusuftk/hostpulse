# HostPulse collector. HostPulse pipes this script to the remote machine:
#
#     ssh <host> sh -s -- <probe path relative to $HOME> <full: 0|1>
#
# Plain POSIX sh + awk, read-only, works on macOS and Linux. Everything after the
# "@@HOSTPULSE" marker is key=value lines; list items use "|" between fields.

LC_ALL=C
export LC_ALL
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH
export PATH

PROBE=$1
FULL=$2

echo "@@HOSTPULSE 1"
echo "os=$(uname -s)"
echo "arch=$(uname -m)"
echo "hostname=$(hostname 2>/dev/null || uname -n)"
echo "now=$(date +%s)"

# ---------------------------------------------------------------- macOS ---

darwin() {
    probe_out=""
    probe_pid=""
    if [ -n "$PROBE" ] && [ -x "$HOME/$PROBE" ]; then
        probe_out=$(mktemp "${TMPDIR:-/tmp}/hostpulse.XXXXXX" 2>/dev/null)
        if [ -n "$probe_out" ]; then
            "$HOME/$PROBE" >"$probe_out" 2>/dev/null &
            probe_pid=$!
        fi
    else
        echo "probe=missing"
    fi

    echo "os.name=$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
    echo "model.id=$(sysctl -n hw.model 2>/dev/null)"
    echo "cpu.model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    echo "cpu.count=$(sysctl -n hw.ncpu 2>/dev/null)"
    p=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null) && [ -n "$p" ] && echo "cpu.pcores=$p"
    e=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null) && [ -n "$e" ] && echo "cpu.ecores=$e"
    sysctl -n vm.loadavg 2>/dev/null | awk '{ print "load=" $2 "|" $3 "|" $4 }'
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\).*/\1/p')
    [ -n "$boot" ] && echo "uptime=$(($(date +%s) - boot))"

    if [ "$FULL" = 1 ]; then
        system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '
            /Model Name:/ { print "model.name=" $2 }
            /Chip:/ { print "model.chip=" $2 }'
    fi

    # Memory, the way Activity Monitor counts it: app + wired + compressed.
    vm_stat 2>/dev/null | awk -v total="$(sysctl -n hw.memsize 2>/dev/null)" '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) }
        /^Pages free:/ { free = $3 + 0 }
        /^Pages wired down:/ { wired = $4 + 0 }
        /^Pages purgeable:/ { purge = $3 + 0 }
        /^File-backed pages:/ { file = $3 + 0 }
        /^Anonymous pages:/ { anon = $3 + 0 }
        /^Pages occupied by compressor:/ { comp = $5 + 0 }
        END {
            if (!ps || !total) exit
            app = (anon - purge) * ps; w = wired * ps; c = comp * ps
            printf "mem.total=%.0f\nmem.used=%.0f\nmem.app=%.0f\nmem.wired=%.0f\nmem.compressed=%.0f\nmem.cached=%.0f\n",
                total, app + w + c, app, w, c, (file + purge) * ps
        }'
    sysctl -n vm.swapusage 2>/dev/null | awk '
        function bytes(v) { u = substr(v, length(v)); n = v + 0
            return u == "G" ? n * 1073741824 : u == "M" ? n * 1048576 : u == "K" ? n * 1024 : n }
        { printf "swap.total=%.0f\nswap.used=%.0f\n", bytes($3), bytes($6) }'
    case $(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null) in
        1) echo "mem.pressure=normal" ;;
        2) echo "mem.pressure=warning" ;;
        4) echo "mem.pressure=critical" ;;
    esac

    gpu=$(ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null | sed -n 's/.*"Device Utilization %"=\([0-9]*\).*/\1/p' | head -n 1)
    [ -n "$gpu" ] && echo "gpu.usage=$gpu"

    { df -kP /System/Volumes/Data 2>/dev/null || df -kP /; } |
        awk 'NR == 2 { printf "disk.total=%.0f\ndisk.used=%.0f\n", $2 * 1024, ($2 - $4) * 1024 }'

    iface=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
    if [ -n "$iface" ]; then
        echo "net.iface=$iface"
        netstat -ibn 2>/dev/null | awk -v i="$iface" '$1 == i && $3 ~ /^<Link/ { print "net.rx=" $(NF - 4); print "net.tx=" $(NF - 1); exit }'
        port=$(networksetup -listallhardwareports 2>/dev/null | awk -v i="$iface" '
            /^Hardware Port:/ { sub(/^Hardware Port: /, ""); p = $0 }
            /^Device:/ && $2 == i { print p; exit }')
        [ -n "$port" ] && echo "net.port=$port"
        ip=$(ipconfig getifaddr "$iface" 2>/dev/null) && [ -n "$ip" ] && echo "net.ip=$ip"
    fi

    # CPU usage and the three busiest processes from the second of two top samples
    # (the first sample has no CPU deltas). ps supplies untruncated names.
    top_out=$(top -l 2 -n 6 -o cpu -s 1 -stats pid,cpu,command 2>/dev/null)
    printf '%s\n' "$top_out" | awk '
        /^CPU usage:/ { n++; if (n == 2) { gsub(/%/, ""); print "cpu.user=" $3; print "cpu.sys=" $5; print "cpu.idle=" $7 } }'
    procs=$(printf '%s\n' "$top_out" | awk '
        /^PID/ { h++; next }
        h == 2 && $1 ~ /^[0-9]+$/ { pid = $1; cpu = $2; sub(/^ *[0-9]+ +[0-9.]+ +/, ""); sub(/ +$/, "")
            if ($0 == "top" || $0 ~ /^hostpulse-pro/) next  # our own sampling
            if (++k <= 3) print pid "|" cpu "|" $0 }')
    pids=$(printf '%s\n' "$procs" | cut -d'|' -f1 | paste -sd, -)
    {
        printf '%s\n' "$procs"
        echo "--"
        [ -n "$pids" ] && ps -o pid=,rss=,comm= -p "$pids" 2>/dev/null
    } | awk -F'|' '
        $0 == "--" { part = 2; FS = " "; next }
        part != 2 && NF >= 3 { order[++n] = $1; cpu[$1] = $2; short[$1] = $3; next }
        part == 2 { pid = $1; rss[pid] = $2 * 1024; sub(/^ *[0-9]+ +[0-9]+ +/, ""); sub(/.*\//, ""); name[pid] = $0 }
        END { for (i = 1; i <= n; i++) { p = order[i]; nm = (p in name && name[p] != "") ? name[p] : short[p]
            printf "proc=%s|%s|%.0f|%s\n", p, cpu[p], rss[p] + 0, nm } }'

    if [ -n "$probe_pid" ]; then
        i=0
        while kill -0 "$probe_pid" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
        kill "$probe_pid" 2>/dev/null
        echo "probe=ok"
        cat "$probe_out"
    elif [ "$FULL" = 1 ]; then
        # No probe: slower system_profiler fallback for Wi-Fi, on full polls only.
        system_profiler SPAirPortDataType 2>/dev/null | awk '
            /Current Network Information:/ { getline; sub(/^ +/, ""); sub(/:$/, ""); print "wifi.ssid=" $0; cur = 1; next }
            cur && /Signal \/ Noise:/ { print "wifi.rssi=" $4; print "wifi.noise=" $7 }
            cur && /Transmit Rate:/ { print "wifi.tx=" $3 }
            cur && /Channel:/ { print "wifi.channel=" $2 }
            cur && /Other Local Wi-Fi Networks:/ { exit }'
    fi
    [ -n "$probe_out" ] && rm -f "$probe_out"
}

# ---------------------------------------------------------------- Linux ---

linux() {
    [ -r /etc/os-release ] && echo "os.name=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
    model=$({ cat /sys/devices/virtual/dmi/id/product_name || tr -d '\0' </proc/device-tree/model; } 2>/dev/null)
    [ -n "$model" ] && echo "model.name=$model"
    cpu_model=$(awk -F': ' '/^model name|^Model|^Hardware/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)
    [ -z "$cpu_model" ] && command -v lscpu >/dev/null 2>&1 &&
        cpu_model=$(lscpu 2>/dev/null | awk -F': *' '/^Model name/ && $2 != "-" { print $2; exit }')
    [ -n "$cpu_model" ] && echo "cpu.model=$cpu_model"
    echo "cpu.count=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
    awk '{ print "load=" $1 "|" $2 "|" $3 }' /proc/loadavg 2>/dev/null
    awk '{ printf "uptime=%d\n", $1 }' /proc/uptime 2>/dev/null

    awk '
        /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } /^MemFree:/ { f = $2 } /^Buffers:/ { b = $2 }
        /^Cached:/ { c = $2 } /^SReclaimable:/ { r = $2 } /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
        END {
            if (a == "") a = f + b + c + r
            printf "mem.total=%.0f\nmem.used=%.0f\nmem.cached=%.0f\nswap.total=%.0f\nswap.used=%.0f\n",
                t * 1024, (t - a) * 1024, (b + c + r) * 1024, st * 1024, (st - sf) * 1024
        }' /proc/meminfo

    df -kP / 2>/dev/null | awk 'NR == 2 { printf "disk.total=%.0f\ndisk.used=%.0f\n", $2 * 1024, ($2 - $4) * 1024 }'

    iface=$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route 2>/dev/null)
    if [ -n "$iface" ]; then
        echo "net.iface=$iface"
        sed 's/^ *//' /proc/net/dev | awk -F'[: ]+' -v i="$iface" '$1 == i { print "net.rx=" $2; print "net.tx=" $10 }'
        if [ -d "/sys/class/net/$iface/wireless" ] || grep -q "^ *$iface:" /proc/net/wireless 2>/dev/null; then
            echo "net.port=Wi-Fi"
        else
            echo "net.port=Ethernet"
        fi
        ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
        [ -n "$ip" ] && echo "net.ip=$ip"
    fi

    # Wi-Fi link (no root needed).
    wif=$(awk 'NR > 2 { sub(/:$/, "", $1); print $1; exit }' /proc/net/wireless 2>/dev/null)
    if [ -n "$wif" ]; then
        echo "wifi.iface=$wif"
        awk -v i="$wif" 'NR > 2 { n = $1; sub(/:$/, "", n); if (n == i) { print "wifi.rssi=" $4 + 0; if ($5 + 0 > -256) print "wifi.noise=" $5 + 0 } }' /proc/net/wireless
        if command -v iw >/dev/null 2>&1; then
            iw dev "$wif" link 2>/dev/null | awk '
                /SSID:/ { sub(/^[ \t]*SSID: /, ""); print "wifi.ssid=" $0 }
                /freq:/ { f = $2 + 0; print "wifi.band=" (f >= 5925 ? "6" : f >= 4900 ? "5" : "2.4") }
                /tx bitrate:/ { print "wifi.tx=" $3 + 0 }'
        elif command -v iwgetid >/dev/null 2>&1; then
            echo "wifi.ssid=$(iwgetid -r 2>/dev/null)"
        fi
    fi

    # Temperatures and fans from hwmon (millidegrees), thermal zones as a fallback.
    {
        for h in /sys/class/hwmon/hwmon*; do
            [ -r "$h/name" ] || continue
            n=$(cat "$h/name" 2>/dev/null)
            for t in "$h"/temp*_input; do
                [ -r "$t" ] || continue
                l=$(cat "${t%_input}_label" 2>/dev/null)
                echo "T|$n|$l|$(cat "$t" 2>/dev/null)"
            done
            for f in "$h"/fan*_input; do
                [ -r "$f" ] && echo "F|$n||$(cat "$f" 2>/dev/null)"
            done
        done
        for z in /sys/class/thermal/thermal_zone*; do
            [ -r "$z/temp" ] && echo "Z|$(cat "$z/type" 2>/dev/null)||$(cat "$z/temp" 2>/dev/null)"
        done
    } | awk -F'|' '
        function add(g, v) { if (v <= 5 || v >= 130) return; s[g] += v; c[g]++; if (v > m[g]) m[g] = v; if (g != "other" && v > hot) { hot = v; hotn = lbl } }
        $1 == "F" { if ($4 + 0 > 0) printf "fan=%d|%d|0|0\n", fans++, $4; next }
        {
            n = tolower($2); l = tolower($3); v = $4 / 1000; lbl = $2 ($3 != "" ? " " $3 : "")
            if ($1 == "Z") { zone = 1; if (n ~ /cpu|x86_pkg|soc|package/) zc[++nz] = v; else if (n ~ /gpu/) zg[++ng] = v; next }
            if (n ~ /coretemp|k10temp|zenpower|cpu|soc/) {
                if (l ~ /package|tdie|tctl/ || l == "") pk = (v > pk ? v : pk)
                add("cpu", v)
            } else if (n ~ /amdgpu|nouveau|radeon|gpu/) add("gpu", v)
            else if (n ~ /nvme|drivetemp/) add("ssd", v)
            else add("other", v)
        }
        END {
            if (!c["cpu"]) for (i = 1; i <= nz; i++) { lbl = "cpu"; add("cpu", zc[i]) }
            if (!c["gpu"]) for (i = 1; i <= ng; i++) { lbl = "gpu"; add("gpu", zg[i]) }
            if (c["cpu"]) printf "temp.cpu=%.1f\ntemp.cpu_max=%.1f\n", (pk > 0 ? pk : s["cpu"] / c["cpu"]), m["cpu"]
            if (c["gpu"]) printf "temp.gpu=%.1f\ntemp.gpu_max=%.1f\n", s["gpu"] / c["gpu"], m["gpu"]
            if (c["ssd"]) printf "temp.ssd=%.1f\n", m["ssd"]
            if (hot > 0) printf "temp.max=%.1f\ntemp.max_name=%s\n", hot, hotn
        }'

    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null |
            awk -F', *' 'NR == 1 { print "gpu.usage=" $1; print "temp.gpu=" $2 }'
    else
        b=$(cat /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -n 1)
        [ -n "$b" ] && echo "gpu.usage=$b"
    fi

    # CPU and per-process usage over the same one-second window.
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    pagesize=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    u1=$(cut -d' ' -f1 /proc/uptime)
    s1=$(grep '^cpu' /proc/stat)
    p1=$(cat /proc/[0-9]*/stat 2>/dev/null)
    sleep 1
    u2=$(cut -d' ' -f1 /proc/uptime)
    s2=$(grep '^cpu' /proc/stat)
    p2=$(cat /proc/[0-9]*/stat 2>/dev/null)

    { printf '%s\n' "$s1"; echo "--"; printf '%s\n' "$s2"; } | awk '
        $0 == "--" { part = 2; next }
        {
            tot = 0; for (i = 2; i <= 9 && i <= NF; i++) tot += $i
            idle = $5 + $6; usr = $2 + $3; sys = $4 + $7 + $8
            if (part != 2) { T[$1] = tot; I[$1] = idle; U[$1] = usr; S[$1] = sys; order[++n] = $1 }
            else { dt = tot - T[$1]; if (dt <= 0) dt = 1
                pct[$1] = 100 * (dt - (idle - I[$1])) / dt
                if ($1 == "cpu") { printf "cpu.user=%.1f\ncpu.sys=%.1f\ncpu.idle=%.1f\n", 100 * (usr - U[$1]) / dt, 100 * (sys - S[$1]) / dt, 100 * (idle - I[$1]) / dt } }
        }
        END { for (k = 1; k <= n; k++) if (order[k] != "cpu") cores = cores (cores == "" ? "" : ",") sprintf("%.1f", pct[order[k]])
            if (cores != "") print "cpu.cores=" cores }'

    { printf '%s\n' "$p1"; echo "--"; printf '%s\n' "$p2"; } | awk -v hz="$hz" -v pg="$pagesize" -v dt="$(awk -v a="$u1" -v b="$u2" 'BEGIN { d = b - a; print (d > 0 ? d : 1) }')" '
        $0 == "--" { part = 2; next }
        match($0, /\(.*\)/) {
            pid = $1; comm = substr($0, RSTART + 1, RLENGTH - 2)
            split(substr($0, RSTART + RLENGTH + 1), f, " ")
            ticks = f[12] + f[13]
            if (part != 2) { a[pid] = ticks; next }
            if (pid in a) { cpu[pid] = 100 * (ticks - a[pid]) / hz / dt; nm[pid] = comm; rss[pid] = f[22] * pg; seen[pid] = 1 }
        }
        END {
            for (k = 0; k < 3; k++) { best = ""; for (p in seen) if (best == "" || cpu[p] > cpu[best]) best = p
                if (best == "") break
                gsub(/\|/, "/", nm[best]); printf "proc=%s|%.1f|%.0f|%s\n", best, cpu[best], rss[best], nm[best]; delete seen[best] }
        }'
}

case $(uname -s) in
    Darwin) darwin ;;
    Linux) linux ;;
    *) echo "error=unsupported OS $(uname -s)" ;;
esac
echo "@@END"
