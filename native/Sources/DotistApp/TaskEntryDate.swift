import Foundation

/// Date interpretation belongs to a new-task draft, not to stored task titles.
struct TaskEntryDate: Equatable {
    enum Selection: Equatable {
        case automatic
        case selected(String)
        case cleared
    }

    var selection: Selection = .automatic
    var contextDay: String?

    struct Submission: Equatable {
        let title: String
        let day: String?
    }

    func resolve(_ text: String, fallback: String? = nil, composing: Bool = false,
                 now: Date = Date(), timeZone: TimeZone = .current) -> Submission {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch selection {
        case .selected(let day): return Submission(title: title, day: day)
        case .cleared: return Submission(title: title, day: nil)
        case .automatic:
            if !composing, let recognized = Self.recognize(title, now: now, timeZone: timeZone) {
                return recognized
            }
            return Submission(title: title, day: contextDay ?? fallback)
        }
    }

    private static let offsets = [
        "今天": 0, "明天": 1, "后天": 2, "後天": 2,
        "today": 0, "tomorrow": 1, "day after tomorrow": 2,
        "aujourd’hui": 0, "aujourd'hui": 0, "demain": 1, "après-demain": 2,
        "heute": 0, "morgen": 1, "übermorgen": 2,
    ]
    private static let nextMonday = ["下周一", "下週一", "next monday"]
    private static let words = (Array(offsets.keys) + nextMonday)
        .sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    private static let phrase = "(?:\(words)|[0-9]{4}-[0-9]{2}-[0-9]{2})"
    private static let prefix = try! NSRegularExpression(
        pattern: #"^(?:(\#(phrase))(?=$|[\s,，:：、])|(今天|明天|后天|後天|下周一|下週一)(?=\p{Han})(?!的|之前|之后|之後|以前|以后|以後))"#,
        options: .caseInsensitive
    )
    private static let suffix = try! NSRegularExpression(
        pattern: #"(?:^|\s)(\#(phrase))(?=(?:\s+#[^\s#]+)*$)"#,
        options: .caseInsensitive
    )
    private static let onlyTags = try! NSRegularExpression(pattern: #"^#[^\s#]+(?:\s+#[^\s#]+)*$"#)
    private static let trailingConnective = try! NSRegularExpression(
        pattern: #"(?:^|\s)(before|after|until|by|since|about|avant|après|depuis|dès|bis|vor|nach|seit)$"#,
        options: .caseInsensitive
    )
    private static let prefixSeparators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",，:：、"))

    private static func match(_ pattern: NSRegularExpression, in text: String, groups: ClosedRange<Int>) -> Range<String.Index>? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups.lazy.compactMap { Range(match.range(at: $0), in: text) }.first
    }

    private static func recognize(_ text: String, now: Date, timeZone: TimeZone) -> Submission? {
        guard text.rangeOfCharacter(from: .newlines) == nil else { return nil }
        let leading = match(prefix, in: text, groups: 1...2)
        let trailing = match(suffix, in: text, groups: 1...1)
        // Two distinct boundary dates give the draft no unambiguous due day.
        if let leading, let trailing, leading != trailing { return nil }
        guard let range = leading ?? trailing else { return nil }

        let title: String
        if leading != nil {
            title = String(text[range.upperBound...].unicodeScalars.drop(while: prefixSeparators.contains))
            guard match(prefix, in: title, groups: 1...2) == nil else { return nil }
        } else {
            let body = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard match(suffix, in: body, groups: 1...1) == nil,
                  trailingConnective.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) == nil else { return nil }
            title = body + text[range.upperBound...]
        }
        guard !title.isEmpty, onlyTags.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) == nil,
              let day = day(for: text[range].lowercased(), now: now, timeZone: timeZone) else { return nil }
        return Submission(title: title, day: day)
    }

    private static func day(for phrase: String, now: Date, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        if let offset = offsets[phrase] {
            return calendar.date(byAdding: .day, value: offset, to: now).map { formatter.string(from: $0) }
        }
        if nextMonday.contains(phrase) {
            let weekday = calendar.component(.weekday, from: now)
            let offset = 7 - (weekday + 5) % 7
            return calendar.date(byAdding: .day, value: offset, to: now).map { formatter.string(from: $0) }
        }
        guard let date = formatter.date(from: phrase), formatter.string(from: date) == phrase else { return nil }
        return phrase
    }
}
