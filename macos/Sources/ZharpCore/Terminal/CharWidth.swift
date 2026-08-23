import Foundation

/// Determines the number of terminal cells a code point occupies (a compact wcwidth).
///
/// The range tables are stored as packed "lo-hi" hex pairs and parsed once on
/// first use: a Swift array literal of this size costs minutes of type-checking,
/// while parsing costs microseconds at launch.
public enum CharWidth {
    // Sorted, non-overlapping [lo, hi] ranges of zero-width code points
    // (combining marks, format controls, variation selectors).
    private static let zeroPacked = """
        300-36f 483-489 591-5bd 5bf-5bf 5c1-5c2 5c4-5c5 5c7-5c7 610-61a 64b-65f 670-670 6d6-6dc
        6df-6e4 6e7-6e8 6ea-6ed 711-711 730-74a 7a6-7b0 7eb-7f3 816-819 859-85b 8d3-8e1 900-902
        93a-93a 93c-93c 941-948 94d-94d 951-957 962-963 981-981 9bc-9bc 9c1-9c4 9cd-9cd 9e2-9e3
        a01-a02 a3c-a3c a41-a42 a47-a48 a4b-a4d a70-a71 a81-a82 abc-abc ac1-ac5 ac7-ac8 acd-acd
        ae2-ae3 b01-b02 b3c-b3c b3f-b3f b41-b44 b4d-b4d b56-b56 b62-b63 b82-b82 bc0-bc0 bcd-bcd
        c00-c00 c3e-c40 c46-c48 c4a-c4d c55-c56 c62-c63 c81-c81 cbc-cbc cbf-cbf cc6-cc6 ccc-ccd
        ce2-ce3 d00-d01 d3b-d3c d41-d44 d4d-d4d d62-d63 dca-dca dd2-dd4 dd6-dd6 e31-e31 e34-e3a
        e47-e4e eb1-eb1 eb4-eb9 ec8-ecd f18-f19 f35-f35 f37-f37 f39-f39 f71-f7e f80-f84 f86-f87
        f8d-f97 f99-fbc fc6-fc6 102d-1030 1032-1037 1039-103a 103d-103e 1058-1059 105e-1060
        1071-1074 1082-1082 1085-1086 108d-108d 109d-109d 135d-135f 1712-1714 1732-1734 1752-1753
        1772-1773 17b4-17b5 17b7-17bd 17c6-17c6 17c9-17d3 17dd-17dd 180b-180e 1885-1886 18a9-18a9
        1920-1922 1927-1928 1932-1932 1939-193b 1a17-1a18 1a56-1a56 1a58-1a5e 1a60-1a60 1a62-1a62
        1a65-1a6c 1a73-1a7c 1a7f-1a7f 1ab0-1abe 1b00-1b03 1b34-1b34 1b36-1b3a 1b3c-1b3c 1b42-1b42
        1b6b-1b73 1b80-1b81 1ba2-1ba5 1ba8-1ba9 1bab-1bad 1be6-1be6 1be8-1be9 1bed-1bed 1bef-1bf1
        1c2c-1c33 1c36-1c37 1cd0-1cd2 1cd4-1ce0 1ce2-1ce8 1ced-1ced 1cf4-1cf4 1cf8-1cf9 1dc0-1dff
        200b-200f 202a-202e 2060-2064 20d0-20f0 2cef-2cf1 2d7f-2d7f 2de0-2dff 302a-302d 3099-309a
        a66f-a672 a674-a67d a69e-a69f a6f0-a6f1 a802-a802 a806-a806 a80b-a80b a825-a826 a8c4-a8c5
        a8e0-a8f1 a926-a92d a947-a951 a980-a982 a9b3-a9b3 a9b6-a9b9 a9bc-a9bd aa29-aa2e aa31-aa32
        aa35-aa36 aa43-aa43 aa4c-aa4c aa7c-aa7c aab0-aab0 aab2-aab4 aab7-aab8 aabe-aabf aac1-aac1
        aaec-aaed aaf6-aaf6 abe5-abe5 abe8-abe8 abed-abed fb1e-fb1e fe00-fe0f fe20-fe2f feff-feff
        101fd-101fd 102e0-102e0 10376-1037a 10a01-10a03 10a05-10a06 10a0c-10a0f 10a38-10a3a
        10a3f-10a3f 10ae5-10ae6 11001-11001 11038-11046 1107f-11081 110b3-110b6 110b9-110ba
        11100-11102 11127-1112b 1112d-1112f 11130-11132 11134-11134 11173-11173 11180-11181
        111b6-111be 111ca-111cc 1122f-11231 11234-11234 11236-11237 112df-112df 112e3-112ea
        11300-11301 1133c-1133c 11340-11340 11366-1136c 11370-11374 11438-1143f 11442-11444
        11446-11446 114b3-114b8 114ba-114ba 114bf-114c0 114c2-114c3 115b2-115b5 115bc-115bd
        115bf-115c0 115dc-115dd 11633-1163a 1163d-1163d 1163f-11640 116ab-116ab 116ad-116ad
        116b0-116b5 116b7-116b7 1171d-1171f 11722-11725 11727-1172b 11a01-11a0a 11a33-11a38
        11a3b-11a3e 11a47-11a47 11a51-11a56 11a59-11a5b 11a8a-11a96 11a98-11a99 11c30-11c36
        11c38-11c3d 11c3f-11c3f 11c92-11ca7 11caa-11cb0 11cb2-11cb3 11cb5-11cb6 16af0-16af4
        16b30-16b36 16f8f-16f9f 1bc9d-1bc9e 1d167-1d169 1d173-1d182 1d17b-1d18b 1d185-1d1ad
        1d1aa-1d242 1d242-1d244 1da00-1da36 1da3b-1da6c 1da75-1da75 1da84-1da84 1da9b-1da9f
        1daa1-1daaf 1e000-1e006 1e008-1e018 1e01b-1e021 1e023-1e024 1e026-1e02a 1e8d0-1e8d6
        1e944-1e94a e0001-e0001 e0020-e007f e0100-e01ef
        """

    // Sorted, non-overlapping [lo, hi] ranges of wide (2-cell) code points.
    private static let widePacked = """
        1100-115f 231a-231b 2329-232a 23e9-23ec 23f0-23f0 23f3-23f3 25fd-25fe 2614-2615 2648-2653
        267f-267f 2693-2693 26a1-26a1 26aa-26ab 26bd-26be 26c4-26c5 26ce-26ce 26d4-26d4 26ea-26ea
        26f2-26f3 26f5-26f5 26fa-26fa 26fd-26fd 2705-2705 270a-270b 2728-2728 274c-274c 274e-274e
        2753-2755 2757-2757 2795-2797 27b0-27b0 27bf-27bf 2b1b-2b1c 2b50-2b50 2b55-2b55 2e80-2e99
        2e9b-2ef3 2f00-2fd5 2ff0-2ffb 3000-303e 3041-3096 3099-30ff 3105-312f 3131-318e 3190-31ba
        31a0-31e3 31c0-31e3 31f0-321e 3220-3247 3250-325f 3260-327f 3280-32b0 32b1-32bf 32c0-32ff
        3300-33ff 3400-4dbf 4dc0-4dff 4e00-9fff a000-a48c a490-a4c6 a960-a97c ac00-d7a3 f900-fa6d
        fa70-fad9 fe10-fe19 fe30-fe52 fe54-fe66 fe68-fe6b ff00-ff60 ffe0-ffe6 16fe0-16fe1
        17000-187f1 18800-18af2 1b000-1b11e 1b170-1b2fb 1f004-1f004 1f0cf-1f0cf 1f18e-1f18e
        1f191-1f19a 1f200-1f202 1f210-1f23b 1f240-1f248 1f250-1f251 1f260-1f265 1f300-1f320
        1f32d-1f335 1f337-1f37c 1f37e-1f393 1f3a0-1f3ca 1f3cf-1f3d3 1f3e0-1f3f0 1f3f4-1f3f4
        1f3f8-1f43e 1f400-1f43e 1f440-1f440 1f442-1f4fc 1f4ff-1f53d 1f54b-1f54e 1f550-1f567
        1f57a-1f57a 1f595-1f596 1f5a4-1f5a4 1f5fb-1f64f 1f600-1f67f 1f680-1f6c5 1f6cc-1f6cc
        1f6d0-1f6d2 1f6eb-1f6ec 1f6f4-1f6f8 1f910-1f91e 1f91f-1f92f 1f930-1f93a 1f93c-1f93e
        1f940-1f945 1f947-1f9cf 1f9c0-1f9c0 1f9d0-1f9e6 20000-2a6df 2a700-2b734 2b740-2b81d
        2b820-2cea1 2ceb0-2ebe0 2f800-2fa1d 30000-3fffd
        """

    private static func unpack(_ packed: String) -> (lo: [Int], hi: [Int]) {
        var lo: [Int] = []
        var hi: [Int] = []
        for pair in packed.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            guard let dash = pair.firstIndex(of: "-"),
                  let a = Int(pair[pair.startIndex..<dash], radix: 16),
                  let b = Int(pair[pair.index(after: dash)...], radix: 16)
            else { continue }
            lo.append(a)
            hi.append(b)
        }
        return (lo, hi)
    }

    private static let zero = unpack(zeroPacked)
    private static let wide = unpack(widePacked)

    /// Returns 0 (zero-width), 1 (normal), or 2 (wide) for a code point.
    public static func width(of codePoint: Int) -> Int {
        if codePoint < 0x20 { return 0 }
        if codePoint < 0x300 { return 1 }
        if inRanges(codePoint, zero.lo, zero.hi) { return 0 }
        if codePoint >= 0x1100 && inRanges(codePoint, wide.lo, wide.hi) { return 2 }
        return 1
    }

    private static func inRanges(_ cp: Int, _ lo: [Int], _ hi: [Int]) -> Bool {
        var min = 0
        var max = lo.count - 1
        if lo.isEmpty || cp < lo[0] || cp > hi[max] { return false }
        while min <= max {
            let mid = (min + max) / 2
            if cp > hi[mid] {
                min = mid + 1
            } else if cp < lo[mid] {
                max = mid - 1
            } else {
                return true
            }
        }
        return false
    }
}
