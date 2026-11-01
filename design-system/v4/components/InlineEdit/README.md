原位编辑：点击正文后就在原地变成可编辑状态，位置、字号、行高和颜色都不变，唯一的变化是出现竹青色光标。

**SwiftUI**：`taskRow` 中 `editing == task.id` 的分支，使用 `TaskEditor`。

- `TaskEditor` 使用 Sans 13 和 20pt 行高，`textContainerInset` 和 `lineFragmentPadding` 都设为 0（已经是），保证文字与非编辑状态逐像素重合。光标颜色设为 accent（`insertionPointColor`）。
- 不加底色、边框、下划线，不放大字号。
- 删除“Return 保存 · ⇧Return 换行 · Tab 缩进”这行提示。快捷键说明放到“⋯ → 键盘快捷键”里。
- 其他行**不再降低到 0.45 透明度**。
- 编辑时元信息和行操作都隐藏，换行后行高随内容增长。
- Return 保存，Esc 取消，Tab 和 ⇧Tab 调整缩进（与现在一致）。
