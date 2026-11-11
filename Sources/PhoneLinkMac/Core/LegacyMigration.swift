import Foundation

/// The bundle ID changed from `id.phonelink.mac` to `id.dysklink.mac` in 0.2.0.
/// Settings saved under the old ID are copied over once, so tools and notch keep their setup.
/// Pairings, keys, and Clipboard History live in Application Support/PhoneLink and don't move.
enum LegacyMigration {
    static let oldBundleID = "id.phonelink.mac"
    private static let doneKey = "migratedFromPhoneLink"

    static func run(defaults: UserDefaults = .standard) {
        guard let bundle = Bundle.main.bundleIdentifier, bundle != oldBundleID,
              !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
