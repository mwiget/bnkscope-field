// Print the CGWindowID of an app's main window, so screencapture can be pointed
// at the window rather than the display.
//
// Recording the display films whatever else is on it — another app, a
// notification, the operator's own terminal. -l<windowid> films one window and
// nothing else, but nothing on the command line reports that id.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "bnkscope Field"
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("cannot list windows\n".utf8))
    exit(2)
}
// Largest window belonging to the app: SwiftUI apps also own small offscreen
// helper windows, and the biggest on-screen one is the document window.
let mine = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }
    .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    .max { a, b in
        func area(_ w: [String: Any]) -> Double {
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double
            else { return 0 }
            return width * height
        }
        return area(a) < area(b)
    }
guard let window = mine, let id = window[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write(Data("no on-screen window for \"\(owner)\"\n".utf8))
    exit(1)
}
// "id x y width height", in points with a top-left origin. The recorder needs
// the rectangle as well as the id: a sheet — the file-open panel is one — is a
// child window, which -l<windowid> excludes, so those beats are filmed from the
// display and cropped to this rectangle instead.
guard let b = window[kCGWindowBounds as String] as? [String: Any],
      let x = b["X"] as? Double, let y = b["Y"] as? Double,
      let w = b["Width"] as? Double, let h = b["Height"] as? Double else {
    FileHandle.standardError.write(Data("window \(id) has no bounds\n".utf8))
    exit(1)
}
print("\(id) \(Int(x)) \(Int(y)) \(Int(w)) \(Int(h))")
