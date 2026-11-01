import AppKit
import SwiftUI

struct NativeSegmentedPicker: NSViewRepresentable {
    @Binding var selection: String
    let options: [(String, String)]
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FocusSegmentedControl {
        let control = FocusSegmentedControl(labels: options.map(\.1), trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.controlSize = .regular
        control.focusRingType = .none
        control.setAccessibilityLabel(label)
        return control
    }
    func updateNSView(_ control: FocusSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.setAccessibilityLabel(label)
        for (index, option) in options.enumerated() where control.label(forSegment: index) != option.1 {
            control.setLabel(option.1, forSegment: index)
        }
        let selected = options.firstIndex(where: { $0.0 == selection }) ?? -1
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }
    final class Coordinator: NSObject {
        var parent: NativeSegmentedPicker
        init(_ parent: NativeSegmentedPicker) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment].0
        }
    }
}

final class FocusSegmentedControl: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124, 115, 119:
            let next = event.keyCode == 115 ? 0 : event.keyCode == 119 ? segmentCount - 1 : min(max(selectedSegment + (event.keyCode == 123 ? -1 : 1), 0), segmentCount - 1)
            guard next != selectedSegment else { return }
            selectedSegment = next
            sendAction(action, to: target)
        case 49, 36:
            sendAction(action, to: target)
        default: super.keyDown(with: event)
        }
    }
}
