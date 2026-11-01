原位编辑：Sans 13/20，位置和颜色不变，光标 accent。输入区使用 rule 18% 不透明度浅色底，圆角 6，左右各外扩 6，文字不位移；无下划线或字号放大。换行续行对齐本层 textX。

`TaskEditor` 的 `textContainerInset` 和 `lineFragmentPadding` 为 0。编辑时隐藏元信息和行操作，其他行不变暗。悬停提示使用系统 tooltip（`.help`），不显示底部提示行。

行选择：Shift+点击范围、⌘+点击增减、Shift+↑/↓ 扩展；选中圆描边 accent，正文 Medium，不加选中底。Tab 将选中任务全部归为选中集合之前最近一个未选中的同级任务的子任务，⇧Tab 提升一级，Esc 清除选择，Return 在行上新建同级任务。层级为 0..4。
