#!/usr/bin/env python3
"""列出收起轮廓到位后的非零像素差分，以及静止段的最大差分。"""

import argparse
import csv
import sys
from pathlib import Path


REGIONS = ("icon", "glass", "rim", "near_exterior", "background")


def read(path):
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


def measure(path, output):
    round_number = path.stem.split("-")[-1]
    path_to_frames = path.with_name(f"collapse-{round_number}.csv")
    captured = [row for row in read(path_to_frames) if row["source"] == "capture"]
    complete = [row for row in captured if row["fingerprint"]]
    # ScreenCaptureKit status 1 explicitly denotes an idle frame, with no new image.
    static_idle = sum(row["status"] == "1" and 650 <= float(row["relative_ms"]) <= 1250
                      for row in captured)
    changes = [
        new for old, new in zip(complete, complete[1:])
        if 0 <= float(new["relative_ms"]) <= 450 and new["silhouette"] != old["silhouette"]
    ]
    if not changes:
        raise ValueError(f"没有采到收起轮廓的移动：{path_to_frames}")
    edge = float(changes[-1]["relative_ms"])
    by_time = {row["host_s"]: index for index, row in enumerate(complete)}
    static_peaks = [0] * len(REGIONS)
    static_samples = 0

    for row in read(path):
        index = by_time[row["host_s"]]
        time = float(complete[index]["relative_ms"])
        deltas = [[int(row[f"{region}_{metric}"]) for metric in ("count", "above_two", "peak")]
                  for region in REGIONS]
        if 650 <= time <= 1250:
            static_samples += 1
            static_peaks = [max(previous, delta[2]) for previous, delta in zip(static_peaks, deltas)]
        elif edge < time < 650 and any(delta[0] for delta in deltas):
            previous_time = float(complete[index - 1]["relative_ms"])
            output.writerow([path.parent.name, round_number, f"{edge:.2f}", f"{time - edge:.2f}",
                             f"{time - previous_time:.2f}",
                             *("/".join(map(str, delta)) for delta in deltas), "", ""])
    if static_samples + static_idle < 10:
        raise ValueError(f"静止段有效采样不足：{path}")
    peaks = static_peaks if static_samples else [""] * len(REGIONS)
    output.writerow([path.parent.name, round_number, f"{edge:.2f}", "", "",
                     *peaks, static_samples, static_idle])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", type=Path, nargs="+")
    args = parser.parse_args()
    output = csv.writer(sys.stdout, lineterminator="\n")
    output.writerow(["batch", "round", "edge_ms", "after_edge_ms", "since_previous_complete_ms",
                     *REGIONS, "static_complete_samples", "static_idle_samples"])
    for directory in args.directories:
        paths = sorted(directory.glob("pixels-*.csv"))
        if not paths:
            parser.error(f"没有区域差分：{directory}")
        for path in paths:
            measure(path, output)


if __name__ == "__main__":
    main()
