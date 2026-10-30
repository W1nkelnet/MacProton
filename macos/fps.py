#!/usr/bin/env python3
"""Frame rate and GPU time from the Metal Performance HUD's log.

Start the game with MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1; Metal then
writes a "metal-HUD:" line about every second to the process's stderr (the
game's log in MacProton), with the interval and the GPU time of each frame:

    macos/fps.py game.log [SECONDS]

Prints the average frame rate, the 1 % low (the frame rate of the slowest
1 % of frames) and the GPU time per frame over the last SECONDS (default 30)
of the log.
"""

import sys


def frames(log):
    """Yield (interval ms, GPU ms) per frame, in order."""
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


def main():
    log = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 30
    tail = []
    total = 0
    for frame in reversed(list(frames(log))):
        if total >= seconds * 1000:
            break
        tail.append(frame)
        total += frame[0]
    if not tail:
        sys.exit("No metal-HUD lines; start the game with MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1")
    intervals = sorted((i for i, _ in tail), reverse=True)
    slowest = intervals[:max(1, len(intervals) // 100)]
    # Some frames come without a GPU time
    timed = [g for _, g in tail if g > 0]
    gpu = sum(timed) / len(timed) if timed else 0
    print(f"{len(tail) * 1000 / total:.1f} fps, 1 % low {1000 * len(slowest) / sum(slowest):.1f} fps, "
          f"GPU {gpu:.2f} ms per frame, GPU busy {100 * sum(timed) / total:.0f} %, over {total / 1000:.0f} s")


if __name__ == "__main__":
    main()
