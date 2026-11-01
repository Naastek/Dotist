图标统一使用 SF Symbols（regular），分三档尺寸，并按字形边缘对齐；唯一的自绘图形是 Logo。

**SwiftUI**：`DotistIcon.swift` 只保留 Logo，其余调用全部换成 `Image(systemName:)`。

| 档位 | 字号 | 点击区 | 用途 |
|---|---|---|---|
| 顶栏 | 14pt | 28×28 | `magnifyingglass` · `rectangle.split.2x1` · `ellipsis` · `arrow.down.right.and.arrow.up.left` |
| 中 | 13pt | 24×24 | `calendar`（日期行、输入栏） |
| 小 | 11pt | 22×22 | `plus` · `calendar` · `xmark` · `arrow.up.right.square` |
| 箭头 | 8–9pt semibold | 随文字 | `chevron.down` / `chevron.right` / `chevron.left` |
| 勾 | 9pt heavy | — | 完成勾选圆内的 `checkmark` |

规则：
- 颜色：默认 ink-muted，悬停 ink；组头操作和箭头用 ink-faint；开启中的开关项在菜单里用系统 ✓ 表示。
- 竖直方向居中到所在行文字的 20pt 行盒；水平方向用字形右缘对齐 348。
- 键盘焦点：图标变为 accent，不加底色。
