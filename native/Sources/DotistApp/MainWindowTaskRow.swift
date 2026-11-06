import AppKit
import Combine
import DotistCore
import SwiftUI

extension MainWindow {
    func interactiveTaskRow(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, next: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool, region: String, date: String?) -> some View {
        let carried = drag?.carries(task.id, region: region) == true
        return TaskSelectableContent(selection: selection.row(task.id)) { selected, focused in
            rowContent(task, children: children, sub: sub, allTasks: allTasks, previous: previous, hideDue: hideDue, titleParts: titleParts, actionsVisible: (actionsVisible || focused) && drag == nil && model.dragId == nil, selected: selected, focused: focused)
                .background {
                    let background = TaskRowBackgroundState(hovered: hoveredTask == task.id, selected: selected, editing: editing == task.id, dragging: drag != nil || model.dragId != nil, carried: carried)
                    RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(background.opacity)).padding(.horizontal, -6)
                        .allowsHitTesting(false)
                        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || drag != nil || model.dragId != nil ? nil : .easeInOut(duration: 0.1), value: background)
                }
        }
        .contentShape(Rectangle())
        .onKeyPress(keys: [.return, .space, .tab, .escape, .upArrow, .downArrow], phases: .down) { press in
            handleRowKey(press, task: task, previous: previous, allTasks: allTasks)
        }
        .onTapGesture { if !hold.suppressesClick { clickRow(task) } }
        .gesture(reorderGesture(task), including: editing == nil && draftAfter == nil ? .all : .subviews)
        .simultaneousGesture(holdGesture(task), including: editing == nil && draftAfter == nil ? .all : .subviews)
        .onContinuousHover(coordinateSpace: .named(Self.listSpace)) { phase in
            if case .active(let point) = phase { hold.pointer = point }
        }
        .onHover { over in if over { hoveredTask = task.id } else if hoveredTask == task.id { hoveredTask = nil } }
        .popover(isPresented: Binding(get: { pickingTask == task.id }, set: { if !$0 && pickingTask == task.id { pickingTask = nil } })) {
            RangeCalendar(model: model, start: task.dueDate ?? "", end: task.dueDate ?? "", choose: { date, _ in
                if task.dueDate == date { pickingTask = nil; return }
                model.change(completed: { pickingTask = nil }) { _ = try $0.setDueDate(task.id, date: date) }
            }, close: { pickingTask = nil }, single: true, clear: {
                model.change(completed: { pickingTask = nil }) { _ = try $0.setDueDate(task.id, date: nil) }
            })
        }
        .contextMenu { rowMenu(task, sub: sub, allTasks: allTasks, previous: previous, next: next) }
        .accessibilityElement(children: .contain)
        // The mounted mouse-down owner is the single one-line placeholder.
        .opacity(carried ? 0 : 1)
        .frame(height: carried ? 32 : nil, alignment: .top).clipped()
        .overlay {
            if carried {
                RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DotistDesign.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .padding(.leading, CGFloat(drag?.target?.level ?? 0) * TaskRowMetrics.indent)
                    .allowsHitTesting(false)
            }
        }
        .background(TaskPickupFrameProbe(runtime: reorderRuntime, role: .row(.before(task.id, region: region)),
            row: .init(task: task, frame: .zero, sub: sub, allTasks: allTasks, hideDue: hideDue, region: region, date: date, depth: model.depth(of: task))))
        .background(rowGeometry(task, sub: sub, allTasks: allTasks, hideDue: hideDue, region: region, date: date))
        .accessibilityIdentifier("task-row:\(task.id)")
    }

    @ViewBuilder private func rowMenu(_ task: DotistTask, sub: Bool, allTasks: Bool, previous: String?, next: String?) -> some View {
            Button(model.text("编辑 {title}").replacingOccurrences(of: "{title}", with: task.title)) { beginEditing(task) }
            if model.depth(of: task) < 4 { Button(model.text("添加子任务")) { startDraft(after: task, asChild: true) } }
            if task.parentId != nil { Button(model.text("取消缩进")) { changeIndent(ids: [task.id], reverse: true) } }
            if previous != nil {
                Button(model.text("缩进为上一条的子任务")) {
                    changeIndent(ids: [task.id], reverse: false)
                }
            }
            if let previous { Button(model.text("上移")) { model.reorder(task.id, relativeTo: previous, after: false, allTasks: allTasks) } }
            if let next { Button(model.text("下移")) { model.reorder(task.id, relativeTo: next, after: true, allTasks: allTasks) } }
            Menu(model.text("到期日")) {
                Button(model.text("今天")) { let date = Date().dotistDay; model.change { _ = try $0.setDueDate(task.id, date: date) } }
                Button(model.text("明天")) { let date = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay; model.change { _ = try $0.setDueDate(task.id, date: date) } }
                Button(model.text(task.dueDate == nil ? "设置到期日…" : "修改到期日…")) { pickingTask = task.id }
                if task.dueDate != nil { Button(model.text("清除到期日")) { model.change { _ = try $0.setDueDate(task.id, date: nil) } } }
            }
            if !sub {
                Menu(model.text("分组")) {
                    ForEach(dropGroupIDs, id: \.self) { id in Button(model.groupDisplayName(id)) { model.change { _ = try $0.patchTask(id: task.id, category: id) } }.font(font(13, serif: true)) }
                }
            }
            Button(model.text(task.completed ? "恢复" : "完成")) { model.complete(task) }
            Button(model.text("删除")) { model.delete(task) }
    }

    func rowContent(_ task: DotistTask, children: [DotistTask], sub: Bool, allTasks: Bool, previous: String?, hideDue: Bool, titleParts: DotistTaskTags?, actionsVisible: Bool, selected: Bool = false, focused: Bool = false, depthOverride: Int? = nil) -> some View {
        let depth = depthOverride ?? model.depth(of: task)
        let actionCount = (depth < 4 ? 1 : 0) + (task.dueDate == nil ? 1 : 0) + 1
        let fadeWidth = actionsVisible ? TaskRowActionMetrics.width(count: actionCount) : 0
        return TaskRowLayout(depth: depth) {
            Button { selection.update { $0.clear() }; model.complete(task) } label: {
                TaskCheckmark(depth: depth, completed: task.completed, children: children.map(\.completed), emphasized: selected || focused || drag?.target?.parentID == task.id)
            }.buttonStyle(.plain).focusEffectDisabled()
                .accessibilityLabel(Text(model.text(task.completed ? "恢复 {title}" : "完成 {title}").replacingOccurrences(of: "{title}", with: task.title)))
            if editing == task.id {
                TaskEditor(text: $editedTitle, height: $editHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("任务内容"), commit: {
                    saveEditing(task) { startDraft(after: task) }
                }, cancel: { clearEditing() }, indent: { reverse in
                    saveEditing(task) { changeIndent(ids: [task.id], reverse: reverse); selection.row(task.id).focusRequest.send() }
                }, blur: { saveEditing(task) }).id("edit:\(task.id)").frame(height: editHeight)
            } else {
                HStack(alignment: .opticalCenter, spacing: 4) {
                    OpticalText(title: titleParts?.tags.isEmpty == false ? (titleParts?.text ?? task.title) : task.title, size: 13, weight: selected ? .medium : .regular, language: model.language).lineLimit(1).truncationMode(.tail)
                        .foregroundColor(task.completed ? DotistDesign.faint : focused ? DotistDesign.accent : DotistDesign.ink)
                        .strikethrough(task.completed, color: DotistDesign.faint)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: task.completed)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(titleParts?.tags ?? [], id: \.self) { tag in
                        Button {
                            if NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty { state.activeTag = state.activeTag == tag ? nil : tag }
                            else { clickRow(task, edit: false) }
                        } label: {
                            OpticalText(title: "#" + tag, size: 12, weight: state.activeTag == tag ? .medium : .regular, language: model.language)
                        }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(state.activeTag == tag ? DotistDesign.ink : DotistDesign.faint).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .mask { if fadeWidth > 0 { TaskTitleFade(trailing: fadeWidth, rowRight: listViewport.maxX - 16) } else { Rectangle() } }
                    .contentShape(Rectangle())
                    .onTapGesture { clickRow(task) }

            }
            rowMetadata(task, children: children, allTasks: allTasks)
                .opacity(editing == task.id ? 0 : 1)
                .allowsHitTesting(editing != task.id)
            rowActions(task, allTasks: allTasks, visible: actionsVisible)
        }
    }

    private func rowMetadata(_ task: DotistTask, children: [DotistTask], allTasks: Bool) -> some View {
            HStack(alignment: .opticalCenter, spacing: 8) {
            if let due = task.dueDate {
                Button { pickingTask = task.id } label: { OpticalText(title: model.dueLabel(due), size: 12, language: model.language) }.buttonStyle(.plain).modifier(DotistFocusRing())
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(due < Date().dotistDay && !task.completed ? DotistDesign.danger : due == Date().dotistDay ? DotistDesign.accent : DotistDesign.muted)
                    .accessibilityLabel(Text(model.text("到期日 {date}，点击修改").replacingOccurrences(of: "{date}", with: model.dueLabel(due))))
                    .accessibilityIdentifier("task-due:\(task.id)")
            }
            if allTasks, state.groupID == nil, let group = model.group(for: task) { OpticalText(title: group.name, size: 12, weight: .semibold, serif: true, language: model.language).foregroundColor(DotistDesign.faint).lineLimit(1).fixedSize(horizontal: true, vertical: false) }
            if !children.isEmpty {
                OpticalText(title: "\(children.filter(\.completed).count)/\(children.count)", size: 12, language: model.language).foregroundColor(DotistDesign.faint)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("task-progress:\(task.id)")
                    .accessibilityLabel(Text(model.text("子任务 {done}/{total}").replacingOccurrences(of: "{done}", with: "\(children.filter(\.completed).count)").replacingOccurrences(of: "{total}", with: "\(children.count)")))
            }
            }.lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                .contentShape(Rectangle()).onTapGesture { }
    }

    @ViewBuilder private func rowActions(_ task: DotistTask, allTasks: Bool, visible: Bool) -> some View {
            if editing != task.id {
                HStack(spacing: 1) {
                    if model.depth(of: task) < 4 {
                        Button { startDraft(after: task, asChild: true) } label: { OpticalSymbol(name: "plus", size: 11).frame(width: 22, height: 22) }
                            .help(model.text("添加子任务"))
                            .accessibilityLabel(Text(model.text("添加子任务 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    }
                    if task.dueDate == nil {
                        Button { pickingTask = task.id } label: { OpticalSymbol(name: "calendar", size: 11).frame(width: 22, height: 22) }
                            .help(model.text("设置到期日"))
                            .accessibilityLabel(Text(model.text("设置到期日 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                    }
                    Button { model.delete(task) } label: { OpticalSymbol(name: "xmark", size: 11).frame(width: 22, height: 22) }
                        .help(model.text("删除"))
                        .accessibilityLabel(Text(model.text("删除 {title}").replacingOccurrences(of: "{title}", with: task.title)))
                }.buttonStyle(.plain).font(font(11, .regular)).foregroundColor(DotistDesign.muted)
                    .fixedSize()
                    .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                    .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15), value: visible)
            }
    }

    var displayOrder: [String] {
        var seen: Set<String> = []
        return rowFrames.filter { $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }.compactMap { seen.insert($0.task.id).inserted ? $0.task.id : nil }
    }

    private func clickRow(_ task: DotistTask, edit: Bool = true) {
        traceReorder("row.click", taskID: task.id, fields: ["edit": "\(edit)"])
        let flags = NSEvent.modifierFlags
        selection.update { $0.click(task.id, order: displayOrder, shift: flags.contains(.shift), command: flags.contains(.command)) }
        selection.row(task.id).focusRequest.send()
        if flags.intersection([.shift, .command]).isEmpty && edit { beginEditing(task) }
    }

    private func changeIndent(ids: [String], reverse: Bool) {
        let complete = { }
        let failed = { showNotice(model.error ?? model.text("无法更改任务层级")); model.error = nil }
        if reverse { model.outdent(ids: ids, completed: complete, failed: failed) }
        else { model.indent(ids: ids, completed: complete, failed: failed) }
    }

    func showNotice(_ message: String) {
        noticeLifetime.restart(at: ProcessInfo.processInfo.systemUptime)
        notice = message
    }

    func handleUndoShortcut(redo: Bool) -> Bool {
        guard !composerFocused, editing == nil, draftAfter == nil, addingToGroup == nil else { return false }
        if redo {
            guard model.canRedoAction else { return false }
            model.redoLast()
            showNotice("已重做")
        } else {
            guard model.canUndoAction else { return false }
            model.undoLast()
            showNotice("已撤销")
        }
        return true
    }

    private func handleRowKey(_ press: KeyPress, task: DotistTask, previous: String?, allTasks: Bool) -> KeyPress.Result {
        guard editing == nil else { return .ignored }
        let order = displayOrder
        if press.key == .escape { selection.update { $0.clear() }; clearInputs(); return .handled }
        if press.key == .upArrow || press.key == .downArrow {
            let direction = press.key == .upArrow ? -1 : 1
            if press.modifiers.contains(.option) {
                let siblings = model.ordered(model.tasks.filter { $0.parentId == task.parentId && $0.category == task.category && $0.completed == task.completed })
                if let i = siblings.firstIndex(where: { $0.id == task.id }), siblings.indices.contains(i + direction) { model.reorder(task.id, relativeTo: siblings[i + direction].id, after: direction > 0, allTasks: false) }
            } else if let i = order.firstIndex(of: task.id), order.indices.contains(i + direction) {
                let id = order[i + direction]
                selection.update {
                    if press.modifiers.contains(.shift) {
                        if $0.anchor == nil { $0.anchor = task.id }
                        $0.click(id, order: order, shift: true, command: false)
                    } else { $0.clear() }
                }
                selection.row(id).focusRequest.send(); selection.navigation.send(id)
            }
            return .handled
        }
        if press.key == .return {
            if press.modifiers.contains(.command) { model.complete(task) }
            else {
                let last = selection.value.last(in: order).flatMap { id in model.tasks.first { $0.id == id } } ?? task
                selection.update { $0.clear() }; startDraft(after: last)
            }
            return .handled
        }
        if press.key == .space { model.complete(task); return .handled }
        if press.key == .tab {
            let ids = selection.value.ids.isEmpty ? [task.id] : order.filter { selection.value.ids.contains($0) }
            clearInputs()
            changeIndent(ids: ids, reverse: press.modifiers.contains(.shift))
            return .handled
        }
        return .ignored
    }

}
