#!/usr/bin/env python3
"""Read-only, one-shot Linux temperature and usage collector. Python stdlib only.

Works when piped into SSH, e.g. ssh faex1 'python3 - --profile faex1' < collect_linux.py
No installation and no persistent agent needed on monitored machines.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

HWMON = Path('/sys/class/hwmon')
NVME = Path('/sys/class/nvme')
PCI_PATTERN = re.compile(r'[0-9a-f]{4}:([0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$', re.I)

# Match these particular drives by serial, never by boot-dependent nvmeX numbering.
# Models not listed here still appear under their controller-reported model name.
FAEX1_LABELS = {
    'S73WNU0XA42784A': 'Samsung 990 PRO 2 TB — Ubuntu',
    'S73WNU0XA42780L': 'Samsung 990 PRO 2 TB — Windows',
    'PHAL1274000Z1P6EGN': 'Intel Optane P5800X 1.6 TB — Data',
}

def read_text(path):
    try:
        return Path(path).read_text(encoding='utf-8').strip()
    except (OSError, UnicodeError):
        return None

def read_millic(path):
    raw = read_text(path)
    try:
        result = round(int(raw) / 1000.0, 1)
        return result if -20 < result < 130 else None
    except (ValueError, TypeError):
        return None

def hwmons():
    result = []
    for folder in sorted(HWMON.glob('hwmon[0-9]*')):
        name = read_text(folder / 'name')
        if name:
            result.append((folder, name))
    return result

def temps_for(folder):
    values = {}
    for f in folder.glob('temp*_input'):
        m = re.fullmatch(r'temp(\d+)_input', f.name)
        if not m:
            continue
        num = int(m.group(1))
        degree = read_millic(f)
        if degree is None:
            continue
        label = read_text(folder / f'temp{num}_label') or f'temp{num}'
        values[label.strip().lower()] = degree
    return values

def named_sensor(devices, driver, label):
    for folder, name in devices:
        if name == driver:
            val = temps_for(folder).get(label.lower())
            if val is not None:
                return val
    return None

def gpu_metrics_v30():
    # Ryzen AI Max+ 395 gpu_metrics v3.0; validated in the original FAEX1 monitor.
    # gfx/soc values at offsets 4/6, expressed in hundredths of a degree.
    for card in sorted(Path('/sys/class/drm').glob('card[0-9]*')):
        dev = card / 'device'
        if read_text(dev / 'vendor') != '0x1002':
            continue
        try:
            raw = (dev / 'gpu_metrics').read_bytes()
            if len(raw) < 8:
                continue
            size, major, minor = struct.unpack_from('<HBB', raw)
            if (major, minor) != (3, 0) or not 8 <= size <= len(raw):
                continue
            gfx, soc = struct.unpack_from('<HH', raw, 4)
            conv = lambda v: round(v / 100.0, 1) if v not in (0, 65535) else None
            return conv(gfx), conv(soc)
        except (OSError, ValueError, struct.error):
            continue
    return None, None

def nvidia_gpu_temp():
    try:
        r = subprocess.run(
            ['nvidia-smi', '--query-gpu=temperature.gpu', '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=3, check=True,
        )
        first = r.stdout.strip().splitlines()[0].strip()
        v = float(first)
        return round(v, 1) if -20 < v < 130 else None
    except (OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError, IndexError):
        return None

def pci_for_controller(controller):
    try:
        parts = (controller / 'device').resolve().parts
    except OSError:
        return None
    for p in reversed(parts):
        m = PCI_PATTERN.fullmatch(p)
        if m:
            return m.group(1).lower()
    return None

def nvme_hwmon_for(controller, devices, pci):
    real_controller = str(controller.resolve())
    hits = []
    for folder, name in devices:
        if name != 'nvme':
            continue
        real_hw = str(folder.resolve())
        if real_hw.startswith(real_controller + os.sep):
            hits.append(folder)
    if not hits and pci:
        hits = [folder for folder, name in devices if name == 'nvme'
                and pci in str(folder.resolve()).lower()]
    return hits[0] if hits else None

def collect_ssds(devices, profile):
    result = []
    seen_serials = set()
    for controller in sorted(NVME.glob('nvme[0-9]*')):
        if not re.fullmatch(r'nvme\d+', controller.name):
            continue
        serial = read_text(controller / 'serial')
        if serial and serial in seen_serials:
            continue
        if serial:
            seen_serials.add(serial)
        model = read_text(controller / 'model') or 'NVMe SSD'
        pci = pci_for_controller(controller)
        folder = nvme_hwmon_for(controller, devices, pci)
        readings = temps_for(folder) if folder else {}
        # hwmon temp1 is the NVMe SMART composite; never fall back to Sensor 1/2.
        temperature = readings.get('composite')
        if temperature is None:
            temperature = readings.get('temp1')
        if profile == 'faex1' and serial in FAEX1_LABELS:
            title = FAEX1_LABELS[serial]
        elif profile == 'ms01' and ('PM9A3' in model.upper() or 'MZQL215THBLA' in model.upper()):
            title = 'Samsung PM9A3 15.36 TB — Ubuntu'
        else:
            title = re.sub(r'\s+', ' ', model).strip()
        result.append({'id': pci or controller.name, '_serial': serial,
                       'name': title, 'device': controller.name,
                       'pci': pci, 'c': temperature})
    if profile == 'faex1':
        order = {key: i for i, key in enumerate(FAEX1_LABELS)}
        result.sort(key=lambda s: (order.get(s['_serial'], 999), s['name']))
    else:
        result.sort(key=lambda s: (s['pci'] or 'zz', s['name']))
    for ssd in result:
        ssd.pop('_serial', None)  # Never send hardware serial numbers to the web UI.
    return result

def cpu_utilization():
    """Aggregate CPU utilization over a short interval, including all cores."""
    def ticks():
        try:
            line = Path('/proc/stat').read_text(encoding='ascii').splitlines()[0]
            parts = line.split()
            if parts[0] != 'cpu' or len(parts) < 9:
                return None
            # Guest time is already included in user/nice; do not double-count it.
            values = [int(x) for x in parts[1:9]]
            return sum(values), values[3] + values[4]
        except (OSError, ValueError, IndexError):
            return None

    before = ticks()
    if before is None:
        return None
    time.sleep(0.5)
    after = ticks()
    if after is None:
        return None
    delta = after[0] - before[0]
    idle = after[1] - before[1]
    return round(max(0.0, min(100.0, 100.0 * (delta - idle) / delta)), 1) if delta > 0 else None


def memory_usage():
    try:
        fields = {}
        for line in Path('/proc/meminfo').read_text(encoding='ascii').splitlines():
            key, _, rest = line.partition(':')
            if key in ('MemTotal', 'MemAvailable'):
                fields[key] = int(rest.split()[0]) * 1024
        total = fields['MemTotal']
        available = fields['MemAvailable']
        if total <= 0 or not 0 <= available <= total:
            return {'used_bytes': None, 'total_bytes': None, 'pct': None}
        used = total - available  # Applications + non-reclaimable cache, not all cache.
        return {'used_bytes': used, 'total_bytes': total,
                'pct': round(used * 100 / total, 1)}
    except (OSError, KeyError, ValueError, IndexError):
        return {'used_bytes': None, 'total_bytes': None, 'pct': None}


def filesystem_usage(name, mount):
    """Filesystem capacity (not raw SSD size). Never use a missing mount's parent."""
    entry = {'name': name, 'mount': mount,
             'used_bytes': None, 'total_bytes': None, 'pct': None}
    if not os.path.ismount(mount):
        return entry
    try:
        fs = os.statvfs(mount)
        total = fs.f_blocks * fs.f_frsize
        used = (fs.f_blocks - fs.f_bfree) * fs.f_frsize
        if total <= 0 or used < 0:
            return entry
        entry.update(used_bytes=used, total_bytes=total,
                     pct=round(min(100.0, used * 100 / total), 1))
    except OSError:
        pass
    return entry


def amd_gpu_utilization():
    for card in sorted(Path('/sys/class/drm').glob('card[0-9]*')):
        if read_text(card / 'device/vendor') != '0x1002':
            continue
        raw = read_text(card / 'device/gpu_busy_percent')
        try:
            value = int(raw)
            if 0 <= value <= 100:
                return value
        except (ValueError, TypeError):
            continue
    return None


def nvidia_gpu_utilization():
    try:
        result = subprocess.run(
            ['nvidia-smi', '--query-gpu=utilization.gpu', '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=3, check=True,
        )
        values = [float(x.strip()) for x in result.stdout.splitlines() if x.strip()]
        return round(sum(values) / len(values), 1) if values and all(0 <= v <= 100 for v in values) else None
    except (OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError):
        return None


def collect_usage(profile):
    if profile == 'faex1':
        storage = [
            filesystem_usage('Samsung 990 PRO 2 TB — ext4', '/'),
            # Windows is intentionally not guessed while it is unmounted.
            {'name': 'Samsung 990 PRO 2 TB — Windows', 'mount': None,
             'used_bytes': None, 'total_bytes': None, 'pct': None},
            filesystem_usage('Intel Optane P5800X 1.6 TB — XFS', '/mnt/p5800x'),
        ]
        gpu = amd_gpu_utilization()
    else:
        storage = [filesystem_usage('Samsung PM9A3 15.36 TB — Btrfs', '/')]
        gpu = nvidia_gpu_utilization()
    return {'cpu_pct': cpu_utilization(), 'gpu_pct': gpu,
            'ram': memory_usage(), 'storage': storage}


def collect(profile):
    devices = hwmons()
    if profile == 'faex1':
        gfx, soc = gpu_metrics_v30()
        cpu = {'name': 'AMD Ryzen AI Max+ 395', 'readings': [
            {'label': 'Tctl', 'c': named_sensor(devices, 'k10temp', 'Tctl')},
            {'label': 'SoC', 'c': soc}]}
        gpu = {'name': 'AMD Radeon 8060S', 'readings': [
            {'label': 'Edge', 'c': named_sensor(devices, 'amdgpu', 'edge') or gfx}]}
        name = 'FAEX1'
    else:
        pkg = named_sensor(devices, 'coretemp', 'Package id 0')
        cores = [v for folder, driver in devices if driver == 'coretemp'
                 for label, v in temps_for(folder).items() if re.fullmatch(r'core \d+', label)]
        cpu = {'name': 'Intel Core i9-13900H', 'readings': [
            {'label': 'Package', 'c': pkg},
            {'label': 'Hottest core', 'c': max(cores) if cores else None}]}
        gpu = {'name': 'NVIDIA RTX 2000E Ada', 'readings': [
            {'label': 'GPU core', 'c': nvidia_gpu_temp()}]}
        name = 'MS-01'
    ssds = collect_ssds(devices, profile)
    return {'name': name, 'observed_at': time.time(), 'cpu': cpu, 'gpu': gpu,
            'ssds': ssds, 'expected_ssds': 3 if profile == 'faex1' else 1,
            'usage': collect_usage(profile)}

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--profile', choices=['faex1', 'ms01'], required=True)
    args = p.parse_args()
    print(json.dumps(collect(args.profile), ensure_ascii=False, separators=(',', ':')))
