import AppKit
import Combine
import DotistCore
import SwiftUI

struct TaskEmptyAddLabel: View {
    var body: some View {
        OpticalSymbol(name: "plus", size: 16)
            .foregroundStyle(DotistDesign.faint)
            .frame(width: 32, height: 32).contentShape(Rectangle())
    }
}

/// Shared presentation keeps translated text constrained to the list width.
struct TaskEmptyStateContent<AddRow: View>: View {
    let title: String
    let hint: String?
    let language: String
    @ViewBuilder var addRow: () -> AddRow
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                OpticalText(title: title, size: 15, weight: .medium, language: language)
                    .foregroundStyle(DotistDesign.ink).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("empty-state-title")
                if let hint {
                    OpticalText(title: hint, size: 12, language: language)
                        .foregroundStyle(DotistDesign.faint).lineLimit(1).truncationMode(.tail)
                        .accessibilityIdentifier("empty-state-hint")
                }
            }.frame(maxWidth: .infinity)
            addRow()
        }
    }
}
