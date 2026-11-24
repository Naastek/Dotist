import AppKit
import Combine
import DotistCore
import SwiftUI

private struct ComposerInputBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct ComposerGlass: View {
    let focused: Bool
    let color: DotistGroupColor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        Group {
            if reduceTransparency || contrast == .increased {
                shape.fill(DotistDesign.surface)
                    .overlay { shape.strokeBorder(DotistDesign.accent.opacity(0.5), lineWidth: 1) }
            } else {
                // Keep the field glass independent of the nearby tag suggestions.
                GlassEffectContainer(spacing: 0) {
                    Color.clear.glassEffect(.regular.tint(DotistTheme.tint(color, scheme)), in: shape)
                }
            }
        }
        .opacity(focused ? 1 : 0)
        .animation(LayoutMotionInputs.shouldReduceMotion(reduceMotion) ? nil : .easeOut(duration: focused ? 0.2 : 0.15),
                   value: focused)
        .accessibilityHidden(true)
    }
}

extension MainWindow {
    func beginGroupDraft(_ group: DotistGroup, after task: DotistTask?) {
        withAnimation(groupCollapseAnimation) { state.setGroupCollapsed(false, id: group.id) }
        if let task { startDraft(after: task) }
        else { clearInputs(); addingToGroup = group.id; groupTitles[group.id] = "" }
    }

    func saveGroupDraft(_ group: DotistGroup, continuing: Bool) {
        guard addingToGroup == group.id, !groupSubmitting else { return }
        guard let title = TaskDraftFlow.titleToSave(groupTitles[group.id] ?? "") else { clearInputs(); return }
        groupSubmitting = true
        var created: DotistTask?
        model.change(completed: {
            groupSubmitting = false
            guard addingToGroup == group.id else { return }
            clearInputs()
            if continuing, let created { startDraft(after: created) }
        }, failed: { groupSubmitting = false }) { created = try $0.addTask(title: title, category: group.id) }
    }

    func leaveInputs() {
        if let id = editing, let task = model.tasks.first(where: { $0.id == id }) {
            saveEditing(task) { clearInputs() }
        } else if let id = draftAfter, let task = model.tasks.first(where: { $0.id == id }) {
            saveDraft(after: task, continueEditing: false)
        } else if let id = addingToGroup, let group = model.groups.first(where: { $0.id == id }) {
            saveGroupDraft(group, continuing: false)
        } else { clearInputs() }
    }

    /// Synchronously snapshots and clears active inline editors/drafts while
    /// persisting changes in the background, so a drag or outside click can
    /// start immediately without waiting for SQLite round-trips.
    func flushInputsOptimistically() {
        if let id = editing {
            let titleToSave = TaskDraftFlow.titleToSave(editedTitle)
            let task = model.tasks.first(where: { $0.id == id })
            clearEditing()
            if let task, let titleToSave, titleToSave != task.title {
                model.patchTaskTitleOptimistically(id: task.id, title: titleToSave)
            }
        }
        if let id = draftAfter {
            let titleToSave = TaskDraftFlow.titleToSave(draftTitle)
            let parent = draftParent
            let plan = draftPlan
            let task = model.tasks.first(where: { $0.id == id })
            clearDraft()
            if let task, let titleToSave {
                model.change { store in
                    let newTask = try store.addTask(title: titleToSave, category: task.category, parentId: parent,
                                                    dueDate: plan == nil ? task.dueDate : nil, plan: plan)
                    let hierarchy = TaskHierarchy(try store.listTasks())
                    let anchor = ([task] + hierarchy.ancestors(of: task.id)).first { $0.parentId == parent }
                    if let anchor { try store.reorder(newTask.id, relativeTo: anchor.id, after: true, allTasks: false) }
                }
            }
        }
        if let id = addingToGroup {
            let titleToSave = TaskDraftFlow.titleToSave(groupTitles[id] ?? "")
            addingToGroup = nil
            groupTitles.removeValue(forKey: id)
            if let titleToSave, model.groups.contains(where: { $0.id == id }) {
                model.change { _ = try $0.addTask(title: titleToSave, category: id) }
            }
        }
    }

    func dismissEditorFromOutsideClick() {
        guard editing != nil || draftAfter != nil || addingToGroup != nil else { return }
        if let id = editing {
            hold.dismissedEditingTaskID = id
            if state.activeTag != nil { pinnedFilteredTaskID = id }
        }
        flushInputsOptimistically()
    }

    func dismissActiveFocus() {
        flushInputsOptimistically()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Clears inline editing or draft states whose target row/group is no longer
    /// mounted in the visible list, preventing ghost locks after deletes or filters.
    func pruneStaleInputState() {
        let editableIDs = Set(listEntries.compactMap { $0.expanded ? $0.row?.task.id : nil })
        if let id = editing, !editableIDs.contains(id) { clearEditing() }
        if let id = draftAfter, !editableIDs.contains(id) { clearDraft() }
        if let id = addingToGroup {
            let visible = id != DotistGroup.inboxID
            if !model.groups.contains(where: { $0.id == id }) || !state.showsGroupContents(id, hasHeader: visible) {
                addingToGroup = nil
                groupTitles.removeValue(forKey: id)
            }
        }
    }

    func clearEditing() { editing = nil; editedTitle = ""; editHeight = 32; editClickWindowPoint = nil; pendingEdit = nil }
    private func clearDraft() { draftAfter = nil; draftTitle = ""; draftParent = nil; draftHeight = 32; draftPlan = nil }
    func clearInputs() {
        clearDraft(); clearEditing(); addingToGroup = nil; groupTitles.removeAll()
    }

    func startDraft(after task: DotistTask, asChild: Bool = false) {
        clearInputs()
        draftAfter = task.id; draftParent = asChild && model.depth(of: task) < 4 ? task.id : task.parentId
        draftPlan = state.planScope
        let depth = draftParent.flatMap { id in model.tasks.first { $0.id == id } }.map { model.depth(of: $0) + 1 } ?? 0
        draftHeight = TaskRowMetrics.height(depth, titleHeight: 20)
    }

    @ViewBuilder func draftRow(after task: DotistTask, sub: Bool) -> some View {
        if draftAfter == task.id {
            let depth = draftParent.flatMap { id in model.tasks.first { $0.id == id } }.map { model.depth(of: $0) + 1 } ?? 0
            let minRowHeight = TaskRowMetrics.height(depth, titleHeight: 20)
            TaskRowLayout(depth: depth, editing: true) {
                TaskCheckmark(depth: depth, completed: false, children: [], emphasized: false)
                TaskEditor(text: $draftTitle, height: $draftHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("任务内容"), minRowHeight: minRowHeight, commit: {
                    saveDraft(after: task, continueEditing: true)
                }, cancel: { clearDraft() }, indent: { reverse in
                    draftParent = TaskDraftFlow.parent(reverse: reverse, current: draftParent, after: task, tasks: model.tasks)
                }, blur: { saveDraft(after: task, continueEditing: false) })
                    .id("draft:\(task.id)").frame(height: max(draftHeight, minRowHeight))
                Color.clear.frame(width: 0, height: 0)
            }.background(RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(0.18)).padding(.horizontal, -6))
        }
    }

    private func saveDraft(after task: DotistTask, continueEditing: Bool) {
        guard draftAfter == task.id, !draftSaving else { return }
        guard let title = TaskDraftFlow.titleToSave(draftTitle) else { clearDraft(); return }
        draftSaving = true
        let parent = draftParent
        let plan = draftPlan
        var created: DotistTask?
        model.change(completed: {
            draftSaving = false
            guard draftAfter == task.id else { return }
            clearDraft()
            if continueEditing, let created { startDraft(after: created) }
        }, failed: { draftSaving = false; showNotice(model.error ?? model.text("无法保存任务")); model.error = nil }) { store in
            let newTask = try store.addTask(title: title, category: task.category, parentId: parent,
                                            dueDate: plan == nil ? task.dueDate : nil, plan: plan)
            let hierarchy = TaskHierarchy(try store.listTasks())
            let anchor = ([task] + hierarchy.ancestors(of: task.id)).first { $0.parentId == parent }
            if let anchor { try store.reorder(newTask.id, relativeTo: anchor.id, after: true, allTasks: false) }
            created = newTask
        }
    }

    func beginEditing(_ task: DotistTask, at clickPoint: CGPoint? = nil) {
        guard editing != task.id else { return }
        if editSaving { pendingEdit = task; return }
        let start = {
            clearInputs()
            editing = task.id
            editedTitle = task.title
            editHeight = TaskRowMetrics.height(model.depth(of: task), titleHeight: 20)
            editClickWindowPoint = clickPoint
        }
        if let id = editing, let current = model.tasks.first(where: { $0.id == id }) { saveEditing(current, then: start) }
        else if let after = draftAfter, let current = model.tasks.first(where: { $0.id == after }), TaskDraftFlow.titleToSave(draftTitle) != nil {
            saveDraft(after: current, continueEditing: false)
            // The old draft callback is identity-guarded, so switching editor
            // cannot make a delayed blur save a different row's buffer.
            start()
        } else { start() }
    }

    func saveEditing(_ task: DotistTask, then: @escaping () -> Void = {}) {
        guard editing == task.id, !editSaving else { return }
        guard let title = TaskDraftFlow.titleToSave(editedTitle), title != task.title else { clearEditing(); then(); return }
        editSaving = true
        model.change(completed: {
            editSaving = false
            if editing == task.id {
                let pending = pendingEdit
                clearEditing()
                if let pending { beginEditing(pending) } else { then() }
            }
        }, failed: { editSaving = false; pendingEdit = nil }) { _ = try $0.patchTask(id: task.id, title: title) }
    }

    var composerBar: some View {
        let selectedID = dropGroupIDs.contains(category) ? category : DotistGroup.inboxID
        let selectedName = model.composerGroupDisplayName(selectedID)
        let entry = resolvedComposer
        let shownDue = composer.isEmpty && composerDate.selection == .automatic ? composerDate.contextDay : entry.day
        let dateLabel = shownDue.map(model.dueLabel) ?? (composerDate.selection == .cleared ? model.text("无日期") : nil)
        let dateHelp = shownDue.map {
            model.text("到期日：{date}").replacingOccurrences(of: "{date}", with: $0)
        } ?? model.text("设置到期日")
        return ComposerLayout {
            Menu {
                Picker(model.text("分组"), selection: $category) {
                    ForEach(dropGroupIDs, id: \.self) { id in
                        Text(model.composerGroupDisplayName(id)).font(font(13, serif: true)).tag(id)
                    }
                }.pickerStyle(.inline)
                Divider()
                Button(model.text("管理分组…")) { manageGroups = true }
            } label: {
                HStack(spacing: 4) {
                    ComposerGroupLabel(title: selectedName, language: model.language, sample: composer.isEmpty ? model.text("写下一件小事") : composer.components(separatedBy: .newlines).first ?? "")
                }.foregroundColor(DotistDesign.muted).frame(height: ComposerMetrics.rowHeight)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).focusEffectDisabled().fixedSize().frame(height: ComposerMetrics.rowHeight).help(model.text("分组")).accessibilityLabel(Text(model.text("分组"))).accessibilityValue(Text(selectedName)).accessibilityIdentifier("composer-group")
            ZStack(alignment: .leading) {
                ComposerInput(text: $composer, focused: $composerFocused, placeholder: model.text("写下一件小事"), label: model.text("新任务"), font: DotistDesign.nativeFont(ComposerMetrics.fontSize, language: model.language), commit: addTask, navigate: { direction in
                    let values = tagSuggestions
                    guard !values.isEmpty else { return false }
                    selectedSuggestion = (selectedSuggestion + direction + values.count) % values.count
                    return true
                }, complete: { force in chooseSuggestion(force: force) }, cancel: {
                    if !tagSuggestions.isEmpty && !tagSuggestionsDismissed {
                        tagSuggestionsDismissed = true
                        selectedSuggestion = -1
                        return true
                    }
                    return false
                }, composing: $composerComposing)
                    .tint(DotistDesign.accent).frame(height: ComposerMetrics.rowHeight)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DotistDesign.accent.opacity(composerCueVisible ? 0.5 : 0), lineWidth: 1).allowsHitTesting(false) }
                    .accessibilityIdentifier("composer-input")
                if !tagSuggestions.isEmpty && !tagSuggestionsDismissed {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { index, tag in
                            Button("#" + tag) { selectedSuggestion = index; _ = chooseSuggestion(force: true) }
                                .buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12, index == selectedSuggestion ? .medium : .regular)).foregroundColor(index == selectedSuggestion ? DotistDesign.ink : DotistDesign.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28)
                        }
                    }.glassEffect(.regular, in: .rect(cornerRadius: 12)).offset(y: -CGFloat(tagSuggestions.count * 28 + 6)).zIndex(1)
                }
            }.frame(maxWidth: .infinity).frame(height: ComposerMetrics.rowHeight)
                .anchorPreference(key: ComposerInputBounds.self, value: .bounds) { $0 }
                .onChange(of: composer) { _ in selectedSuggestion = -1; tagSuggestionsDismissed = false; dismissComposerCue() }
                .onChange(of: composerFocused) { focused in if !focused { tagSuggestionsDismissed = false; dismissComposerCue() } }
            Button { showDuePicker.toggle() } label: {
                IconTextRow(spacing: 4) {
                    if let dateLabel { OpticalText(title: dateLabel, size: 12, language: model.language).lineLimit(1) }
                    ComposerCalendarIcon(language: model.language).opacity(dateLabel != nil || composerHovered || composerFocused ? 1 : 0)
                }.foregroundColor(shownDue == nil ? DotistDesign.muted : DotistDesign.accent)
            }
                .buttonStyle(.plain).frame(height: ComposerMetrics.rowHeight).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("设置到期日")))
                .accessibilityValue(Text(dateLabel ?? ""))
                .help(dateHelp)
                .disabled(composerComposing)
                .accessibilityIdentifier("composer-due")
                .popover(isPresented: $showDuePicker) {
                    RangeCalendar(model: model, start: entry.day ?? "", end: entry.day ?? "", choose: { date, _ in
                        setComposerDate(.selected(date))
                    }, close: { showDuePicker = false }, single: true, clear: { setComposerDate(.cleared) })
                }

        }.padding(.leading, 16).padding(.trailing, 11).frame(height: ComposerMetrics.barHeight)
            .backgroundPreferenceValue(ComposerInputBounds.self) { anchor in
                GeometryReader { geometry in
                    if let anchor {
                        let input = geometry[anchor]
                        let leading = input.minX - ComposerMetrics.glassLeadingInset
                        // Match the original field surround, including the date control.
                        let width = max(0, geometry.size.width - 8 - leading)
                        ComposerGlass(focused: composerFocused, color: model.themeColor(forGroup: state.groupID))
                            .frame(width: width, height: 36)
                            .position(x: leading + width / 2, y: input.midY)
                    }
                }
                .allowsHitTesting(false)
            }
            .onHover { composerHovered = $0 }
            .overlay(alignment: .top) { Rectangle().fill(DotistDesign.rule.opacity(0.65)).frame(height: 0.5).padding(.horizontal, 12) }
            #if DEBUG
            .background(ComposerBarLayoutAnchor().allowsHitTesting(false).accessibilityHidden(true))
            #endif
    }

    var groupShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
            ForEach(dropGroupIDs, id: \.self) { id in
                OpticalText(title: model.groupDisplayName(id), size: 14, weight: shelfTarget == id ? .semibold : .regular, serif: true, language: model.language)
                    .foregroundColor(shelfTarget == id ? DotistDesign.ink : DotistDesign.faint)
                    .frame(height: 48).contentShape(Rectangle())
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TaskShelfFrameKey.self, value: [id: geometry.frame(in: .named(Self.listSpace))])
                    })
            }
        }.padding(.horizontal, 16).frame(height: 48)
        }.frame(height: ComposerMetrics.barHeight)
    }

    private var tagSuggestions: [String] {
        guard !composerComposing, let range = composer.range(of: "(^|\\s)#([^\\s#]*)$", options: .regularExpression),
              let hash = composer[range].lastIndex(of: "#") else { return [] }
        let prefix = String(composer[composer.index(after: hash)...])
        return Array(model.tagCounts.filter { $0.open > 0 && $0.tag.lowercased().hasPrefix(prefix.lowercased()) && $0.tag != prefix }.prefix(6).map(\.tag))
    }
    private func chooseSuggestion(force: Bool) -> Bool {
        let values = tagSuggestions
        guard !values.isEmpty, force || selectedSuggestion >= 0,
              let range = composer.range(of: "#([^\\s#]*)$", options: .regularExpression) else { return false }
        composer.replaceSubrange(range, with: "#\(values[max(0, min(selectedSuggestion, values.count - 1))]) ")
        selectedSuggestion = -1
        return true
    }

    private var resolvedComposer: TaskEntryDate.Submission {
        let fallback = ["today", "tomorrow", "week", "nextweek", "next7"].contains(state.scope) ? rangeBounds.0 : nil
        return composerDate.resolve(composer, fallback: fallback, composing: composerComposing)
    }

    private func setComposerDate(_ selection: TaskEntryDate.Selection) {
        composerDate.selection = selection
        showDuePicker = false
        composerFocused = true
    }

    private func addTask() {
        guard !composerComposing, !composerSubmitting else { return }
        let entry = resolvedComposer
        guard !entry.title.isEmpty else { return }
        let submittedText = composer
        let submittedDate = composerDate
        let plan = state.planScope
        let selectedCategory = dropGroupIDs.contains(category) ? category : DotistGroup.inboxID
        composerSubmitting = true
        model.change(completed: {
            composerSubmitting = false
            if composer == submittedText { composer = "" }
            if composerDate == submittedDate { composerDate = TaskEntryDate() }
        }, failed: { composerSubmitting = false }) {
            _ = try $0.addTask(title: entry.title, category: selectedCategory, dueDate: entry.day, plan: plan)
        }
    }
}
