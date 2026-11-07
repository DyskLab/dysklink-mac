import Foundation
import Security

/// This Mac's self-signed certificate. Stored as PKCS#12 in Application Support
/// and loaded into memory only, so the app doesn't trigger Keychain dialogs.
struct LocalIdentity {
    let identity: SecIdentity
    let deviceId: String

    enum Failure: LocalizedError {
        case openssl(String)
        case importFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .openssl(let detail): return "Failed to create the certificate: \(detail)"
            case .importFailed(let status): return "Failed to load the certificate (code \(status))"
            }
        }
    }

    static func loadOrCreate(in directory: URL) throws -> LocalIdentity {
        let p12URL = directory.appendingPathComponent("identity.p12")
        let passwordURL = directory.appendingPathComponent("identity.key")
        if !FileManager.default.fileExists(atPath: p12URL.path) {
            try create(p12URL: p12URL, passwordURL: passwordURL)
        }
        let password = try String(contentsOf: passwordURL, encoding: .utf8)
        return try load(p12: Data(contentsOf: p12URL), password: password)
    }

    private static func load(p12: Data, password: String) throws -> LocalIdentity {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String]
        else { throw Failure.importFailed(status) }

        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else {
            throw Failure.importFailed(certificateStatus)
        }
        let der = SecCertificateCopyData(certificate) as Data
        return LocalIdentity(identity: identity, deviceId: Hex.sha256(der))
    }

    private static func create(p12URL: URL, passwordURL: URL) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("phonelink-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }

        let key = temp.appendingPathComponent("key.pem").path
        let cert = temp.appendingPathComponent("cert.pem").path
        let password = UUID().uuidString + UUID().uuidString

        // Must use a named curve. SecPKCS12Import can't read keys from `req -newkey ec`.
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key])
        try openssl(["req", "-x509", "-new", "-key", key, "-nodes", "-out", cert, "-days", "7300",
                     "-sha256", "-subj", "/CN=PhoneLink"])
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-name", "PhoneLink",
                     "-out", p12URL.path, "-passout", "pass:\(password)"])

        try password.write(to: passwordURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.openssl(detail)
        }
    }
}
