#if os(iOS)
import Testing
import WatchConnectivity
@testable import Zimam

/// The system calls some delegates on its own queues. With the main actor as the default
/// isolation, such a delegate method that was left on the main actor stops the app (this one
/// did, at launch). Calling it from a detached task must compile and must not trap.
struct SystemCallbackTests {
    @Test func watchLinkTakesCallsOffTheMainThread() async {
        await Task.detached {
            // Does nothing, so it is safe to call with no watch paired.
            WatchLink.shared.sessionDidBecomeInactive(WCSession.default)
        }.value
    }
}
#endif
