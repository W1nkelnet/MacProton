#!/usr/bin/env python3
"""Summarize the GPU time of a process in a Metal System Trace.

Record a trace of a running game, for example 5 seconds of the Wine process
with the game's PID:

    xcrun xctrace record --template 'Metal System Trace' --attach PID \\
        --time-limit 5s --output game.trace
    macos/gpu-trace.py game.trace PID

xctrace leaves a raw kernel trace of close to 1 GB per recording in $TMPDIR
(instruments*.ktrace); delete those afterwards.

Prints the time the GPU was busy for the process per second and per frame,
overall and per channel (vertex, fragment, compute), and how many GPU
intervals, roughly encoders, ran per second.
"""

import subprocess
import sys
import xml.etree.ElementTree as ET


def export(trace):
    xpath = '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]'
    out = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                         capture_output=True, check=True).stdout
    return ET.fromstring(out)


def intervals_of(root, pid):
    # xctrace writes each value once with an id and refers to it later
    ids = {el.attrib["id"]: el for el in root.iter() if "id" in el.attrib}

    def resolve(el):
        return ids[el.attrib["ref"]] if el is not None and "ref" in el.attrib else el

    node = root.find("node")
    columns = [c.findtext("mnemonic") for c in node.find("schema").findall("col")]
    for row in node.findall("row"):
        cells = {name: resolve(el) for name, el in zip(columns, row)}
        process = cells.get("process")
        if process is None or process.tag != "process":
            continue
        if int(resolve(process.find("pid")).text) != pid:
            continue
        channel = cells.get("channel-name")
        frame = cells.get("frame-number")
        yield (int(cells["start"].text), int(cells["duration"].text),
               channel.text if channel is not None and channel.tag != "sentinel" else "?",
               frame.text if frame is not None and frame.tag != "sentinel" else None)


def main():
    trace, pid = sys.argv[1], int(sys.argv[2])
    report(list(intervals_of(export(trace), pid)))


def report(intervals):
    if not intervals:
        sys.exit("No GPU intervals for that process")
    first = min(s for s, _, _, _ in intervals)
    last = max(s + d for s, d, _, _ in intervals)
    seconds = (last - first) / 1e9

    # Busy time is the union of the intervals, as channels overlap
    busy = 0
    end = 0
    for s, d, _, _ in sorted(intervals):
        if s + d > end:
            busy += s + d - max(s, end)
            end = s + d
    per_channel = {}
    for _, d, c, _ in intervals:
        per_channel[c] = per_channel.get(c, 0) + d
    frames = len({f for _, _, _, f in intervals if f is not None})

    print(f"{seconds:.2f} s traced, GPU busy {busy / 1e6 / seconds:.1f} ms per second "
          f"({100 * busy / (last - first):.0f} %), {len(intervals) / seconds:.0f} intervals per second")
    if frames:
        print(f"{frames / seconds:.1f} frames per second, GPU busy {busy / 1e6 / frames:.2f} ms per frame")
    for c, d in sorted(per_channel.items(), key=lambda x: -x[1]):
        print(f"  {c:12} {d / 1e6 / seconds:8.1f} ms per second")


if __name__ == "__main__":
    main()
