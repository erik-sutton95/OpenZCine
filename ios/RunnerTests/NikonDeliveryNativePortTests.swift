import Foundation
import OpenCineAppKit
import OpenCineFrameIO
import XCTest
import os

@testable import Runner

private final class NikonDeliveryMemoryTokens: FrameioTokenStorage, @unchecked Sendable {
    private struct State {
        var value: StoredFrameioToken?
        var saves = 0
        var clears = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var saves: Int { state.withLock { $0.saves } }
    var clears: Int { state.withLock { $0.clears } }
    func load() -> StoredFrameioToken? { state.withLock { $0.value } }
    func save(_ stored: StoredFrameioToken) {
        state.withLock {
            $0.value = stored
            $0.saves += 1
        }
    }
    func clear() {
        state.withLock {
            $0.value = nil
            $0.clears += 1
        }
    }
}

@MainActor private final class NikonDeliveryHTTPGate: FrameioHTTPTransport {
    var requests: [FrameioAPIRequest] = []
    var waiters: [CheckedContinuation<FrameioHTTPResponse, Never>] = []
    func send(_ request: FrameioAPIRequest) async throws -> FrameioHTTPResponse {
        requests.append(request)
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ response: FrameioHTTPResponse = .init(statusCode: 200)) {
        waiters.removeFirst().resume(returning: response)
    }
}

/// SIMULATED HTTP and token storage exercise the actual bounded shipping account/transport ports.
/// These tests never touch the real keychain, browser, network or camera.
@MainActor final class NikonDeliveryNativePortTests: XCTestCase {
    private var request: FrameioAPIRequest {
        .init(url: URL(string: "https://SIMULATED.invalid/request")!, method: .get)
    }
    private var token: StoredFrameioToken {
        .init(
            token: .init(
                accessToken: "SIMULATED", refreshToken: nil,
                expiresIn: 3600, tokenType: "Bearer"),
            receivedAt: Date(timeIntervalSince1970: 0))
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Actual native port did not reach its manual gate")
    }
    func testCurrentCredentialReceiptUsesOnlyItsSuppliedNativeStore() {
        let owner = NikonFrameioAccount()
        let memory = NikonDeliveryMemoryTokens()
        let port = NikonFrameioCapturedTokens(account: owner.capture(), native: memory)
        port.save(token)
        XCTAssertEqual(port.load(), token)
        XCTAssertEqual(memory.saves, 1)
        port.clear()
        XCTAssertNil(memory.load())
        XCTAssertEqual(memory.clears, 1)
    }
    func testRetiredAndRecreatedAccountCannotWriteOrClearSuccessorCredentials() {
        let owner = NikonFrameioAccount()
        let memory = NikonDeliveryMemoryTokens()
        let oldReceipt = owner.capture()
        let old = NikonFrameioCapturedTokens(account: oldReceipt, native: memory)
        old.save(token)
        let successorReceipt = owner.retire()
        let successor = NikonFrameioCapturedTokens(account: successorReceipt, native: memory)
        successor.save(token)
        old.save(token)
        old.clear()
        XCTAssertNil(old.load())
        XCTAssertEqual(successor.load(), token)
        XCTAssertEqual(memory.saves, 2)
        XCTAssertEqual(memory.clears, 0)
        XCTAssertNotEqual(oldReceipt.identity, successorReceipt.identity)
        _ = owner.retire()
        XCTAssertFalse(oldReceipt.isCurrent)
        XCTAssertFalse(successorReceipt.isCurrent)
    }
    func testCredentialReceiptIsReadAndRefusedAtActualOffActorExecutor() async {
        let owner = NikonFrameioAccount()
        let memory = NikonDeliveryMemoryTokens()
        let receipt = owner.capture()
        let port = NikonFrameioCapturedTokens(account: receipt, native: memory)
        let value = token
        _ = owner.retire()
        let accepted = await Task.detached {
            port.save(value)
            port.clear()
            return receipt.isCurrent || port.load() != nil
        }.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(memory.saves, 0)
        XCTAssertEqual(memory.clears, 0)
    }
    func testCurrentCapturedHTTPDispatchesExactlyOnceAndReturnsNativeResponse() async throws {
        let account = NikonFrameioAccount().capture()
        let native = NikonDeliveryHTTPGate()
        let port = NikonFrameioAdmittedTransport(
            native: native, admission: .init { account.isCurrent })
        let work = Task { try await port.send(request) }
        await settle { native.waiters.count == 1 }
        let response = FrameioHTTPResponse(statusCode: 201, body: Data([1, 2]))
        native.release(response)
        let received = try await work.value
        XCTAssertEqual(received, response)
        XCTAssertEqual(native.requests, [request])
    }
    func testExpiredReceiptRefusesBeforeFirstUnsentHTTPRequest() async {
        let owner = NikonFrameioAccount()
        let receipt = owner.capture()
        let native = NikonDeliveryHTTPGate()
        let port = NikonFrameioAdmittedTransport(
            native: native, admission: .init { receipt.isCurrent })
        _ = owner.retire()
        do {
            _ = try await port.send(request)
            XCTFail("Expired account entered native HTTP")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(native.requests.isEmpty)
    }
    func testEnteredOldResponseCannotPublishOrStartTheNextRequestAfterAccountABA() async {
        let owner = NikonFrameioAccount()
        let receipt = owner.capture()
        let native = NikonDeliveryHTTPGate()
        let port = NikonFrameioAdmittedTransport(
            native: native, admission: .init { receipt.isCurrent })
        var publications = 0
        let work = Task {
            do {
                _ = try await port.send(request)
                publications += 1
                _ = try await port.send(request)
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await settle { native.waiters.count == 1 }
        _ = owner.retire()
        let successor = owner.retire()
        native.release()
        await work.value
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(native.requests.count, 1)
        XCTAssertTrue(successor.isCurrent)
    }
    func testCancelledEnteredAuthResponseCannotCommitTokensAfterNativeCleanup() async {
        let owner = NikonFrameioAccount()
        let account = owner.capture()
        let memory = NikonDeliveryMemoryTokens()
        let tokens = NikonFrameioCapturedTokens(account: account, native: memory)
        let native = NikonDeliveryHTTPGate()
        let port = NikonFrameioAdmittedTransport(
            native: native, admission: .init { account.isCurrent })
        let work = Task {
            do { _ = try await port.send(request) } catch {
                XCTAssertTrue(error is CancellationError)
            }
            tokens.save(token)
            tokens.clear()
        }
        await settle { native.waiters.count == 1 }
        work.cancel()
        native.release()
        await work.value
        XCTAssertTrue(account.isCurrent)
        XCTAssertEqual(native.requests.count, 1)
        XCTAssertEqual(memory.saves, 0)
        XCTAssertEqual(memory.clears, 0)
    }
}
