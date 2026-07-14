import Foundation
import Testing

@testable import OpenZCineCore

@Suite("PTP object transfer planning")
struct PTPObjectTransferTests {
    @Test func nikonOperationCodesMatchLibgphotoSymbols() {
        #expect(PTPOperationCode.getObjectSize.rawValue == 0x9421)
        #expect(PTPOperationCode.getPartialObjectEx.rawValue == 0x9431)
    }

    @Test func objectSizeDecodesLittleEndianUInt64() throws {
        let size = try PTPObjectSize(
            data: Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]))

        #expect(size.bytes == 0x0102_0304_0506_0708)
    }

    @Test func objectSizeRejectsTruncatedPayload() {
        #expect(throws: PTPObjectTransferError.truncatedObjectSize(actualLength: 7)) {
            _ = try PTPObjectSize(data: Data(repeating: 0, count: 7))
        }
    }

    @Test func standardRequestUses32BitParameters() throws {
        let request = try PTPPartialObjectRequest(
            objectHandle: 0x1020_3040,
            offset: 0x0102_0304,
            maximumBytes: 0x0010_0000,
            totalBytes: 0x4000_0000,
            supportsExtendedReads: false
        )

        #expect(request.operationCode == .getPartialObject)
        #expect(request.parameters == [0x1020_3040, 0x0102_0304, 0x0010_0000])
        #expect(request.byteCount == 0x0010_0000)
        #expect(request.endOffset == 0x0112_0304)
    }

    @Test func extendedRequestSplitsOffsetAndMaximumIntoLowHighWords() throws {
        let offset = UInt64(UInt32.max) + 1
        let maximumBytes = UInt64(UInt32.max) + 2
        let request = try PTPPartialObjectRequest(
            objectHandle: 0xAABB_CCDD,
            offset: offset,
            maximumBytes: maximumBytes,
            totalBytes: offset + maximumBytes,
            supportsExtendedReads: true
        )

        #expect(request.operationCode == .getPartialObjectEx)
        #expect(
            request.parameters == [
                0xAABB_CCDD,
                0x0000_0000,
                0x0000_0001,
                0x0000_0001,
                0x0000_0001,
            ])
    }

    @Test func largeObjectUsesExtendedRequestFromOffsetZero() throws {
        let request = try PTPPartialObjectRequest(
            objectHandle: 9,
            offset: 0,
            maximumBytes: 4 * 1_024 * 1_024,
            totalBytes: UInt64(UInt32.max) + 1,
            supportsExtendedReads: true
        )

        #expect(request.operationCode == .getPartialObjectEx)
        #expect(request.parameters == [9, 0, 0, UInt32(4 * 1_024 * 1_024), 0])
    }

    @Test func objectAtUInt32BoundaryStillUsesStandardRequest() throws {
        let request = try PTPPartialObjectRequest(
            objectHandle: 7,
            offset: UInt64(UInt32.max) - 1,
            maximumBytes: 1,
            totalBytes: UInt64(UInt32.max),
            supportsExtendedReads: false
        )

        #expect(request.operationCode == .getPartialObject)
        #expect(request.parameters == [7, UInt32.max - 1, 1])
    }

    @Test func finalRequestIsTrimmedToRemainingBytes() throws {
        let request = try PTPPartialObjectRequest(
            objectHandle: 4,
            offset: 900,
            maximumBytes: 256,
            totalBytes: 1_000,
            supportsExtendedReads: false
        )

        #expect(request.byteCount == 100)
        #expect(request.parameters == [4, 900, 100])
        #expect(request.endOffset == 1_000)
    }

    @Test func cursorResumesAdvancesAndCompletes() throws {
        var cursor = try PTPObjectTransferCursor(
            objectHandle: 12,
            totalBytes: 1_000,
            resumeOffset: 600,
            chunkSize: 256,
            supportsExtendedReads: false
        )

        #expect(try cursor.nextRequest()?.offset == 600)
        #expect(try cursor.nextRequest()?.byteCount == 256)
        try cursor.advance(by: 256)
        #expect(cursor.offset == 856)
        #expect(try cursor.nextRequest()?.byteCount == 144)
        try cursor.advance(by: 144)
        #expect(cursor.isComplete)
        #expect(try cursor.nextRequest() == nil)
    }

    @Test func cursorAcceptsShortNonemptyChunkAndResumesAfterIt() throws {
        var cursor = try PTPObjectTransferCursor(
            objectHandle: 3,
            totalBytes: 1_000,
            chunkSize: 256,
            supportsExtendedReads: false
        )

        try cursor.advance(by: 100)

        #expect(cursor.offset == 100)
        #expect(try cursor.nextRequest()?.offset == 100)
        #expect(try cursor.nextRequest()?.byteCount == 256)
    }

    @Test func zeroRequestAndChunkSizesAreRejected() {
        #expect(throws: PTPObjectTransferError.zeroMaximumBytes) {
            _ = try PTPPartialObjectRequest(
                objectHandle: 1,
                offset: 0,
                maximumBytes: 0,
                totalBytes: 1,
                supportsExtendedReads: false
            )
        }
        #expect(throws: PTPObjectTransferError.zeroMaximumBytes) {
            _ = try PTPObjectTransferCursor(
                objectHandle: 1,
                totalBytes: 1,
                chunkSize: 0,
                supportsExtendedReads: false
            )
        }
    }

    @Test func invalidResumeAndRequestOffsetsAreRejected() {
        #expect(
            throws: PTPObjectTransferError.offsetOutsideObject(offset: 101, totalBytes: 100)
        ) {
            _ = try PTPObjectTransferCursor(
                objectHandle: 1,
                totalBytes: 100,
                resumeOffset: 101,
                supportsExtendedReads: false
            )
        }
        #expect(
            throws: PTPObjectTransferError.offsetOutsideObject(offset: 100, totalBytes: 100)
        ) {
            _ = try PTPPartialObjectRequest(
                objectHandle: 1,
                offset: 100,
                maximumBytes: 1,
                totalBytes: 100,
                supportsExtendedReads: false
            )
        }
    }

    @Test func largeObjectWithoutExtendedSupportIsRejected() {
        let totalBytes = UInt64(UInt32.max) + 1
        #expect(
            throws: PTPObjectTransferError.extendedReadUnsupported(totalBytes: totalBytes)
        ) {
            _ = try PTPObjectTransferCursor(
                objectHandle: 1,
                totalBytes: totalBytes,
                supportsExtendedReads: false
            )
        }
    }

    @Test func cursorRejectsEmptyOversizedOverflowingAndPostCompletionAdvances() throws {
        var cursor = try PTPObjectTransferCursor(
            objectHandle: 1,
            totalBytes: 10,
            chunkSize: 4,
            supportsExtendedReads: false
        )
        #expect(throws: PTPObjectTransferError.emptyChunkBeforeCompletion(offset: 0)) {
            try cursor.advance(by: 0)
        }
        #expect(
            throws: PTPObjectTransferError.chunkExceedsRequest(
                receivedBytes: 5,
                maximumBytes: 4
            )
        ) {
            try cursor.advance(by: 5)
        }

        var overflowCursor = try PTPObjectTransferCursor(
            objectHandle: 2,
            totalBytes: UInt64.max,
            resumeOffset: UInt64.max - 1,
            chunkSize: 1,
            supportsExtendedReads: true
        )
        #expect(
            throws: PTPObjectTransferError.offsetOverflow(
                offset: UInt64.max - 1,
                receivedBytes: 2
            )
        ) {
            try overflowCursor.advance(by: 2)
        }

        var completeCursor = try PTPObjectTransferCursor(
            objectHandle: 3,
            totalBytes: 1,
            chunkSize: 1,
            supportsExtendedReads: false
        )
        try completeCursor.advance(by: 1)
        #expect(throws: PTPObjectTransferError.transferAlreadyComplete) {
            try completeCursor.advance(by: 1)
        }
    }

    @Test func zeroLengthObjectStartsComplete() throws {
        let cursor = try PTPObjectTransferCursor(
            objectHandle: 1,
            totalBytes: 0,
            supportsExtendedReads: false
        )

        #expect(cursor.isComplete)
        #expect(try cursor.nextRequest() == nil)
    }
}
