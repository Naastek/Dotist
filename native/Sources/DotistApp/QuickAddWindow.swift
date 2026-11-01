import AppKit
import DotistCore
import SwiftUI

struct QuickAddWindow: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var title = ""
    @State private var submitting = false
    @State private var category = UserDefaults.standard.string(forKey: "dotist.quick.group") ?? DotistGroup.inboxID
    @State private var dueIndex = -1
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font {
        (serif ? DotistDesign.nameFont(size, weight: weight, language: model.language) : DotistDesign.textFont(size, weight: weight, language: model.language))
    }
    private var choices: [(String, String)] {
        let today = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: today)
        let nextMonday = (2 - weekday + 7) % 7
        return [("今天", today.dotistDay), ("明天", calendar.date(byAdding: .day, value: 1, to: today)!.dotistDay), ("下周一", calendar.date(byAdding: .day, value: nextMonday == 0 ? 7 : nextMonday, to: today)!.dotistDay)]
    }
    private var groupIDs: [String] { [DotistGroup.inboxID] + model.visibleGroups.map(\.id) }
    private var group: DotistGroup? { model.groups.first { $0.id == category } ?? model.groups.first { $0.id == DotistGroup.inboxID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickInput(text: $title, placeholder: model.text("写下一件小事"), label: model.text("快速添加"), font: DotistDesign.nativeFont(22, language: model.language), commit: add, cancel: close, cycle: cycle)
                .frame(height: 30)
            HStack(spacing: 14) {
                if let group {
                    Button { cycle(1) } label: {
                        OpticalText(title: model.groupDisplayName(group.id), size: 12, weight: .semibold, serif: true, language: model.language)
                            .foregroundColor(DotistDesign.ink)
                            .lineLimit(1).frame(minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).modifier(DotistFocusRing())
                }
                Button { dueIndex = dueIndex + 1 >= choices.count ? -1 : dueIndex + 1 } label: {
                    OpticalText(title: dueIndex < 0 ? model.text("到期日") : model.text(choices[dueIndex].0), size: 12, language: model.language).frame(height: 24)
                }.buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(dueIndex < 0 ? DotistDesign.muted : DotistDesign.accent)
                Spacer()
                OpticalText(title: model.error.map { model.text($0) } ?? model.text("回车添加 · Esc 关闭 · Tab 换分组"), size: 12, language: model.language).foregroundColor(model.error == nil ? DotistDesign.faint : DotistDesign.danger).lineLimit(1)
            }.frame(height: 24)
        }.padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .foregroundColor(DotistDesign.ink).background(WindowMaterial(opacity: model.settings.opacity, frost: model.settings.frost)).cornerRadius(18).background(WindowShadowInvalidation()).modifier(DotistTheme(theme: model.settings.theme))
    }
    private func cycle(_ step: Int) {
        let index = groupIDs.firstIndex(of: category) ?? 0
        category = groupIDs[(index + step + groupIDs.count) % groupIDs.count]
        UserDefaults.standard.set(category, forKey: "dotist.quick.group")
    }
    private func add() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !submitting, let group else { return }
        let date = dueIndex < 0 ? nil : choices[dueIndex].1
        submitting = true
        model.change(completed: { submitting = false; close() }, failed: { submitting = false }) { _ = try $0.addTask(title: value, category: group.id, dueDate: date) }
    }
}

struct QuickInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let font: NSFont
    let commit: () -> Void
    let cancel: () -> Void
    let cycle: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = ComposerTextField()
        field.rowHeight = 30
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(DotistDesign.faint)])
        (field as? ComposerTextField)?.configure(font: font, reference: text.isEmpty ? placeholder : text)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickInput
        init(_ parent: QuickInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { parent.commit(); return true }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.cancel(); return true }
            if commandSelector == #selector(NSResponder.insertTab(_:)) { parent.cycle(1); return true }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) { parent.cycle(-1); return true }
            return false
        }
    }
}
