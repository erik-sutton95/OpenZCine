import Foundation
import Testing

@testable import OpenZCineCore

@Test func readBufferReturnsNilUntilEnoughBytesAvailable() {
    var buffer = PTPIPReadBuffer()
    buffer.append(Data([1, 2, 3]))

    #expect(buffer.take(4) == nil)
    #expect(buffer.availableCount == 3)
}

@Test func readBufferTakesExactBytesAndAdvances() {
    var buffer = PTPIPReadBuffer()
    buffer.append(Data([1, 2, 3, 4, 5]))

    #expect(buffer.take(2) == Data([1, 2]))
    #expect(buffer.take(2) == Data([3, 4]))
    #expect(buffer.availableCount == 1)
    #expect(buffer.take(2) == nil)
    #expect(buffer.take(1) == Data([5]))
    #expect(buffer.availableCount == 0)
}

@Test func readBufferSpansAppendBoundaries() {
    var buffer = PTPIPReadBuffer()
    buffer.append(Data([1, 2]))
    #expect(buffer.take(4) == nil)

    buffer.append(Data([3, 4, 5]))
    #expect(buffer.take(4) == Data([1, 2, 3, 4]))
    #expect(buffer.take(1) == Data([5]))
}

@Test func readBufferStaysByteCorrectAcrossCompaction() {
    // Drive the consumed prefix past the compaction threshold and confirm subsequent reads are
    // still byte-correct — the cursor reset must not corrupt or misalign the unread tail.
    var buffer = PTPIPReadBuffer(compactionThreshold: 8)
    buffer.append(Data((0..<20).map { UInt8($0) }))

    // 10 consumed > threshold (8) → triggers compaction.
    #expect(buffer.take(10) == Data((0..<10).map { UInt8($0) }))
    #expect(buffer.availableCount == 10)
    // Tail must stay intact and aligned after the compaction reset.
    #expect(buffer.take(10) == Data((10..<20).map { UInt8($0) }))
}

@Test func readBufferTakeZeroReturnsEmptyWithoutConsuming() {
    var buffer = PTPIPReadBuffer()
    buffer.append(Data([9]))

    #expect(buffer.take(0) == Data())
    #expect(buffer.availableCount == 1)
}
