import AppKit
import DotistCore
import SwiftUI

@MainActor
final class TaskPanelState: ObservableObject {
    @Published var groupID: String?
    @Published var scope: String
    @Published var activeTag: String?
    // Legacy navigation bookkeeping only; descendants always render expanded.
    @Published var expanded: Set<String> = []
    @Published var folded: Set<String> = []
    func selectedColor(in model: AppModel) -> DotistGroupColor {
        guard let groupID, let group = model.groups.first(where: { $0.id == groupID }) else {
            return DotistGroupColor(rawValue: model.settings.allColor)
        }
        return DotistGroupColor(rawValue: group.color)
    }

    func selectColor(_ color: DotistGroupColor, in model: AppModel) {
        if let groupID {
            model.setGroupColor(groupID, color)
        } else {
            var patch = DotistSettingsPatch()
            patch.allColor = color.rawValue
            model.updateSettings(patch)
        }
    }

    init(groupID: String? = nil, scope: String = "all") {
        self.groupID = groupID
        self.scope = scope
    }
}

/// Navigation and task data stay local/shared respectively; motion is common to every panel.
@MainActor
final class GroupPanelController: NSWindowController, NSWindowDelegate, ObservableObject {
    let model: AppModel
    let state: TaskPanelState
    private(set) var motion: PanelMotion!
    var compact: Bool { motion?.bubble ?? false }
    private let didClose: (GroupPanelController) -> Void

    var groupName: String { state.groupID.map { model.groupDisplayName($0) } ?? model.text("全部") }
    var tasks: [DotistTask] { model.topLevelTasks.filter { state.groupID == nil || $0.category == state.groupID } }
    var bubbleContent: BubbleContent { BubbleContent(model: model, groupID: state.groupID, fallbackTitle: groupName) }
    var remaining: Int { bubbleContent.remaining }
    var bubbleTitle: String { bubbleContent.title }

    init(model: AppModel, groupID: String, near frame: NSRect, showViews: @escaping () -> Void,
         showSearch: @escaping () -> Void, showSettings: @escaping () -> Void,
         showGroupPanel: @escaping (String) -> Void, didClose: @escaping (GroupPanelController) -> Void) {
        self.model = model
        state = TaskPanelState(groupID: groupID)
        self.didClose = didClose
        // Inbox is storage for ungrouped tasks, never an independent group panel.
        guard groupID != DotistGroup.inboxID else { super.init(window: nil); return }
        let size = NSSize(width: 364, height: 620)
        let panel = DotistPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 320, height: 440)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        super.init(window: panel)
        motion = PanelMotion(model: model, panel: panel, size: size, title: { [weak self] in self?.bubbleTitle ?? "" },
            bubbleContent: { [weak self, model] in self?.bubbleContent ?? BubbleContent(model: model) })
        panel.delegate = self
        applyAppearance()
        updateTitle()
        let hosting = DotistHostingView(rootView: GroupPanelContent(model: model, state: state, controller: self,
            showViews: showViews, showSearch: showSearch, showSettings: showSettings, showGroupPanel: showGroupPanel))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: hosting.frame)
        container.addSubview(hosting)
        panel.contentView = container
        let area = (NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main)?.visibleFrame
        let origin = NSPoint(x: frame.minX - size.width - 18, y: frame.maxY - size.height - 24)
        panel.setFrameOrigin(area.map { NSPoint(x: min(max(origin.x, $0.minX + 12), $0.maxX - size.width),
                                               y: min(max(origin.y, $0.minY), $0.maxY - size.height)) } ?? origin)
    }
    required init?(coder: NSCoder) { return nil }

    func applyAppearance() {
        window?.appearance = model.settings.theme == "light" ? NSAppearance(named: .aqua) : model.settings.theme == "dark" ? NSAppearance(named: .darkAqua) : nil
        window?.level = model.settings.alwaysOnTop ? .floating : .normal
        motion?.refreshShadow()
    }
    func updateTitle() { window?.title = "Dotist · " + groupName }
    func toggleCompact() { motion?.toggleBubble() }

    func showBubbleMenu(_ event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        let expand = NSMenuItem(title: groupName, action: #selector(expandPanel), keyEquivalent: "")
        expand.target = self
        menu.addItem(expand)
        let close = NSMenuItem(title: model.text("关闭面板"), action: #selector(closePanel), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        motion?.showMenu(menu, event: event, in: view)
    }
    @objc private func expandPanel() { if compact { toggleCompact() }; window?.makeKeyAndOrderFront(nil) }
    @objc func closePanel() { close() }
    func windowWillClose(_ notification: Notification) {
        motion?.stop()
        window?.contentView = nil
        didClose(self)
    }
}

private struct GroupPanelContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: TaskPanelState
    @ObservedObject var controller: GroupPanelController
    let showViews: () -> Void
    let showSearch: () -> Void
    let showSettings: () -> Void
    let showGroupPanel: (String) -> Void

    var body: some View {
        FloatingPanelView(model: model, motion: controller.motion, colorState: state, title: controller.bubbleTitle,
            remaining: controller.remaining, total: controller.tasks.count, groupName: controller.groupName,
            contextMenu: controller.showBubbleMenu,
            content: MainWindow(model: model, state: state, showViews: showViews, showSearch: showSearch, showSettings: showSettings,
                showGroupPanel: showGroupPanel, collapse: controller.toggleCompact, close: controller.closePanel, primary: false))
        .onChange(of: state.groupID) { id in
            guard let id, id != DotistGroup.inboxID else { controller.closePanel(); return }
            controller.updateTitle()
        }
        .onChange(of: model.groups) { groups in
            if let id = state.groupID, !groups.contains(where: { $0.id == id }) { controller.closePanel(); return }
            controller.updateTitle()
        }
    }
}
