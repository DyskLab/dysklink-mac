import CryptoKit
import Foundation
import Security

/// An element of GF(2^255 - 19) in 16 signed limbs of 16 bits (the TweetNaCl layout). Only what Elligator 2 needs.
/// No branches or table lookups depend on the value, so the code doesn't leak through timing.
struct FieldElement {
    fileprivate var limbs: [Int64]

    init(limbs: [Int64]) { self.limbs = limbs }

    static let zero = FieldElement(limbs: [Int64](repeating: 0, count: 16))
    static let one = FieldElement(small: 1)

    init(small value: UInt64) {
        var limbs = [Int64](repeating: 0, count: 16)
        var rest = value
        for index in 0..<4 {
            limbs[index] = Int64(rest & 0xffff)
            rest >>= 16
        }
        self.limbs = limbs
    }

    /// RFC 7748 decoding: little-endian, bit 255 ignored. Values from p to 2^255 - 1 are fine, they reduce later.
    init(bytes: [UInt8]) {
        precondition(bytes.count == 32)
        var limbs = [Int64](repeating: 0, count: 16)
        for index in 0..<16 {
            limbs[index] = Int64(bytes[2 * index]) + (Int64(bytes[2 * index + 1]) << 8)
        }
        limbs[15] &= 0x7fff
        self.limbs = limbs
    }

    /// The canonical encoding, fully reduced mod p.
    var bytes: [UInt8] {
        var t = limbs
        Self.carry(&t)
        Self.carry(&t)
        Self.carry(&t)
        var m = [Int64](repeating: 0, count: 16)
        for _ in 0..<2 {
            m[0] = t[0] - 0xffed
            for index in 1..<15 {
                m[index] = t[index] - 0xffff - ((m[index - 1] >> 16) & 1)
                m[index - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let borrow = (m[15] >> 16) & 1
            m[14] &= 0xffff
            // No borrow: t was at least p, so keep t - p.
            Self.select(&t, m, take: 1 - borrow)
        }
        var out = [UInt8](repeating: 0, count: 32)
        for index in 0..<16 {
            out[2 * index] = UInt8(t[index] & 0xff)
            out[2 * index + 1] = UInt8((t[index] >> 8) & 0xff)
        }
        return out
    }

    private static func carry(_ o: inout [Int64]) {
        for index in 0..<16 {
            o[index] += 1 << 16
            let c = o[index] >> 16
            if index < 15 {
                o[index + 1] += c - 1
            } else {
                // 2^256 = 38 mod p.
                o[0] += 38 * (c - 1)
            }
            o[index] -= c << 16
        }
    }

    /// `target` becomes `other` when `take` is 1, and stays when it's 0, without branching on it.
    private static func select(_ target: inout [Int64], _ other: [Int64], take: Int64) {
        let mask = ~(take - 1)
        for index in 0..<16 {
            target[index] ^= mask & (target[index] ^ other[index])
        }
    }

    /// `b` when `condition`, otherwise `a`.
    static func select(_ a: FieldElement, _ b: FieldElement, _ condition: Bool) -> FieldElement {
        var result = a.limbs
        select(&result, b.limbs, take: condition ? 1 : 0)
        return FieldElement(limbs: result)
    }

    static func + (a: FieldElement, b: FieldElement) -> FieldElement {
        var out = a.limbs
        for index in 0..<16 { out[index] += b.limbs[index] }
        var result = FieldElement(limbs: out)
        result.normalize()
        return result
    }

    static func - (a: FieldElement, b: FieldElement) -> FieldElement {
        var out = a.limbs
        for index in 0..<16 { out[index] -= b.limbs[index] }
        var result = FieldElement(limbs: out)
        result.normalize()
        return result
    }

    static prefix func - (a: FieldElement) -> FieldElement { zero - a }

    static func * (a: FieldElement, b: FieldElement) -> FieldElement {
        var t = [Int64](repeating: 0, count: 31)
        for i in 0..<16 {
            for j in 0..<16 { t[i + j] += a.limbs[i] * b.limbs[j] }
        }
        // 2^256 = 38 mod p.
        for index in 0..<15 { t[index] += 38 * t[index + 16] }
        var out = Array(t[0..<16])
        carry(&out)
        carry(&out)
        return FieldElement(limbs: out)
    }

    /// Keeps the limbs small after an addition or subtraction, so chains of them can't overflow.
    private mutating func normalize() {
        Self.carry(&limbs)
        Self.carry(&limbs)
    }

    var squared: FieldElement { self * self }

    /// `self` to a public exponent, given as 32 little-endian bytes. The exponent is a constant, so the
    /// branch on its bits reveals nothing secret.
    func power(_ exponent: [UInt8]) -> FieldElement {
        var result = FieldElement.one
        for bit in stride(from: 255, through: 0, by: -1) {
            result = result.squared
            if (exponent[bit / 8] >> (bit % 8)) & 1 == 1 { result = result * self }
        }
        return result
    }

    /// p - 2 and (p - 1) / 2, little-endian.
    private static let pMinus2: [UInt8] = [0xeb] + [UInt8](repeating: 0xff, count: 30) + [0x7f]
    private static let legendreExponent: [UInt8] = [0xf6] + [UInt8](repeating: 0xff, count: 30) + [0x3f]

    /// The inverse, and 0 for 0 (inv0 in RFC 9380).
    var inverse: FieldElement { power(Self.pMinus2) }

    var isZero: Bool { Self.constantTimeEqual(bytes, [UInt8](repeating: 0, count: 32)) }

    /// Whether this is a square in the field, 0 included (is_square in RFC 9380).
    var isSquare: Bool {
        let legendre = power(Self.legendreExponent).bytes
        let zero = Self.constantTimeEqual(legendre, [UInt8](repeating: 0, count: 32))
        let one = Self.constantTimeEqual(legendre, FieldElement.one.bytes)
        return zero || one
    }

    static func == (a: FieldElement, b: FieldElement) -> Bool { constantTimeEqual(a.bytes, b.bytes) }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// CPace (draft-irtf-cfrg-cpace) with X25519, Elligator 2, and SHA-512: the "CPace255" cipher suite.
/// X25519 itself comes from CryptoKit.
enum Cpace {
    static let dsi = Array("CPace255".utf8)
    static let pointBytes = 32
    /// SHA-512's input block size.
    private static let sInBytes = 128
    private static let curveA = FieldElement(small: 486662)
    /// Elligator 2's non-square for Curve25519.
    private static let z = FieldElement(small: 2)

    /// The length in LEB128, then the bytes.
    static func prependLen(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var length = data.count
        repeat {
            out.append(length < 128 ? UInt8(length) : UInt8((length & 0x7f) | 0x80))
            length >>= 7
        } while length != 0
        return out + data
    }

    static func lvCat(_ parts: [UInt8]...) -> [UInt8] { lvCat(parts) }
    static func lvCat(_ parts: [[UInt8]]) -> [UInt8] { parts.flatMap(prependLen) }

    static func generatorString(_ dsi: [UInt8], _ prs: [UInt8], _ ci: [UInt8], _ sid: [UInt8]) -> [UInt8] {
        let zpad = max(0, sInBytes - 1 - prependLen(prs).count - prependLen(dsi).count)
        return lvCat(dsi, prs, [UInt8](repeating: 0, count: zpad), ci, sid)
    }

    /// The generator for this code, channel, and session, as a u coordinate.
    static func calculateGenerator(prs: [UInt8], ci: [UInt8], sid: [UInt8]) -> [UInt8] {
        var genStr = generatorString(dsi, prs, ci, sid)
        var hash = Array(SHA512.hash(data: genStr).prefix(pointBytes))
        let u = FieldElement(bytes: hash)
        zero(&genStr)
        zero(&hash)
        return elligator2(u).bytes
    }

    /// RFC 9380 map_to_curve_elligator2 for Curve25519 (J = 486662, K = 1, Z = 2). Only x is needed.
    static func elligator2(_ u: FieldElement) -> FieldElement {
        let denominator = FieldElement.one + z * u.squared
        var x1 = -curveA * denominator.inverse
        x1 = FieldElement.select(x1, -curveA, x1.isZero)
        // x^3 + A x^2 + x
        let gx1 = ((x1 + curveA) * x1 + .one) * x1
        let x2 = -x1 - curveA
        return FieldElement.select(x2, x1, gx1.isSquare)
    }

    /// RFC 7748 X25519. All zeros out means a low-order point, which callers must treat as failure.
    static func x25519(_ scalar: [UInt8], _ point: [UInt8]) -> [UInt8] {
        let neutral = [UInt8](repeating: 0, count: pointBytes)
        guard scalar.count == pointBytes, point.count == pointBytes,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point),
              let shared = try? key.sharedSecretFromKeyAgreement(with: peer) else { return neutral }
        return shared.withUnsafeBytes { Array($0) }
    }

    static func isIdentity(_ point: [UInt8]) -> Bool { point.reduce(0) { $0 | $1 } == 0 }

    static func transcriptIr(_ ya: [UInt8], _ adA: [UInt8], _ yb: [UInt8], _ adB: [UInt8]) -> [UInt8] {
        lvCat(ya, adA) + lvCat(yb, adB)
    }

    /// ISK = SHA-512(lv_cat(DSI || "_ISK", sid, K) || transcript_ir(Ya, ADa, Yb, ADb)).
    static func isk(sid: [UInt8], k: [UInt8], ya: [UInt8], adA: [UInt8], yb: [UInt8], adB: [UInt8]) -> [UInt8] {
        var input = lvCat(dsi + Array("_ISK".utf8), sid, k) + transcriptIr(ya, adA, yb, adB)
        defer { zero(&input) }
        return Array(SHA512.hash(data: input))
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "No secure random bytes")
        return bytes
    }

    static func zero(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
    }
}

/// Pairing version 3 (CPace) in `pair.request`, `pair.pake`, and `pair.accept`. `v` is the PAKE version, 1.
/// Base64 fields: `nonce` (16 bytes), `y` (a 32-byte X25519 point), and `confirm` (32 bytes).
struct PakeMessage: Codable, Equatable, Sendable {
    var v: Int
    var nonce: String? = nil
    var y: String? = nil
    var confirm: String? = nil
}

/// Pairing version 3: CPace on the typed code, bound to both TLS certificates. T types the code and sent
/// `pair.request`, S shows it. S is CPace's A (sends Ya first), T is B. ADa and ADb are empty.
enum Pake {
    static let version = 1
    static let nonceBytes = 16
    static let confirmBytes = 32
    private static let channelLabel = Array("dysklink-pair-v3".utf8)
    private static let confirmTLabel = Array("dysklink-confirm-T".utf8)
    private static let confirmSLabel = Array("dysklink-confirm-S".utf8)

    /// CI from the fingerprints (lowercase hex, as device IDs are) each side sees on this connection.
    static func channel(typing: String, showing: String) -> [UInt8] {
        Cpace.lvCat(channelLabel, Array(typing.utf8), Array(showing.utf8))
    }

    static func confirm(_ isk: [UInt8], _ label: [UInt8]) -> [UInt8] {
        let code = HMAC<SHA512>.authenticationCode(for: label, using: SymmetricKey(data: isk))
        return Array(Array(code).prefix(confirmBytes))
    }

    static func confirmT(_ isk: [UInt8]) -> [UInt8] { confirm(isk, confirmTLabel) }
    static func confirmS(_ isk: [UInt8]) -> [UInt8] { confirm(isk, confirmSLabel) }

    static func encode(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    /// Nil unless it's base64 of exactly `length` bytes.
    static func decode(_ text: String?, _ length: Int) -> [UInt8]? {
        guard let text, let data = Data(base64Encoded: text), data.count == length else { return nil }
        return Array(data)
    }

    /// What `pair.request` must carry; anything else is an older app.
    static func requestNonce(_ pake: PakeMessage?) -> [UInt8]? {
        guard let pake, pake.v == version else { return nil }
        return decode(pake.nonce, nonceBytes)
    }

    /// The showing side. Keeps ya and Ya for as long as its code shows, so the same code can be typed again.
    final class Shower {
        let nonceS: [UInt8]
        let yaPublic: [UInt8]
        private let nonceT: [UInt8]
        private let sid: [UInt8]
        private var ya: [UInt8]

        init(code: String, nonceT: [UInt8], ci: [UInt8], nonceS: [UInt8] = Cpace.randomBytes(Pake.nonceBytes),
             ya: [UInt8] = Cpace.randomBytes(Cpace.pointBytes)) {
            self.nonceT = nonceT
            self.nonceS = nonceS
            self.ya = ya
            sid = nonceT + nonceS
            var g = Cpace.calculateGenerator(prs: Array(code.utf8), ci: ci, sid: sid)
            yaPublic = Cpace.x25519(ya, g)
            Cpace.zero(&g)
        }

        deinit { Cpace.zero(&ya) }

        func sameRequest(_ nonce: [UInt8]) -> Bool { FieldElement.constantTimeEqual(nonce, nonceT) }

        /// `pair.pake`: nonceS and Ya.
        var message: PakeMessage { PakeMessage(v: Pake.version, nonce: Pake.encode(nonceS), y: Pake.encode(yaPublic)) }

        /// Checks T's `pair.accept`. The reply to send when confirmT is right, nil for a wrong code or bad point.
        func check(_ accept: PakeMessage) -> PakeMessage? {
            guard accept.v == Pake.version, let yb = Pake.decode(accept.y, Cpace.pointBytes),
                  let confirm = Pake.decode(accept.confirm, Pake.confirmBytes) else { return nil }
            var k = Cpace.x25519(ya, yb)
            guard !Cpace.isIdentity(k) else { return nil }
            var isk = Cpace.isk(sid: sid, k: k, ya: yaPublic, adA: [], yb: yb, adB: [])
            Cpace.zero(&k)
            defer { Cpace.zero(&isk) }
            guard FieldElement.constantTimeEqual(Pake.confirmT(isk), confirm) else { return nil }
            return PakeMessage(v: Pake.version, confirm: Pake.encode(Pake.confirmS(isk)))
        }
    }

    /// The typing side. A fresh yb for every code typed.
    final class Typer {
        let nonceT: [UInt8]
        private var nonceS: [UInt8]?
        private var ya: [UInt8]?
        private var expectedConfirm: [UInt8]?

        init(nonceT: [UInt8] = Cpace.randomBytes(Pake.nonceBytes)) { self.nonceT = nonceT }

        deinit { wrongCode() }

        /// For `pair.request`.
        var request: PakeMessage { PakeMessage(v: Pake.version, nonce: Pake.encode(nonceT)) }

        var ready: Bool { ya != nil }

        /// Takes S's `pair.pake`. False if it isn't valid.
        func received(_ pake: PakeMessage?) -> Bool {
            guard let pake, pake.v == Pake.version, let nonce = Pake.decode(pake.nonce, Pake.nonceBytes),
                  let point = Pake.decode(pake.y, Cpace.pointBytes) else { return false }
            nonceS = nonce
            ya = point
            wrongCode()
            return true
        }

        /// The `pair.accept` for this code, or nil when S's Ya is missing or a low-order point.
        func answer(code: String, ci: [UInt8], yb: [UInt8] = Cpace.randomBytes(Cpace.pointBytes)) -> PakeMessage? {
            guard let nonceS, let ya else { return nil }
            var secret = yb
            defer { Cpace.zero(&secret) }
            let sid = nonceT + nonceS
            var g = Cpace.calculateGenerator(prs: Array(code.utf8), ci: ci, sid: sid)
            let ybPublic = Cpace.x25519(secret, g)
            Cpace.zero(&g)
            var k = Cpace.x25519(secret, ya)
            guard !Cpace.isIdentity(k) else { return nil }
            var isk = Cpace.isk(sid: sid, k: k, ya: ya, adA: [], yb: ybPublic, adB: [])
            Cpace.zero(&k)
            defer { Cpace.zero(&isk) }
            wrongCode()
            expectedConfirm = Pake.confirmS(isk)
            return PakeMessage(v: Pake.version, y: Pake.encode(ybPublic), confirm: Pake.encode(Pake.confirmT(isk)))
        }

        /// True only for S's `pair.accept` with the right confirmS for the last code sent.
        func confirms(_ accept: PakeMessage?) -> Bool {
            guard let expectedConfirm, let accept, accept.v == Pake.version,
                  let confirm = Pake.decode(accept.confirm, Pake.confirmBytes) else { return false }
            return FieldElement.constantTimeEqual(expectedConfirm, confirm)
        }

        /// A wrong code: the next try starts again.
        func wrongCode() {
            if var old = expectedConfirm { Cpace.zero(&old) }
            expectedConfirm = nil
        }
    }
}
