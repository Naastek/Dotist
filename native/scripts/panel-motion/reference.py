#!/usr/bin/env python3
"""从同屏画面核对按钮反馈和折叠中段的采集覆盖。"""

import argparse
import csv
import sys
from math import isfinite
from pathlib import Path
from statistics import median

# Eight gray levels as delivered in the display capture color space.
GRAY = (0, 48, 91, 129, 162, 195, 225, 255)
BUTTON_DELTA = 1.0


def read_trial(path, stream="capture", *, has_reference=True):
    with path.open(newline="") as source:
        rows = list(csv.DictReader(source))
    down, = (float(row["relative_ms"]) for row in rows if row["source"] == "mouse-down")
    frames = [
        (float(row["relative_ms"]), int(row["silhouette"]), float(row["button_luma"]),
         min(range(len(GRAY)), key=lambda level: abs(GRAY[level] - int(row["reference_luma"])))
         if has_reference else None)
        for row in rows if row["source"] == stream and row["reference_luma"]
    ]
    if has_reference and len({frame[3] for frame in frames}) != len(GRAY):
        raise ValueError(f"同屏参考块未完整呈现：{path}")
    return down, frames


def button(down, frames, period):
    before = [frame for frame in frames if down - 80 <= frame[0] < down]
    held = [frame for frame in frames if down <= frame[0] < 0]
    if (not before or not held or held[-1][0] - down < 80
            or down - before[-1][0] > 2 * period or -held[-1][0] > 2 * period):
        raise ValueError("长按试验缺少按住期间或按下前的画面")
    rest = median(frame[2] for frame in before)
    feedback = [frame for frame in held if abs(frame[2] - rest) >= BUTTON_DELTA]
    if any(frame[1] != before[-1][1] for frame in held):
        raise ValueError("松开前折叠轮廓已移动")
    onset = feedback[0][0] - down if feedback else None
    # An early sampled change is positive evidence. A late sampled change is
    # inconclusive when the reference itself missed an intervening frame.
    covered = feedback and continuous([before[-1]] + [frame for frame in held if frame[0] <= feedback[0][0]], period)
    return onset, max((abs(frame[2] - rest) for frame in held), default=0), bool(covered)


def short_click(down, frames):
    if not -50 <= down < 0:
        raise ValueError("短按试验的按住时间异常")
    before = [frame for frame in frames if frame[0] < down]
    if not before:
        raise ValueError("短按试验缺少按下前的画面")
    _, edge, rest, _ = before[-1]
    for time, silhouette, luma, _ in frames:
        if time < down:
            continue
        if silhouette != edge or time > 50:
            break
        delta = abs(luma - rest)
        if delta >= BUTTON_DELTA:
            return time - down, delta, time < 0
    return None, 0, False


def continuous(frames, period):
    return all(
        0.5 * period <= end[0] - start[0] <= 1.5 * period
        and (start[3] is None or (end[3] - start[3]) % len(GRAY) == 1)
        for start, end in zip(frames, frames[1:])
    )


def middle_coverage(frames, period):
    middle_frames = [frame for frame in frames if 50 <= frame[0] <= 210]
    if len(middle_frames) < 2:
        raise ValueError("收起中段缺少显示画面")
    covered = sum(continuous((start, end), period) for start, end in zip(middle_frames, middle_frames[1:]))
    expected = round((middle_frames[-1][0] - middle_frames[0][0]) / period)
    return expected, covered


def middle(frames, period):
    # Exclude startup and the last 70 ms of the 280 ms collapse curve.
    edges = []
    for index, frame in enumerate(frames):
        if 0 < index and 50 <= frame[0] <= 210 and frame[1] != frames[index - 1][1]:
            edges.append(index)
    if len(edges) < 4:
        raise ValueError("收起中段缺少可测的轮廓变化")
    for first, last in zip(edges, edges[1:]):
        start, end = frames[first][0], frames[last][0]
        if end - start < 2.5 * period:
            continue
        interval = frames[first:last + 1]
        yield start, end, len(interval), continuous(interval, period)


def paired_gaps(display, filtered, period):
    for start, end, count, covered in middle(filtered, period):
        reference = [frame for frame in display if start - period / 2 <= frame[0] <= end + period / 2]
        if (not reference or abs(reference[0][0] - start) > period / 2
                or abs(reference[-1][0] - end) > period / 2 or not continuous(reference, period)):
            result = "整屏覆盖不足"
        elif any(frame[1] != reference[0][1] for frame in reference[1:-1]):
            result = "整屏在该区间内有轮廓变化"
        else:
            result = "整屏也呈现相同轮廓"
        yield start, end, count, covered, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("button", "click", "middle", "paired"))
    parser.add_argument("directories", type=Path, nargs="+")
    parser.add_argument("--hz", type=float, required=True)
    parser.add_argument("--check", action="store_true", help="检查按钮时限或可确认的中段停顿")
    args = parser.parse_args()
    if not isfinite(args.hz) or args.hz <= 0:
        parser.error("刷新率必须是有限正数")
    period = 1000 / args.hz
    writer = csv.writer(sys.stdout, lineterminator="\n")
    failed = False
    if args.mode == "button":
        writer.writerow(("批次", "轮次", "按下到反馈毫秒", "亮度变化峰值", "参考块连续", "三周期内反馈"))
    elif args.mode == "click":
        writer.writerow(("批次", "轮次", "按下到反馈毫秒", "亮度首次变化", "松开前已可见", "三周期内反馈"))
    elif args.mode == "middle":
        writer.writerow(("批次", "轮次", "间隔起点毫秒", "间隔终点毫秒", "间隔内画面数",
                         "参考块连续", "中段预期刷新数", "中段连续覆盖刷新数"))
    else:
        writer.writerow(("批次", "轮次", "窗口间隔起点毫秒", "窗口间隔终点毫秒",
                         "窗口间隔内画面数", "窗口帧时间连续", "整屏呈现"))
    for directory in args.directories:
        trials = sorted(directory.glob("collapse-*.csv"))
        if not trials:
            parser.error(f"缺少收起试验：{directory}")
        for path in trials:
            try:
                down, frames = read_trial(path, has_reference=args.mode != "click")
                if args.mode == "button":
                    onset, delta, covered = button(down, frames, period)
                    timely = onset is not None and onset <= 3 * period
                    writer.writerow((directory.name, path.stem, "" if onset is None else round(onset, 2),
                                     round(delta, 2), int(covered), int(timely)))
                    failed |= not timely
                elif args.mode == "click":
                    onset, delta, before_release = short_click(down, frames)
                    timely = onset is not None and onset <= 3 * period
                    writer.writerow((directory.name, path.stem, "" if onset is None else round(onset, 2),
                                     round(delta, 2), int(before_release), int(timely)))
                    failed |= not (timely and before_release)
                elif args.mode == "middle":
                    coverage = middle_coverage(frames, period)
                    gaps = list(middle(frames, period))
                    if not gaps:
                        writer.writerow((directory.name, path.stem, "", "", "", "", *coverage))
                    for start, end, count, covered in gaps:
                        writer.writerow((directory.name, path.stem, round(start, 2), round(end, 2),
                                         count, int(covered), *coverage))
                        failed |= covered
                else:
                    _, filtered = read_trial(path, "filtered", has_reference=False)
                    gaps = list(paired_gaps(frames, filtered, period))
                    if not gaps:
                        writer.writerow((directory.name, path.stem, "", "", "", "", ""))
                    for start, end, count, covered, result in gaps:
                        writer.writerow((directory.name, path.stem, round(start, 2), round(end, 2),
                                         count, int(covered), result))
                        failed |= result == "整屏也呈现相同轮廓"
            except ValueError as error:
                parser.error(f"{path}：{error}")
    return int(args.check and failed)


if __name__ == "__main__":
    raise SystemExit(main())
