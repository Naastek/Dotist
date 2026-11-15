# 累计原生修复整合来源

2026-11-15 按用户授权整合正式仓库，未发布版本标签或 GitHub Release。

## 来源与整合依据

正式基线：`c1662be31955d8368384eb4235c172f043d2a44c`，整合前 GitHub main 与本机 main 一致，工作区干净。

完整候选：平台分支 `tds/conv-01a1df28-e459-7cdb-9c4a-26436123e848`，提交 `1967136144bbe6b15ae9789baa1ccc252f96bd68`，native 树 `04630c07cdfffa43588c6ee0ada7487cc44695a2`。

此前累计来源为 `0c1faeae1bd5ea975f11b6b6230f27306ecaedde`。完整候选相对此来源仅改变 TaskRowActionStyle.swift、TaskRowKeyboard.swift、build-local.sh。这是内容继承，并不声称平台分支具有完整产品提交祖先关系。

在正式仓库的隔离 detached 工作树上应用正式基线到完整候选的 native 差异，共51文件；native 树精确一致。保留正式基线全部非 native 文件，仅新增本文。不把平台整树、历史诊断报告、私人资料导入产品仓库。

## 保留的累计功能

英文首次使用示例在 TaskStore/FirstRunExamplesTests；标签筛选与原日期滑条、日期入口去重在 MainWindowToolbar/HeaderPresentation；输入玻璃、拖动与分组内新增在 DotistInputBackground/MainWindowTaskList/TaskListBlankDoubleClick；键盘及焦点规则在 TaskRowKeyboard/MainWindowTaskRow/TaskSelection；动作 clear 玻璃与局部渐隐高光在 TaskRowActionStyle/TaskRowKeyboard。整合直接保持完整候选，不在此次另修产品缺陷。

## 必要检查与安装判定

native 树及源码工作区与完整候选一致，补丁空白检查、打包脚本 bash 语法检查通过。依赖、Package.swift、打包资源采用完整候选既有内容。沿用此源码已成功的本机构建记录，没有重跑整套测试或操作桌面键鼠。

当前安装 com.dotist.app，版本0.2.48，构建 native-local-20261115T122735Z。安装包与该候选保留的正式构建产物全部153个文件散列一致；严格签名校验通过。可执行文件 SHA256：f73febbfd6df86ae91e8c1ae15158958a82d386f95922f5700852e9adc728c63。

因此无需重新构建替换，不退出应用、不接触个人库或偏好。原备份保留于 ~/Library/Application Support/DotistLocalBackups/20261115-202744。回退只替换应用，保留最新个人资料，不自动恢复旧资料。

此前核心交互验收仍有偶发滚动区与视口外任务焦点停滞记录；clear 玻璃未另做主观观感验收。本次合并不消除此边界。
