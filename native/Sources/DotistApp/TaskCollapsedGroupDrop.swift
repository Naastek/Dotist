import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Collapsed groups accept a complete subtree as a new final root.
enum TaskCollapsedGroupDrop {
    static func target(groupID: String) -> TaskReorderEngine.Target {
        .init(groupID: groupID, slot: Int.max, level: 0, parentID: nil, beforeID: nil)
    }

}

