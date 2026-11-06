import Foundation

enum AppResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        #if DOTIST_PACKAGED_BUILD
        return nil
        #else
        return Bundle.module.url(forResource: name, withExtension: ext)
        #endif
    }
}
