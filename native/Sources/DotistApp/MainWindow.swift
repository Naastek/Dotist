import AppKit
import Combine
import DotistCore
import SwiftUI

struct MainWindow: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.colorSchemeContrast) var contrast
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    let showViews: () -> Void
    let showSearch: () -> Void
    let showSettings: () -> Void
    let showGroupPanel: (String) -> Void
    let collapse: () -> Void
    var close: (() -> Void)? = nil
    var primary = true
    @ObservedObject var toolbarConfig = ToolbarConfig.shared
    @State var panelHovered = false
    @State var composerHovered = false
    @State var composerFocused = false
    @State var composerFlight = false
    @State var composerFlightAtField = false
    @State var composerFlightGeneration = UUID()
    @State var composerFrames: [String: CGRect] = [:]
    @State var toolbarDrag: ToolbarDragSession?
    @GestureState var toolbarGestureActive = false
    @State private var toolbarFrames: [ToolbarItem: CGRect] = [:]
    @State var showColorPicker = false
    @State var shelfTarget: String?
    @State var composer = ""
    @State var composerSubmitting = false
    @State var selectedSuggestion = -1
    @State var category = DotistGroup.inboxID
    @State var dueDate: Date?
    @State var addingToGroup: String?
    @State var groupTitles: [String: String] = [:]
    @State var groupSubmitting = false
    @State var editing: String?
    @State var draftAfter: String?
    @State var draftTitle = ""
    @State var draftParent: String?
    @State var draftHeight: CGFloat = 20
    @State var draftSaving = false
    @State var emptyAddHovered = false
    @State var emptyStateHeight: CGFloat = 0
    @State var editedTitle = ""
    @State var editSaving = false
    @State var editHeight: CGFloat = 20
    @State var pendingEdit: DotistTask?
    @State var manageGroups = false
    @State var manageTags = false
    @State var showCalendar = false
    @StateObject var filterPresentation = DateFilterPresentation()
    @State var hideCompleted = false
    @State var showDuePicker = false
    @State var pickingTask: String?
    @State var hoveredTask: String?
    @State var hoveredGroup: String?
    var customStart: String? {
        get { state.customStart }
        nonmutating set { state.customStart = newValue }
    }
    var customEnd: String? {
        get { state.customEnd }
        nonmutating set { state.customEnd = newValue }
    }
    @State var upcomingOpen = false
    @State var todayDoneOpen = false
    static let listSpace = "dotist-task-list"
    @State var rowFrames: [TaskListRowFrame] = []
    @State var groupFrames: [TaskListGroupFrame] = []
    @State var shelfFrames: [String: CGRect] = [:]
    @State var listViewport = CGRect.zero
    @State var dragCancelled = false
    @GestureState var reorderGestureActive = false
    @GestureState var holdGestureActive = false
    @State var hold = TaskHoldTracker()
    @StateObject var reorderRuntime = TaskReorderRuntime()
    @State var dragMotion = TaskDragMotion()
    @StateObject var selection = TaskSelectionController()
    @State var notice: String?
    @State var noticeLifetime = PausableToastLifetime(duration: 2)
    @State var undoToastLifetime = PausableToastLifetime(duration: 7)
    @State var undoToastVisible = false
    @State var ghostFrame = CGRect.zero

    var drag: TaskListDrag? {
        get { reorderRuntime.drag }
        nonmutating set { reorderRuntime.drag = newValue }
    }

    private var textColor: Color { DotistDesign.ink }
    var panelTasks: [DotistTask] {
        let tasks = state.activeTag.map { TaskTags.filter(model.tasks, tag: $0, description: model.tagDescription) } ?? model.tasks
        return tasks.filter { state.groupID == nil || $0.category == state.groupID }
    }
    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        (serif ? DotistDesign.nameFont(size, weight: weight, language: model.language) : DotistDesign.textFont(size, weight: weight, language: model.language))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(model.text(error)).font(font(12)).foregroundColor(DotistDesign.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            if manageTags {
                TagManager(model: model, close: { manageTags = false }, groups: { manageTags = false; manageGroups = true }, select: { tag in state.activeTag = tag; state.scope = "all" })
            } else if manageGroups {
                GroupManager(model: model, close: { manageGroups = false }, tags: { manageGroups = false; manageTags = true })
            } else {
                header
                DateFilterPushdown(isOpen: filterPresentation.isOpen) { filterStrip }
                VStack(spacing: 0) {
                    activeFilterLine
                    if model.tagCounts.contains(where: { $0.open > 0 }) { tagBar }
                    taskList
                }.background(DateFilterContentClickObserver(enabled: filterPresentation.isOpen, dismiss: filterPresentation.contentClicked))
            }
            if !manageGroups && !manageTags {
                composerArea
                    .background(DateFilterContentClickObserver(enabled: filterPresentation.isOpen, dismiss: filterPresentation.contentClicked))
            }
        }
        .background(alignment: .topLeading) { composerGlass }
        .coordinateSpace(name: Self.listSpace)
        .onPreferenceChange(ComposerFrameKey.self) { composerFrames = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .init("DotistQAComposer"))) { _ in
            if primary { activateEmptyStateComposer() }
        }
        .overlay(alignment: .topLeading) {
            ghostConnector
            if let drag {
                TaskLiftedBlock(drag: drag, motion: dragMotion) { row in
                    rowContent(row.task, children: model.children(of: row.task), sub: row.sub, allTasks: row.allTasks, previous: nil,
                               hideDue: row.hideDue, titleParts: model.tags(for: row.task), actionsVisible: false,
                               selected: selection.value.ids.contains(row.task.id), depthOverride: row.depth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: listViewport.width, height: listViewport.height).offset(x: listViewport.minX, y: listViewport.minY)
                }
            }
        }
        .background(TaskPickupFrameProbe(runtime: reorderRuntime, role: .panel))
        .background(TaskReorderInteractionGuard(rowFrames: rowFrames.map(\.frame) + Array(toolbarFrames.values), dragging: drag != nil, cancel: cancelReorder, undoRedo: handleUndoShortcut))
        .onPreferenceChange(TaskListRowFrame.Key.self) { if rowFrames != $0 { rowFrames = $0; updateGhostFrame() } }
        .onPreferenceChange(TaskListGroupFrame.Key.self) { if groupFrames != $0 { groupFrames = $0; updateGhostFrame() } }
        .preference(key: TaskGhostFrameKey.self, value: ghostFrame)
        .onChange(of: listViewport) { _ in updateGhostFrame() }
        .onPreferenceChange(ToolbarFrameKey.self) { toolbarFrames = $0 }
        .onChange(of: toolbarGestureActive) { active in if !active { toolbarDrag = nil } }
        .onPreferenceChange(TaskShelfFrameKey.self) { shelfFrames = $0 }
        .onChange(of: holdGestureActive) { active in
            if !active {
                hold.finish()
                DispatchQueue.main.async { if drag?.committing == false, !reorderGestureActive { cancelReorder() } }
            }
        }
        .onChange(of: reorderGestureActive) { active in
            traceReorder("swiftui.active-change", fields: ["newActive": "\(active)"])
            if !active {
                DispatchQueue.main.async {
                    if drag?.committing == false { cancelReorder() }
                    dragCancelled = false
                }
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in autoScrollReorder() }
        .onReceive(model.$undo) { entry in
            undoToastVisible = entry != nil
            undoToastLifetime.restart(at: ProcessInfo.processInfo.systemUptime)
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            if undoToastVisible && !undoToastLifetime.isVisible(at: now) { undoToastVisible = false }
            if notice != nil && !noticeLifetime.isVisible(at: now) { notice = nil }
        }
        .onDisappear { filterPresentation.dismiss(); traceReorder("lifecycle.disappear"); cancelReorder(); reorderRuntime.handleInput = nil; leaveInputs(); selection.update { $0.clear() } }
        .onHover { panelHovered = $0 }
        .foregroundColor(textColor)
        .onAppear { category = state.groupID ?? DotistGroup.inboxID; reorderRuntime.handleInput = handleReorderInput }
        .onChange(of: showCalendar) { _, open in filterPresentation.dateControlsChanged(open) }
        .onChange(of: state.groupID) { id in
            cancelReorder()
            dismissComposerCue()
            category = id ?? DotistGroup.inboxID
            leaveInputs()
            selection.update { $0.clear() }
        }
        .onChange(of: model.groups) { groups in
            if let id = state.groupID, !groups.contains(where: { $0.id == id }) { state.groupID = nil }
            if !groups.contains(where: { $0.id == category }) { category = state.groupID ?? DotistGroup.inboxID }
        }
        .onChange(of: state.activeTag) { _ in dismissComposerCue() }
        .onChange(of: customStart) { _ in dismissComposerCue() }
        .onChange(of: customEnd) { _ in dismissComposerCue() }
        .onChange(of: model.tagDescription) { _ in
            if let tag = state.activeTag, !model.tagCounts.contains(where: { $0.tag == tag && $0.open > 0 }) { state.activeTag = nil }
        }
        .onChange(of: model.scope) { scope in if primary { state.scope = scope } }
        .onChange(of: state.scope) { scope in dismissComposerCue(); cancelReorder(); leaveInputs(); selection.update { $0.clear() }; if primary { model.scope = scope } }
        .onChange(of: model.scopeNavigation) { _ in
            guard primary else { return }
            state.activeTag = nil
            customStart = nil; customEnd = nil
            manageGroups = false; manageTags = false
        }
    }

}
