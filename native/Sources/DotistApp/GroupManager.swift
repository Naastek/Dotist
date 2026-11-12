import AppKit
import DotistCore
import SwiftUI

struct GroupManager: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let tags: () -> Void
    @State private var adding = ""
    @State private var addingGroup = false
    @State private var renaming: String?
    @State private var name = ""
    @State private var renameSaving = false
    @State private var pendingRename: DotistGroup?
    @State private var drag = ManagerDragState()
    @State private var hovered: String?
    @State private var colorGroup: String?
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .opticalCenter, spacing: 8) {
                Button(action: close) { OpticalSymbol(name: "chevron.left", size: 11).frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("返回任务列表")))
                OpticalText(title: model.text("分组"), size: 14, weight: .semibold, language: model.language)
                Button(action: tags) { OpticalText(title: model.text("标签"), size: 14, weight: .semibold, language: model.language) }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.faint)
                Spacer()
                OpticalText(title: model.text("{n} 个").replacingOccurrences(of: "{n}", with: "\(model.visibleGroups.count)"), size: 12, language: model.language).foregroundColor(DotistDesign.muted)
            }.padding(.horizontal, 16).frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.visibleGroups.enumerated()), id: \.element.id) { index, group in
                        HStack(alignment: .opticalCenter, spacing: 8) {
                            OpticalSymbol(name: "line.3.horizontal", size: 11)
                                .foregroundColor(hovered == group.id ? DotistDesign.muted : DotistDesign.faint)
                                .frame(width: 18)
                            if renaming == group.id {
                                OpticalInput(text: $name, placeholder: model.text("分组名称"), font: DotistDesign.nativeFont(14, weight: .semibold, serif: true, language: model.language), focusOnAppear: true, commit: { save(group) }, blur: { save(group) }).frame(height: 24)
                            } else {
                                Button { begin(group) } label: { OpticalText(title: group.name, size: 14, weight: .semibold, serif: true, language: model.language).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).modifier(DotistFocusRing()).disabled(group.id == DotistGroup.inboxID)
                            }
                            Button { colorGroup = group.id } label: {
                                ManagerColorSwatch(color: DotistGroupColor(rawValue: group.color), selected: false)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(Text(model.text("分组颜色")))
                                .popover(isPresented: Binding(get: { colorGroup == group.id }, set: { if !$0 { colorGroup = nil } })) {
                                    ManagerColorPalette(model: model, selected: DotistGroupColor(rawValue: group.color)) { color in
                                        model.setGroupColor(group.id, color); colorGroup = nil
                                    }.padding(12)
                                }
                            Button { model.deleteGroup(group) } label: { OpticalSymbol(name: "xmark", size: 11).frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing())
                                .accessibilityLabel(Text(model.text("删除分组 {name}").replacingOccurrences(of: "{name}", with: group.name)))
                        }.frame(height: 40).contentShape(Rectangle())
                            .onHover { hovered = $0 ? group.id : nil }
                            .modifier(ManagerReorderRow(id: group.id, index: index, count: model.visibleGroups.count, drag: $drag) { model.moveGroup(group.id, toIndex: $0) })
                    }
                    TextField(model.text("新分组，回车添加"), text: $adding, onCommit: {
                        let value = adding.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty, !addingGroup else { return }
                        addingGroup = true
                        model.change(completed: { addingGroup = false; if adding.trimmingCharacters(in: .whitespacesAndNewlines) == value { adding = "" } }, failed: { addingGroup = false }) { _ = try $0.addGroup(name: value) }
                    }).textFieldStyle(.plain).modifier(DotistFocusRing()).font(font(13)).padding(.leading, 26).frame(height: 32).padding(.top, 12)
                    Text(model.text("该分组的任务会移到「无分组」（全部）里，不会被删除。"))
                        .font(font(12)).foregroundColor(DotistDesign.muted).padding(.top, 10)
                }.padding(.horizontal, 16)
            }
        }.foregroundColor(DotistDesign.ink)
    }
    private func begin(_ group: DotistGroup) {
        if renameSaving { pendingRename = group; return }
        let open = { renaming = group.id; name = group.name }
        if let id = renaming, let current = model.groups.first(where: { $0.id == id }) { save(current, then: open) } else { open() }
    }
    private func save(_ group: DotistGroup, then: @escaping () -> Void = {}) {
        guard renaming == group.id, !renameSaving else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty && value != group.name else { renaming = nil; then(); return }
        renameSaving = true
        model.change(completed: {
            renameSaving = false; renaming = nil
            if let pending = pendingRename { pendingRename = nil; renaming = pending.id; name = pending.name } else { then() }
        }, failed: { renameSaving = false; pendingRename = nil }) { _ = try $0.updateGroup(group.id, name: value) }
    }
}


// The rows retain their original positions during a drag; neighbours shift to reveal the destination.
struct ManagerDragState {
    var id: String?
    var source = 0
    var target = 0
    var translation: CGFloat = 0
}

struct ManagerReorderRow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    let index: Int
    let count: Int
    @Binding var drag: ManagerDragState
    let move: (Int) -> Void
    private let height: CGFloat = 40

    private var offset: CGFloat {
        guard drag.id != nil else { return 0 }
        if drag.id == id { return drag.translation }
        if drag.source < drag.target && index > drag.source && index <= drag.target { return -height }
        if drag.target < drag.source && index >= drag.target && index < drag.source { return height }
        return 0
    }
    func body(content: Content) -> some View {
        content.offset(y: offset).zIndex(drag.id == id ? 1 : 0)
            .shadow(color: .black.opacity(drag.id == id ? 0.16 : 0), radius: 4, y: 3)
            .animation(LayoutMotionInputs.shouldReduceMotion(reduceMotion) ? nil : .easeInOut(duration: 0.15), value: drag.target)
            .simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { value in
                    if drag.id == nil { drag.id = id; drag.source = index; drag.target = index }
                    guard drag.id == id else { return }
                    drag.translation = value.translation.height
                    drag.target = min(max(drag.source + Int((value.translation.height / height).rounded()), 0), max(count - 1, 0))
                }
                .onEnded { _ in
                    guard drag.id == id else { return }
                    let target = drag.target
                    let source = drag.source
                    drag = ManagerDragState()
                    if target != source { move(target) }
                })
    }
}

struct ManagerColorSwatch: View {
    let color: DotistGroupColor
    let selected: Bool
    var body: some View {
        Circle().fill(DotistTheme.swatch(color)).frame(width: 16, height: 16)
            .overlay(Circle().stroke(DotistDesign.muted, lineWidth: color == .none || selected ? 1 : 0))
            .overlay { if selected { OpticalSymbol(name: "checkmark", size: 9, weight: .bold).foregroundColor(color == .none ? DotistDesign.ink : .white) } }
            .frame(width: 24, height: 24).contentShape(Rectangle())
    }
}

struct ManagerColorPalette: View {
    @ObservedObject var model: AppModel
    let selected: DotistGroupColor
    let choose: (DotistGroupColor) -> Void
    private let names = ["无颜色", "红色", "橙色", "黄色", "绿色", "青色", "蓝色", "紫色", "粉色"]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(DotistGroupColor.allCases.enumerated()), id: \.element.rawValue) { index, color in
                Button { choose(color) } label: { ManagerColorSwatch(color: color, selected: color == selected) }
                    .buttonStyle(.plain).accessibilityLabel(Text(model.text(names[index])))
                    .accessibilityAddTraits(color == selected ? .isSelected : [])
            }
        }
    }
}
