#!/usr/bin/env python3
"""比较交错采集的首变、帧间隔和收尾。"""

import argparse
import csv
from dataclasses import dataclass
from math import isfinite
from pathlib import Path
from statistics import median


@dataclass
class Trial:
    first: float
    edge_first: float
    edge_end: float
    gaps: list[float]
    tail: float
    display: float


@dataclass
class Summary:
    first: float
    edge_first: float
    edge_end: float
    slow: float
    worst: float
    tail: float
    worst_tail: float
    display: float


def measure(path: Path, period: float, duration: int) -> Trial:
    with path.open(newline="") as source:
        rows = list(csv.DictReader(source))
    display = [float(row["relative_ms"]) for row in rows if row["source"] == "display"
               and -period <= float(row["relative_ms"]) <= 450 + period]
    if len(display) < 2 or display[0] > 0 or display[-1] < 450:
        raise ValueError(f"显示节拍未覆盖完整试验：{path}")
    display_gaps = [end - start for start, end in zip(display, display[1:])]
    if abs(median(display_gaps) - period) > period / 10:
        raise ValueError(f"实测显示节拍与指定刷新率不符：{path}")
    display_gap = max(display_gaps)

    def changes(column, cutoff):
        samples = [(float(row["relative_ms"]), row[column]) for row in rows
                   if row["source"] == "capture" and row.get(column)]
        before = [value for time, value in samples if time < 0]
        # An idle delivery confirms the retained image without carrying pixels.
        covered_end = any(row["source"] == "capture" and float(row["relative_ms"]) >= cutoff
                          and (row.get(column) or row["status"] == "1") for row in rows)
        if not before or not covered_end:
            raise ValueError(f"缺少点击前画面或收尾画面：{path}")
        previous = before[-1]
        times = []
        for time, value in samples:
            if 0 <= time <= cutoff and value != previous:
                times.append(time)
                previous = value
        if len(times) < 5:
            raise ValueError(f"缺少连续画面变化：{path}")
        return times

    full = changes("fingerprint", 370)
    edge = changes("silhouette", 450)
    gaps = [end - start for start, end in zip(full, full[1:])]
    tail = [end - start for start, end in zip(edge, edge[1:]) if end >= duration - 70]
    if not tail:
        raise ValueError(f"缺少收尾轮廓变化：{path}")
    return Trial(full[0], edge[0], edge[-1], gaps, max(tail), display_gap)


def aggregate(trials, period):
    gaps = [gap for trial in trials for gap in trial.gaps]
    return Summary(
        median(trial.first for trial in trials),
        median(trial.edge_first for trial in trials),
        median(trial.edge_end for trial in trials),
        sum(gap > 1.5 * period for gap in gaps) / len(gaps),
        max(gaps),
        median(trial.tail for trial in trials),
        max(trial.tail for trial in trials),
        max(trial.display for trial in trials),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hz", type=float, required=True)
    parser.add_argument("--check", action="store_true", help="对两组结果执行性能回归判定")
    parser.add_argument("directories", type=Path, nargs="+", help="按 A B A B 顺序填写采集目录")
    args = parser.parse_args()
    if not isfinite(args.hz) or args.hz <= 0 or len(args.directories) < 4 or len(args.directories) % 2:
        parser.error("需要正刷新率与至少两对交错采集")
    if len({path.resolve() for path in args.directories}) != len(args.directories):
        parser.error("各批必须来自独立采集目录")
    period = 1000 / args.hz
    failures = []
    for kind, label, duration in (("collapse", "收起", 280), ("expand", "展开", 340)):
        groups = [[], []]
        for index, directory in enumerate(args.directories):
            try:
                trials = [measure(path, period, duration) for path in sorted(directory.glob(f"{kind}-*.csv"))]
            except ValueError as error:
                parser.error(str(error))
            if len(trials) < 3 or (index > 0 and len(trials) != len(groups[(index - 1) % 2][-1])):
                parser.error(f"各批轮数必须相等且至少三轮：{directory}")
            groups[index % 2].append(trials)

        baseline, candidate = (aggregate([trial for batch in group for trial in batch], period) for group in groups)
        for group, result in zip("AB", (baseline, candidate)):
            print(f"{label} {group} 首变 {result.first:.1f}，轮廓首变 {result.edge_first:.1f}，"
                  f"轮廓末次变化 {result.edge_end:.1f}，慢间隔 {result.slow:.1%}，"
                  f"最长间隔 {result.worst:.1f}，尾段最长间隔中位数 {result.tail:.1f}，"
                  f"尾段最差 {result.worst_tail:.1f}，显示节拍最长 {result.display:.1f} 毫秒")
            if result.display > 1.5 * period:
                failures.append(f"{label} {group} 显示时钟有缺口，需复测")
        if (candidate.first > baseline.first + period / 2
                or candidate.edge_first > baseline.edge_first + period / 2):
            failures.append(f"{label}首变退步")
        if candidate.edge_end > baseline.edge_end + period or candidate.worst > baseline.worst + period / 2:
            failures.append(f"{label}轮廓终点时间或最长间隔退步")
        if candidate.slow > baseline.slow + 0.05:
            failures.append(f"{label}慢间隔占比退步")
        if candidate.tail > baseline.tail + period / 2 or candidate.worst_tail > baseline.worst_tail + period / 2:
            failures.append(f"{label}尾段间隔退步")
    if args.check and failures:
        parser.exit(1, "\n".join(failures) + "\n")


if __name__ == "__main__":
    main()
