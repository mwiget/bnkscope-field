import SwiftUI

extension View {
    /// The Mac has no autocapitalisation to switch off.
    func noAutocaps() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// The app draws its own chrome. On iPadOS that means hiding the navigation
    /// bar; on macOS there is no navigation bar to hide, and the window's own
    /// title bar is dealt with by the scene.
    func noNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}
