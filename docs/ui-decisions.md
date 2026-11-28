# 已锁定的 UI 决定与防回退清单

本文件记录已确认的界面与交互约定。**修改任何一条前须先与用户确认，并同步更新本文件及 `native/Tests/` 下对应的守护测试**（标注「暂无测试」表示暂无专项守护；桌面实拍归档见[报告目录](reports/README.md)）。

## 布局与结构

- **顶栏与侧边分组便签**：顶部第一行仅保留右侧工具栏，无分组标题、下拉菜单及箭头。分组便签始终依附面板左缘并随面板移动，不翻到右侧：静止普通项宽 10 pt，当前面板 `TaskPanelState.groupID` 对应项（含 `nil`「全部」）宽 15 pt 且不显示文字，使用更清晰的主题色／中性色实面染色，展开态保留选中字重、无轮廓描边（白／黑底可见合成色差阈值 1/255）。左侧空间足够时向左展开（子窗口在面板下方）；空间不足完整展开宽度时，窄边尽可能露在左侧，其余贴面板左缘内侧，悬停向右展开覆盖面板内容，连接面板一侧为直角、外侧两角为圆角，展开及收回动画期间子窗口置于面板上方，完全收回后恢复下方。按最大展开宽度判断方向，回到向外模式需额外 80 pt 迟滞，拖动跨阈值不反复跳变。便签列从面板顶部下方 40 pt 起，宽度适配完整组名不省略，间距 6 pt，「全部」固定第一，与管理分组共享上下拖动顺序；窗口、绘制与命中区域共用同一动画采样。拖动任务（含子任务整块与多选）移入便签时复用 `CADisplayLink` 时钟展开并高亮落点，松手归组（拖入「全部」归入隐式无分组 `inbox`）并支持 ⌘Z／⇧⌘Z 撤销重做。面板展开完成后，便签按顺序从连接边伸出 8 pt 并淡入（每项 180 ms ease-out，常规间隔 35 ms，大量分组总起始延迟上限 280 ms、最晚 460 ms 完成），收起与快速重开从当前呈现连续衔接，未呈现项不参与命中或 AX，降低动态效果时立即呈现／隐藏。
  - 守护：`SideTabGeometryTests.swift`、`SideTabAppearanceTests.swift`、`SideTabEntranceTests.swift`、`SideTabAndDateDropTests.swift`；顶部无标题专项暂无测试。
- **非便签按压冻结**：拖动或缩放主窗口期间，冻结便签当前展开目标并取消待执行的悬停收起，松开后恢复悬停判断；便签自身点击／排序不受影响。
  - 守护：`SideTabEntranceTests.swift`。
- **工具栏与命令面板**：工具栏仅「收起为悬浮球」常驻且最右；颜色、任务视图、置顶窗口、保持展开默认悬停显示，可在设置中配置常驻／悬停／隐藏及顺序。「保持展开」沿用锁形图标，仅暂停自动收起与失焦淡出、不锁定窗口位置或尺寸，归于设置「通用 > 展开与收起」。按住 ⌘ 拖动排序时相邻图标实时挤开。无搜索按钮；⌘K 切换命令面板，面板仅含输入框与结果，无标题、快捷键提示与关闭按钮。颜色按钮为填充当前色的圆，色板为圆形色块，选中用外圈不用对勾。
  - 守护：`ToolbarConfigTests.swift`、`PanelInteractionRevisionTests.swift`、`SearchDragTests.swift`、`SettingsLayoutTests.swift`、`SettingsSearchTests.swift`；命令面板外观和色板选中专项暂无测试。
- **提示与输入栏**：所有悬停提示使用系统 tooltip（`.help`，约 1 秒），无底部提示行。输入栏组名与日历图标无下箭头；输入栏分组菜单标签及首项将隐式 `inbox` 显示为「全部」（`model.text("全部")`），仅此入口使用该显示名，其它界面保留「无分组」语义；日历仅悬停或聚焦显示，日期文字仅在显式设日期后显示。
  - 守护：`ComposerAlignmentTests.swift`；其余专项暂无测试。
- **隐式无分组与管理**：内部 ID `inbox` 是隐式「无分组」桶，不出现在分组列表、便签或管理中。「全部」视图的无分组任务置顶且无组头。删除分组将任务迁移至无分组、不删除任务；删除标签仅移除标题中的 `#标签`。分组和标签均支持按住拖动排序，管理窗口与便签共享分组顺序。
  - 守护：`GroupTagThemeTests.swift`、`GroupPanelTypographyTests.swift`、`SideTabGeometryTests.swift`；标签拖动手势专项暂无测试。
- **材质、主题色与无障碍表面**：分组可选 `none` 加 8 色，「全部」有默认颜色。展开态主面板提供「清透水滴」（`NSGlassEffectView.Style.clear`）与「柔和自适应」（`NSGlassEffectView.Style.regular`，默认，由系统按窗口背后明暗自动调节模糊与对比度）两档原生玻璃材质切换（存储键 `panel_material`），不再叠加独立 `NSVisualEffectView` 或手写 wash 层；展开态按当前分组着色（`NSGlassEffectView.tintColor` 加柔和内羽化 tint，柔和自适应浅色 16%、深色 18%，清透水滴浅色 8%、深色 10%）。历史 `settings.json` 仅含旧 `opacity`/`frost` 时兼容读取不报错，旧透明/极致组合（`opacity <= 40 && frost <= 25`）内存推断为清透水滴，其余推断为柔和自适应且不改写磁盘文件。compact 悬浮球／横条固定使用原生 `.clear` 玻璃与三分之一强度分组 tint（无分组色时不加 tint），不受展开态 `panel_material` 影响。展开面板与 compact 共用按尺寸和浅深外观标定的定向边缘层（左上细亮、向两侧衰减、窄幅内侧光边、中心透明，球到横条按宽度连续插值）。compact 保留 48 pt 点击区与原有几何，普通玻璃轮廓四周内收 2 pt（球可见 44 × 44 pt，240 × 48 pt 横条可见 236 × 44 pt），展开态与无障碍实底不内收；原生 regular glass 在窗口失焦时可能随系统 key 状态变灰，保留上述材质内收与定向光边。不绘制人工黑色内缘；提高对比度或降低透明度时，展开态、compact 与便签均使用不透明回退表面并关闭装饰边缘。便签背景使用半透明染色层，存储键 `sideTabOpacity`（默认 85%，范围 0…100%），界面反向显示为「分组便签背景透明度」（默认 15%），随分组 `themeColor` 实时变化。玻璃调试仅在环境变量 `DOTIST_GLASS_DEBUG=1` 时启用，参数仅驻留进程内存，不写入 `UserDefaults` 或 `settings.json`。设置「颜色主题」动态列出所有分组，面板可用颜色按钮或组头右键改色。
  - 守护：`GlassEdgePolishTests.swift`、`CompactGlassPerimeterTests.swift`、`TransientGlassTests.swift`、`TransientGlassDebugTests.swift`、`PanelColorTests.swift`、`GroupTagThemeTests.swift`、`SettingsLayoutTests.swift`、`SideTabAppearanceTests.swift`、`SideTabSettingsTests.swift`。

## 任务与交互

- **五层层级与几何**：最多 5 层（`0..4`）。正文左缘 `textX(d) = 42 + 22d`；圆左缘 `circleX(0) = 16`、`circleX(d≥1) = textX(d-1)`；顶层圆直径 16 pt、子层 13 pt；正文左对齐，圆心与整块文字垂直居中，右缘对齐 348 pt。
  - 守护：`TaskHierarchyTests.swift`、`TaskInteractionTests.swift`、`OpticalAlignmentTests.swift`。
- **进度圆与分组折叠**：有直接子任务的任务圆按直接子任务数分段（间隙约 8°，`N=1` 为整圆，超过 12 段封顶按比例表示，完成段 `accent`、未完成段 `checkStroke`）；行尾 `1/3` 仅为文字不可点击；悬浮球不显示进度环或弧，仅显示剩余数字。父任务不可折叠、子任务始终展开；仅分组可点击组头折叠并持久化，组头为单一右箭头连续旋转 0…90° 预留固定槽位，不挤占标题，真实内容按固有高度连续裁切并渐显（220 ms 平滑时钟，支持反向衔接，降低动态效果时立即切换）；「已完成」区亦可折叠。
  - 守护：`TaskInteractionTests.swift`、`PanelFeedbackRevisionTests.swift`、`GroupHeaderRenderingTests.swift`；悬浮球无进度环专项暂无测试。
- **键盘操作、多选与撤销**：`Return` 新建同级并继续录入（空任务丢弃）；`Tab` 缩进到前一个未选中同级任务，`⇧Tab` 提升，`Esc` 取消；空格或 `⌘Return` 完成。`Shift+点击` 选范围、`⌘+点击` 增减、`Shift+↑/↓` 扩展选择；选中态圆描边 `accent`、正文 Medium；多选 `Tab` 整体归入选中集之前最近的未选中同级。`⌘Z`／`⇧⌘Z` 会话内通用撤销／重做（上限 100 步，文本框内交由文本框处理），撤销提示 7 秒自动消失、悬停暂停。
  - 守护：`TaskInteractionTests.swift`、`TaskHierarchyTests.swift`、`AppModelUndoTests.swift`、`ComposerAlignmentTests.swift`、`PanelInteractionRevisionTests.swift`；完整快捷键端到端专项暂无测试。
- **手势拖动排序与跨区归类**：浮起块直接跟随指针，内容固定一行 32 pt，子树／多选数量以 `+N` 表示；被拖头行保持挂载但不可见，作为唯一占位。标题与任务位于同一 SwiftUI 布局树；仅槽位或层级变化时以 0.16 秒 snappy 过渡，松手以 0.18 秒 snappy 一次提交并撤去占位。折叠组内及未完全展开／裁剪的行排除在拖动拾取、鼠标保护几何和无障碍树之外。水平移动超过 22 pt 缩进步长的 70% 才改变层级；层级 > 0 时绘制同组父任务至占位的圆角 L 形连接线（不穿过标题）。`Esc` 取消，支持多选整组拖、上下边缘 24 pt 自动滚动、折叠目标组自动展开，降低动态效果时立即切换。单分组视图拖动时输入栏位置变为分组架（含「无分组」落点）；全视图支持拖入左侧分组便签归组。按日期分节的视图（「今天」「未来 7 天」「本周」「下周」及自定义日期范围）支持跨具体日期分区拖拽改到期日（原开始日晚于新到期日时同步收紧开始日）及 `⌘Z`／`⇧⌘Z` 原子撤销重做；不可确定单一日期的分区（「已逾期」「接下来 7 天」「已完成」）拒绝跨区落点。
  - 守护：`TaskReorderPresentationTests.swift`、`TaskDragFlowTests.swift`、`TaskGestureGeometryTests.swift`、`FeedbackFourRegressionTests.swift`、`TaskReorderEngineTests.swift`、`SideTabAndDateDropTests.swift`。
- **任务行悬停与行内编辑**：任务行是无底色悬停规则的唯一例外：整行 `rule` 10% 背景、圆角 6 pt、左右外扩 6 pt；多选 16%，编辑 18%。悬停操作 `＋`、日历、`×` 位于固定列（右缘在行右缘左侧 88 pt），浮在标题尾部上方，标题尾部 mask 渐隐、不画色块，行尾元信息始终可见可点；整行除圆、元信息及按钮外均可点击编辑。
  - 守护：`TaskRowMetadataTests.swift`；背景、mask 及整行点击专项暂无测试。
- **日期筛选与范围定义**：日期筛选摘要固定预留 22 pt，结果切换用 0.16 秒短位移动画加交叉渐变（降低动态效果时立即切换）。筛选行高 34 pt，选中 17 pt Medium `ink`，未选中 14 pt Regular `faint`，槽宽按 17 pt Medium 预留；按与选中项槽位距离 0／1／2／3／≥4，文字不透明度为 1／0.78／0.58／0.42／0.32，悬停 ≥0.9 且转为 `muted`，键盘焦点为 `accent` 且全不透明，VoiceOver 或「提高对比度」开启时不衰减；保留光学居中及拖动窗口手势。「今天」视图不重复显示「今天」分区标题，面板分区为「已逾期」「接下来 7 天」「已完成」，筛选为逾期加今日到期（精确定义见 `native/Sources/DotistCore/TaskFiltering.swift`：`todaySections` 组合逾期与今日，底层 `filter(scope: "today")` 仅返回今日）。全部包含所有未完成任务；明天为次日；本周遵循系统周起始日；未来 7 天为 `T..T+6`；另有已逾期、无日期、已完成（无数量上限、按更新时间倒序）与自定义范围（含两端）；子任务命中时保留灰显祖先上下文。
  - 守护：`TaskFilteringTests.swift`、`DateFilterModelTests.swift`、`PanelFeedbackRevisionTests.swift`、`TaskEmptyStateTests.swift`。
- **空状态**：筛选主结果为空时，空状态块中心位于列表视口高度约 38%，主文案 15 pt Medium `ink`（按视图区分）、次文案 12 pt `faint` 单行省略，均为 Sans，无插图、emoji、装饰图标或卡片底。「已逾期」和「已完成」不显示提示及添加入口；其它视图在次文案下方 12 pt 显示水平居中加号（命中区 32 × 32 pt，AX 名称「在这里添加任务」），点击清理互斥编辑状态并聚焦底部输入栏（不插入空状态编辑行、不建空任务、不清空已有草稿），新建任务沿用当前分组与视图日期规则。空状态仅叠加于空白区，避让「今天」的辅助分区点击区，展开辅助任务时隐藏。
  - 守护：`TaskEmptyStateTests.swift`、`PanelFeedbackRevisionTests.swift`。

## 视觉规范

- **衬线与无衬线分工**：衬线体仅用于名字（组头、今天视图分区标题、便签、输入栏组名、拖动分组架、跨组行尾组名、管理窗口分组名、快速添加组名、甘特组名）；日期大标题、设置标题、管理窗口切换标题、日历年月、悬浮球数字、任务正文等一律使用无衬线。统一经 `DotistDesign.nameFont`／`textFont` 调用，禁止绕过封装裸调系统字体（MCP 配置等宽文本除外）。
  - 守护：`GroupPanelTypographyTests.swift`；全调用点专项暂无测试。
- **默认字体与偏好**：西文衬线默认 Newsreader（可变 `wght`／`opsz`），西文无衬线默认 Atkinson Hyperlegible Next（可变 `wght`），中文默认思源宋体／思源黑体（按简／繁／日选择 Noto SC／TC／JP，不使用楷体）。外观「字体」提供四项菜单、即时混排预览与「恢复默认字体」，西文可选 Source Serif 4／Source Sans 3 或 New York／SF Pro，中文可选系统宋体／苹方，日文保留 JP 变体，昭源宋体 Chiron Sung HK VF 仅用于繁体（简／日回退 Noto）。设置键 `font_serif_latin`／`font_sans_latin`／`font_serif_cjk`／`font_sans_cjk`，缺失或未知值回退默认并即时刷新。字体与度量缓存须区分四项偏好、字重、区域和可变轴；光学偏移按实际墨迹校准（4× 校准基线、2× 测残差对齐像素网格，偏差 ≤0.5 pt）。字体文件仅使用官方固定版本并随包校验 SHA-256 与 OFL 许可证。
  - 守护：`FontPreferenceTests.swift`、`OpticalAlignmentTests.swift`。
- **可见墨迹对齐**：同行图标与文字以真实可见墨迹中心对齐（偏差 ≤0.5 pt），统一使用 `Design/DotistOptical.swift` 封装与实测偏移表，禁止零散手写 `offset` 补偿。
  - 守护：`OpticalAlignmentTests.swift`、`ComposerAlignmentTests.swift`。
- **本地化与标点**：中文使用全角标点（，。：；！？（）「」…——），中文与英文单词、数字单位间留一个半角空格；说明句加句号，按钮、标题、菜单不加句末标点。`en`／`ja`／`zh-TW` 按各自规范；`locales` 键与源码中文一致。
  - 守护：`LocalizationPunctuationTests.swift`。
- **设置窗口布局、透明度与局部动效**：采用系统设置式布局：214 pt 纯文字无图标侧栏（导航文字起点 38 pt、顶部 Liquid Glass 搜索气泡，短文案「搜索」，完整「搜索设置」作 AX 标签与 tooltip），右侧 26 pt 内容边距、22 pt 组间距、10 pt 容器圆角、≥44 pt 表单行（长标签容不下时控件换行）、小开关；默认窗口 880 × 660、最小 800 × 540。外观按「外观／主面板材质／分组便签／字体／颜色主题／失焦淡出」组织，「主面板材质」仅保留「玻璃材质」两档分段切换（清透水滴 / 柔和自适应），材质说明紧邻该组并明确仅影响展开态主面板；已移除原三档数字玻璃预设、「主表面透明度」与「磨砂程度」滑块。便签背景与失焦整窗透明度统一数值越大越透明（便签背景 0…100%，失焦整窗 0…80% 且最低保留 20% alpha），界面以 `100 - opacity` 转换，保留原存储值不迁移。字体四行采用标签在上、下方 110 pt 混排预览与 244 pt 原生 picker 对齐列边缘；颜色主题动态列出分组，「全部」行显示「全部」／“All”，色板为圆形色块配选中外圈。动画仅作用于局部（悬停 100 ms、选中 120 ms、搜索定位 200 ms、强调停留 1.2 s 后 200 ms 消退、工具栏重排 180 ms），不加全局根动画；响应 `accessibilityReduceMotion`；搜索按目标行实际几何偏好定位并校验请求代际取消旧请求。分组便签内提供一次性「播放便签动画」原生按钮与紧凑示意，复用生产 `SideTabEntrance`、`SideTabGeometry.snapshot` 与 `SideTabsCanvas`（不写设置、不循环或悬停自动播放，降低动态效果时禁用播放并展示静态终态）。
  - 守护：`SettingsLayoutTests.swift`、`SettingsSearchTests.swift`、`SettingsMotionTests.swift`、`SettingsPolishRenderingTests.swift`、`OpticalAlignmentTests.swift`。
- **Logo 与菜单栏图标**：Logo 为 D 内点（100 viewBox 外圆 `(50,50) r34`，透明孔 `(56,60) r11`，源资产在 `design-system/logo/`）；macOS 安装图标固定使用浅色版，保留深色资源不自动切换，通过 `python3 native/scripts/generate-icons.py --check` 校验 PNG 与 10 表示位 ICNS 一致性。菜单栏为 16／22 pt 黑色透明孔模板（`MenuBarImage` 用 16 pt 路径居中于 18 pt 高度，`isTemplate = true`）；count 模式在标记右侧间隔 3 pt 绘制 11 pt 等宽数字（不放入孔中，含 1 pt 尾部余量，无外置 title），99+ 的 tooltip／AX 保留完整数量；文字模式上限 24 字符。
  - 守护：`MenuBarTests.swift`。
- **输入栏与渲染所有者**：输入栏 placeholder 与 editor 同一时刻仅有一个原生绘制所有者，保留幂等 `drawingRect`、IME、marked text 与 undo；组名模板按最终 muted 着色与深浅外观测墨迹框；52 pt 输入栏按外层布局 bounds 校验共同中心与上下余白（覆盖 454 × 568、320 × 440、364 × 620 路径）。
  - 守护：`FeedbackFourRegressionTests.swift`、`ComposerRenderingRegressionTests.swift`。
- **任务面板阴影策略**：主任务面板与分组任务面板在初建、展开态、悬浮球、悬停横条及全部转换生命周期均关闭额外 AppKit 整窗阴影（`hasShadow = false`），取消或降低动态效果也不恢复，依赖原生 glass 光缘；快速添加、命令面板、设置与任务视图沿用各自系统阴影。玻璃调试阴影开关不覆盖任务面板策略；禁止独立阴影子窗口及玻璃外自绘实心阴影层。
  - 守护：`PanelShadowTests.swift`、`PanelMotionLifecycleTests.swift`。
- **悬浮横条宽度与对齐**：48 pt 圆保持原位，宽度按标题／单行元数据较宽者加 78 pt（圆 48、间距 18、外边距 12），上限 440 pt 或屏幕可用宽度一半，无 250 pt 下限。圆在左或右时文字均左对齐，标题与可选元数据整体按截断后 CoreText 墨迹边界对齐圆心，数字按实际墨迹居中；无元数据时仅居中显示标题。
  - 守护：`BubbleLayoutTests.swift`。
- **视觉禁项**：允许便签耳朵形状及玻璃、任务行悬停背景、编辑态底、分段进度圆。禁止悬浮球进度环／弧、按钮或标签下划线指示、条目前小圆点、选中项左侧竖线、编辑时放大字号加下划线、面板内再嵌玻璃按钮、分组色点。
  - 守护：上述相关测试；其余禁项暂无专项测试。

### 展开与折叠的几何连续性

- 窗口动画由 `PanelMotion` 持有的 `PanelFrameAnimation` 驱动：同一进度插值四条边后重建矩形，避免位置与尺寸分别量化导致顶边或右边逆向；可见窗口跟随显示刷新，保留展开 0.34 秒、折叠 0.28 秒及 `easeInEaseOut`，降低动态效果时同步完成；停止、关闭与释放时取消驱动，禁止晚到回调继续写窗口。
- compact 的 2 pt 材质内缩与窗口几何共同过渡，通过 `PanelSurfaceTransition` 按实际 frame 推导 `surfaceInsets` 并经同窗移动／缩放通知发布，不使用独立内缩计时器；降低透明度或提高对比度时保持零内缩实底。
- 守护：`PanelFrameQuantizationTests.swift`、`PanelMotionLifecycleTests.swift`、`BubbleClickTransitionTests.swift`。

## 常见回退陷阱

- 不要把输入栏或顶部的菜单改回带箭头的 Menu，不要恢复顶部组名和搜索按钮。
- 不要恢复父任务折叠或让 `1/3` 成为按钮，不要给悬浮球加进度环。
- 不要把隐式 `inbox` 展示成分组，不要在删除分组时删除任务。
- 不要绕过 `nameFont`／`textFont` 直接使用系统字体，不要在 SwiftUI 中零散用 `offset` 补居中。
- 不要修改 `locales` 键而不同步源码中文，不要恢复底部悬停提示行。
- 拖动必须遵循上述一行浮起块与单一占位契约。
