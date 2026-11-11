#if DEBUG
import Foundation

/// CPace255 against draft-irtf-cfrg-cpace-21 Appendix B.1, the field math under Elligator 2, and pairing version 3.
@MainActor
enum CpaceSelfTest {
    private static func hex(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Shared with CpaceTest.matchesTheMacImplementation in the Kotlin core, and a Python reference.
    static let crossG = "596bf2b3635255f8ddad24bcca56d5466c83731d14569819aa6c55757f612937"
    static let crossYa = "8c989051b56d84665212c5560f098d75bc34f4a6ae2b9f6cf234c867ddc4884a"
    static let crossYb = "f13ef81a083b9ac532e99f3d6b4f3ffd3066b569b583f14fd2ddeceb8acd9a58"
    static let crossK = "54d8ecaaafded0a9aac8db60d07cd9e1fc04a3985fbe96abc8b82af420f2ef59"
    static let crossIsk = "823079120c1016676b1861386fb7a0946f212de3f515773cc16c326690c368d4"
        + "75fb4c887ec5536518b2e453b44120febc634298df19b5200f5fd7fbce990c5e"
    static let crossConfirmT = "1ef6ce4bac0cc89dade05defb21f9327de2966f9d1dcf42f6e7c9e96223d6a7c"
    static let crossConfirmS = "98e16d6a01ecef6c8cb0a650ca813027d4d405bc23b0af5a1b2efdf541a3b39f"

    static func run(_ check: (String, Bool) -> Void) {
        // String functions.
        check("cpace prepend_len", hex(Cpace.prependLen([])) == "00" && hex(Cpace.prependLen(Array("1234".utf8))) == "0431323334"
            && hex(Array(Cpace.prependLen((0..<127).map { UInt8($0) }).prefix(1))) == "7f"
            && hex(Array(Cpace.prependLen((0..<128).map { UInt8($0) }).prefix(2))) == "8001")
        check("cpace lv_cat", hex(Cpace.lvCat(Array("1234".utf8), Array("5".utf8), [], Array("678".utf8))) == "043132333401350003363738")
        check("cpace transcript_ir", hex(Cpace.transcriptIr(Array("123".utf8), Array("PartyA".utf8), Array("234".utf8), Array("PartyB".utf8)))
            == "03313233065061727479410332333406506172747942")

        // Field arithmetic.
        let p = FieldElement(bytes: [0xed] + [UInt8](repeating: 0xff, count: 30) + [0x7f])
        check("field: p reduces to 0", p.isZero && (p + .one) == .one)
        let x = FieldElement(bytes: hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"))
        let y = FieldElement(bytes: hex("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221170"))
        check("field: inverse", (x * x.inverse) == .one && (y * y.inverse) == .one && FieldElement.zero.inverse.isZero)
        check("field: add and subtract", ((x + y) - y) == x && (x - x).isZero && (-x + x).isZero)
        check("field: multiply commutes and distributes", (x * y) == (y * x) && (x * (y + .one)) == (x * y + x))
        check("field: squares", !FieldElement(small: 2).isSquare && FieldElement(small: 4).isSquare
            && (-FieldElement.one).isSquare && FieldElement.zero.isSquare && x.squared.isSquare)
        check("field: p-1 is -1", hex((-FieldElement.one).bytes) == "ec" + String(repeating: "ff", count: 30) + "7f")
        check("field: bit 255 ignored", FieldElement(bytes: x.bytes.enumerated().map { $0.offset == 31 ? $0.element | 0x80 : $0.element }) == x)
        // (2^255 - 1) mod p = 18.
        check("field: high values reduce", FieldElement(bytes: [UInt8](repeating: 0xff, count: 32)) == FieldElement(small: 18))
        let a = FieldElement(small: 486662)
        var onCurve = true
        for _ in 0..<40 {
            let u = FieldElement(bytes: Cpace.randomBytes(32))
            let m = Cpace.elligator2(u)
            onCurve = onCurve && (m * m * m + a * m * m + m).isSquare
        }
        check("elligator2 lands on the curve", onCurve)

        // Draft test vectors.
        let ci = hex("0b415f696e69746961746f720b425f726573706f6e646572")
        let sid = hex("7e4b4791d6a8ef019b936c79fb7f2c57")
        let genStr = Cpace.generatorString(Cpace.dsi, Array("Password".utf8), ci, sid)
        check("cpace generator_string", genStr.count == 170 && hex(Array(genStr.prefix(19))) == "0843506163653235350850617373776f72646d")
        let g = Cpace.calculateGenerator(prs: Array("Password".utf8), ci: ci, sid: sid)
        check("cpace generator", hex(g) == "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f")
        let ya = hex("21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080")
        let yb = hex("848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a")
        let bigYa = Cpace.x25519(ya, g), bigYb = Cpace.x25519(yb, g)
        check("cpace Ya", hex(bigYa) == "1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32")
        check("cpace Yb", hex(bigYb) == "248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623")
        let k = Cpace.x25519(ya, bigYb)
        check("cpace K", k == Cpace.x25519(yb, bigYa) && hex(k) == "5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b")
        check("cpace ISK", hex(Cpace.isk(sid: sid, k: k, ya: bigYa, adA: Array("ADa".utf8), yb: bigYb, adB: Array("ADb".utf8)))
            == "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263")

        // Low-order points and bit 255.
        let s = hex("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")
        let lowOrder: [(String, String?)] = [
            ("0000000000000000000000000000000000000000000000000000000000000000", nil),
            ("0100000000000000000000000000000000000000000000000000000000000000", nil),
            ("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", nil),
            ("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", nil),
            ("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
            ("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", nil),
            ("dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
            ("d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
            ("cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880", "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
            ("4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7", "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"),
        ]
        for (index, (u, q)) in lowOrder.enumerated() {
            let out = Cpace.x25519(s, hex(u))
            check("cpace low-order u\(index)", q.map { hex(out) == $0 } ?? Cpace.isIdentity(out))
        }

        // The same transcript as the Kotlin core.
        let nonceT = (0..<16).map { UInt8($0) }, nonceS = (16..<32).map { UInt8($0) }
        let fixedYa = (32..<64).map { UInt8($0) }, fixedYb = (64..<96).map { UInt8($0) }
        let channel = Pake.channel(typing: String(repeating: "ab", count: 32), showing: String(repeating: "cd", count: 32))
        let crossGenerator = Cpace.calculateGenerator(prs: Array("123456".utf8), ci: channel, sid: nonceT + nonceS)
        check("cpace cross generator", hex(crossGenerator) == crossG)
        let crossShared = Cpace.x25519(fixedYa, Cpace.x25519(fixedYb, crossGenerator))
        check("cpace cross K", hex(crossShared) == crossK)
        check("cpace cross ISK", hex(Cpace.isk(sid: nonceT + nonceS, k: crossShared, ya: hex(crossYa), adA: [], yb: hex(crossYb), adB: [])) == crossIsk)
        let shower = Pake.Shower(code: "123456", nonceT: nonceT, ci: channel, nonceS: nonceS, ya: fixedYa)
        let typer = Pake.Typer(nonceT: nonceT)
        let accept = typer.received(shower.message) ? typer.answer(code: "123456", ci: channel, yb: fixedYb) : nil
        let reply = accept.flatMap(shower.check)
        check("cpace cross transcript", hex(shower.yaPublic) == crossYa && accept.flatMap { Pake.decode($0.y, 32) }.map(hex) == crossYb
            && accept.flatMap { Pake.decode($0.confirm, 32) }.map(hex) == crossConfirmT
            && reply.flatMap { Pake.decode($0.confirm, 32) }.map(hex) == crossConfirmS && typer.confirms(reply))

        // Whole exchanges.
        func exchange(_ shown: String, _ typed: String, typerCi: [UInt8], showerCi: [UInt8]) -> Bool {
            let typer = Pake.Typer()
            guard let nonce = Pake.requestNonce(typer.request) else { return false }
            let shower = Pake.Shower(code: shown, nonceT: nonce, ci: showerCi)
            guard typer.received(shower.message), let accept = typer.answer(code: typed, ci: typerCi),
                  let reply = shower.check(accept) else { return false }
            return typer.confirms(reply)
        }
        let same = Pake.channel(typing: "aa", showing: "bb")
        check("pake: right code pairs", exchange("123456", "123456", typerCi: same, showerCi: same))
        check("pake: wrong code fails", !exchange("123456", "123457", typerCi: same, showerCi: same))
        check("pake: a device in the middle can't relay", !exchange("123456", "123456",
            typerCi: Pake.channel(typing: "phone", showing: "attacker"), showerCi: Pake.channel(typing: "attacker", showing: "mac")))
        let retryTyper = Pake.Typer()
        let retryShower = Pake.Shower(code: "654321", nonceT: Pake.requestNonce(retryTyper.request)!, ci: same)
        _ = retryTyper.received(retryShower.message)
        let wrongTry = retryShower.check(retryTyper.answer(code: "111111", ci: same)!)
        retryTyper.wrongCode()
        let first = retryTyper.answer(code: "654321", ci: same)!, second = retryTyper.answer(code: "654321", ci: same)!
        let retryReply = retryShower.check(second)
        check("pake: the same code can be typed again", wrongTry == nil && first.y != second.y && retryTyper.confirms(retryReply))
        let zero = Pake.encode([UInt8](repeating: 0, count: 32)), one = Pake.encode([1] + [UInt8](repeating: 0, count: 31))
        let anyConfirm = Pake.encode([UInt8](repeating: 0, count: 32))
        check("pake: low-order Yb refused", retryShower.check(PakeMessage(v: 1, y: zero, confirm: anyConfirm)) == nil
            && retryShower.check(PakeMessage(v: 1, y: one, confirm: anyConfirm)) == nil)
        let badTyper = Pake.Typer()
        check("pake: low-order Ya refused", badTyper.received(PakeMessage(v: 1, nonce: Pake.encode([UInt8](repeating: 0, count: 16)), y: one))
            && badTyper.answer(code: "123456", ci: same) == nil)
        check("pake: bad sizes and versions refused", !badTyper.received(PakeMessage(v: 1, nonce: Pake.encode([1, 2]), y: zero))
            && !badTyper.received(PakeMessage(v: 2, nonce: Pake.encode([UInt8](repeating: 0, count: 16)), y: zero))
            && Pake.requestNonce(nil) == nil && Pake.requestNonce(PakeMessage(v: 1)) == nil)
        check("pake: reflected confirmation refused", !retryTyper.confirms(PakeMessage(v: 1, confirm: second.confirm)) && !retryTyper.confirms(nil))
        // A request from an older app has no pake: there's no nonce, so no code can be shown for it.
        let legacy = try? JSONDecoder().decode(Envelope.self, from: Data(#"{"type":"pair.accept","key":"abc"}"#.utf8))
        check("pake: legacy key has no pake", legacy?.pake == nil && legacy?.key == "abc" && Pairing.updateRequired == "update-required"
            && Pairing.updateMessage("Pixel") == "Update DyskLink on Pixel to pair." && PhoneLinkProtocol.version == 3)
        var share = Envelope(type: MessageType.pairPake)
        share.pake = PakeMessage(v: 1, nonce: "bm9uY2U=", y: "eQ==")
        let encoded = (try? JSONEncoder().encode(share)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let parsed = try? JSONDecoder().decode(Envelope.self, from: Data(#"{"type":"pair.accept","pake":{"v":1,"y":"eQ==","confirm":"Yw==","later":1}}"#.utf8))
        check("pake: travels in the envelope", encoded.contains(#""pake":{"#) && !encoded.contains("confirm") && parsed?.pake?.confirm == "Yw==")
    }
}
#endif
