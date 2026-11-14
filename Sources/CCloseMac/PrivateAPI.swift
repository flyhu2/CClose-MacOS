import Foundation
import ApplicationServices

// Optional window identity only. No private window-layer mutations or Dock injection.
typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
final class PrivateAPI {
    static let shared = PrivateAPI()
    let axGetWindow: AXGetWindowFn?
    private init() {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        if let handle, let pointer = dlsym(handle, "_AXUIElementGetWindow") {
            axGetWindow = unsafeBitCast(pointer, to: AXGetWindowFn.self)
        } else { axGetWindow = nil }
    }
}
