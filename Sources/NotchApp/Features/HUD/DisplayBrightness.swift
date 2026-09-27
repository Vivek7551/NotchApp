import CoreGraphics
import Foundation

/// Reads and sets the built-in display's brightness.
///
/// There's no public API for this on Apple Silicon Macs, so we load Apple's
/// private DisplayServices framework at runtime (fine for personal use; an
/// App Store app couldn't do this).
@MainActor
enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFunction = framework
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setFunction = framework
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFunction.self) }

    /// The laptop's own screen, if it's on (not in clamshell mode).
    static var builtInDisplay: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 0...1
    static func brightness() -> Float? {
        guard let display = builtInDisplay, let getFunction else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    static func setBrightness(_ value: Float) {
        guard let display = builtInDisplay, let setFunction else { return }
        _ = setFunction(display, min(max(value, 0), 1))
    }
}
