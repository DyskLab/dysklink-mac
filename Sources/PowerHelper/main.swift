// dysklink-power: the only part of DyskLink that runs as root. It can read a few battery keys from the SMC and switch
// the charger input off and on (the CHIE key). Nothing else can be written, so a sudo rule for it can't do more.
import Foundation
import IOKit
import PowerKit

// MARK: Commands

/// Below this the charger always comes back, whatever DyskLink asked for.
let guardLowPercent = 10

let dyskLinkBundleId = "id.dysklink.mac"

/// True when a running process is exactly DyskLink's executable: `<something>.app/Contents/MacOS/DyskLink` inside a
/// bundle whose Info.plist names DyskLink's bundle ID and executable. A process that merely has the words in its
/// arguments doesn't count. When processes can't be listed at all, the charger is put back, which is the safe side.
func isDyskLinkRunning() -> Bool {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return false }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = pids.withUnsafeMutableBufferPointer { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
    }
    guard filled > 0 else { return false }
    var checked = Set<String>()
    for pid in pids.prefix(Int(filled)) where pid > 0 {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
        let path = String(cString: buffer)
        guard path.hasSuffix(".app/Contents/MacOS/DyskLink"), checked.insert(path).inserted else { continue }
        if isDyskLinkExecutable(path) { return true }
    }
    return false
}

func isDyskLinkExecutable(_ path: String) -> Bool {
    let executable = URL(fileURLWithPath: path)
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents", executable.deletingLastPathComponent().lastPathComponent == "MacOS",
          let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] else { return false }
    return info["CFBundleIdentifier"] as? String == dyskLinkBundleId && info["CFBundleExecutable"] as? String == executable.lastPathComponent
}

func usage() -> Never {
    print("""
    usage: dysklink-power status          battery state and charger input, as JSON
           dysklink-power adapter on|off  turn the charger input on or off (root)
           dysklink-power test            charger off for 10 seconds, then back on (root)
           dysklink-power guard           turn the charger back on if DyskLink isn't running or the battery is low (root)
           dysklink-power lowpower never|battery|adapter|always   when macOS's Low Power Mode is on (root)
    """)
    exit(2)
}

guard SMC.open() else { print("{\"error\":\"can't open the SMC\"}"); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "status":
    let adapter = Adapter.isOff.map { $0 ? "\"off\"" : "\"on\"" } ?? "null"
    print("{\"battery\":\(Battery.now().json),\"adapter\":\(adapter),\"chieAvailable\":\(Adapter.isAvailable)}")

case "adapter":
    guard args.count == 2, ["on", "off"].contains(args[1]) else { usage() }
    if let error = Adapter.set(enabled: args[1] == "on") { print("{\"error\":\"\(error)\"}"); exit(1) }
    print("{\"adapter\":\"\(args[1])\"}")

case "test":
    // Whatever happens, the charger comes back on.
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig) { _ in _ = Adapter.set(enabled: true); _exit(130) }
    }
    let before = Battery.now()
    print("before:  \(before.json)")
    guard before.onAC else { print("Plug in the charger first."); exit(1) }
    if let error = Adapter.set(enabled: false) { print("could not turn the charger off: \(error)"); exit(1) }
    print("charger input off, waiting 10 seconds…")
    var during = before
    for _ in 0..<10 {
        Thread.sleep(forTimeInterval: 1)
        during = Battery.now()
        print("  \(during.json)")
    }
    let restore = Adapter.set(enabled: true)
    Thread.sleep(forTimeInterval: 3)
    let after = Battery.now()
    print("after:   \(after.json)  restore=\(restore ?? "ok") CHIE=\(SMC.read("CHIE")?.first.map { String(format: "%02x", $0) } ?? "?")")
    // The current reading lags by several seconds, so what counts is that macOS saw the charger go away.
    let worked = !during.onAC && !during.charging
    print(worked ? "RESULT: works. The Mac ran on battery with the charger plugged in."
                 : "RESULT: no effect. The firmware ignores CHIE on this Mac.")
    exit(worked ? 0 : 3)

case "lowpower":
    // Only these four choices, so the sudo rule can't be used to change any other power setting.
    let modes = ["never": ("0", "0"), "battery": ("1", "0"), "adapter": ("0", "1"), "always": ("1", "1")]
    guard args.count == 2, let (battery, adapter) = modes[args[1]] else { usage() }
    for (flag, value) in [("-b", battery), ("-c", adapter)] {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = [flag, "lowpowermode", value]
        try? pmset.run()
        pmset.waitUntilExit()
        guard pmset.terminationStatus == 0 else { print("{\"error\":\"pmset failed\"}"); exit(1) }
    }
    print("{\"lowpower\":\"\(args[1])\"}")

case "guard":
    // Run by launchd every minute. DyskLink turns the charger off on purpose, but nothing else should leave it off.
    guard Adapter.isOff == true else { exit(0) }
    let battery = Battery.now()
    let appRunning = isDyskLinkRunning()
    if battery.percent <= guardLowPercent || !appRunning {
        let error = Adapter.set(enabled: true)
        print("guard: charger back on (battery \(battery.percent)%, app running \(appRunning)) \(error ?? "ok")")
    }

default:
    usage()
}
