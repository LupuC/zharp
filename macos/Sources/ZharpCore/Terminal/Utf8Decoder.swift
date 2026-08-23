import Foundation

/// Incremental UTF-8 decoder: feeds whole Unicode scalars out of a byte stream
/// that may split a multi-byte sequence across reads (the .NET `Decoder`
/// equivalent). Invalid bytes yield U+FFFD, matching the replacement-character
/// behavior of the Windows build.
struct Utf8Decoder {
    private var pending: [UInt8] = []
    private var needed = 0

    mutating func decode(_ bytes: UnsafeBufferPointer<UInt8>, _ emit: (Int) -> Void) {
        for byte in bytes {
            if needed > 0 {
                if byte & 0xC0 == 0x80 {
                    pending.append(byte)
                    needed -= 1
                    if needed == 0 {
                        emit(Self.assemble(pending))
                        pending.removeAll(keepingCapacity: true)
                    }
                } else {
                    // Truncated sequence; restart on this byte.
                    emit(0xFFFD)
                    pending.removeAll(keepingCapacity: true)
                    needed = 0
                    start(byte, emit)
                }
            } else {
                start(byte, emit)
            }
        }
    }

    private mutating func start(_ byte: UInt8, _ emit: (Int) -> Void) {
        switch byte {
        case 0x00...0x7F:
            emit(Int(byte))
        case 0xC2...0xDF:
            pending = [byte]; needed = 1
        case 0xE0...0xEF:
            pending = [byte]; needed = 2
        case 0xF0...0xF4:
            pending = [byte]; needed = 3
        default:
            emit(0xFFFD)
        }
    }

    private static func assemble(_ bytes: [UInt8]) -> Int {
        var value: Int
        switch bytes.count {
        case 2: value = Int(bytes[0] & 0x1F)
        case 3: value = Int(bytes[0] & 0x0F)
        case 4: value = Int(bytes[0] & 0x07)
        default: return 0xFFFD
        }
        for b in bytes.dropFirst() {
            value = (value << 6) | Int(b & 0x3F)
        }
        // Reject surrogates and out-of-range values.
        if value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) { return 0xFFFD }
        return value
    }
}
