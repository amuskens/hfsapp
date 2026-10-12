import Foundation

extension Bundle {
    /// The bundle holding the app's processed resources (icons, help text).
    ///
    /// SwiftPM's generated `Bundle.module` only looks for `FloppyFox_FloppyFox.bundle` at the
    /// top level of the .app (next to `Contents/`) and calls `fatalError` otherwise — but
    /// anything at the bundle root makes `codesign` fail with "unsealed contents present in
    /// the bundle root", so a release built that way can be neither notarized nor submitted to
    /// the App Store. The packaged app keeps the bundle in `Contents/Resources` instead;
    /// `swift run` and `swift test` fall back to `Bundle.module`, which finds the build folder.
    static let floppyFoxResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("FloppyFox_FloppyFox.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
