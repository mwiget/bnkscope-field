import XCTest

/// Drives the app through the demo, so a recording is a re-runnable script
/// rather than a performance.
///
/// This exists because the simulator cannot be tapped from the command line —
/// `simctl` has no gesture verbs, and idb is archived and refuses to build
/// against Xcode 26. XCUITest is Apple's own answer to the same problem and was
/// already on the machine.
///
/// Each beat is its own test method so a fumbled one can be re-shot on its own:
/// `-only-testing:BNKScopeFieldUITests/DemoDrive/beat4Logs`.
final class DemoDrive: XCTestCase {

    /// Long enough to read what changed, short enough not to bore. Tuned per
    /// beat rather than globally — waiting on a chart is not the same as
    /// waiting on a menu.
    /// A take must outlast its narration, or the picture runs out before the
    /// voice does. These are the scene durations plus slack for the launch, which
    /// is trimmed off the head during assembly.
    enum Beat {
        static let glance: TimeInterval = 1.6
        static let read: TimeInterval = 3.0
        static let settle: TimeInterval = 6.0
        /// scene03 is 31.0s, scene04 24.4s, scene06 26.6s, scene07 21.5s.
        static let hold3: TimeInterval = 20.0
        static let hold4: TimeInterval = 26.0
        static let hold6: TimeInterval = 12.0
        static let hold7: TimeInterval = 24.0
    }

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Landscape, set here rather than by pinning the app's supported
        // orientations: the recording should exercise the shipping build, not a
        // special one that cannot rotate.
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launch()
        dwell(1.0)
    }

    // MARK: - Helpers

    /// Tap something by its label, once it exists.
    ///
    /// Fails loudly rather than silently doing nothing: a demo that quietly
    /// skips a step produces a recording that has to be watched to be found
    /// wrong.
    @discardableResult
    func tap(_ label: String, in query: XCUIElementQuery? = nil,
             timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let element = (query ?? app.buttons)[label]
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("never found \"\(label)\"", file: file, line: line)
            return false
        }
        element.tap()
        return true
    }

    func dwell(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func goTo(_ section: String) {
        tap(section)
        dwell(Beat.glance)
    }

    // MARK: - Beats

    /// The app with nothing in it. scene01 is 11.2s.
    func beat1Empty() throws {
        dwell(18.0)
    }

    /// The empty app, and the tap that starts the import.
    ///
    /// It stops at the tap. What opens next is the system document picker —
    /// Apple's UI, in another process, showing nothing about this app — so the
    /// cut lands on the cluster appearing instead. The import itself is real;
    /// only the file-browsing is off camera.
    func beat2ImportTap() throws {
        dwell(Beat.read)
        tap("Import kubeconfig")
        dwell(2.0)
        // Dismiss it before the test ends. A modal left open belongs to another
        // process, and the harness waits on teardown that never comes.
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        for candidate in [files.buttons["Cancel"], app.buttons["Cancel"]] where candidate.exists {
            candidate.tap()
            break
        }
        // Rest on the empty Overview. The next take is the cluster that the
        // import produced, and the two are crossfaded — so this take has to end
        // somewhere the other one can be dissolved into.
        dwell(10.0)
    }

    /// The other half: a cluster that has just been imported and probed. The
    /// import selects it, which opens it in the sidebar; its own screen is the
    /// first row under it.
    func beat2ImportResult() throws {
        goTo("Cluster")
        dwell(Beat.settle)
    }

    /// Overview alone.
    ///
    /// Split from the tap because the narration spends twenty-odd seconds on
    /// what Overview is before it mentions the pod — and in one take the sheet
    /// opened as soon as the finding rendered, so the voice was still explaining
    /// the ranking while the screen had moved on.
    func beat3Overview() throws {
        goTo("Overview")
        dwell(26.0)
    }

    /// Opening the pod, and what it says. The second half of scene03.
    func beat3Finding() throws {
        goTo("Overview")
        dwell(2.0)
        let finding = app.buttons.containing(NSPredicate(format: "label CONTAINS 'f5-dssm'")).firstMatch
        guard finding.waitForExistence(timeout: 20) else {
            XCTFail("no f5-dssm finding on Overview")
            return
        }
        finding.tap()
        dwell(14.0)
    }

    func beat4Logs() throws {
        goTo("Logs")
        dwell(Beat.hold4)
    }

    func beat5TMMLive() throws {
        goTo("TMM Live")
        dwell(Beat.read)
        if app.buttons["Add the exporter"].waitForExistence(timeout: 5) {
            app.buttons["Add the exporter"].tap()
            // The image pull is the slow part; this wait is what gets cut.
            dwell(45)
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            dwell(Beat.settle)
        } else {
            // Re-run with the exporter already in: this is the second half of
            // scene05, the charts the install was for. It needs to last.
            dwell(26.0)
        }
    }

    func beat6Terminal() throws {
        goTo("Terminal")
        tap("ip -s link")
        dwell(Beat.settle)
        tap("connections")
        dwell(Beat.hold6)
    }

    func beat7DPUServices() throws {
        goTo("DPU Services")
        dwell(Beat.hold7)
    }

    /// NICo is under the cluster that runs it, so that cluster is opened first.
    /// Its row is found by the badge rather than by name — the lab's name does
    /// not belong in the repository — and only the row carries the badge until
    /// it is open: once it is, a "NICo" screen row appears beneath it, and that
    /// one matches the exact label.
    func beat8NICo() throws {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'NICo'")).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            XCTFail("no cluster with the NICo badge")
            return
        }
        row.tap()
        dwell(Beat.read)
        goTo("NICo")
        dwell(Beat.settle)
    }

    /// The closing shot: back to Overview, both clusters in.
    func beat9Close() throws {
        goTo("Overview")
        dwell(Beat.settle)
    }
}
