import AppKit
import Combine
import DotistCore
import SwiftUI

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

    func clearEditing() { editing = nil; editedTitle = ""; editHeight = 20; pendingEdit = nil }
    private func clearDraft() { draftAfter = nil; draftTitle = ""; draftParent = nil; draftHeight = 20 }
    func clearInputs() {
        clearDraft(); clearEditing(); addingToGroup = nil; groupTitles.removeAll()
    }

    func startDraft(after task: DotistTask, asChild: Bool = false) {
        clearInputs()
        draftAfter = task.id; draftParent = asChild && model.depth(of: task) < 4 ? task.id : task.parentId
    }

    @ViewBuilder func draftRow(after task: DotistTask, sub: Bool) -> some View {
        if draftAfter == task.id {
            let depth = draftParent.flatMap { id in model.tasks.first { $0.id == id } }.map { model.depth(of: $0) + 1 } ?? 0
            TaskRowLayout(depth: depth) {
                TaskCheckmark(depth: depth, completed: false, children: [], emphasized: false)
                TaskEditor(text: $draftTitle, height: $draftHeight, font: DotistDesign.nativeFont(13, language: model.language), label: model.text("任务内容"), commit: {
                    saveDraft(after: task, continueEditing: true)
                }, cancel: { clearDraft() }, indent: { reverse in
                    draftParent = TaskDraftFlow.parent(reverse: reverse, current: draftParent, after: task, tasks: model.tasks)
                }, blur: { saveDraft(after: task, continueEditing: false) })
                    .id("draft:\(task.id)").frame(height: draftHeight)
                Color.clear.frame(width: 0, height: 0)
            }.background(RoundedRectangle(cornerRadius: 6).fill(DotistDesign.rule.opacity(0.18)).padding(.horizontal, -6))
        }
    }

    private func saveDraft(after task: DotistTask, continueEditing: Bool) {
        guard draftAfter == task.id, !draftSaving else { return }
        guard let title = TaskDraftFlow.titleToSave(draftTitle) else { clearDraft(); return }
        draftSaving = true
        let parent = draftParent
        var created: DotistTask?
        model.change(completed: {
            draftSaving = false
            guard draftAfter == task.id else { return }
            clearDraft()
            if continueEditing, let created { startDraft(after: created) }
        }, failed: { draftSaving = false; showNotice(model.error ?? model.text("无法保存任务")); model.error = nil }) { store in
            let newTask = try store.addTask(title: title, category: task.category, parentId: parent, dueDate: task.dueDate)
            let hierarchy = TaskHierarchy(try store.listTasks())
            let anchor = ([task] + hierarchy.ancestors(of: task.id)).first { $0.parentId == parent }
            if let anchor { try store.reorder(newTask.id, relativeTo: anchor.id, after: true, allTasks: false) }
            created = newTask
        }
    }

    func beginEditing(_ task: DotistTask) {
        guard editing != task.id else { return }
        if editSaving { pendingEdit = task; return }
        let start = { clearInputs(); editing = task.id; editedTitle = task.title }
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

    var composerGlass: some View {
        GeometryReader { geometry in
            if let input = composerFrames["input"] {
                let field = CGRect(x: input.minX - 12, y: input.midY - 18,
                                   width: max(0, geometry.size.width - 8 - input.minX + 12), height: 36)
                let source = composerFrames["plus"] ?? field
                let rect = composerFlight && !composerFlightAtField ? source : field
                // 12 = panel corner radius 20 minus the 8pt edge margin, so the field's
                // trailing corner is concentric with the panel's.
                let radius: CGFloat = composerFlight && !composerFlightAtField ? 6 : 12
                Group {
                    if reduceTransparency || contrast == .increased {
                        RoundedRectangle(cornerRadius: radius).fill(DotistDesign.surface)
                            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(DotistDesign.accent.opacity(0.5), lineWidth: 1))
                    } else {
                        Color.clear.dotistGlass(.regular.tint(DotistTheme.tint(model.themeColor(forGroup: state.groupID), scheme)), in: RoundedRectangle(cornerRadius: radius))
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(composerFocused || composerFlight ? 1 : 0)
                .animation(composerFlight || LayoutMotionInputs.shouldReduceMotion(reduceMotion) ? nil : .easeOut(duration: composerFocused ? 0.2 : 0.15), value: composerFocused)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    var composerBar: some View {
        let selectedID = dropGroupIDs.contains(category) ? category : DotistGroup.inboxID
        let selectedName = model.composerGroupDisplayName(selectedID)
        let shownDue = dueDate?.dotistDay
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
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).focusEffectDisabled().frame(maxWidth: .infinity, alignment: .leading).frame(height: ComposerMetrics.rowHeight).clipped().help(model.text("分组")).accessibilityLabel(Text(model.text("分组"))).accessibilityValue(Text(selectedName)).accessibilityIdentifier("composer-group")
            ZStack(alignment: .leading) {
                ComposerInput(text: $composer, focused: $composerFocused, placeholder: model.text("写下一件小事"), label: model.text("新任务"), font: DotistDesign.nativeFont(ComposerMetrics.fontSize, language: model.language), commit: addTask, navigate: { direction in
                    let values = tagSuggestions
                    guard !values.isEmpty else { return false }
                    selectedSuggestion = (selectedSuggestion + direction + values.count) % values.count
                    return true
                }, complete: { force in chooseSuggestion(force: force) }).tint(DotistDesign.accent).frame(height: ComposerMetrics.rowHeight)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ComposerFrameKey.self, value: ["input": geometry.frame(in: .named(Self.listSpace))])
                    })
                    .accessibilityIdentifier("composer-input")
                if !tagSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { index, tag in
                            Button("#" + tag) { selectedSuggestion = index; _ = chooseSuggestion(force: true) }
                                .buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12, index == selectedSuggestion ? .medium : .regular)).foregroundColor(index == selectedSuggestion ? DotistDesign.ink : DotistDesign.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28)
                        }
                    }.dotistGlass(.regular.tint(DotistTheme.tint(model.themeColor(forGroup: state.groupID), scheme)), in: RoundedRectangle(cornerRadius: 12)).dotistInlineShadow().offset(y: -CGFloat(tagSuggestions.count * 28 + 6)).zIndex(1)
                }
            }.frame(maxWidth: .infinity).frame(height: ComposerMetrics.rowHeight)
                .onChange(of: composer) { _ in selectedSuggestion = -1; dismissComposerCue() }
                .onChange(of: composerFocused) { focused in if !focused { dismissComposerCue() } }
            Button { showDuePicker.toggle() } label: {
                IconTextRow(spacing: 4) {
                    if let shownDue { OpticalText(title: model.dueLabel(shownDue), size: 12, language: model.language).lineLimit(1) }
                    ComposerCalendarIcon(language: model.language).opacity(composerHovered || composerFocused ? 1 : 0)
                }.foregroundColor(shownDue == nil ? DotistDesign.muted : DotistDesign.accent)
            }
                .buttonStyle(.plain).frame(height: ComposerMetrics.rowHeight).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("设置到期日")))
                .help(model.text("设置到期日"))
                .accessibilityIdentifier("composer-due")
                .popover(isPresented: $showDuePicker) {
                    RangeCalendar(model: model, start: shownDue ?? "", end: shownDue ?? "", choose: { date, _ in dueDate = Date.dotistDay(date); showDuePicker = false }, close: { showDuePicker = false }, single: true, clear: { dueDate = nil; showDuePicker = false })
                }

        }.padding(.leading, 16).padding(.trailing, 8).frame(height: ComposerMetrics.barHeight).onHover { composerHovered = $0 }.overlay(alignment: .top) { Rectangle().fill(DotistDesign.rule).frame(height: 0.5) }
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
        guard let range = composer.range(of: "(^|\\s)#([^\\s#]*)$", options: .regularExpression),
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

    private func addTask() {
        let title = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !composerSubmitting else { return }
        let date = dueDate?.dotistDay ?? (["today", "tomorrow", "week", "nextweek", "next7"].contains(state.scope) ? rangeBounds.0 : nil)
        let selectedDue = dueDate
        let selectedCategory = dropGroupIDs.contains(category) ? category : DotistGroup.inboxID
        composerSubmitting = true
        model.change(completed: {
            composerSubmitting = false
            if composer.trimmingCharacters(in: .whitespacesAndNewlines) == title { composer = "" }
            if dueDate == selectedDue { dueDate = nil }
        }, failed: { composerSubmitting = false }) {
            _ = try $0.addTask(title: title, category: selectedCategory, dueDate: date)
        }
    }
}
