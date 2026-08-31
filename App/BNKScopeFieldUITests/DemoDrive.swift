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
    enum Beat {
        static let glance: TimeInterval = 1.6
        static let read: TimeInterval = 3.0
        static let settle: TimeInterval = 6.0
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

    func beat2ImportTenant1() throws {
        goTo("Clusters")
        dwell(Beat.read)
    }

    func beat3Overview() throws {
        goTo("Overview")
        dwell(Beat.read)
        // The DSSM pods are the story: open the first finding that leads somewhere.
        let finding = app.buttons.containing(NSPredicate(format: "label CONTAINS 'f5-dssm'")).firstMatch
        if finding.waitForExistence(timeout: 10) {
            finding.tap()
            dwell(Beat.settle)
            tap("Done")
        }
    }

    func beat4Logs() throws {
        goTo("Logs")
        dwell(Beat.settle)
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
        }
    }

    func beat6Terminal() throws {
        goTo("Terminal")
        tap("ip -s link")
        dwell(Beat.settle)
        tap("connections")
        dwell(Beat.settle)
    }

    func beat7DPUServices() throws {
        goTo("DPU Services")
        dwell(Beat.settle)
    }

    func beat8NICo() throws {
        goTo("NICo")
        dwell(Beat.settle)
    }
}
