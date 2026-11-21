import AppKit
import DotistCore
import SwiftUI

struct TagManager: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    let groups: () -> Void
    let select: (String) -> Void
    @State private var renaming: String?
    @State private var name = ""
    @State private var saving = false
    @State private var drag = ManagerDragState()
    @State private var hovered: String?
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        DotistDesign.font(size, weight: weight, serif: serif, language: model.language)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .opticalCenter, spacing: 8) {
                Button(action: close) { OpticalSymbol(name: "chevron.left", size: 11).frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("返回任务列表")))
                Button(action: groups) { OpticalText(title: model.text("分组"), size: 14, weight: .medium, language: model.language) }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.faint)
                OpticalText(title: model.text("标签"), size: 14, weight: .medium, language: model.language)
                Spacer()
                OpticalText(title: model.text("{n} 个").replacingOccurrences(of: "{n}", with: "\(model.orderedTagCounts.count)"), size: 12, language: model.language).foregroundColor(DotistDesign.muted)
            }.padding(.horizontal, 16).frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.orderedTagCounts.isEmpty { Text(model.text("在任务里写 #词 就会有标签，比如：写周报 #sideproject。")).font(font(12)).foregroundColor(DotistDesign.muted) }
                    ForEach(Array(model.orderedTagCounts.enumerated()), id: \.element.tag) { index, tag in
                        HStack(alignment: .opticalCenter, spacing: 8) {
                            OpticalSymbol(name: "line.3.horizontal", size: 11).foregroundColor(hovered == tag.tag ? DotistDesign.muted : DotistDesign.faint).frame(width: 18)
                            if renaming == tag.tag {
                                OpticalInput(text: $name, placeholder: model.text("标签名称"), font: DotistDesign.nativeFont(14, weight: .medium, language: model.language), focusOnAppear: true, commit: { save(tag.tag) }, blur: { save(tag.tag) }).frame(height: 24)
                            } else {
                                Button { select(tag.tag); close() } label: { OpticalText(title: "#" + tag.tag, size: 14, weight: .medium, language: model.language) }.buttonStyle(.plain).modifier(DotistFocusRing()).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            OpticalText(title: "\(tag.open)", size: 12, language: model.language).foregroundColor(DotistDesign.faint)
                            Button { renaming = tag.tag; name = tag.tag } label: { OpticalText(title: model.text("重命名"), size: 12, language: model.language) }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.faint)
                            Button { model.deleteTag(tag.tag) } label: { OpticalSymbol(name: "trash", size: 11).frame(width: 24, height: 24) }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("移除标签 {tag}").replacingOccurrences(of: "{tag}", with: tag.tag)))
                        }.frame(height: 40).contentShape(Rectangle())
                            .onHover { hovered = $0 ? tag.tag : nil }
                            .modifier(ManagerReorderRow(id: tag.tag, index: index, count: model.orderedTagCounts.count, drag: $drag) { model.moveTag(tag.tag, toIndex: $0) })
                    }
                    Text(model.text("只移除标题里的 #标签，任务会保留。")).font(font(12)).foregroundColor(DotistDesign.muted).padding(.top, 10)
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
