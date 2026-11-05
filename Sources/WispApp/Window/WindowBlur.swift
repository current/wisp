import AppKit

/// Blurs whatever is behind the window's clear areas, with a radius the system materials
/// don't offer. This is the window server's own background blur, reached through
/// CGSSetWindowBackgroundBlurRadius, the private call terminal apps use for blurred
/// transparent windows. When the call is missing, `available` is false and the sidebar
/// falls back to a system material.
@MainActor
enum WindowBlur {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let functions: (MainConnection, SetRadius)? = {
        let handle = dlopen(nil, RTLD_NOW)
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let radius = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(radius, to: SetRadius.self))
    }()

    static var available: Bool { functions != nil }

    /// Applies the blur; the window must have been ordered in so it has a window number.
    @discardableResult
    static func apply(_ radius: Int, to window: NSWindow) -> Bool {
        guard let (connection, setRadius) = functions, window.windowNumber > 0 else { return false }
        return setRadius(connection(), Int32(window.windowNumber), Int32(radius)) == 0
    }
}
