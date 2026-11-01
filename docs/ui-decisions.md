# 已锁定的 UI 决定与防回退清单

本文件记录 2026-11-01 用户实机试用后的最新决定，是 v4.2 的最终依据。原因均为用户实机反馈及后续明确要求；下列测试仅表示相关守护，不能推断覆盖每一种视觉状态或实机验收。**修改任何一条前必须先与用户确认，并同步本文件、SPEC.md、测试。** 测试文件均位于 `native/Tests/`，按文件名列出；标注「暂无测试」表示未找到对应专项守护。

## 布局与结构

- 顶部第一行仅右侧工具栏，无分组标题、下拉菜单及箭头。分组便签始终依附面板左缘并跟随面板移动，不再翻到右侧：保持现有玻璃／纸色与分组主题色；静止为 10 pt 窄边、不显示文字，保留加强描边，深浅色均须可见。左侧空间足够时向左展开，子窗口在面板下方；空间不足完整展开宽度时，窄边尽可能露在左侧可用空间，其余贴在面板左缘内侧，悬停向右展开覆盖面板内容，四角柔和，展开及收回动画中子窗口在面板上方，完全收回后恢复面板下方（面板内窄边由同源内容覆盖层保持可见与可点击）。按最大展开宽度判断模式，回到向外模式需额外 80 pt 空间迟滞；空间不足时直接向内展开，不强制先完全收回再切换方向，正常悬停展开与收回保留，拖动跨阈值不反复跳变。便签列从面板顶部下方 40 pt 起，不遮挡工具栏图标；宽度适配完整组名、不省略，相邻间距 6 pt，「全部」固定第一，上下拖动排序与管理分组共享顺序；窗口、绘制与命中区域使用同一动画采样。守护：`SideTabGeometryTests.swift`；顶部无标题专项暂无测试。
- 工具栏只有「收起为悬浮球」常驻且始终最右；颜色、任务视图、置顶窗口、固定窗口默认悬停显示，设置可配置常驻／悬停／隐藏及顺序。按住 ⌘ 拖动排序，相邻图标实时挤开。无搜索按钮；⌘K 打开或再次关闭命令面板，面板只有输入框与结果，无标题、快捷键提示和关闭按钮。颜色按钮是填充当前色的圆，色板为圆形色块，选中用外圈、不用对勾。守护：`ToolbarConfigTests.swift`、`PanelInteractionRevisionTests.swift`、`SearchDragTests.swift`；命令面板外观和色板选中专项暂无测试。
- 所有悬停提示使用系统 tooltip（`.help`，约 1 秒），无底部提示行。输入栏组名与日历图标无下箭头；输入栏分组菜单标签及第一项将隐式 `inbox` 显示为「全部」（`model.text("全部")`），仅此入口使用该显示名，其它界面的「无分组」语义保留；日历仅悬停或聚焦显示，日期文字仅显式设置日期后显示。守护：`ComposerAlignmentTests.swift`（对齐）；其余专项暂无测试。
- 不再有可见的 Inbox 分组：内部 ID `inbox` 是隐式「无分组」桶，不出现在分组列表、便签或管理中。「全部」视图的无分组任务在最上方且无组头。删除分组将任务移到无分组、不删除任务；删除标签只移除标题中的 `#标签`，任务保留。分组和标签均可按住拖动排序，管理窗口与便签共享分组顺序。守护：`GroupTagThemeTests.swift`、`GroupPanelTypographyTests.swift`、`SideTabGeometryTests.swift`；标签拖动手势专项暂无测试。
- 分组可设 none 加 8 色，「全部」有默认颜色。既定设计意图是面板、悬浮球和便签的 Liquid Glass 按当前分组着色：浅色 16%、深色 18% wash，加同色 tint；提高对比度或降低透明度时使用极淡着色的纸色实底。当前便签运行时使用 `.paper`：主题着色的半透明纸色背景；降低透明度或提高对比度时为实底，不能据此声称便签实机 Liquid Glass 已通过验收。便签独立的 `sideTabOpacity` 默认 85%，范围 10…100%，仅作用于背景并随分组 `themeColor` 实时变化。设置「颜色主题」动态列出所有分组；面板可用颜色按钮或组头右键改色。守护：`PanelColorTests.swift`、`GroupTagThemeTests.swift`、`SettingsLayoutTests.swift`；便签离屏着色、不透明度及无障碍分支守护：`SideTabAppearanceTests.swift`；设置默认值、范围及持久化守护：`SideTabSettingsTests.swift`，不代表实机玻璃验收。

## 任务与交互

- 最多 5 层（0..4）。正文左缘 `textX(d)=42+22d`；圆左缘 `circleX(0)=16`、`circleX(d≥1)=textX(d-1)`；顶层圆直径 16 pt、子层 13 pt。正文左对齐，圆心与整块文字垂直居中，右缘对齐 348 pt。守护：`TaskHierarchyTests.swift`、`TaskInteractionTests.swift`、`OpticalAlignmentTests.swift`。
- 有直接子任务的任务圆按直接子任务数分段，间隙约 8°；N=1 为整圆，超过 12 段封顶并按比例表示；完成段为 accent、未完成段为 checkStroke。行尾 `1/3` 只是文字、不可点击。悬浮球绝不能出现进度环或弧，只显示剩余数字。父任务不可折叠，子任务始终显示；仅分组可点击组头折叠，折叠时组名旁显示小箭头且状态持久化；「已完成」区也可折叠。守护：`TaskInteractionTests.swift`；球无进度环及分组折叠持久化专项暂无测试。
- Return 新建同级并继续录入，空任务丢弃；Tab 缩进到前一个未选中同级任务，⇧Tab 提升，Esc 取消；空格或 ⌘Return 完成。Shift+点击选范围、⌘+点击增减、Shift+↑/↓ 扩展选择；选中态为圆描边 accent、正文 Medium。多选 Tab 整体归入选中集合之前最近的未选中同级任务。⌘Z／⇧⌘Z 会话内通用撤销／重做，上限 100 步；文本框内由文本框处理撤销。撤销提示 7 秒自动消失，悬停暂停。守护：`TaskInteractionTests.swift`、`TaskHierarchyTests.swift`、`AppModelUndoTests.swift`、`ComposerAlignmentTests.swift`、`PanelInteractionRevisionTests.swift`；各快捷键完整端到端专项暂无测试。
- 手势拖动参考 Tic：原位的被拖行及子树淡至 35%，目标位置显示同高灰色 ghost，不画跟随光标的浮起副本。水平移动超过 22 pt 缩进步长的 70% 才改变层级；层级大于 0 时画从父任务圆下方至 ghost 圆的圆角 L 形连接线，目标父圆描边 accent。松手一次提交，Esc 取消，多选整组拖；上下边缘 24 pt 自动滚动，开始瞬间页面零位移。单分组视图拖动时输入栏位置变为分组架，包含「无分组」落点。守护：`TaskDragDropTests.swift`、`TaskGestureGeometryTests.swift`、`TaskReorderEngineTests.swift`、`GroupPanelTypographyTests.swift`；连接线视觉专项暂无测试。
- 任务行是无底色悬停规则的唯一例外：整行 rule 10% 背景、圆角 6 pt、左右各外扩 6 pt；多选 16%，编辑 18%。悬停操作 ＋、日历、× 使用固定列，其右缘在行右缘左侧 88 pt，浮在标题尾部上方；标题尾部 mask 渐隐，不画色块，行尾元信息始终可见可点。整行除圆、元信息及按钮外均可点击编辑。守护：`TaskRowMetadataTests.swift`；背景、mask 及整行点击专项暂无测试。
- 日期筛选行高 34 pt，选中 17 pt Medium ink，未选中 14 pt Regular faint，槽宽始终按 17 pt Medium 预留；按与选中项的槽位距离 0／1／2／3／≥4，文字不透明度为 1／0.78／0.58／0.42／0.32；悬停至少 0.9 并转为 muted，键盘焦点为 accent 且全不透明；VoiceOver 或「提高对比度」开启时不衰减；保留光学居中及拖动窗口手势；「今天」视图不重复显示「今天」分区标题。今天筛选为逾期加今天到期；今天面板分区为「已逾期」「接下来 7 天」「已完成」。全部包括所有未完成任务（含无分组及深层）；明天为明天；本周遵循系统周起始日；未来 7 天为 T..T+6；另有已逾期、无日期；已完成无数量上限、按更新时间倒序；自定义范围包含两端。子任务命中时保留灰显的祖先上下文。守护：`TaskFilteringTests.swift`、`DateFilterModelTests.swift`；筛选字号、槽宽、光学居中守护：`PanelFeedbackRevisionTests.swift`；渐隐及可访问性分支守护：`TaskEmptyStateTests.swift`。精确定义见 `native/Sources/DotistCore/TaskFiltering.swift`：面板通过 `todaySections` 组合逾期与今日结果；底层 `filter(scope: "today")` 单独返回今日范围。

- 筛选主结果为空时，空状态块中心位于列表视口高度约 38%，主文案为 15 pt Medium ink，按今天、明天、本周、下周、未来 7 天、已逾期、无日期、已完成、自定义范围、分组和全部区分；次文案 12 pt faint，单行省略，均为 Sans，无插图、emoji、装饰图标或卡片底。已逾期和已完成不显示提示及添加入口；其它视图显示任务行式「添加任务」，圆左缘 16 pt、正文左缘 42 pt，点击原处进入原生草稿编辑，Return 创建并继续录入、Esc 或空草稿取消。新任务属于当前分组（全部视图为隐式无分组），今天／明天分别带当日／次日日期，其它日期范围取起始日，无日期／已完成／已逾期／全部不带日期；自定义范围优先。空状态仅在空结果时叠加于列表空白区域，不覆盖筛选行、不移动正常任务行或辅助分区；今天的未来与已完成等辅助分区保留原位，空状态避让其点击区域，展开辅助任务时隐藏空状态。守护：`TaskEmptyStateTests.swift`、`PanelFeedbackRevisionTests.swift`。

## 视觉规范

- 衬线体仅用于名字：组头、今天视图分区标题、便签、输入栏组名、拖动分组架、跨组行尾组名、管理窗口分组名、快速添加组名、甘特组名。日期大标题、设置标题、管理窗口切换标题、日历年月、悬浮球数字、任务正文等均用无衬线。统一经 `DotistDesign.nameFont`／`textFont`，禁止绕过封装使用系统字体；MCP 配置等宽文本除外。守护：`GroupPanelTypographyTests.swift`；所有调用点专项暂无测试。
- 字体默认：西文名字用 Newsreader（可变 wght／opsz），交互与正文用 Atkinson Hyperlegible Next（可变 wght）；中文默认思源宋体／思源黑体，按简体、繁体、日文选择 Noto SC／TC／JP。中文不使用楷体。外观中的「字体」提供西文衬线、西文无衬线、中文衬线、中文无衬线四个菜单、即时混排预览和「恢复默认字体」。西文可选原 Source Serif 4／Source Sans 3 或系统 New York／SF Pro；中文可选系统宋体／苹方，日文保留 JP 区域变体。昭源宋体 Chiron Sung HK VF 仅用于繁体，简体和日文回退对应 Noto；霞鹜新晰黑官方为 IPA Font License，未作为 OFL 字体打包。设置以 `font_serif_latin`／`font_sans_latin`／`font_serif_cjk`／`font_sans_cjk` 保存，缺失或未知值回退默认；所有界面即时刷新，无需重启。字体与度量缓存必须区分四项偏好、字重、区域和可变轴；光学偏移按实际字体墨迹重新测量：4× 校准基线，2× 测量残差并对齐像素网格；原生菜单保留基线属性，普通文本另补实测残差，均保持 ≤0.5 pt。字体下载仅用官方固定版本文件，SHA-256 与 OFL 许可证随包校验；新默认缺失时依次回退原 Source 和系统。守护：`FontPreferenceTests.swift`、`OpticalAlignmentTests.swift`。
- 同行图标与文字以墨迹中心对齐，差不超过 0.5 pt；统一使用 `Design/DotistOptical.swift` 封装与实测偏移表，禁止零散 `offset` 补偿。离屏渲染守护：`OpticalAlignmentTests.swift`、`ComposerAlignmentTests.swift`。
- 中文使用全角标点（，。：；！？（）「」…——）；中文与英文单词、数字单位间留一个半角空格；说明句加句号，按钮、标题、菜单不加句末标点。en／ja／zh-TW 按各自规范；locales 键与源码中文一致。守护：`LocalizationPunctuationTests.swift`。
- 设置为系统设置式布局：左侧栏纯文字无图标、顶部 Liquid Glass 搜索气泡；右侧分组容器、44 pt 行、垂直居中、小开关，容器间有清晰区域；导航文字起点为 38 pt；颜色主题动态列出分组，全部颜色行显示「全部」／“All”，不附加 default color；所有色板使用圆形色块及选中外圈，不显示对勾。外观提供独立的便签背景不透明度设置；当前滑块位于「外观」分组内，与玻璃预设、透明程度和磨砂程度同组。守护：`SettingsLayoutTests.swift`、`SettingsSearchTests.swift`、`OpticalAlignmentTests.swift`。
- 菜单栏 count 模式使用 26 × 18 pt 模板图像：数字位于 16 pt 圆内，右侧有小点，无外置 title。今天计数包含逾期及今日未完成任务，保留分组过滤；显示 99+ 时 tooltip 和辅助功能仍提供完整数量。文字模式保留。一次系统 status item 实屏测试场景中旧宽度为 60 pt、新宽度为 42 pt，不推及所有系统。
- 输入栏 placeholder 与 editor 同一时刻只能有一个绘制所有者；箭头位置须按真实原生窗口的墨迹验证。
- 面板、悬浮球、悬浮横条、快速添加、命令面板、设置和任务视图统一使用 AppKit 系统阴影；透明窗口的 SwiftUI 内容裁切决定轮廓，形状、尺寸或着色变化及动画过程中刷新阴影。禁止独立阴影子窗口及玻璃外的自绘实心阴影层，避免错位底板与残影。守护：`PanelShadowTests.swift`、`PanelMotionLifecycleTests.swift`。
- 悬浮横条的 48 pt 圆保持原位，宽度按标题／单行元数据的较宽者加 78 pt（圆 48、圆与文字间距 18、外边距 12）分配，最多 440 pt 或屏幕可用宽度一半，不设固定 250 pt 下限。圆在左或右时文字均左对齐；标题与可选元数据构成一个整体，以最终截断后的 CoreText 墨迹边界对齐圆心，数字也按实际墨迹居中，避免 `ImageRenderer` 校准与窗口渲染差异。无元数据时仅显示居中的标题。守护：`BubbleLayoutTests.swift` 的真实 AppKit／`NSHostingView` 离屏截图与位置测量；窗口缓存不包含 WindowServer 绘制的系统阴影，不能据此宣称实机阴影缺陷已消除。
- 相对 v4 原禁用项，允许便签耳朵形状及玻璃、任务行悬停背景、编辑态底、分段进度圆。仍禁止悬浮球进度环／弧、按钮或标签下划线指示、条目前小圆点、选中项左侧竖线、编辑时放大字号加下划线、面板内再嵌玻璃按钮、分组色点。守护：上述相关测试；其余视觉禁项暂无专项测试。

## 常见回退陷阱

- 不要把输入栏或顶部的菜单改回带箭头的 Menu，也不要恢复顶部组名和搜索按钮。
- 不要恢复父任务折叠或让 `1/3` 成为按钮；不要给悬浮球加进度环。
- 不要把隐式 `inbox` 展示成分组，也不要删除分组时删除任务。
- 不要用系统字体绕过 `nameFont`／`textFont`，不要在 SwiftUI 中零散用 `offset` 补居中。
- 不要改 locales 键而不同步源码中文；不要恢复底部悬停提示行。
- 不要把旧截图、历史文档或旧 HTML 示意当作新设计依据；拖动不能出现跟随鼠标的浮起副本。
