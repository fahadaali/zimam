import SwiftUI
import ZimamKit

/// A quadrant's color and icon, the same on the matrix screen and the matrix widget. The color
/// never goes alone: the quadrant's name and icon go with it.
extension PriorityQuadrant {
    var color: Color {
        switch self {
        case .urgentImportant: ZimamColor.quadrantUrgentImportant
        case .important: ZimamColor.quadrantImportant
        case .urgent: ZimamColor.quadrantUrgent
        case .someday: ZimamColor.quadrantSomeday
        }
    }

    var systemImage: String {
        switch self {
        case .urgentImportant: "flame"
        case .important: "calendar"
        case .urgent: "bolt"
        case .someday: "line.3.horizontal"
        }
    }
}
