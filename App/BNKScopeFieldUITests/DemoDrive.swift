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
        // The Mac has no device orientation to set; its window geometry comes
        // from the recorder instead.
        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app = XCUIApplication()
        // Attach to an app that is already up rather than relaunching it.
        //
        // The recorder films one window by its CGWindowID, which it can only
        // look up once that window exists — so the app is launched, positioned
        // and measured before recording starts. A launch() here would replace
        // that window with a new one and the take would film an id that no
        // longer exists.
        if app.state == .runningForeground || app.state == .runningBackground {
            app.activate()
        } else {
            app.launch()
        }
        dwell(1.5)
        // macOS gives the first click on an inactive window to activation and
        // does not pass it through. Without a throwaway click here the first
        // real one of every beat is silently lost — which looks exactly like a
        // driver that found the wrong element.
        let warmUp = app.buttons["Overview"]
        if warmUp.waitForExistence(timeout: 20) { press(warmUp) }
        dwell(0.6)
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
        // .firstMatch, because a label is not unique: the Clusters screen
        // offers "Import kubeconfig" both in its toolbar and in the middle of
        // its empty state, and an ambiguous query throws rather than picking.
        let element = (query ?? app.buttons)[label].firstMatch
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("never found \"\(label)\"", file: file, line: line)
            return false
        }
        press(element)
        return true
    }

    /// The platforms disagree about the verb. `tap()` exists on macOS and
    /// compiles, but does nothing — which is worse than not existing: the
    /// element is found, no failure is raised, and the take films an app that
    /// never moved. The whole first cut of the Mac beats was lost to it.
    func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    func dwell(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func goTo(_ section: String) {
        tap(section)
        dwell(Beat.glance)
    }

    /// Not a beat: prints the element tree, which is the only reliable way to
    /// learn what a SwiftUI view is on the other platform. Sidebar rows are
    /// buttons on iPadOS and something else on macOS.
    func dumpTree() throws {
        dwell(3.0)
        print("===TREE-START===")
        print(app.debugDescription)
        print("===TREE-END===")
    }

    // MARK: - Helpers for the Mac cut

    /// Click a row in the cluster sidebar by the context name it shows.
    ///
    /// The row is a Button whose label is the whole card run together —
    /// "dpu-cplane-tenant1, 192.168.68.200 · v1.34.0, BNK, DPU" — so it is
    /// matched on its prefix. Looking for a StaticText of the bare name finds
    /// nothing, silently leaves whatever cluster was selected last, and films
    /// the right screen on the wrong cluster.
    func selectCluster(_ name: String) {
        let row = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        guard row.waitForExistence(timeout: 30) else {
            XCTFail("no cluster row starting \"\(name)\"")
            return
        }
        press(row)
        dwell(Beat.glance)
    }

    /// Switch the Terminal's container picker.
    ///
    /// There are two menus on that row — the pod and the container — and they
    /// are MenuButtons, not popUpButtons. Taking the first match picks the pod,
    /// which changes nothing visible and leaves the debug tools on screen. This
    /// one is found by the container it currently shows.
    func pickContainer(from current: String, startingWith prefix: String) {
        let picker = app.menuButtons
            .matching(NSPredicate(format: "title == %@", current)).firstMatch
        guard picker.waitForExistence(timeout: 20) else {
            XCTFail("no container picker showing \"\(current)\"")
            return
        }
        press(picker)
        dwell(1.0)
        let item = app.menuItems
            .matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        guard item.waitForExistence(timeout: 10) else {
            XCTFail("no container starting \"\(prefix)\"")
            return
        }
        press(item)
        dwell(Beat.glance)
    }

    // MARK: - Beats

    /// The app with nothing in it, before the import.
    func beat1Empty() throws {
        dwell(16.0)
    }

    /// The import, end to end.
    ///
    /// On the Mac this is fully filmable, which it was not on the iPad: an
    /// unsandboxed app runs NSOpenPanel in its own process, so the open dialog
    /// is one of the app's own windows and the driver can type into it. Go-to-
    /// folder takes the path directly rather than clicking through a file tree
    /// that looks like nothing in particular on camera.
    func beat2Import() throws {
        goTo("Clusters")
        dwell(Beat.read)
        tap("Import kubeconfig")
        dwell(2.5)
        // The panel opens on the home directory, where the file is, so this is a
        // click rather than a typed path — and a viewer can see which file is
        // being chosen, which a ⇧⌘G path they never see cannot show.
        let sheet = app.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 20) else {
            XCTFail("the open panel never appeared")
            return
        }
        let file = sheet.textFields
            .matching(NSPredicate(format: "value == %@", "config-multi.txt")).firstMatch
        guard file.waitForExistence(timeout: 10) else {
            XCTFail("config-multi.txt is not in the panel's list")
            return
        }
        press(file)
        dwell(1.5)
        let open = sheet.buttons["Open"]
        if open.exists { press(open) } else { app.typeKey(.return, modifierFlags: []) }
        // Three contexts read, three keys into the keychain, three probes. The
        // beat is the rows appearing and going green.
        dwell(24.0)
    }

    /// Three clusters, probed. Health is the point, so it rests on the list.
    func beat3Clusters() throws {
        goTo("Clusters")
        dwell(24.0)
    }

    /// What the clusters actually are: Overview ranks what is wrong, Resources
    /// is the read-only browser.
    func beat4Explore() throws {
        selectCluster("dpu-cplane-tenant1")
        goTo("Overview")
        dwell(20.0)
        goTo("Resources")
        dwell(16.0)
    }

    /// Installing the exporter, and the charts it feeds.
    ///
    /// Written to work whether or not the exporter is already in: with it
    /// missing this films the install, with it present the charts. The install
    /// is the slow half — the image has to be pulled — and that wait is what
    /// gets cut.
    func beat5TMMLive() throws {
        selectCluster("dpu-cplane-tenant1")
        goTo("TMM Live")
        dwell(Beat.read)
        if app.buttons["Add the exporter"].waitForExistence(timeout: 6) {
            press(app.buttons["Add the exporter"])
            dwell(50.0)
            if app.buttons["Done"].exists { press(app.buttons["Done"]) }
        }
        dwell(26.0)
    }

    /// A command in the debug container.
    func beat6TerminalDebug() throws {
        selectCluster("dpu-cplane-tenant1")
        goTo("Terminal")
        dwell(Beat.read)
        tap("connections")
        dwell(8.0)
        tap("interfaces")
        dwell(Beat.hold6)
    }

    /// The routing container, and BGP from ZebOS's own shell.
    func beat7TerminalRouting() throws {
        selectCluster("dpu-cplane-tenant1")
        goTo("Terminal")
        dwell(Beat.read)
        pickContainer(from: "debug", startingWith: "f5-tmm-routing")
        dwell(2.0)
        tap("bgp summary")
        dwell(14.0)
        tap("routes")
        dwell(12.0)
    }

    /// Logs, then the same logs filtered.
    func beat8Logs() throws {
        selectCluster("dpu-cplane-tenant1")
        goTo("Logs")
        dwell(12.0)
        let search = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch : app.textFields["Search"]
        if search.waitForExistence(timeout: 10) {
            press(search)
            app.typeText("bgp")
            dwell(14.0)
        } else {
            XCTFail("no log search field")
        }
    }

    /// The closing shot: back to the cluster list, all three in.
    func beat9Close() throws {
        goTo("Clusters")
        dwell(Beat.settle)
    }
}
