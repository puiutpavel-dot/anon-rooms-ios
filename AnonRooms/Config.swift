import Foundation

/// Completează valorile înainte de primul build.
enum Config {
    /// Supabase → Project Settings → API → Project URL
    static let supabaseURL = "https://gzauitpswsxdqsewhcgf.supabase.co"
    /// Supabase → Project Settings → API Keys → cheia publică (anon / publishable)
    static let supabaseKey = "sb_publishable_LmDOIJSQTfXz1lSbefxt_w_5O8bUp3y"
    /// Adresa afișată în aplicație la „Contact” (cerută de Apple pentru aplicații cu chat)
    static let contactEmail = "puiutpavel@gmail.com"

    /// Cheile regulilor; textele sunt în Localizable.strings, pentru fiecare limbă.
    static let rules = ["rule.1", "rule.2", "rule.3", "rule.4", "rule.5"]
}

/// Text tradus în limba telefonului. Cheile sunt în <limba>.lproj/Localizable.strings.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// Limba în care rulează aplicația (una dintre cele 8), ex. „en”, „ro”, „ar”.
var appLanguage: String {
    String((Bundle.main.preferredLocalizations.first ?? "en").prefix(2)).lowercased()
}
