import SwiftUI

extension Animation {
    /// The app's animation (design/README.md «الحالات والحركة»): SwiftUI's default spring, or
    /// with Reduce Motion a short cross-fade over `duration-complete` in place of the movement.
    static func zimam(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: ZimamMotion.complete) : .default
    }

    /// Completing a task: the circle fills and the row fades over `duration-complete`. A change
    /// of colour and fill rather than of place, so it is the same with Reduce Motion.
    static var zimamComplete: Animation {
        .easeInOut(duration: ZimamMotion.complete)
    }
}
