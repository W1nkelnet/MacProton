#!/usr/bin/env python3
"""Frame rate of a game from its log.

    macos/fps.py game.log [SECONDS]

Reads the last SECONDS (default 30) of whichever the log holds:

- KosmicKrisp with MESA_WSI_METAL_FPS=1: a "wsi/metal: N fps" line every
  second.
- MoltenVK with MVK_CONFIG_PERFORMANCE_TRACKING=1 and
  MVK_CONFIG_PERFORMANCE_LOGGING_FRAME_COUNT=60: running averages of the
  frame interval every 60 frames.
- Either driver with MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1: the Metal
  Performance HUD's interval and GPU time of each frame, which also gives
  the 1 % low. The HUD costs time per encoder on the thread encoding them,
  which is DXVK's CS thread under KosmicKrisp, so compare the drivers with
  the first two.
"""

import re
import sys


def hud_frames(log):
    """Yield (interval ms, GPU ms) per frame from the Metal HUD, in order."""
    with open(log, errors="replace") as f:
        for line in f:
            _, sep, rest = line.partition("metal-HUD: ")
            if not sep:
                continue
            # The first three values are a counter, the CPU time and the
            # memory in MB; then interval and GPU time per frame
            values = rest.strip().split(",")[3:]
            for interval, gpu in zip(values[0::2], values[1::2]):
                try:
                    yield float(interval), float(gpu)
                except ValueError:
                    pass


def wsi_rates(log):
    with open(log, errors="replace") as f:
        return [float(m.group(1)) for m in re.finditer(r"wsi/metal: ([0-9.]+) fps", f.read())]


def mvk_rates(log):
    """Frame rates between MoltenVK's reports, from its running averages."""
    pattern = re.compile(r"Frame interval\s+avg: ([0-9.]+) ms.*count: (\d+)")
    with open(log, errors="replace") as f:
        totals = [(int(m.group(2)), float(m.group(1)) * int(m.group(2)))
                  for m in pattern.finditer(f.read())]
    rates = []
    for (count0, ms0), (count1, ms1) in zip(totals, totals[1:]):
        if count1 > count0 and ms1 > ms0:
            rates.append(((count1 - count0) * 1000 / (ms1 - ms0), ms1 - ms0))
    return rates


def main():
    log = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 30

    rates = wsi_rates(log)
    if rates:
        tail = rates[-int(seconds):]
        print(f"{sum(tail) / len(tail):.1f} fps, slowest second {min(tail):.1f} fps, over {len(tail)} s")
        return

    rates = mvk_rates(log)
    if rates:
        tail, total = [], 0
        for rate, ms in reversed(rates):
            if total >= seconds * 1000:
                break
            tail.append((rate, ms))
            total += ms
        frames = sum(rate * ms / 1000 for rate, ms in tail)
        print(f"{frames * 1000 / total:.1f} fps, slowest report {min(r for r, _ in tail):.1f} fps, "
              f"over {total / 1000:.0f} s")
        return

    tail = []
    total = 0
    for frame in reversed(list(hud_frames(log))):
        if total >= seconds * 1000:
            break
        tail.append(frame)
        total += frame[0]
    if not tail:
        sys.exit("No frame rates in the log; see macos/fps.py for the variables")
    intervals = sorted((i for i, _ in tail), reverse=True)
    slowest = intervals[:max(1, len(intervals) // 100)]
    # Some frames come without a GPU time
    timed = [g for _, g in tail if g > 0]
    gpu = sum(timed) / len(timed) if timed else 0
    print(f"{len(tail) * 1000 / total:.1f} fps, 1 % low {1000 * len(slowest) / sum(slowest):.1f} fps, "
          f"GPU {gpu:.2f} ms per frame, GPU busy {100 * sum(timed) / total:.0f} %, over {total / 1000:.0f} s, "
          "with the Metal HUD")


if __name__ == "__main__":
    main()
