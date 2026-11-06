import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

struct TaskListRowFrame: Equatable {
    let task: DotistTask
    var frame: CGRect
    var sub = false
    var allTasks = false
    var hideDue = false
    var region = ""
    var date: String? = nil
    var depth = 0
    var context = false
    var previous: String? = nil
    var next: String? = nil
    struct Key: PreferenceKey {
        static let defaultValue: [TaskListRowFrame] = []
        static func reduce(value: inout [TaskListRowFrame], nextValue: () -> [TaskListRowFrame]) { value.append(contentsOf: nextValue()) }
    }
}

struct TaskListGroupFrame: Equatable {
    let id: String
    let region: String
    let frame: CGRect
    var date: String? = nil
    struct Key: PreferenceKey {
        static let defaultValue: [TaskListGroupFrame] = []
        static func reduce(value: inout [TaskListGroupFrame], nextValue: () -> [TaskListGroupFrame]) { value.append(contentsOf: nextValue()) }
    }
}

struct TaskShelfFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

