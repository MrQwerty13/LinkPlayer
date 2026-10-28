// Placeholder so the SwiftPM manifest resolves on every platform.
// The real macOS application lives in `macOS/` and is built with Xcode
// (see README → Build). This file exists only to keep `swift build`
// of the Core target usable in CI/sandboxes without macOS.

print("LinkPlayer is a macOS application. Build it on Apple Silicon with:")
print("    open LinkPlayer.xcodeproj   (or: xcodebuild -scheme LinkPlayer ...)")
print("See README.md for details.")
