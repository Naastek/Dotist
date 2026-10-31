import AppKit
import DotistCore
import SwiftUI

struct TagManager: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let groups: () -> Void
    @State private var renaming: String?
    @State private var name = ""
    @State private var saving = false
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "chevron.left").frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("返回任务列表")))
                Button(model.text("分组"), action: groups).buttonStyle(.plain).modifier(DotistFocusRing()).font(font(14, .semibold, serif: true)).foregroundColor(DotistDesign.faint)
                Text(model.text("标签")).font(font(14, .semibold, serif: true))
                Spacer()
                Text(model.text("{n} 个").replacingOccurrences(of: "{n}", with: "\(model.tagCounts.count)")).font(font(12)).foregroundColor(DotistDesign.muted)
            }.padding(.horizontal, 16).frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.tagCounts.isEmpty { Text(model.text("在任务里写 #词 就会有标签，比如：写周报 #sideproject")).font(font(12)).foregroundColor(DotistDesign.muted) }
                    ForEach(model.tagCounts) { tag in
                        HStack(spacing: 8) {
                            if renaming == tag.tag {
                                TextField(model.text("标签名称"), text: $name, onEditingChanged: { active in if !active { save(tag.tag) } }, onCommit: { save(tag.tag) }).textFieldStyle(.plain).modifier(DotistFocusRing()).font(font(14, .semibold, serif: true))
                            } else {
                                Button("#" + tag.tag) { model.selectTag(tag.tag); model.scope = "all"; close() }.buttonStyle(.plain).modifier(DotistFocusRing()).font(font(14, .semibold, serif: true)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text("\(tag.open)").font(font(12)).foregroundColor(DotistDesign.faint)
                            Button(model.text("重命名")) { renaming = tag.tag; name = tag.tag }.buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12)).foregroundColor(DotistDesign.faint)
                            Button { model.change { try $0.retag(tag.tag, replacement: nil) } } label: { Image(systemName: "trash").frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("移除标签 {tag}").replacingOccurrences(of: "{tag}", with: tag.tag)))
                        }.frame(minHeight: 40)
                    }
                    Text(model.text("标签写在任务标题里（#词），所以改名和移除会同步改写所有带它的任务。")).font(font(12)).foregroundColor(DotistDesign.muted).padding(.top, 10)
                }.padding(.horizontal, 16)
            }
        }.foregroundColor(DotistDesign.ink)
    }
    private func save(_ tag: String) {
        guard renaming == tag, !saving else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty && value != tag else { renaming = nil; return }
        saving = true
        model.change(completed: { saving = false; renaming = nil }, failed: { saving = false }) { try $0.retag(tag, replacement: value) }
    }
}
