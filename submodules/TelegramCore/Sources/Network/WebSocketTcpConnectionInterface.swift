import Foundation
import Network

import MtProtoKit

enum WebSocketByteStreamBufferError: Error {
    case invalidReadLength
    case bufferLimitExceeded
}

enum WebSocketByteStreamReadEvent: Equatable {
    case partial(length: Int, tag: Int)
    case data(Data, tag: Int)
}

final class WebSocketByteStreamBuffer {
    private struct ReadRequest {
        let length: Int
        let tag: Int
        var data: Data
    }

    private let maximumBufferedByteCount: Int
    private var buffer = Data()
    private var readRequests: [ReadRequest] = []

    init(maximumBufferedByteCount: Int) {
        self.maximumBufferedByteCount = maximumBufferedByteCount
    }

    var bufferedByteCount: Int {
        return self.buffer.count + self.readRequests.reduce(0, { $0 + $1.data.count })
    }

    func enqueueRead(length: Int, tag: Int) throws -> [WebSocketByteStreamReadEvent] {
        guard length > 0, length <= self.maximumBufferedByteCount else {
            throw WebSocketByteStreamBufferError.invalidReadLength
        }
        self.readRequests.append(ReadRequest(length: length, tag: tag, data: Data()))
        return self.processReadRequests()
    }

    func append(_ data: Data) throws -> [WebSocketByteStreamReadEvent] {
        guard !data.isEmpty else {
            return []
        }
        guard data.count <= self.maximumBufferedByteCount - self.bufferedByteCount else {
            throw WebSocketByteStreamBufferError.bufferLimitExceeded
        }
        self.buffer.append(data)
        return self.processReadRequests()
    }

    func reset() {
        self.buffer.removeAll(keepingCapacity: false)
        self.readRequests.removeAll(keepingCapacity: false)
    }

    private func processReadRequests() -> [WebSocketByteStreamReadEvent] {
        var events: [WebSocketByteStreamReadEvent] = []
        while !self.buffer.isEmpty && !self.readRequests.isEmpty {
            var request = self.readRequests.removeFirst()
            let readLength = min(request.length - request.data.count, self.buffer.count)
            guard readLength > 0 else {
                assertionFailure("Invalid WebSocket byte-stream read state")
                continue
            }

            request.data.append(self.buffer.prefix(readLength))
            self.buffer.removeFirst(readLength)
            events.append(.partial(length: readLength, tag: request.tag))

            if request.data.count == request.length {
                events.append(.data(request.data, tag: request.tag))
            } else {
                self.readRequests.insert(request, at: 0)
            }
        }
        return events
    }
}

enum WebSocketSendQueueError: Error {
    case queueLimitExceeded
}

enum WebSocketRelayTransportContract {
    static let usesIntermediateFormat = true
    static let usesMtProxySecret = false
    static let connectionType: UInt32 = 0xdddddddd
    static let initialReadLength = 4
}

enum WebSocketRelayDiagnostic {
    static let domain = "WSSRelay"

    static func errorFields(_ error: Error?) -> String {
        guard let error else {
            return "errorDomain=none errorCode=0"
        }
        let nsError = error as NSError
        return "errorDomain=\(self.safeDomain(nsError.domain)) errorCode=\(nsError.code)"
    }

    private static func safeDomain(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain,
             NSPOSIXErrorDomain,
             NSCocoaErrorDomain,
             NSOSStatusErrorDomain,
             "NSMachErrorDomain",
             "kCFErrorDomainCFNetwork",
             "TelegramCore.WebSocketTcpConnectionInterface":
            return domain
        default:
            return "other"
        }
    }
}

final class WebSocketSendQueue {
    private let maximumMessageSize: Int
    private let maximumQueuedByteCount: Int

    private var isOpen = false
    private var pendingMessages: [Data] = []
    private var inFlightMessage: Data?

    init(maximumMessageSize: Int, maximumQueuedByteCount: Int) {
        precondition(maximumMessageSize > 0)
        precondition(maximumQueuedByteCount >= maximumMessageSize)
        self.maximumMessageSize = maximumMessageSize
        self.maximumQueuedByteCount = maximumQueuedByteCount
    }

    var isSendInFlight: Bool {
        return self.inFlightMessage != nil
    }

    var queuedByteCount: Int {
        return (self.inFlightMessage?.count ?? 0) + self.pendingMessages.reduce(0, { $0 + $1.count })
    }

    func open() -> Data? {
        self.isOpen = true
        return self.takeNextMessageIfPossible()
    }

    func enqueue(_ data: Data) throws -> Data? {
        guard !data.isEmpty else {
            return nil
        }
        guard data.count <= self.maximumQueuedByteCount - self.queuedByteCount else {
            throw WebSocketSendQueueError.queueLimitExceeded
        }

        var offset = 0
        while offset < data.count {
            let length = min(self.maximumMessageSize, data.count - offset)
            self.pendingMessages.append(data.subdata(in: offset ..< offset + length))
            offset += length
        }
        return self.takeNextMessageIfPossible()
    }

    func didCompleteSend() -> Data? {
        precondition(self.inFlightMessage != nil)
        self.inFlightMessage = nil
        return self.takeNextMessageIfPossible()
    }

    func reset() {
        self.isOpen = false
        self.pendingMessages.removeAll(keepingCapacity: false)
        self.inFlightMessage = nil
    }

    private func takeNextMessageIfPossible() -> Data? {
        guard self.isOpen, self.inFlightMessage == nil, !self.pendingMessages.isEmpty else {
            return nil
        }
        let message = self.pendingMessages.removeFirst()
        self.inFlightMessage = message
        return message
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
final class WebSocketTcpConnectionInterface: NSObject, MTTcpConnectionInterface, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    static let webSocketProtocol = "telegram-mtproto-relay.v1"
    static let maximumMessageSize = 16 * 1024 * 1024
    static let maximumBufferedByteCount = 16 * 1024 * 1024

    private static let outgoingMessageSize = 64 * 1024
    private static let maximumQueuedSendByteCount = 32 * 1024 * 1024
    private static let errorDomain = "TelegramCore.WebSocketTcpConnectionInterface"

    private enum State {
        case idle
        case connecting
        case open
        case closed
    }

    private enum ErrorCode: Int {
        case invalidSettings = 1
        case invalidState
        case connectTimeout
        case redirectRejected
        case unexpectedSubprotocol
        case textMessageRejected
        case inputLimitExceeded
        case outputLimitExceeded
        case transportFailure
    }

    private final class DelegateToken {
        private let lock = NSLock()
        private weak var delegate: MTTcpConnectionInterfaceDelegate?
        private var isValid = true

        init(delegate: MTTcpConnectionInterfaceDelegate) {
            self.delegate = delegate
        }

        func invoke(on queue: DispatchQueue, _ f: @escaping (MTTcpConnectionInterfaceDelegate) -> Void) {
            queue.async { [weak self] in
                guard let self else {
                    return
                }
                self.lock.lock()
                let delegate = self.isValid ? self.delegate : nil
                self.lock.unlock()
                if let delegate {
                    f(delegate)
                }
            }
        }

        func invalidate() {
            self.lock.lock()
            self.isValid = false
            self.delegate = nil
            self.lock.unlock()
        }
    }

    private let settings: MTSocksProxySettings
    private let delegateQueue: DispatchQueue
    private let delegateToken: DelegateToken
    private let stateQueue = DispatchQueue(label: "org.telegram.WebSocketTcpConnectionInterface")

    private let receiveBuffer = WebSocketByteStreamBuffer(maximumBufferedByteCount: WebSocketTcpConnectionInterface.maximumBufferedByteCount)
    private let sendQueue = WebSocketSendQueue(maximumMessageSize: WebSocketTcpConnectionInterface.outgoingMessageSize, maximumQueuedByteCount: WebSocketTcpConnectionInterface.maximumQueuedSendByteCount)

    private var state: State = .idle
    private var generation: Int = 0
    private var didReportDisconnection = false
    private var receiveInFlight = false
    private var getLogPrefix: (() -> String)?
    private var didLogFirstWrite = false
    private var didLogFirstSendCompletion = false
    private var didLogFirstReceive = false
    private var writtenByteCount = 0
    private var sentMessageCount = 0
    private var sentByteCount = 0
    private var receivedMessageCount = 0
    private var receivedByteCount = 0

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var connectTimeoutWorkItem: DispatchWorkItem?

    private var usageCalculationInfo: MTNetworkUsageCalculationInfo?
    private var networkUsageManager: MTNetworkUsageManager?
    private var pathMonitor: NWPathMonitor?
    private var currentPathIsCellular = false

    init(settings: MTSocksProxySettings, delegate: MTTcpConnectionInterfaceDelegate, delegateQueue: DispatchQueue) {
        self.settings = settings
        self.delegateQueue = delegateQueue
        self.delegateToken = DelegateToken(delegate: delegate)
        super.init()
    }

    deinit {
        self.delegateToken.invalidate()
        self.connectTimeoutWorkItem?.cancel()
        self.pathMonitor?.cancel()
        self.task?.cancel()
        self.session?.invalidateAndCancel()
    }

    func setGetLogPrefix(_ getLogPrefix: (() -> String)?) {
        self.stateQueue.async { [weak self] in
            self?.getLogPrefix = getLogPrefix
        }
    }

    func setUsageCalculationInfo(_ usageCalculationInfo: MTNetworkUsageCalculationInfo?) {
        self.stateQueue.async { [weak self] in
            guard let self else {
                return
            }
            if self.usageCalculationInfo !== usageCalculationInfo {
                self.usageCalculationInfo = usageCalculationInfo
                if let usageCalculationInfo {
                    self.networkUsageManager = MTNetworkUsageManager(info: usageCalculationInfo)
                } else {
                    self.networkUsageManager = nil
                }
            }
        }
    }

    func connect(toHost inHost: String, onPort port: UInt16, viaInterface inInterface: String?, withTimeout timeout: TimeInterval, error errPtr: NSErrorPointer) -> Bool {
        guard inHost == self.settings.ip, port == self.settings.port, let path = self.settings.webSocketPath, let token = self.settings.webSocketToken, let url = ProxyServerWebSocketRelayValidation.validatedURL(host: inHost, port: Int32(port), path: path, token: token) else {
            errPtr?.pointee = Self.error(.invalidSettings)
            return false
        }

        let didStart: Bool = self.stateQueue.sync {
            guard self.state == .idle else {
                return false
            }

            self.state = .connecting
            self.generation += 1
            let generation = self.generation
            self.log("connect-start generation=\(generation) timeoutMs=\(Int(min(max(timeout, 1.0), 30.0) * 1000.0))")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil

            let boundedTimeout = min(max(timeout, 1.0), 30.0)
            configuration.timeoutIntervalForRequest = boundedTimeout
            configuration.timeoutIntervalForResource = boundedTimeout

            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: boundedTimeout)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.webSocketProtocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")

            let delegateOperationQueue = OperationQueue()
            delegateOperationQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateOperationQueue)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = Self.maximumMessageSize

            self.session = session
            self.task = task

            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { [weak self] path in
                self?.stateQueue.async {
                    guard let self, self.generation == generation, self.state != .closed else {
                        return
                    }
                    self.currentPathIsCellular = path.usesInterfaceType(.cellular)
                }
            }
            self.pathMonitor = pathMonitor
            pathMonitor.start(queue: self.stateQueue)

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation, self.state == .connecting else {
                    return
                }
                self.terminate(error: Self.error(.connectTimeout), closeCode: .goingAway)
            }
            self.connectTimeoutWorkItem = timeoutWorkItem
            self.stateQueue.asyncAfter(deadline: .now() + boundedTimeout, execute: timeoutWorkItem)

            task.resume()
            return true
        }

        if !didStart {
            errPtr?.pointee = Self.error(.invalidState)
        }
        return didStart
    }

    func write(_ data: Data) {
        self.stateQueue.async { [weak self] in
            guard let self, self.state == .connecting || self.state == .open else {
                return
            }
            self.writtenByteCount += data.count
            if !self.didLogFirstWrite {
                self.didLogFirstWrite = true
                self.log("first-write state=\(self.stateName) bytes=\(data.count) queuedBefore=\(self.sendQueue.queuedByteCount)")
            }
            do {
                if let message = try self.sendQueue.enqueue(data) {
                    self.send(message: message, generation: self.generation)
                }
            } catch {
                self.terminate(error: Self.error(.outputLimitExceeded), closeCode: .messageTooBig)
            }
        }
    }

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        guard length > 0, length <= UInt(Self.maximumBufferedByteCount) else {
            self.stateQueue.async { [weak self] in
                self?.terminate(error: Self.error(.inputLimitExceeded), closeCode: .messageTooBig)
            }
            return
        }
        let readLength = Int(length)
        self.stateQueue.async { [weak self] in
            guard let self, self.state != .closed else {
                return
            }
            do {
                let events = try self.receiveBuffer.enqueueRead(length: readLength, tag: tag)
                self.deliverReadEvents(events)
            } catch {
                self.terminate(error: Self.error(.inputLimitExceeded), closeCode: .messageTooBig)
            }
        }
    }

    func disconnect() {
        self.stateQueue.async { [weak self] in
            self?.terminate(error: nil, closeCode: .normalClosure)
        }
    }

    func resetDelegate() {
        self.delegateToken.invalidate()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        self.stateQueue.async { [weak self] in
            guard let self, self.task === webSocketTask, self.state == .connecting else {
                return
            }
            guard `protocol` == Self.webSocketProtocol else {
                self.log("open-rejected selectedProtocolMatches=0")
                self.terminate(error: Self.error(.unexpectedSubprotocol), closeCode: .protocolError)
                return
            }

            self.state = .open
            self.log("open selectedProtocolMatches=1 queuedBytes=\(self.sendQueue.queuedByteCount)")
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil

            self.delegateToken.invoke(on: self.delegateQueue) { delegate in
                delegate.connectionInterfaceDidConnect()
            }

            if let message = self.sendQueue.open() {
                self.send(message: message, generation: self.generation)
            }
            self.armReceive(generation: self.generation)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.stateQueue.async { [weak self] in
            guard let self, self.task === webSocketTask, self.state != .closed else {
                return
            }
            self.log("peer-close closeCode=\(closeCode.rawValue)")
            let error: NSError?
            if closeCode == .normalClosure || closeCode == .goingAway {
                error = nil
            } else {
                error = Self.error(.transportFailure)
            }
            self.terminate(error: error, closeCode: closeCode)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.stateQueue.async { [weak self] in
            guard let self, self.task === task, self.state != .closed else {
                return
            }
            self.log("task-complete \(WebSocketRelayDiagnostic.errorFields(error))")
            self.terminate(error: error == nil ? nil : Self.error(.transportFailure), closeCode: .goingAway)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        self.stateQueue.async { [weak self] in
            guard let self, self.task === task, self.state != .closed else {
                return
            }
            self.log("redirect-rejected statusCode=\(response.statusCode)")
            self.terminate(error: Self.error(.redirectRejected), closeCode: .policyViolation)
        }
    }

    private func send(message: Data, generation: Int) {
        guard let task = self.task, self.state == .open else {
            return
        }
        let isFirstMessage = self.sentMessageCount == 0
        self.sentMessageCount += 1
        self.sentByteCount += message.count
        if isFirstMessage {
            self.log("first-send-start bytes=\(message.count) queuedBytes=\(self.sendQueue.queuedByteCount)")
        }
        task.send(.data(message)) { [weak self] error in
            self?.stateQueue.async {
                guard let self, self.generation == generation, self.state == .open else {
                    return
                }
                if let error {
                    self.log("send-failed \(WebSocketRelayDiagnostic.errorFields(error))")
                    self.terminate(error: Self.error(.transportFailure), closeCode: .goingAway)
                    return
                }
                if !self.didLogFirstSendCompletion {
                    self.didLogFirstSendCompletion = true
                    self.log("first-send-complete bytes=\(message.count)")
                }

                self.networkUsageManager?.addOutgoingBytes(UInt(message.count), interface: self.currentPathIsCellular ? MTNetworkUsageManagerInterfaceWWAN : MTNetworkUsageManagerInterfaceOther)
                if let nextMessage = self.sendQueue.didCompleteSend() {
                    self.send(message: nextMessage, generation: generation)
                }
            }
        }
    }

    private func armReceive(generation: Int) {
        guard !self.receiveInFlight, let task = self.task, self.state == .open else {
            return
        }
        self.receiveInFlight = true
        task.receive { [weak self] result in
            self?.stateQueue.async {
                guard let self, self.generation == generation, self.state == .open else {
                    return
                }
                self.receiveInFlight = false

                switch result {
                case let .success(message):
                    switch message {
                    case let .data(data):
                        self.receivedMessageCount += 1
                        self.receivedByteCount += data.count
                        if !self.didLogFirstReceive {
                            self.didLogFirstReceive = true
                            self.log("first-receive bytes=\(data.count)")
                        }
                        self.networkUsageManager?.addIncomingBytes(UInt(data.count), interface: self.currentPathIsCellular ? MTNetworkUsageManagerInterfaceWWAN : MTNetworkUsageManagerInterfaceOther)
                        do {
                            let events = try self.receiveBuffer.append(data)
                            self.deliverReadEvents(events)
                            self.armReceive(generation: generation)
                        } catch {
                            self.terminate(error: Self.error(.inputLimitExceeded), closeCode: .messageTooBig)
                        }
                    case .string:
                        self.log("receive-rejected type=text")
                        self.terminate(error: Self.error(.textMessageRejected), closeCode: .unsupportedData)
                    @unknown default:
                        self.terminate(error: Self.error(.transportFailure), closeCode: .protocolError)
                    }
                case let .failure(error):
                    self.log("receive-failed \(WebSocketRelayDiagnostic.errorFields(error))")
                    self.terminate(error: Self.error(.transportFailure), closeCode: .goingAway)
                }
            }
        }
    }

    private func deliverReadEvents(_ events: [WebSocketByteStreamReadEvent]) {
        let networkType: Int32 = self.currentPathIsCellular ? 1 : 0
        for event in events {
            switch event {
            case let .partial(length, tag):
                self.delegateToken.invoke(on: self.delegateQueue) { delegate in
                    delegate.connectionInterfaceDidReadPartialData(ofLength: UInt(length), tag: tag)
                }
            case let .data(data, tag):
                self.delegateToken.invoke(on: self.delegateQueue) { delegate in
                    delegate.connectionInterfaceDidRead(data, withTag: tag, networkType: networkType)
                }
            }
        }
    }

    private func terminate(error: NSError?, closeCode: URLSessionWebSocketTask.CloseCode) {
        guard self.state != .closed else {
            return
        }
        let terminalState = self.stateName
        self.log("terminate state=\(terminalState) closeCode=\(closeCode.rawValue) \(WebSocketRelayDiagnostic.errorFields(error)) writtenBytes=\(self.writtenByteCount) sentMessages=\(self.sentMessageCount) sentBytes=\(self.sentByteCount) receivedMessages=\(self.receivedMessageCount) receivedBytes=\(self.receivedByteCount) firstSendComplete=\(self.didLogFirstSendCompletion ? 1 : 0) firstReceive=\(self.didLogFirstReceive ? 1 : 0)")
        self.state = .closed
        self.connectTimeoutWorkItem?.cancel()
        self.connectTimeoutWorkItem = nil
        self.receiveInFlight = false
        self.receiveBuffer.reset()
        self.sendQueue.reset()

        self.pathMonitor?.cancel()
        self.pathMonitor = nil

        let task = self.task
        self.task = nil
        task?.cancel(with: closeCode, reason: nil)

        let session = self.session
        self.session = nil
        session?.invalidateAndCancel()

        if !self.didReportDisconnection {
            self.didReportDisconnection = true
            self.delegateToken.invoke(on: self.delegateQueue) { delegate in
                delegate.connectionInterfaceDidDisconnectWithError(error)
            }
        }
    }

    private var stateName: String {
        switch self.state {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .open:
            return "open"
        case .closed:
            return "closed"
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        // Relay diagnostics are intentionally disabled in production builds.
    }

    private static func error(_ code: ErrorCode) -> NSError {
        return NSError(domain: self.errorDomain, code: code.rawValue)
    }
}