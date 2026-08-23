import Foundation

/// Locates bundled resources.
///
/// A packaged Zharp.app carries them in `Contents/Resources`, the conventional
/// macOS layout - which also keeps `codesign --deep` happy, since a SwiftPM
/// `.bundle` directory has no Info.plist and is rejected as a malformed nested
/// bundle. Running straight from `swift run` has no app bundle, so the module
/// bundle is the fallback.
enum Resources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }
}
