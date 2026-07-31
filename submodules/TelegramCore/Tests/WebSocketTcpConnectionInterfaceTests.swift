import Foundation
import ObjectiveC
import XCTest
import MtProtoKit
@testable import TelegramCore

private final class TcpConnectionTestEncryptionProvider: NSObject, EncryptionProvider {
    func createBignumContext() -> MTBignumContext {
        preconditionFailure("Not needed by MTTcpConnection startup tests")
    }

    func rsaEncrypt(withPublicKey publicKey: String, data: Data) -> Data? {
        preconditionFailure("Not needed by MTTcpConnection startup tests")
    }

    func rsaEncryptPKCS1OAEP(withPublicKey publicKey: String, data: Data) -> Data? {
        preconditionFailure("Not needed by MTTcpConnection startup tests")
    }

    func parseRSAPublicKey(_ publicKey: String) -> MTRsaPublicKey {
        preconditionFailure("Not needed by MTTcpConnection startup tests")
    }

    func macosRSAEncrypt(_ publicKey: String, data: Data) -> Data {
        preconditionFailure("Not needed by MTTcpConnection startup tests")
    }
}

private final class CapturingTcpConnectionInterface: NSObject, MTTcpConnectionInterface {
    struct Read: Equatable {
        let length: UInt
        let tag: Int
    }

    weak var delegate: MTTcpConnectionInterfaceDelegate?
    private let delegateQueue: DispatchQueue
    private let lock = NSLock()
    private var capturedWrites: [Data] = []
    private var capturedReads: [Read] = []

    init(delegate: MTTcpConnectionInterfaceDelegate, delegateQueue: DispatchQueue) {
        self.delegate = delegate
        self.delegateQueue = delegateQueue
    }

    var writes: [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.capturedWrites
    }

    var reads: [Read] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.capturedReads
    }

    func setGetLogPrefix(_ getLogPrefix: (() -> String)?) {
    }

    func setUsageCalculationInfo(_ usageCalculationInfo: MTNetworkUsageCalculationInfo?) {
    }

    func connect(toHost inHost: String, onPort port: UInt16, viaInterface inInterface: String?, withTimeout timeout: TimeInterval, error errPtr: NSErrorPointer) -> Bool {
        return true
    }

    func write(_ data: Data) {
        self.lock.lock()
        self.capturedWrites.append(data)
        self.lock.unlock()
    }

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        self.lock.lock()
        self.capturedReads.append(Read(length: length, tag: tag))
        self.lock.unlock()
    }

    func disconnect() {
    }

    func resetDelegate() {
        self.delegate = nil
    }

    func simulateOpen() {
        self.delegateQueue.async { [weak self] in
            self?.delegate?.connectionInterfaceDidConnect()
        }
    }
}

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

    func testWebSocketDiagnosticErrorFieldsAreBoundedAndExcludeErrorDetails() {
        let credential = "credential-that-must-not-appear"
        let error = NSError(
            domain: "NSURLError Domain/\(credential)",
            code: -1005,
            userInfo: [
                NSLocalizedDescriptionKey: credential,
                NSURLErrorFailingURLStringErrorKey: "wss://relay.example/hidden?token=\(credential)"
            ]
        )

        let fields = WebSocketRelayDiagnostic.errorFields(error)
        XCTAssertEqual(fields, "errorDomain=other errorCode=-1005")
        XCTAssertFalse(fields.contains(credential))
        XCTAssertFalse(fields.contains("wss://"))
        XCTAssertFalse(fields.contains("hidden"))
        XCTAssertFalse(fields.contains("token="))
        XCTAssertFalse(fields.contains(error.localizedDescription))
        XCTAssertEqual(WebSocketRelayDiagnostic.errorFields(nil), "errorDomain=none errorCode=0")
        XCTAssertEqual(
            WebSocketRelayDiagnostic.errorFields(NSError(domain: NSURLErrorDomain, code: -1001)),
            "errorDomain=NSURLErrorDomain errorCode=-1001"
        )
        XCTAssertEqual(
            WebSocketRelayDiagnostic.errorFields(NSError(domain: String(repeating: "a", count: 200), code: 7)),
            "errorDomain=other errorCode=7"
        )
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

    func testWebSocketTcpConnectionWaitsForOpenBeforeWritingObfuscated2Stream() throws {
        let settings = MTSocksProxySettings(
            ip: "127.0.0.1",
            port: 443,
            webSocketPath: "/relay",
            webSocketToken: "synthetic-token"
        )
        let apiEnvironment = MTApiEnvironment(deviceModelName: "TelegramCoreTests")
            .withUpdatedSocksProxySettings(settings)
        let context = MTContext(
            serialization: Serialization(),
            encryptionProvider: TcpConnectionTestEncryptionProvider(),
            apiEnvironment: apiEnvironment,
            isTestingEnvironment: false,
            useTempAuthKeys: false
        )

        let interfaceCreated = self.expectation(description: "WebSocket connection interface created")
        var capturingInterface: CapturingTcpConnectionInterface?
        context.makeWebSocketTcpConnectionInterface = { _, delegate, delegateQueue in
            let interface = CapturingTcpConnectionInterface(delegate: delegate, delegateQueue: delegateQueue)
            capturingInterface = interface
            interfaceCreated.fulfill()
            return interface
        }

        let address = MTDatacenterAddress(
            ip: "149.154.167.50",
            port: 443,
            preferForMedia: false,
            restrictToTcp: true,
            cdn: false,
            preferForProxy: false,
            secret: nil
        )
        let scheme = MTTransportScheme(transport: MTTcpTransport.self, address: address, media: false)
        let connection = try self.makeTcpConnection(context: context, datacenterId: 4, scheme: scheme)
        defer { self.invokeVoid(connection, selector: NSSelectorFromString("stop")) }

        let payload = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        self.invokeSendDatas(connection, datas: [payload])
        self.invokeVoid(connection, selector: NSSelectorFromString("start"))

        self.wait(for: [interfaceCreated], timeout: 2.0)
        let interface = try XCTUnwrap(capturingInterface)
        self.waitForTcpQueue()
        XCTAssertEqual(interface.writes, [])
        XCTAssertEqual(interface.reads, [])

        interface.simulateOpen()
        self.waitForTcpQueue()
        let firstWrite = try XCTUnwrap(interface.writes.first)
        XCTAssertGreaterThanOrEqual(firstWrite.count, 64 + 4 + payload.count)
        XCTAssertFalse(firstWrite.starts(with: Data([0x05, 0x01, 0x00])))

        let wireHeader = firstWrite.subdata(in: 0 ..< 64)
        let encryptedFrame = firstWrite.subdata(in: 64 ..< firstWrite.count)
        let decryptedStream = try self.decryptObfuscated2Stream(
            wireHeader: wireHeader,
            encryptedFrame: encryptedFrame
        )
        XCTAssertEqual(decryptedStream.subdata(in: 56 ..< 60), Data([0xdd, 0xdd, 0xdd, 0xdd]))
        XCTAssertEqual(decryptedStream.subdata(in: 60 ..< 62), Data([0x04, 0x00]))

        let frame = decryptedStream.subdata(in: 64 ..< decryptedStream.count)
        let framedLength = frame.prefix(4).withUnsafeBytes { bytes in
            Int(UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self)))
        }
        XCTAssertEqual(framedLength, frame.count - 4)
        XCTAssertGreaterThanOrEqual(framedLength, payload.count)
        XCTAssertLessThan(framedLength - payload.count, 16)
        XCTAssertEqual(frame.subdata(in: 4 ..< 4 + payload.count), payload)
        XCTAssertEqual(interface.reads.map(\.length), [4])
    }

    func testSocksTcpConnectionStillStartsMethodNegotiation() throws {
        try self.assertSocksStartup(
            username: nil,
            password: nil,
            expectedGreeting: Data([0x05, 0x01, 0x00])
        )
        try self.assertSocksStartup(
            username: "user",
            password: "password",
            expectedGreeting: Data([0x05, 0x02, 0x00, 0x02])
        )
    }

    func testSecretlessObfuscated2HeaderAndFirstFrameUseContinuousCtr() throws {
        let prefix = try self.makeEncryptedObfuscated2Prefix(datacenterTag: 4)
        let decryptedStream = try self.decryptObfuscated2Stream(
            wireHeader: prefix.wireHeader,
            encryptedFrame: prefix.encryptedFrame
        )

        XCTAssertEqual(prefix.wireHeader.count, 64)
        XCTAssertEqual(prefix.wireHeader.prefix(56), prefix.randomBytes.prefix(56))
        XCTAssertEqual(
            prefix.wireHeader,
            try self.data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031323334353637752b166d1a00fd5d")
        )
        XCTAssertEqual(prefix.encryptedFrame, try self.data(hex: "3aa9c12828d155017210227e"))
        XCTAssertEqual(decryptedStream.subdata(in: 56 ..< 60), Data([0xdd, 0xdd, 0xdd, 0xdd]))
        XCTAssertEqual(decryptedStream.subdata(in: 60 ..< 62), Data([0x04, 0x00]))
        XCTAssertEqual(decryptedStream.subdata(in: 64 ..< decryptedStream.count), prefix.plaintextFrame)
    }

    func testSecretlessObfuscated2HeaderEncodesNegativeMediaDatacenterTag() throws {
        let prefix = try self.makeEncryptedObfuscated2Prefix(datacenterTag: -4)
        let decryptedStream = try self.decryptObfuscated2Stream(
            wireHeader: prefix.wireHeader,
            encryptedFrame: prefix.encryptedFrame
        )

        XCTAssertEqual(decryptedStream.subdata(in: 56 ..< 60), Data([0xdd, 0xdd, 0xdd, 0xdd]))
        XCTAssertEqual(decryptedStream.subdata(in: 60 ..< 62), Data([0xfc, 0xff]))
    }

    func testObfuscated2BuilderPreservesLegacyAbridgedAndSecretDerivation() throws {
        let randomBytes = Data((0 ..< 64).map { UInt8($0) })

        let abridgedState = try XCTUnwrap(MTMakeObfuscated2ConnectionState(randomBytes, false, 2, nil))
        XCTAssertEqual(
            abridgedState.wireHeader,
            try self.data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30313233343536374719245f1c00fd5d")
        )

        let secret = Data((0 ..< 16).map { UInt8($0) })
        let secretState = try XCTUnwrap(MTMakeObfuscated2ConnectionState(randomBytes, true, 4, secret))
        XCTAssertEqual(
            secretState.wireHeader,
            try self.data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30313233343536377fb7a7adbd08ade4")
        )

        XCTAssertNil(MTMakeObfuscated2ConnectionState(Data(repeating: 0, count: 63), true, 4, nil))
        XCTAssertNil(MTMakeObfuscated2ConnectionState(randomBytes, true, 4, Data(repeating: 0, count: 15)))
    }

    func testSendQueuePreservesActualObfuscated2StreamAcrossChunkingCases() throws {
        let prefix = try self.makeEncryptedObfuscated2Prefix(datacenterTag: 2)
        var stream = prefix.wireHeader
        stream.append(prefix.encryptedFrame)

        XCTAssertEqual(
            try self.sendQueueOutput(maximumMessageSize: 128, writesBeforeOpen: [stream], writesAfterOpen: []),
            stream
        )
        XCTAssertEqual(
            try self.sendQueueOutput(maximumMessageSize: 64, writesBeforeOpen: [prefix.wireHeader, prefix.encryptedFrame], writesAfterOpen: []),
            stream
        )
        XCTAssertEqual(
            try self.sendQueueOutput(maximumMessageSize: 64, writesBeforeOpen: [stream], writesAfterOpen: []),
            stream
        )

        let writes = stride(from: 0, to: stream.count, by: 11).map { offset in
            stream.subdata(in: offset ..< min(stream.count, offset + 11))
        }
        XCTAssertEqual(
            try self.sendQueueOutput(
                maximumMessageSize: 16,
                writesBeforeOpen: Array(writes.prefix(3)),
                writesAfterOpen: Array(writes.dropFirst(3))
            ),
            stream
        )
    }

    private func assertSocksStartup(username: String?, password: String?, expectedGreeting: Data) throws {
        let settings = MTSocksProxySettings(
            ip: "127.0.0.1",
            port: 1080,
            username: username,
            password: password,
            secret: nil
        )
        let apiEnvironment = MTApiEnvironment(deviceModelName: "TelegramCoreTests")
            .withUpdatedSocksProxySettings(settings)
        let context = MTContext(
            serialization: Serialization(),
            encryptionProvider: TcpConnectionTestEncryptionProvider(),
            apiEnvironment: apiEnvironment,
            isTestingEnvironment: false,
            useTempAuthKeys: false
        )

        let interfaceCreated = self.expectation(description: "SOCKS connection interface created")
        var capturingInterface: CapturingTcpConnectionInterface?
        context.makeTcpConnectionInterface = { delegate, delegateQueue in
            let interface = CapturingTcpConnectionInterface(delegate: delegate, delegateQueue: delegateQueue)
            capturingInterface = interface
            interfaceCreated.fulfill()
            return interface
        }

        let address = MTDatacenterAddress(
            ip: "149.154.167.50",
            port: 443,
            preferForMedia: false,
            restrictToTcp: true,
            cdn: false,
            preferForProxy: false,
            secret: nil
        )
        let scheme = MTTransportScheme(transport: MTTcpTransport.self, address: address, media: false)
        let connection = try self.makeTcpConnection(context: context, datacenterId: 4, scheme: scheme)
        defer { self.invokeVoid(connection, selector: NSSelectorFromString("stop")) }

        self.invokeVoid(connection, selector: NSSelectorFromString("start"))
        self.wait(for: [interfaceCreated], timeout: 2.0)
        let interface = try XCTUnwrap(capturingInterface)
        self.waitForTcpQueue()

        XCTAssertEqual(interface.writes, [expectedGreeting])
        XCTAssertEqual(interface.reads.map(\.length), [2])
    }

    private func makeEncryptedObfuscated2Prefix(datacenterTag: Int16) throws -> (
        randomBytes: Data,
        wireHeader: Data,
        plaintextFrame: Data,
        encryptedFrame: Data
    ) {
        let randomBytes = Data((0 ..< 64).map { UInt8($0) })
        let state = try XCTUnwrap(MTMakeObfuscated2ConnectionState(randomBytes, true, datacenterTag, nil))

        let payload = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let padding = Data([0xa1, 0xb2, 0xc3])
        let framedLength = payload.count + padding.count
        var plaintextFrame = Data([
            UInt8(truncatingIfNeeded: framedLength),
            UInt8(truncatingIfNeeded: framedLength >> 8),
            UInt8(truncatingIfNeeded: framedLength >> 16),
            UInt8(truncatingIfNeeded: framedLength >> 24)
        ])
        plaintextFrame.append(payload)
        plaintextFrame.append(padding)

        var encryptedFrame = Data(count: plaintextFrame.count)
        plaintextFrame.withUnsafeBytes { plaintextBytes in
            encryptedFrame.withUnsafeMutableBytes { encryptedBytes in
                state.outgoingAesCtr.encrypt(in:
                    plaintextBytes.bindMemory(to: UInt8.self).baseAddress!,
                    out: encryptedBytes.bindMemory(to: UInt8.self).baseAddress!,
                    len: plaintextFrame.count
                )
            }
        }

        return (randomBytes, state.wireHeader, plaintextFrame, encryptedFrame)
    }

    private func decryptObfuscated2Stream(wireHeader: Data, encryptedFrame: Data) throws -> Data {
        let key = wireHeader.subdata(in: 8 ..< 40)
        let iv = wireHeader.subdata(in: 40 ..< 56)
        var stream = wireHeader
        stream.append(encryptedFrame)
        return try XCTUnwrap(MTAesCtrDecrypt(stream, key, iv))
    }

    private func makeTcpConnection(context: MTContext, datacenterId: Int, scheme: MTTransportScheme) throws -> AnyObject {
        guard let connectionClass = NSClassFromString("MTTcpConnection") else {
            throw TcpConnectionRuntimeError.classNotFound
        }
        let selector = NSSelectorFromString("initWithContext:datacenterId:scheme:interface:usageCalculationInfo:getLogPrefix:")
        guard
            let instance = class_createInstance(connectionClass, 0) as AnyObject?,
            let method = class_getInstanceMethod(connectionClass, selector)
        else {
            throw TcpConnectionRuntimeError.methodNotFound
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            MTContext,
            Int,
            MTTransportScheme,
            NSString?,
            MTNetworkUsageCalculationInfo?,
            AnyObject?
        ) -> AnyObject
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        return function(instance, selector, context, datacenterId, scheme, nil, nil, nil)
    }

    private func invokeVoid(_ object: AnyObject, selector: Selector) {
        guard let method = class_getInstanceMethod(type(of: object), selector) else {
            XCTFail("Missing Objective-C method \(selector)")
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(object, selector)
    }

    private func invokeSendDatas(_ object: AnyObject, datas: [Data]) {
        let selector = NSSelectorFromString("sendDatas:completion:requestQuickAck:expectDataInResponse:")
        guard let method = class_getInstanceMethod(type(of: object), selector) else {
            XCTFail("Missing Objective-C method \(selector)")
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, NSArray, AnyObject?, Bool, Bool) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(object, selector, datas as NSArray, nil, false, false)
    }

    private func waitForTcpQueue() {
        guard
            let connectionClass = NSClassFromString("MTTcpConnection"),
            let method = class_getClassMethod(connectionClass, NSSelectorFromString("tcpQueue"))
        else {
            XCTFail("Missing MTTcpConnection.tcpQueue")
            return
        }
        typealias Function = @convention(c) (AnyClass, Selector) -> MTQueue
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let queue = function(connectionClass, NSSelectorFromString("tcpQueue"))
        queue.dispatch(onQueue: {
        }, synchronous: true)
    }

    private func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw HexDataError.invalidLength
        }
        var result = Data()
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< nextIndex], radix: 16) else {
                throw HexDataError.invalidByte
            }
            result.append(byte)
            index = nextIndex
        }
        return result
    }

    private enum HexDataError: Error {
        case invalidLength
        case invalidByte
    }

    private enum TcpConnectionRuntimeError: Error {
        case classNotFound
        case methodNotFound
    }

    private func sendQueueOutput(
        maximumMessageSize: Int,
        writesBeforeOpen: [Data],
        writesAfterOpen: [Data]
    ) throws -> Data {
        let expectedByteCount = (writesBeforeOpen + writesAfterOpen).reduce(0, { $0 + $1.count })
        let queue = WebSocketSendQueue(
            maximumMessageSize: maximumMessageSize,
            maximumQueuedByteCount: max(maximumMessageSize, expectedByteCount)
        )

        for write in writesBeforeOpen {
            XCTAssertNil(try queue.enqueue(write))
        }
        var nextMessage = queue.open()
        for write in writesAfterOpen {
            XCTAssertNil(try queue.enqueue(write))
        }

        var result = Data()
        while let message = nextMessage {
            result.append(message)
            nextMessage = queue.didCompleteSend()
        }
        XCTAssertFalse(queue.isSendInFlight)
        XCTAssertEqual(queue.queuedByteCount, 0)
        return result
    }
}
