# AGENTS.md

Dotist 为原生 macOS SwiftUI 应用。架构迁移、UI 决策与视图设计详见 [docs/swiftui-migration.md](docs/swiftui-migration.md)、[docs/ui-decisions.md](docs/ui-decisions.md)、[docs/views-r1.md](docs/views-r1.md) 与 [docs/native-macos.md](docs/native-macos.md)。

## 1. 设计品味与材质方向

- **材质方向（2026-11-05 更新）**：正常表面为「玻璃主体 + 染色层 + 边缘反射 + 独立前景文字」，**禁止再用“纸色 / 纸底 / 便签纸”语义推导表面材质**；染色层承担分组色、明暗与密度，不透明表面仅作降低透明度或提高对比度时的回退态。
- **形状与状态区分**：严格遵循设计系统圆角（`6 / 8 / 12px`），正圆仅用于勾选圆圈、开关和浮动气泡，**禁用胶囊形 tab / chip**。优先以形状、尺寸、透明度区分状态，分组颜色仅用小圆点标识，不用彩色文字。
- **透明度与阴影**：保持工程安全透明，不得遮挡阅读与工作；通过染色、柔光晕、稳固表面与闲置淡出保证可读性。默认开启柔和系统阴影，禁用深色细边线（改用浅色高光边缘）。
- **色彩、入口与禁忌（Hard No）**：
  - 不使用黄/奶油色，遵循 Design System v3.1（中性冷白、炭灰、竹绿强调）；hover/选中不使用填充圆角底板，改为文字色 + 2px 下划线（pin 开启态保留填充/直立以明确区分开关状态）。
  - 设置置于独立窗口（菜单栏、快捷键、`Cmd+,`），不在主窗口内放置设置按钮。
  - 明确禁止：左侧竖向选中条、编辑中任务下划线、填充选中底板、气泡/胶囊/耳翼的弹簧过冲回弹（spring / overshoot bounce），以及任何 macOS 窗口平铺行为（窗口须禁用 tiling）。
  - 无法在无辅助功能/屏幕录制权限时自行截取原生窗口截图，未实测的视觉结果须明确标示“未验证”。

## 2. 全交互动效要求

- 任何显隐、hover 展开（日期筛选条、工具栏图标、行操作、popover）与状态切换都必须有动画，禁止生硬跳变。
- 使用 `withAnimation` / `.animation`（约 `0.14–0.16s easeOut`）与视图插入过渡 `transition`，且必须遵守 `accessibilityReduceMotion`（开启减少动态效果时将动画设为 `nil`）。

## 3. 产物与备份路径约束

- 所有构建产物、快照、备份与构建缓存一律写入项目目录内的 `.cache/` 子目录，**严禁在 `~/DevProjects/` 同级新建目录**。
- 安装前备份写入 `.cache/install-backups/$(date +%Y%m%dT%H%M%S)`，且只保留最近 3 份。
