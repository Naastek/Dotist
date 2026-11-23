#!/usr/bin/env python3
"""Summarize scoped desktop frame evidence from Capture.swift."""

import argparse
import csv
from math import isfinite
from pathlib import Path
from statistics import median


def summarize(path, period_ms):
    with path.open(newline="") as source:
        rows = list(csv.DictReader(source))
    captures = [row for row in rows if row["source"] == "capture"]
    display = [float(row["relative_ms"]) for row in rows if row["source"] == "display"]
    previous = None
    changes = []
    for row in captures:
        fingerprint = row["fingerprint"]
        if not fingerprint:
            continue
        elapsed = float(row["relative_ms"])
        if fingerprint != previous and 0 <= elapsed <= 370:
            changes.append(elapsed)
        previous = fingerprint
    if len(changes) < 2 or len(display) < 2:
        raise ValueError(f"缺少可用时序：{path}")

    gaps = [end - start for start, end in zip(changes, changes[1:])]
    missing = repeats = idle = 0
    for start, end in zip(changes, changes[1:]):
        if end - start < 2.5 * period_ms:
            continue
        between = [row for row in captures if start < float(row["relative_ms"]) < end]
        missing += len(between) < round((end - start) / period_ms) - 1
        repeats += any(row["fingerprint"] for row in between)
        idle += any(row["status"] == "1" for row in between)
    display_gaps = [end - start for start, end in zip(display, display[1:]) if 0 <= start < end <= 370]
    if not display_gaps:
        raise ValueError(f"动画期间缺少独立显示节拍：{path}")
    return changes[0], gaps, missing, repeats, idle, max(display_gaps)


def main():
    parser = argparse.ArgumentParser(description="汇总安装包的玻璃开合时间")
    parser.add_argument("directory", type=Path, help="采集程序生成的目录")
    parser.add_argument("--hz", type=float, required=True, help="对照时的显示刷新频率")
    args = parser.parse_args()
    if not isfinite(args.hz) or args.hz <= 0:
        parser.error("刷新频率必须大于零")
    period = 1000 / args.hz

    for kind, label in (("collapse", "收起"), ("expand", "展开")):
        results = [summarize(path, period) for path in sorted(args.directory.glob(f"{kind}-*.csv"))]
        if not results:
            parser.error(f"缺少{label}样本")
        gaps = [value for result in results for value in result[1]]
        print(f"{label} {len(results)} 轮，首个变化中位数 {median(r[0] for r in results):.1f} 毫秒，"
              f"最长变化间隔 {max(gaps):.1f} 毫秒，慢间隔 {sum(gap > 1.5 * period for gap in gaps)}/{len(gaps)}")
        print(f"  长间隔内的采集缺口 {sum(r[2] for r in results)}、重复画面 {sum(r[3] for r in results)}、"
              f"空闲状态 {sum(r[4] for r in results)}（可重叠），显示回调最长间隔 {max(r[5] for r in results):.1f} 毫秒")


if __name__ == "__main__":
    main()
