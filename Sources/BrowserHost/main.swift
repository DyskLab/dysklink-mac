// dysklink-browser-host: Firefox starts this when the DyskLink extension connects (native messaging). It reads the
// extension's messages, 4-byte length plus JSON, from standard input and hands them to the DyskLink app.
import Foundation

let maxMessage = 64 * 1024
let input = FileHandle.standardInput

while true {
    let header = input.readData(ofLength: 4)
    guard header.count == 4 else { break }
    let length = Int(header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
    guard length > 0, length <= maxMessage else { break }
    let body = input.readData(ofLength: length)
    guard body.count == length, let json = String(data: body, encoding: .utf8) else { break }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("id.dysklink.browser-media"), object: nil, userInfo: ["json": json], deliverImmediately: true
    )
}
