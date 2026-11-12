#!/bin/sh
# FS6712X live temperatures. BusyBox sh + awk + sensors.
# Usage: temps [1-60] | temps --once
set -u
INTERVAL=${1:-1}
ONCE=0
if [ "$INTERVAL" = '--once' ]; then
    ONCE=1
    INTERVAL=2
fi
case "$INTERVAL" in
    ''|*[!0-9]*|0)
        echo 'Usage: temps [1-60] | temps --once' >&2
        exit 2 ;;
esac
[ "$INTERVAL" -le 60 ] || exit 2
command -v sensors >/dev/null 2>&1 || exit 1
command -v awk >/dev/null 2>&1 || exit 1
# PCI address -> Linux NVMe device (not ADM bay number).
MAP=$(
    for ctl in /sys/class/nvme/nvme[0-9]*; do
        [ -e "$ctl/device" ] || continue
        path=$(readlink -f "$ctl/device" 2>/dev/null) || continue
        pci=${path##*/}
        case "$pci" in
            ????:??:??.?) ;;
            *) continue ;;
        esac
        bus=${pci#*:}
        bus=${bus%%:*}
        dev=${pci#*:*:}
        dev=${dev%%.*}
        printf '%s %s\n' "$bus$dev" "${ctl##*/}"
    done
)
COLOR=0
if [ -t 1 ] &&
   [ -z "${NO_COLOR:-}" ] &&
   [ "${TERM:-dumb}" != dumb ]; then
    COLOR=1
fi
render() {
    sensors | awk \
        -v mapping="$MAP" \
        -v color="$COLOR" \
        -v now="$(date '+%Y-%m-%d %H:%M:%S')" \
        -v interval="$INTERVAL" '
    BEGIN {
        count=split(mapping, entries, "\n")
        for(i=1; i<=count; i++) {
            split(entries[i], p, /[ \t]+/)
            if(p[1]!="" && p[2]!="")
                devmap[p[1]]=p[2]
        }
        green=sprintf("%c[32m",27)
        yellow=sprintf("%c[33m",27)
        red=sprintf("%c[31m",27)
        reset=sprintf("%c[0m",27)
        sep="────────────────────────────────────────────────────────────────────────────────────────────"
    }
    function value(line) {
        sub(/^[^:]*:/,"",line)
        sub(/^[ \t]*/,"",line)
        return line+0
    }
    function temp(x,warn,critical, t,c) {
        if(x=="") return "   N/A "
        t=sprintf("%5.1f°C",x)
        if(!color) return t
        c=(x>=critical ? red : (x>=warn ? yellow : green))
        return c t reset
    }
    /^nvme-pci-[0-9a-f]+$/ {
        kind="nvme"
        id=substr($1,10)
        seen[id]=1
        next
    }
    /^coretemp-isa-/ { kind="cpu"; next }
    /^[[:alnum:]_-]+-(pci|isa|acpi)-[[:alnum:]_-]+$/ {
        kind="other"
        next
    }
    kind=="cpu" && /^Package id 0:/ {
        package=value($0)
        have_cpu=1
        next
    }
    kind=="cpu" && /^Core [0-9]+:/ {
        x=value($0)
        if(!have_core || x>core_max) core_max=x
        have_core=1
        next
    }
    kind=="nvme" && /^Composite:/ {
        comp[id]=value($0)
        next
    }
    kind=="nvme" && /^Sensor 1:/ {
        sensor1[id]=value($0)
        next
    }
    kind=="nvme" && /^Sensor 2:/ {
        sensor2[id]=value($0)
        next
    }
    END {
        print "FLASHSTOR 12 PRO  •  LIVE TEMPERATURES     " now
        print sep
        print "CPU  |  Intel Celeron N5105"
        printf "  Package: %s",
            (have_cpu ? temp(package,80,95) : "N/A")
        if(have_core)
            printf "      Hottest core: %s",
                temp(core_max,80,95)
        printf "\n\n"
        n=0
        for(k in seen) keys[++n]=k
        for(i=1;i<=n;i++)
            for(j=i+1;j<=n;j++)
                if(keys[j]<keys[i]) {
                    tmp=keys[i]
                    keys[i]=keys[j]
                    keys[j]=tmp
                }
        printf "SSD  |  %d × Crucial P3 Plus 4 TB (PCI order, not ADM bay order)\n",n
        printf "  %-10s %-10s    %-9s     %-8s     %-8s\n",
            "PCI","Linux dev","Composite","Sensor 1","Sensor 2"
        for(i=1;i<=n;i++) {
            k=keys[i]
            address=substr(k,1,2) ":" substr(k,3,2) ".0"
            dev=(devmap[k]!="" ? devmap[k] : "--")
            printf "  %-10s %-10s    %s       %s      %s\n",
                address,dev,
                temp(comp[k],60,70),
                temp(sensor1[k],60,70),
                temp(sensor2[k],70,80)
            if(comp[k]!="") {
                sum+=comp[k]
                available++
                if(available==1 || comp[k]>max)
                    max=comp[k]
                if(available==1 || comp[k]<min)
                    min=comp[k]
            }
        }
        if(available)
            printf "\n  Composite: min %s  |  avg %s  |  max %s\n",
                temp(min,60,70),
                temp(sum/available,60,70),
                temp(max,60,70)
        if(n!=12)
            print "  Note: Expected 12 SSDs; check sensors if a drive is missing."
        print sep
        print "q / Ctrl+C: quit    +/-: interval    Refresh: " interval "s"
    }'
}
if [ "$ONCE" -eq 1 ] ||
   [ ! -t 0 ] ||
   [ ! -t 1 ]; then
    render
    exit $?
fi
OLD_STTY=$(stty -g </dev/tty 2>/dev/null) || OLD_STTY=''
restore() {
    [ -z "$OLD_STTY" ] ||
        stty "$OLD_STTY" </dev/tty 2>/dev/null
    printf '\033[?25h\n'
}
trap restore 0
trap 'exit 0' 1 2 3 15
if [ -n "$OLD_STTY" ]; then
    stty -echo -icanon min 0 time 0 \
        </dev/tty 2>/dev/null
fi
printf '\033[?25l\033[2J'
while :; do
    FRAME=$(render)
    printf '\033[H\033[J%s\n' "$FRAME"
    sleep "$INTERVAL"
    if [ -n "$OLD_STTY" ]; then
        KEY=$(dd if=/dev/tty bs=1 count=1 2>/dev/null)
        case "$KEY" in
            q|Q) break ;;
            +)
                [ "$INTERVAL" -le 1 ] ||
                    INTERVAL=$((INTERVAL-1)) ;;
            -)
                [ "$INTERVAL" -ge 60 ] ||
                    INTERVAL=$((INTERVAL+1)) ;;
        esac
    fi
done
