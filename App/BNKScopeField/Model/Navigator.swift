import Foundation
import Observation
import BNKKit

/// Which screen is showing, and what it was asked to show.
///
/// Exists because Overview names a broken pod and the natural next move is to
/// open it — which means one screen has to be able to send another somewhere.
/// Holding the selected section in a `@State` inside the root view made that
/// impossible: a finding could name the pod but not reach it.
@Observable
@MainActor
final class Navigator {
    var section: Section = .overview

    /// An object another screen asked Resources to open.
    struct Request: Equatable, Hashable {
        let kind: String
        let namespace: String?
        let name: String
    }

    private(set) var pending: Request?

    /// Send the reader to one object, wherever they are now.
    func reveal(pod name: String, namespace: String?) {
        pending = Request(kind: "pods", namespace: namespace, name: name)
        section = .resources
    }

    /// Cleared only once the request has been acted on.
    ///
    /// Clearing it first looks tidier and breaks the thing: the screen that
    /// honours a request keys its work on `pending`, so setting it to nil at the
    /// top invalidates that work's own identity and SwiftUI cancels it halfway.
    func clear() { pending = nil }
}
