import AppKit
import Foundation
import IOKit

/// "Report a problem": opens WhatsApp to the developer with a short message the user can edit.
/// The message holds only the app version, macOS version, Mac model, and how many phones are connected.
/// It never holds device names, user names, addresses, pairing IDs, or paths.
@MainActor
@Observable
final class Support {
    static let shared = Support()

    /// The developer's WhatsApp number, in wa.me form (country code, no plus or spaces).
    nonisolated static let whatsappNumber = "6285117241230"
    /// The same number as people read it.
    static let whatsappNumberDisplay = "+62 851-1724-1230"

    static let reportTitle = "Report a problem"
    static let reportDetail = "Send a message on WhatsApp. It includes the app version and system so the problem is easier to find; you can edit it before sending."
    static var failureMessage: String { "Couldn't open WhatsApp. Message \(whatsappNumberDisplay) instead." }

    /// Set when opening the link failed, so the About card and the menu show the number to copy.
    var openFailed = false

    /// What the message says about this Mac.
    struct Facts: Equatable {
        var appVersion: String
        var build: String
        var osVersion: String
        var modelName: String
        var modelIdentifier: String
        var connectedPhones: Int
        /// Names that must never appear in the message, such as the Mac's name and the user's name.
        var privateNames: [String] = []
    }

    nonisolated static func message(_ facts: Facts) -> String {
        let phones = facts.connectedPhones == 1 ? "1 phone" : "\(facts.connectedPhones) phones"
        let model: String
        if facts.modelName.isEmpty || facts.modelName == facts.modelIdentifier {
            model = facts.modelIdentifier
        } else {
            model = "\(facts.modelName) (\(facts.modelIdentifier))"
        }
        let text = """
        Hi, I found a problem in DyskLink.

        What happened:

        What I expected:

        ---
        DyskLink for Mac \(facts.appVersion) (\(facts.build))
        \(facts.osVersion), \(model)
        Connected: \(phones)
        """
        return scrub(text, facts.privateNames)
    }

    /// Takes out any private name that slipped into a field, such as a model name that holds the Mac's name.
    nonisolated static func scrub(_ text: String, _ names: [String]) -> String {
        names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: "[hidden]", options: .caseInsensitive) }
    }

    /// Encodes everything but letters, digits, and `-._~`, so newlines, `&`, `#`, and `+` survive in the query.
    nonisolated static func url(message: String) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let text = message.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://wa.me/\(whatsappNumber)?text=\(text)")!
    }

    static func currentFacts(connectedPhones: Int) -> Facts {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let patch = os.patchVersion > 0 ? ".\(os.patchVersion)" : ""
        return Facts(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String ?? "dev",
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion)\(patch)",
            modelName: productName ?? "",
            modelIdentifier: LocalDevice.model,
            connectedPhones: connectedPhones,
            privateNames: [LocalDevice.name, NSUserName(), NSFullUserName()]
        )
    }

    /// The Mac's marketing name, such as "MacBook Air (15-inch, M3, 2024)", which Apple silicon Macs keep in the device tree.
    static var productName: String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func report(connectedPhones: Int) {
        let link = Self.url(message: Self.message(Self.currentFacts(connectedPhones: connectedPhones)))
        openFailed = !NSWorkspace.shared.open(link)
    }

    func copyNumber() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.whatsappNumberDisplay, forType: .string)
    }
}

extension AppModel {
    /// Phones that are paired and connected now. Only the count goes into a problem report.
    var connectedPhoneCount: Int { peers.filter { $0.isPaired && $0.isConnected && !$0.isComputer }.count }
}
