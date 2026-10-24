import Foundation

nonisolated func loc(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

nonisolated func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: loc(key), locale: Locale.current, arguments: args)
}
