主面板是 Dotist 唯一常驻的玻璃：从上到下依次是标题与工具（44）、日期范围（30）、可选的标签行（24）、任务列表、输入栏（52）。

**SwiftUI**：`MainWindow.body`，玻璃来自 `WindowMaterial` / `FloatingMaterial`。

- 尺寸 364 × 620，圆角 `radius-window` 20。
- 面板内只有文字、图标和发丝线，没有任何底块、胶囊或玻璃按钮。
- 原来的分组标签行（`groupTabs`）删除，分组切换交给标题菜单（见 TitleMenu）。
- 列表的 `LazyVStack(spacing:)` 由 24 改为 0；组间距由每个组自身的 `.padding(.top, 20)` 提供（第一个组为 6）。
- 列表外层左右 padding 16。

**玻璃**：`.glassEffect(.regular, in: .rect(cornerRadius: 20))` 上叠 `paper.opacity(用户透明度)`。系统开启“减少透明度”时直接用 `paper` 实色。
