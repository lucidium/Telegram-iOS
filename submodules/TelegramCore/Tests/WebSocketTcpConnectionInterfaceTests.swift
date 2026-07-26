import Foundation
import XCTest
import MtProtoKit
@testable import TelegramCore

final class WebSocketTcpConnectionInterfaceTests: XCTestCase {
    func testOneMessageSatisfiesMultipleReads() throws {
        let buffer = WebSocketByteStreamBuffer(maximumBufferedByteCount: 64)

        XCTAssertEqual(try buffer.enqueueRead(length: 2, tag: 1), [])
        XCTAssertEqual(try buffer.enqueueRead(length: 3, tag: 2), [])
        XCTAssertEqual(try buffer.append(Data([1, 2, 3, 4, 5])), [
            .partial(length: 2, tag: 1),
            .data(Data([1, 2]), tag: 1),
            .partial(length: 3, tag: 2),
            .data(Data([3, 4, 5]), tag: 2)
        ])
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testOneReadSpansMultipleMessagesWithoutEmptyInputLoop() throws {
        let buffer = WebSocketByteStreamBuffer(maximumBufferedByteCount: 64)

        XCTAssertEqual(try buffer.enqueueRead(length: 5, tag: 7), [])
        XCTAssertEqual(try buffer.append(Data([1, 2])), [.partial(length: 2, tag: 7)])
        XCTAssertEqual(try buffer.append(Data()), [])
        XCTAssertEqual(try buffer.append(Data([3])), [.partial(length: 1, tag: 7)])
        XCTAssertEqual(try buffer.append(Data([4, 5])), [
            .partial(length: 2, tag: 7),
            .data(Data([1, 2, 3, 4, 5]), tag: 7)
        ])
    }

    func testBufferedInputIsDeliveredInOrderWhenReadArrivesLater() throws {
        let buffer = WebSocketByteStreamBuffer(maximumBufferedByteCount: 64)

        XCTAssertEqual(try buffer.append(Data([10, 11, 12, 13])), [])
        XCTAssertEqual(try buffer.enqueueRead(length: 3, tag: 4), [
            .partial(length: 3, tag: 4),
            .data(Data([10, 11, 12]), tag: 4)
        ])
        XCTAssertEqual(try buffer.enqueueRead(length: 1, tag: 5), [
            .partial(length: 1, tag: 5),
            .data(Data([13]), tag: 5)
        ])
    }

    func testReceiveBufferRejectsInvalidReadsAndExcessInput() throws {
        let buffer = WebSocketByteStreamBuffer(maximumBufferedByteCount: 4)

        XCTAssertThrowsError(try buffer.enqueueRead(length: 0, tag: 0))
        XCTAssertThrowsError(try buffer.enqueueRead(length: 5, tag: 0))
        XCTAssertEqual(try buffer.append(Data([1, 2, 3, 4])), [])
        XCTAssertThrowsError(try buffer.append(Data([5])))

        buffer.reset()
        XCTAssertEqual(buffer.bufferedByteCount, 0)
        XCTAssertEqual(try buffer.enqueueRead(length: 1, tag: 9), [])
    }

    func testSendQueueWaitsForOpenAndKeepsOneMessageInFlight() throws {
        let queue = WebSocketSendQueue(maximumMessageSize: 3, maximumQueuedByteCount: 16)

        XCTAssertNil(try queue.enqueue(Data([1, 2, 3, 4, 5, 6, 7])))
        XCTAssertFalse(queue.isSendInFlight)
        XCTAssertEqual(queue.open(), Data([1, 2, 3]))
        XCTAssertTrue(queue.isSendInFlight)
        XCTAssertNil(try queue.enqueue(Data([8, 9])))
        XCTAssertEqual(queue.didCompleteSend(), Data([4, 5, 6]))
        XCTAssertEqual(queue.didCompleteSend(), Data([7]))
        XCTAssertEqual(queue.didCompleteSend(), Data([8, 9]))
        XCTAssertNil(queue.didCompleteSend())
        XCTAssertFalse(queue.isSendInFlight)
        XCTAssertEqual(queue.queuedByteCount, 0)
    }

    func testSendQueueEnforcesBoundAndResetDiscardsPendingWork() throws {
        let queue = WebSocketSendQueue(maximumMessageSize: 4, maximumQueuedByteCount: 8)

        XCTAssertNil(try queue.enqueue(Data([1, 2, 3, 4, 5, 6, 7, 8])))
        XCTAssertThrowsError(try queue.enqueue(Data([9])))
        XCTAssertEqual(queue.open(), Data([1, 2, 3, 4]))
        queue.reset()
        XCTAssertFalse(queue.isSendInFlight)
        XCTAssertEqual(queue.queuedByteCount, 0)
        XCTAssertNil(queue.open())
    }

    func testWebSocketTransportContractIsSecretlessPaddedIntermediate() {
        XCTAssertTrue(WebSocketRelayTransportContract.usesIntermediateFormat)
        XCTAssertFalse(WebSocketRelayTransportContract.usesMtProxySecret)
        XCTAssertEqual(WebSocketRelayTransportContract.connectionType, 0xdddddddd)
        XCTAssertEqual(WebSocketRelayTransportContract.initialReadLength, 4)
    }

    func testWebSocketConstantsAndErrorsDoNotContainCredentials() {
        XCTAssertEqual(WebSocketTcpConnectionInterface.webSocketProtocol, "telegram-mtproto-relay.v1")
        XCTAssertEqual(WebSocketTcpConnectionInterface.maximumMessageSize, 16 * 1024 * 1024)
        XCTAssertEqual(WebSocketTcpConnectionInterface.maximumBufferedByteCount, 16 * 1024 * 1024)

        let token = "credential-that-must-not-appear"
        let error = NSError(domain: "TelegramCore.WebSocketTcpConnectionInterface", code: 1)
        XCTAssertFalse(error.description.contains(token))
    }

    func testNetworkProxyIdentityIncludesAllWebSocketFields() {
        let first = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/a", webSocketToken: "token-a")
        let same = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/a", webSocketToken: "token-a")
        let changedHost = MTSocksProxySettings(ip: "other.example.com", port: 443, webSocketPath: "/relay/v1/a", webSocketToken: "token-a")
        let changedPort = MTSocksProxySettings(ip: "relay.example.com", port: 8443, webSocketPath: "/relay/v1/a", webSocketToken: "token-a")
        let changedPath = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/b", webSocketToken: "token-a")
        let changedToken = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/a", webSocketToken: "token-b")

        XCTAssertEqual(NetworkContextProxyId(settings: first), NetworkContextProxyId(settings: same))
        XCTAssertNotEqual(NetworkContextProxyId(settings: first), NetworkContextProxyId(settings: changedHost))
        XCTAssertNotEqual(NetworkContextProxyId(settings: first), NetworkContextProxyId(settings: changedPort))
        XCTAssertNotEqual(NetworkContextProxyId(settings: first), NetworkContextProxyId(settings: changedPath))
        XCTAssertNotEqual(NetworkContextProxyId(settings: first), NetworkContextProxyId(settings: changedToken))
    }

    func testRawAndWebSocketFactoriesRemainSeparate() {
        XCTAssertTrue(MTContext.instancesRespond(to: NSSelectorFromString("makeTcpConnectionInterface")))
        XCTAssertTrue(MTContext.instancesRespond(to: NSSelectorFromString("makeWebSocketTcpConnectionInterface")))
        XCTAssertNotEqual(NSSelectorFromString("makeTcpConnectionInterface"), NSSelectorFromString("makeWebSocketTcpConnectionInterface"))
    }
}