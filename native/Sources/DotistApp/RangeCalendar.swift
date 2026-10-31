import AppKit
import SwiftUI

struct RangeCalendar: View {
    @ObservedObject var model: AppModel
    let start: String
    let end: String
    let choose: (String, String) -> Void
    let close: () -> Void
    var single = false
    var clear: (() -> Void)? = nil
    @State private var month = Date()
    @State private var anchor: String?
    @State private var hover: String?
    @State private var keyboardDate: String?
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.firstWeekday = model.language == "en" ? 1 : 2
        return value
    }
    private var first: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month))! }
    private var gridStart: Date { calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7), to: first)! }
    private var marks: Set<String> { Set(model.tasks.filter { !$0.completed }.compactMap(\.dueDate)) }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: gridStart)! }
    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> Font { DotistDesign.font(size, weight: weight, serif: serif, language: model.language) }
    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: model.language); formatter.setLocalizedDateFormatFromTemplate(pattern)
        return formatter.string(from: date)
    }
    private var quick: [(String, String, String)] {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        func add(_ date: Date, _ n: Int) -> String { calendar.date(byAdding: .day, value: n, to: date)!.dotistDay }
        if single { return [("今天", today.dotistDay, today.dotistDay), ("明天", add(today, 1), add(today, 1)), ("下周一", add(monday, 7), add(monday, 7))] }
        return [("今天", today.dotistDay, today.dotistDay), ("明天", add(today, 1), add(today, 1)), ("本周", monday.dotistDay, add(monday, 6)), ("下周", add(monday, 7), add(monday, 13)), ("未来 7 天", today.dotistDay, add(today, 6))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(quick, id: \.0) { label, from, to in
                    Button(model.text(label)) { anchor = nil; hover = nil; choose(from, to) }.buttonStyle(.plain).modifier(DotistFocusRing())
                        .foregroundColor(start == from && end == to ? DotistDesign.accent : DotistDesign.muted)
                }
                if let clear, !start.isEmpty { Button(model.text("清除"), action: clear).buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.muted) }
            }.font(font(12))
            HStack {
                Button { month = calendar.date(byAdding: .month, value: -1, to: first)! } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("上个月")))
                Text(format(month, "yyyyMMMM")).font(font(14, .semibold, serif: true))
                Spacer()
                Button(model.text("今天")) { month = Date() }.buttonStyle(.plain).modifier(DotistFocusRing()).font(font(12))
                Button { month = calendar.date(byAdding: .month, value: 1, to: first)! } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).modifier(DotistFocusRing()).accessibilityLabel(Text(model.text("下个月")))
            }.frame(height: 28)
            HStack(spacing: 0) {
                Text(model.text("周")).frame(width: 24)
                ForEach(0..<7, id: \.self) { index in Text(format(day(index), "EEE")).frame(maxWidth: .infinity) }
            }.font(font(11)).foregroundColor(DotistDesign.muted)
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    let monday = day(week * 7 + (calendar.firstWeekday == 1 ? 1 : 0))
                    Text("\(Calendar(identifier: .iso8601).component(.weekOfYear, from: monday))").font(font(10)).foregroundColor(DotistDesign.faint).frame(width: 24)
                    ForEach(0..<7, id: \.self) { weekday in
                        let date = day(week * 7 + weekday)
                        let iso = date.dotistDay
                        let previewStart = anchor.flatMap { a in hover.map { min(a, $0) } } ?? start
                        let previewEnd = anchor.flatMap { a in hover.map { max(a, $0) } } ?? end
                        let selected = iso >= previewStart && iso <= previewEnd
                        let edge = iso == previewStart || iso == previewEnd
                        Button {
                            let chosen = NSApp.currentEvent?.type == .keyDown ? keyboardDate ?? iso : iso
                            keyboardDate = chosen
                            if single { choose(chosen, chosen); return }
                            let from = anchor ?? (NSEvent.modifierFlags.contains(.shift) ? start : nil)
                            if let from { choose(min(from, chosen), max(from, chosen)); anchor = nil; hover = nil }
                            else { anchor = chosen; choose(chosen, chosen) }
                        } label: {
                            ZStack {
                                if edge { Circle().fill(DotistDesign.accent).frame(width: 24, height: 24) }
                                Text("\(calendar.component(.day, from: date))").font(font(12, iso == Date().dotistDay ? .semibold : .regular))
                                    .foregroundColor(edge ? .white : selected || iso == Date().dotistDay ? DotistDesign.accent : DotistDesign.ink)
                                if !single && marks.contains(iso) {
                                    VStack { Spacer(); RoundedRectangle(cornerRadius: 1).fill(edge ? Color.white : DotistDesign.accent).frame(width: 6, height: 2).padding(.bottom, 2) }
                                }
                            }.frame(height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).opacity(calendar.isDate(date, equalTo: month, toGranularity: .month) ? 1 : 0.6)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .onHover { over in if anchor != nil { hover = over ? iso : nil } }
                            .modifier(CalendarFocusModifier(date: iso, keyboardDate: $keyboardDate))
                            .onMoveCommand { direction in
                                let offset: Int
                                switch direction {
                                case .left: offset = -1
                                case .right: offset = 1
                                case .up: offset = -7
                                case .down: offset = 7
                                @unknown default: return
                                }
                                let current: Date
                                if #available(macOS 12, *) { current = date }
                                else { current = keyboardDate.flatMap(Date.dotistDay) ?? date }
                                if let next = calendar.date(byAdding: .day, value: offset, to: current) {
                                    month = next
                                    keyboardDate = next.dotistDay
                                }
                            }
                            .accessibilityLabel(Text(format(date, "yyyyMMMMEEEEd")))
                            .accessibilityValue(Text(selected ? model.text("已选择") : ""))
                    }
                }
            }
            if !single {
                Text(model.text(anchor == nil ? "点一天，再点另一天可选范围；按住 Shift 点击也能延伸" : "再点一天，选出结束日期")).font(font(11)).foregroundColor(DotistDesign.muted)
                HStack { Spacer(); Button(model.text("完成"), action: close).buttonStyle(.plain).modifier(DotistFocusRing()).foregroundColor(DotistDesign.accent) }
            }
        }.padding(12).frame(width: 300).background(DotistDesign.paper)
            .onAppear { month = Date.dotistDay(start) ?? Date() }
            .onExitCommand { if anchor != nil { anchor = nil; hover = nil } else { close() } }
    }
}
