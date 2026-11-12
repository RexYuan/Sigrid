#!/usr/bin/env bash
# Smooth ncurses temperature monitor for the Minisforum MS-01.
# A self-contained Bash launcher + Python 3 (standard-library curses) program.
# No root access, sensors-detect, watch, or pip packages required.
set -euo pipefail
if [[ ! -t 0 || ! -t 1 ]]; then
    echo 'temps.sh requires an interactive terminal (local or SSH).' >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo 'Python 3 is required: sudo apt install python3' >&2
    exit 1
fi
if [[ ${TERM:-dumb} == dumb ]]; then
    echo 'A terminal with ncurses support is required (TERM is dumb).' >&2
    exit 1
fi
# Feed embedded Python to "cat", not to Python's stdin: keyboard input remains
# attached to the SSH terminal, allowing curses to handle keys and resize events.
exec python3 -c "$(cat <<'PYTHON'
import curses
import datetime
import glob
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

def interval_argument(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1] in ('-h', '--help')):
        print('Usage: temps.sh [refresh_seconds]', file=sys.stderr)
        raise SystemExit(0 if len(argv) == 2 and argv[1] in ('-h', '--help') else 2)
    try:
        interval = float(argv[1]) if len(argv) == 2 else 1.0
    except ValueError:
        interval = float('nan')
    if not math.isfinite(interval) or not 0.1 <= interval <= 60:
        print('Refresh interval must be between 0.1 and 60 seconds.', file=sys.stderr)
        raise SystemExit(2)
    return interval

def read(path):
    try:
        return Path(path).read_text().strip()
    except (OSError, UnicodeError):
        return None

def temp(path):
    value = read(path)
    try:
        return int(value) / 1000 if value is not None else None
    except ValueError:
        return None

def c(value):
    return f'{value:.1f}°C' if value is not None else 'N/A'

TEMP_RE = re.compile(r'\d+(?:\.\d+)?°C')

def temperature_limits(line):
    label = line.lstrip()

    if label.startswith('Package:'):
        return 80, 95

    if label.startswith(('GPU core:', 'Core:')):
        return 75, 85

    if label.startswith('Sensor 2'):
        return 70, 80

    if label.startswith(('Composite', 'Sensor ')):
        return 60, 70

    return None

def hwmon():
    devices = []
    for p in sorted(glob.glob('/sys/class/hwmon/hwmon*')):
        name = read(Path(p) / 'name')
        if name:
            devices.append((Path(p), name))
    return devices

def cpu_readings(devices):
    package = None
    cores = []
    for hw, name in devices:
        if name != 'coretemp':
            continue
        for inp in hw.glob('temp*_input'):
            number = inp.stem[4:-6]
            if not number.isdigit():
                continue
            label = read(hw / f'temp{number}_label') or f'CPU sensor {number}'
            val = temp(inp)
            if val is None:
                continue
            if label.startswith('Package'):
                package = val if package is None else max(package, val)
            elif label.startswith('Core '):
                try:
                    core_no = int(label.split()[1])
                    cores.append((core_no, label, val))
                except (ValueError, IndexError):
                    pass
    cores.sort(key=lambda x: x[0])
    hottest = max((v for _, _, v in cores), default=None)
    return package, hottest, cores

def gpu_reading():
    try:
        result = subprocess.run(
            ['nvidia-smi', '--query-gpu=temperature.gpu', '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=2, check=True,
        )
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        return None
    try:
        return float(result.stdout.strip().splitlines()[0].strip())
    except (IndexError, ValueError):
        return None

def nvme_readings(devices):
    drives = []
    for hw, name in devices:
        if name != 'nvme':
            continue
        model = read(hw / 'device/model') or read(hw / 'device/device/model') or ''
        if 'PM9A3' in model.upper() or 'MZQL2' in model.upper():
            display = 'Samsung PM9A3 15.36 TB'
            is_pm9a3 = True
        else:
            display = model or 'NVMe SSD'
            is_pm9a3 = False
        measurements = []
        for inp in hw.glob('temp*_input'):
            number = inp.stem[4:-6]
            if not number.isdigit():
                continue
            val = temp(inp)
            if val is None:
                continue
            label = read(hw / f'temp{number}_label') or f'Sensor {number}'
            if label.lower() == 'composite':
                priority, label = 0, 'Composite'
            elif label == 'Sensor 1' and is_pm9a3:
                priority, label = 1, 'Sensor 1'
            elif label == 'Sensor 2' and is_pm9a3:
                priority, label = 2, 'Sensor 2'
            else:
                priority = 20 + int(number)
            measurements.append((priority, label, val))
        measurements.sort()
        drives.append((display, measurements))
    return drives

# Lines contain a (text, style) pair. Only altered lines are sent to the screen.
def build_lines(width, interval):
    devices = hwmon()
    package, hottest, cores = cpu_readings(devices)
    nvmes = nvme_readings(devices)
    gpu = gpu_reading()
    now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    result = []
    def add(text='', style=0):
        result.append((text, style))

    add(f'MS-01  •  LIVE TEMPERATURES     {now}', 1)
    add('─' * max(0, width - 1), 2)
    add('CPU  |  Intel Core i9-13900H', 3)
    add(f'  Package: {c(package):>9}      Hottest core: {c(hottest):>9}')
    add()
    add('GPU  |  NVIDIA RTX 2000E Ada', 3)
    add(f'  GPU core: {c(gpu):>9}' if gpu is not None else '  NVIDIA temperature unavailable (check nvidia-smi)', 0 if gpu is not None else 4)
    add()
    if nvmes:
        for idx, (model, measurements) in enumerate(nvmes, 1):
            add(f'SSD {idx}  |  {model}', 3)
            if not measurements:
                add('  NVMe temperature sensors unavailable', 4)
            for _, label, value in measurements:
                add(f'  {label:<25} {c(value):>9}')
            add()
    else:
        add('SSD  |  No NVMe hwmon temperature sensors found', 4)
        add()
    add('─' * max(0, width - 1), 2)
    add(f'q / Ctrl+C: quit    +/-: interval    Refresh: {interval:g}s', 2)
    return result

def tui(stdscr, interval):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    stdscr.keypad(True)
    stdscr.timeout(100)
    colors = {0: curses.A_NORMAL, 1: curses.A_BOLD, 2: curses.A_DIM,
              3: curses.A_BOLD, 4: curses.A_DIM}
    if curses.has_colors():
        curses.start_color()
        try:
            curses.use_default_colors()
        except curses.error:
            pass
        curses.init_pair(1, curses.COLOR_CYAN, -1)
        curses.init_pair(2, curses.COLOR_YELLOW, -1)
        curses.init_pair(3, curses.COLOR_GREEN, -1)
        curses.init_pair(4, curses.COLOR_YELLOW, -1)
        curses.init_pair(5, curses.COLOR_RED, -1)
        colors[1] = curses.A_BOLD | curses.color_pair(1)
        colors[3] = curses.A_BOLD | curses.color_pair(1)
        colors[4] = curses.color_pair(2)

    prev = []
    next_read = 0.0
    prior_size = (0, 0)
    while True:
        now = time.monotonic()
        height, width = stdscr.getmaxyx()
        if (height, width) != prior_size:
            # Only initialize/clear when the *terminal dimensions* change.
            # Routine refreshes never clear the screen.
            stdscr.erase()
            prev = []
            prior_size = (height, width)
            next_read = 0.0
        if now >= next_read:
            lines = build_lines(width, interval)
            available = max(0, height - 1)
            if len(lines) > available:
                # Keep vital CPU/GPU/SSD data visible on small SSH windows.
                # A one-line hint explains the display limit.
                lines = lines[:max(0, available - 1)] + [
                    ('Terminal too short to show all sensors; enlarge window.', 4)
                ]
            for y in range(min(available, max(len(prev), len(lines)))):
                item = lines[y] if y < len(lines) else ('', 0)
                if y < len(prev) and prev[y] == item:
                    continue
                text, style = item
                try:
                    stdscr.move(y, 0)
                    stdscr.clrtoeol()
                    if text and width > 1:
                        stdscr.addnstr(y, 0, text, width - 1, colors[style])

                        # Color temperature values only.
                        limits = temperature_limits(text)

                        if limits is not None:
                            warn, critical = limits

                            for match in TEMP_RE.finditer(text):
                                x = match.start()

                                if x >= width - 1:
                                    break

                                value = float(match.group()[:-2])

                                pair = (
                                    5 if value >= critical else
                                    4 if value >= warn else
                                    3
                                )

                                stdscr.addnstr(
                                    y,
                                    x,
                                    match.group(),
                                    width - 1 - x,
                                    curses.color_pair(pair)
                                )
                except curses.error:
                    pass
            stdscr.noutrefresh()
            curses.doupdate()    # ncurses applies only changed cells, no flash
            prev = lines
            next_read = time.monotonic() + interval
        ch = stdscr.getch()
        if ch in (ord('q'), ord('Q'), 27):
            return
        if ch in (ord('+'), ord('=')):
            interval = max(0.1, round(interval / 2, 2))
            next_read = 0
        elif ch in (ord('-'), ord('_')):
            interval = min(60.0, round(interval * 2, 2))
            next_read = 0
        elif ch == curses.KEY_RESIZE:
            prior_size = (0, 0)

if __name__ == '__main__':
    seconds = interval_argument(sys.argv)
    try:
        curses.wrapper(tui, seconds)
    except KeyboardInterrupt:
        pass
    except curses.error as exc:
        print(f'Cannot initialize the ncurses display: {exc}', file=sys.stderr)
        raise SystemExit(1)
PYTHON
)" "$@"
