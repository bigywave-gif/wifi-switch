import Foundation
import Security

// Only the packaging key is imported. Passwords and private keys never enter
// command-line arguments or output; the caller removes the temporary files.
func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "SigningImport", code: 1)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let passphrase = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        .trimmingCharacters(in: .newlines)
    var keychain: SecKeychain?
    try check(SecKeychainOpen(CommandLine.arguments[3], &keychain))
    guard let keychain else { throw NSError(domain: "SigningImport", code: 2) }
    var trustedTool: SecTrustedApplication?
    try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trustedTool))
    guard let trustedTool else { throw NSError(domain: "SigningImport", code: 3) }
    var access: SecAccess?
    try check(SecAccessCreate("WiFi Switch Local Signing" as CFString,
                             [trustedTool] as CFArray, &access))
    guard let access else { throw NSError(domain: "SigningImport", code: 4) }
    let options: [String: Any] = [
        kSecImportExportPassphrase as String: passphrase,
        kSecImportExportKeychain as String: keychain,
        kSecImportExportAccess as String: access
    ]
    var items: CFArray?
    try check(SecPKCS12Import(data as CFData, options as CFDictionary, &items))
    print("Imported packaging identity; private-key access restricted to codesign.")
} catch {
    // Do not print input data or passphrases even when import fails.
    fputs("Signing identity import failed (\((error as NSError).code)).\n", stderr)
    exit(1)
}
