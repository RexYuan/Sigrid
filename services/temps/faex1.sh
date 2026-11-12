#!/usr/bin/env bash
# FAEX1 live temperature monitor
# AMD Ryzen AI Max+ 395 / Radeon 8060S
# Smooth ncurses display, suitable for SSH.
# Requirements: Bash, Python 3 (standard library only).

set -euo pipefail

if [[ ! -t 0 || ! -t 1 ]]; then
    echo "An interactive terminal is required." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is required." >&2
    exit 1
fi

if [[ ${TERM:-dumb} == dumb ]]; then
    echo "A terminal with ncurses support is required." >&2
    exit 1
fi

# Python source is passed as an argument so stdin remains
# attached to the terminal for keyboard interaction.

exec python3 -c "$(cat <<'PYTHON'
import curses
import datetime
import glob
import math
import os
from pathlib import Path
import re
import struct
import sys
import time

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

KNOWN_SSDS = [
    (
        "S73WNU0XA42784A",
        "Samsung 990 PRO 2 TB — Ubuntu"
    ),
    (
        "S73WNU0XA42780L",
        "Samsung 990 PRO 2 TB — Windows"
    ),
    (
        "PHAL1274000Z1P6EGN",
        "Intel Optane P5800X 1.6 TB — Data"
    ),
]

# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------

def interval_argument(argv):
    if len(argv) == 2 and argv[1] in ("-h", "--help"):
        print("Usage: temps.sh [refresh_seconds]")
        raise SystemExit(0)

    if len(argv) > 2:
        print("Usage: temps.sh [refresh_seconds]", file=sys.stderr)
        raise SystemExit(2)

    try:
        interval = float(argv[1]) if len(argv) == 2 else 1.0
    except ValueError:
        interval = float("nan")

    if not math.isfinite(interval) or not 0.1 <= interval <= 60:
        print("Refresh must be between 0.1 and 60 seconds.", file=sys.stderr)
        raise SystemExit(2)

    return interval

def read(path):
    try:
        return Path(path).read_text().strip()
    except (OSError, UnicodeError):
        return None

def temperature(path):
    value = read(path)

    try:
        return int(value) / 1000 if value is not None else None
    except ValueError:
        return None

def fmt(value):
    return f"{value:.1f}°C" if value is not None else "N/A"

# ------------------------------------------------------------
# Hardware monitoring
# ------------------------------------------------------------

TEMP_RE = re.compile(r'\d+(?:\.\d+)?°C')

def temperature_limits(line):
    label = line.lstrip()

    if label.startswith(("Tctl:", "CPU Tctl:")):
        return 80, 95

    if label.startswith(("Edge:", "GPU edge:")):
        return 75, 85

    if label.startswith("Sensor 2"):
        return 70, 80

    if label.startswith(("Composite", "Sensor ")):
        return 60, 70

    return None

def hwmon_devices():
    devices = []

    for p in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        name = read(Path(p) / "name")

        if name:
            devices.append((Path(p), name))

    return devices

def sensors_for(hw):
    result = []

    for inp in hw.glob("temp*_input"):
        number = inp.stem[4:-6]

        if not number.isdigit():
            continue

        value = temperature(inp)

        if value is None:
            continue

        label = (
            read(hw / f"temp{number}_label")
            or f"Sensor {number}"
        )

        if label.lower() == "composite":
            order = 0
            label = "Composite"
        elif label.startswith("Sensor "):
            order = int(number)
        else:
            order = int(number) + 20

        result.append((order, label, value))

    return sorted(result)

def temperature_for(devices, driver_name, label):
    for hw, driver in devices:
        if driver != driver_name:
            continue

        for _, sensor_label, value in sensors_for(hw):
            if sensor_label == label:
                return value

    return None

# ------------------------------------------------------------
# AMD GPU Metrics v3.0
# ------------------------------------------------------------

def gpu_metrics():
    # AMD GPU Metrics 3.0:
    # 0-3: structure header
    # 4-5: GPU temperature (centi-Celsius)
    # 6-7: SoC temperature (centi-Celsius)

    for card in sorted(Path("/sys/class/drm").glob("card[0-9]*")):
        dev = card / "device"

        if read(dev / "vendor") != "0x1002":
            continue

        try:
            data = (dev / "gpu_metrics").read_bytes()

            if len(data) < 8:
                continue

            size, major, minor = struct.unpack_from(
                "<HBB", data
            )

            if (major, minor) != (3, 0):
                continue

            if not 8 <= size <= len(data):
                continue

            gfx, soc = struct.unpack_from("<HH", data, 4)

            def convert(raw):
                if raw in (0, 65535):
                    return None
                return raw / 100

            return convert(gfx), convert(soc)

        except (OSError, ValueError, struct.error):
            continue

    return None, None

def cpu_gpu_readings(devices):
    cpu = temperature_for(devices, "k10temp", "Tctl")
    gpu = temperature_for(devices, "amdgpu", "edge")

    gfx_metrics, soc = gpu_metrics()

    if gpu is None:
        gpu = gfx_metrics

    return cpu, gpu, soc

# ------------------------------------------------------------
# NVMe SSD identification by serial number
# ------------------------------------------------------------

def nvme_readings(devices):
    hw_nvmes = [
        (hw.resolve(), hw)
        for hw, driver in devices
        if driver == "nvme"
    ]

    by_serial = {}

    for controller in sorted(
        Path("/sys/class/nvme").glob("nvme[0-9]*")
    ):
        if not re.fullmatch(r"nvme\d+", controller.name):
            continue

        serial = read(controller / "serial")

        if not serial:
            continue

        canonical = str(controller.resolve())

        matches = []

        for resolved, hw in hw_nvmes:
            if str(resolved).startswith(canonical + os.sep):
                matches.append(hw)

        if not matches:
            # Fallback: identify hardware by PCI address.
            pci_path = str((controller / "device").resolve())

            pci_bdf = next(
                (
                    part
                    for part in reversed(pci_path.split(os.sep))
                    if re.fullmatch(
                        r"[0-9a-f]{4}:[0-9a-f]{2}:"
                        r"[0-9a-f]{2}\.[0-7]",
                        part
                    )
                ),
                None
            )

            if pci_bdf:
                matches = [
                    hw
                    for resolved, hw in hw_nvmes
                    if pci_bdf in str(resolved)
                ]

        readings = sensors_for(matches[0]) if matches else []

        by_serial[serial] = (
            controller.name,
            readings
        )

    result = []

    for serial, display in KNOWN_SSDS:
        found = by_serial.get(serial)

        if found:
            device, readings = found

            result.append((
                f"{display} [{device}]",
                readings,
                None
            ))
        else:
            result.append((
                display,
                [],
                "Drive not detected"
            ))

    return result

# ------------------------------------------------------------
# Dashboard construction
# ------------------------------------------------------------

def build_lines(width, interval):
    devices = hwmon_devices()

    cpu, gpu, soc = cpu_gpu_readings(devices)
    drives = nvme_readings(devices)

    now = datetime.datetime.now().strftime(
        "%Y-%m-%d %H:%M:%S"
    )

    lines = []

    def add(message="", style=0):
        lines.append((message, style))

    add(f"FAEX1  •  LIVE TEMPERATURES     {now}", 1)
    add("─" * max(0, width - 1), 2)

    # CPU and SoC
    add("CPU  |  AMD Ryzen AI Max+ 395", 3)
    add(
        f"  Tctl: {fmt(cpu):>9}"
        f"      SoC: {fmt(soc):>9}"
    )
    add()

    # Integrated GPU
    add("GPU  |  AMD Radeon 8060S", 3)
    add(f"  Edge: {fmt(gpu):>9}")
    add()

    # SSDs
    for index, (display, measurements, error) in enumerate(
        drives, 1
    ):
        add(f"SSD {index}  |  {display}", 3)

        if error:
            add(f"  {error}", 4)

        elif not measurements:
            add("  Temperature sensors unavailable", 4)

        else:
            for _, label, value in measurements:
                add(
                    f"  {label:<25}"
                    f" {fmt(value):>9}"
                )

        add()

    add("─" * max(0, width - 1), 2)

    add(
        "q / Ctrl+C: quit    "
        "+/-: interval    "
        f"Refresh: {interval:g}s",
        2
    )

    return lines

# ------------------------------------------------------------
# Smooth ncurses interface
# ------------------------------------------------------------

def tui(stdscr, interval):
    try:
        curses.curs_set(0)
    except curses.error:
        pass

    stdscr.keypad(True)
    stdscr.timeout(100)

    colors = {
        0: curses.A_NORMAL,
        1: curses.A_BOLD,
        2: curses.A_DIM,
        3: curses.A_BOLD,
        4: curses.A_DIM,
    }

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

        colors[1] = (
            curses.A_BOLD | curses.color_pair(1)
        )
        colors[3] = (
            curses.A_BOLD | curses.color_pair(1)
        )
        colors[4] = curses.color_pair(2)

    previous = []
    next_read = 0.0
    previous_size = (0, 0)

    while True:
        now = time.monotonic()
        height, width = stdscr.getmaxyx()

        if (height, width) != previous_size:
            # Clear only when terminal dimensions change.
            # Normal refreshes never clear the screen.
            stdscr.erase()

            previous = []
            previous_size = (height, width)
            next_read = 0.0

        if now >= next_read:
            lines = build_lines(width, interval)
            available = max(0, height - 1)

            if len(lines) > available:
                lines = lines[:max(0, available - 1)] + [
                    (
                        "Terminal too short; enlarge window.",
                        4
                    )
                ]

            for y in range(
                min(
                    available,
                    max(len(previous), len(lines))
                )
            ):
                item = (
                    lines[y]
                    if y < len(lines)
                    else ("", 0)
                )

                if (
                    y < len(previous)
                    and previous[y] == item
                ):
                    continue

                text, style = item

                try:
                    stdscr.move(y, 0)
                    stdscr.clrtoeol()

                    if text and width > 1:
                        stdscr.addnstr(
                            y,
                            0,
                            text,
                            width - 1,
                            colors[style]
                        )

                        if curses.has_colors():
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

            # Refresh only changed terminal cells.
            stdscr.noutrefresh()
            curses.doupdate()

            previous = lines
            next_read = time.monotonic() + interval

        ch = stdscr.getch()

        if ch in (ord("q"), ord("Q"), 27):
            return

        if ch in (ord("+"), ord("=")):
            interval = max(
                0.1, round(interval / 2, 2)
            )
            next_read = 0

        elif ch in (ord("-"), ord("_")):
            interval = min(
                60.0, round(interval * 2, 2)
            )
            next_read = 0

        elif ch == curses.KEY_RESIZE:
            previous_size = (0, 0)

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------

if __name__ == "__main__":
    seconds = interval_argument(sys.argv)

    try:
        curses.wrapper(tui, seconds)

    except KeyboardInterrupt:
        pass

    except curses.error as exc:
        print(
            f"Cannot initialize ncurses: {exc}",
            file=sys.stderr
        )
        raise SystemExit(1)
PYTHON
)" "$@"
