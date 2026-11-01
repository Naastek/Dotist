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
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "chevron.left").frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("返回任务列表")))
                Text(model.text("分组")).font(font(14, .semibold, serif: true))
                Button(model.text("标签"), action: tags).buttonStyle(.plain).modifier(DotistFocusRing()).font(font(14, .semibold, serif: true)).foregroundColor(DotistDesign.faint)
                Spacer()
                Text(model.text("{n} 个").replacingOccurrences(of: "{n}", with: "\(model.groups.count)")).font(font(12)).foregroundColor(DotistDesign.muted)
            }.padding(.horizontal, 16).frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        HStack(spacing: 8) {
                            if renaming == group.id {
                                TextField(model.text("分组名称"), text: $name, onEditingChanged: { active in if !active { save(group) } }, onCommit: { save(group) })
                                    .textFieldStyle(.plain).modifier(DotistFocusRing()).font(font(14, .semibold, serif: true))
                            } else {
                                Button { begin(group) } label: { Text(group.name).font(font(14, .semibold, serif: true)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).modifier(DotistFocusRing()).disabled(group.id == DotistGroup.inboxID)
                            }
                            Button { model.change { try $0.moveGroup(group.id, direction: -1) } } label: { Image(systemName: "chevron.up").frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).disabled(index <= 1)
                            Button { model.change { try $0.moveGroup(group.id, direction: 1) } } label: { Image(systemName: "chevron.down").frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).disabled(group.id == DotistGroup.inboxID || index == model.groups.count - 1)
                            Button { model.deleteGroup(group) } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).disabled(group.id == DotistGroup.inboxID)
                        }.frame(minHeight: 40)
                    }
                    TextField(model.text("新分组，回车添加"), text: $adding, onCommit: {
                        let value = adding.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty, !addingGroup else { return }
                        addingGroup = true
                        model.change(completed: { addingGroup = false; if adding.trimmingCharacters(in: .whitespacesAndNewlines) == value { adding = "" } }, failed: { addingGroup = false }) { _ = try $0.addGroup(name: value) }
                    }).textFieldStyle(.plain).modifier(DotistFocusRing()).font(font(13)).padding(.leading, 26).frame(height: 32).padding(.top, 12)
                    Text(model.text("删除分组会连同其中的任务一起删除，底部提示里可以撤销。点名字重命名。"))
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
