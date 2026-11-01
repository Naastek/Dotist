输入栏固定在面板底部，高 52，从左到右依次是组名、正文输入和到期按钮。

**SwiftUI**：`MainWindow.composerBar`、`ComposerLayout`、`ComposerInput`。

- 顶部 0.5pt `rule` 发丝线；padding 左 16、右 11。
- 组名：Serif 13 Semibold，ink-muted，后接 9pt 箭头。点击弹出原生 `Menu`（替代现在的 popover 加 `GroupPickerRow`），当前组用系统 ✓ 标出。
- 正文：Sans 13/20，占位文字用 ink-faint，光标用 accent（加 `.tint(DotistDesign.accent)`，或设置 `NSTextView.insertionPointColor`）。
- 到期按钮移到**最右侧**：`calendar` 13pt / 24×24，字形右缘对齐 348。设置了到期日时，日期文字（Sans 12，accent）显示在图标左侧。
- `ComposerLayout` 的顺序因此改为：组名 → 正文 → 到期。窄宽度下需要换行时，到期按钮跟随第一行。
- 标签补全：改为输入栏上方 8pt 处的浮起玻璃列表（`radius-float` 12）。当前项用 ink + Medium，其余用 ink-muted，不铺底色。
