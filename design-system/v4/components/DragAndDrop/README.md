拖动排序与归类：用一条细线标出落点；拖动期间，输入栏变形为分组架，拖到架上的组名即可移到该组。

**SwiftUI**：`TaskDragSource`、`TaskDrop`、`GroupDrop`，`composerBar` 外包 `GlassEffectContainer`。

**落点线**
- 1.5pt accent，两端圆角。
- 起点在目标层级的正文列：任务为 42，子任务为 64；终点为 348。
- 替换现在的 `HStack { Circle 5×5; Rectangle }`：**去掉圆点**，并加上 `.padding(.leading, sub ? 22 : 26)`。

**拖起的任务**
- 系统拖动图像，或自绘一块 `.glassEffect(.regular, in: .rect(cornerRadius: 10))`，内含勾选圆和正文，倾斜 1.2°。

**分组架**
- 拖动开始时，输入栏与分组架通过 `glassEffectID("composer", in: ns)` 完成变形。
- 分组架是胶囊，高 48，宽为面板宽减 24，组名使用 Serif 14 Semibold。
- 悬停的目标组为 ink，其余为 ink-faint。最右侧是“＋ 新分组”（Sans 12）。
- 松手后分组架变回输入栏。
- 组头本身仍然接受拖放（`GroupDrop`），规则不变。
