#!/bin/sh
# Flashstor FS6712X temperature collector — read-only Linux sysfs.
# BusyBox/POSIX sh + awk; no sensors, Python, sudo, or persistent agent required.
# Example: ssh -T flashstor 'sh -s' < collect_flashstor.sh
set -eu

HWMON_BASE=${HWMON_BASE:-/sys/class/hwmon}
NVME_BASE=${NVME_BASE:-/sys/class/nvme}

command -v awk >/dev/null 2>&1 || { echo 'awk not available on Flashstor' >&2; exit 1; }
command -v readlink >/dev/null 2>&1 || { echo 'readlink not available on Flashstor' >&2; exit 1; }

# Print raw millidegree readings as TSV. awk converts and formats to JSON below.
cpu_readings() {
  for hw in "$HWMON_BASE"/hwmon[0-9]*; do
    [ -f "$hw/name" ] || continue
    IFS= read -r driver < "$hw/name" || continue
    [ "$driver" = coretemp ] || continue
    for input in "$hw"/temp[0-9]*_input; do
      [ -f "$input" ] || continue
      label_file=${input%_input}_label
      [ -f "$label_file" ] || continue
      IFS= read -r label < "$label_file" || continue
      IFS= read -r raw < "$input" || continue
      case "$label" in
        'Package id 0') printf 'PACKAGE\t%s\n' "$raw" ;;
        'Core '[0-9]*) printf 'CORE\t%s\n' "$raw" ;;
      esac
    done
  done
}

# Return the final PCI BDF component from a resolved sysfs path.
# We never assume that nvme0 is the first physical NAS bay.
pci_from_path() {
  rest=$1
  bdf=''
  while [ -n "$rest" ]; do
    segment=${rest%%/*}
    case "$segment" in
      ????:??:??.?) bdf=$segment ;;
    esac
    case "$rest" in
      */*) rest=${rest#*/} ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$bdf"
}

ssd_readings() {
  for ctl in "$NVME_BASE"/nvme[0-9]*; do
    [ -e "$ctl" ] || continue
    device=${ctl##*/}
    # Only controller names, not potential namespace names (nvme0n1).
    case "$device" in nvme[0-9]*) case "${device#nvme}" in *[!0-9]*|'') continue ;; esac ;; *) continue ;; esac
    controller_path=$(readlink -f "$ctl" 2>/dev/null) || continue
    pci_path=$(readlink -f "$ctl/device" 2>/dev/null) || pci_path=$controller_path
    bdf=$(pci_from_path "$pci_path")
    [ -n "$bdf" ] || bdf=$(pci_from_path "$controller_path")
    short_pci=''
    [ -z "$bdf" ] || short_pci=${bdf#*:}
    raw=''
    for hw in "$HWMON_BASE"/hwmon[0-9]*; do
      [ -f "$hw/name" ] || continue
      IFS= read -r driver < "$hw/name" || continue
      [ "$driver" = nvme ] || continue
      hw_path=$(readlink -f "$hw" 2>/dev/null) || continue
      match=0
      case "$hw_path" in "$controller_path"/*) match=1 ;; esac
      if [ "$match" -eq 0 ] && [ -n "$bdf" ]; then
        case "$hw_path" in */"$bdf"/*) match=1 ;; esac
      fi
      [ "$match" -eq 1 ] || continue
      # The NVMe hwmon temp1_input is SMART Composite; never use Sensor 1/2.
      if [ -f "$hw/temp1_input" ]; then
        IFS= read -r raw < "$hw/temp1_input" || raw=''
      fi
      break
    done
    printf 'SSD\t%s\t%s\t%s\n' "$short_pci" "$device" "$raw"
  done
}

{
  cpu_readings
  ssd_readings
} | awk -F '\t' -v timestamp="$(date '+%s')" '
function temp(raw) {
  if (raw !~ /^[-+]?[0-9]+$/ || raw <= -20000 || raw >= 130000) return "null"
  return sprintf("%.1f", raw/1000)
}
$1 == "PACKAGE" { pkg=$2 }
$1 == "CORE" && $2 ~ /^[-+]?[0-9]+$/ {
  if (!have_core || $2 > hottest) hottest=$2
  have_core=1
}
$1 == "SSD" {
  ++n; pci[n]=$2; dev[n]=$3; reading[n]=$4
}
END {
  printf "{\"name\":\"FLASHSTOR 12 PRO\",\"observed_at\":%s,",timestamp
  printf "\"cpu\":{\"name\":\"Intel Celeron N5105\",\"readings\":["
  printf "{\"label\":\"Package\",\"c\":%s},",temp(pkg)
  printf "{\"label\":\"Hottest core\",\"c\":%s}]},",have_core?temp(hottest):"null"
  printf "\"gpu\":null,\"expected_ssds\":12,\"ssds\":["
  for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) {
    if (pci[j]<pci[i]) {
      t=pci[i];pci[i]=pci[j];pci[j]=t
      t=dev[i];dev[i]=dev[j];dev[j]=t
      t=reading[i];reading[i]=reading[j];reading[j]=t
    }
  }
  for (i=1;i<=n;i++) {
    if (i>1) printf ","
    split(pci[i],parts, /[:.]/)
    id=parts[1] parts[2]
    if (id=="") id=dev[i]
    # All names and paths are kernel-provided identifiers, not free-form strings.
    printf "{\"id\":\"%s\",\"name\":\"Crucial P3 Plus 4 TB\",\"device\":\"%s\",\"pci\":\"%s\",\"c\":%s}",id,dev[i],pci[i],temp(reading[i])
  }
  printf "]}\n"
}'
