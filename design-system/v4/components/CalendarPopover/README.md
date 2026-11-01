日历弹层用于选择到期日或日期区间；它是原生 popover，日期状态只靠颜色和字重区分。

**SwiftUI**：`RangeCalendar.swift`。

- 外壳用 `.popover`，系统自带玻璃，不另加背景。宽 252，内边距 12。
- 月份标题：Serif 14 Semibold；前后翻页 `chevron.left` / `chevron.right`，11pt / 22×22。
- 快捷项（今天、明天、本周、下周）：Sans 12，选中 ink + Medium，其余 ink-faint。
- 日期格：Sans 12，行高 28，tabular-nums。
- 底部：“清除”用 ink-muted，“完成”用 accent Medium。

**日期状态**

| 状态 | 颜色 | 字重 |
|---|---|---|
| 普通 | ink-muted | Regular |
| 有任务 | ink | Regular |
| 今天 | ink | Semibold |
| 区间内 | accent | Regular |
| 区间端点 / 单选 | accent | Semibold |
| 其他月份 | ink-faint | Regular |

**删除**：端点的 accent 实心圆（`Circle().fill(accent)` 24），以及“有任务”的 6×2 小横条。
