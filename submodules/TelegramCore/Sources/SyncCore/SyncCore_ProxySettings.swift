import Foundation
import Postbox

public enum ProxyServerConnection: Equatable, Hashable, Codable {
    case socks5(username: String?, password: String?)
    case mtp(secret: Data)
    case web(secret: Data, path: String)
    case webSocketRelay(path: String, token: String)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        switch try container.decode(Int32.self, forKey: "_t") {
            case 0:
                self = .socks5(username: try container.decodeIfPresent(String.self, forKey: "username"), password: try container.decodeIfPresent(String.self, forKey: "password"))
            case 1:
                self = .mtp(secret: try container.decode(Data.self, forKey: "secret"))
            case 2:
                // The 12.9.2 fork used 2 for WSS before upstream assigned it to WEB.
                // Either legacy WSS key selects that format; a partial record must not
                // be reinterpreted as a different transport.
                if container.contains("webSocketPath") || container.contains("webSocketToken") {
                    self = .webSocketRelay(path: try container.decode(String.self, forKey: "webSocketPath"), token: try container.decode(String.self, forKey: "webSocketToken"))
                } else {
                    self = .web(secret: try container.decode(Data.self, forKey: "secret"), path: "")
                }
            case 3:
                self = .web(secret: try container.decode(Data.self, forKey: "secret"), path: try container.decode(String.self, forKey: "path"))
            case 4:
                self = .webSocketRelay(path: try container.decode(String.self, forKey: "webSocketPath"), token: try container.decode(String.self, forKey: "webSocketToken"))
            default:
                self = .socks5(username: nil, password: nil)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        switch self {
            case let .socks5(username, password):
                try container.encode(0 as Int32, forKey: "_t")
                try container.encodeIfPresent(username, forKey: "username")
                try container.encodeIfPresent(password, forKey: "password")
            case let .mtp(secret):
                try container.encode(1 as Int32, forKey: "_t")
                try container.encode(secret, forKey: "secret")
            case let .web(secret, path):
                if path.isEmpty {
                    try container.encode(2 as Int32, forKey: "_t")
                    try container.encode(secret, forKey: "secret")
                } else {
                    try container.encode(3 as Int32, forKey: "_t")
                    try container.encode(secret, forKey: "secret")
                    try container.encode(path, forKey: "path")
                }
            case let .webSocketRelay(path, token):
                try container.encode(4 as Int32, forKey: "_t")
                try container.encode(path, forKey: "webSocketPath")
                try container.encode(token, forKey: "webSocketToken")
        }
    }
}

public enum ProxyServerWebSocketRelayValidation {
    public static let maximumHostLength = 253
    public static let maximumPathLength = 2048
    public static let minimumTokenByteCount = 32
    public static let maximumTokenByteCount = 64
    public static let maximumTokenLength = 86

    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= self.maximumHostLength, !host.hasSuffix(".") else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return false
        }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else {
                return false
            }
            for byte in label.utf8 {
                guard (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 else {
                    return false
                }
            }
        }
        if host.utf8.allSatisfy({ byte in
            return (byte >= 48 && byte <= 57) || byte == 46
        }) {
            return false
        }
        return true
    }

    public static func isValidPort(_ port: Int32) -> Bool {
        return port >= 1 && port <= 65535
    }

    public static func isValidPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= self.maximumPathLength else {
            return false
        }
        for byte in path.utf8 {
            guard (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 47 || byte == 95 || byte == 126 else {
                return false
            }
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component == "." || component == ".." {
                return false
            }
        }
        return true
    }

    public static func isValidToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.utf8.count <= self.maximumTokenLength else {
            return false
        }
        for byte in token.utf8 {
            guard (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 95 else {
                return false
            }
        }
        guard token.utf8.count % 4 != 1 else {
            return false
        }
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4))
        guard let decoded = Data(base64Encoded: base64), decoded.count >= self.minimumTokenByteCount, decoded.count <= self.maximumTokenByteCount else {
            return false
        }
        let canonical = decoded.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == token
    }

    public static func validatedURL(host: String, port: Int32, path: String, token: String) -> URL? {
        guard self.isValidHost(host), self.isValidPort(port), self.isValidPath(path), self.isValidToken(token) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = Int(port)
        components.percentEncodedPath = path
        guard let url = components.url, let parsedComponents = URLComponents(url: url, resolvingAgainstBaseURL: false), parsedComponents.scheme == "wss", parsedComponents.host?.caseInsensitiveCompare(host) == .orderedSame, parsedComponents.port == Int(port), parsedComponents.percentEncodedPath == path, parsedComponents.user == nil, parsedComponents.password == nil, parsedComponents.query == nil, parsedComponents.fragment == nil else {
            return nil
        }
        return url
    }

    public static func isValid(host: String, port: Int32, path: String, token: String) -> Bool {
        return self.validatedURL(host: host, port: port, path: path, token: token) != nil
    }
}

public enum ProxyServerWebSocketRelayConfigurationLink {
    public static let scheme = "tg"
    public static let host = "wssproxy"

    public static func string(for settings: ProxyServerSettings) -> String? {
        guard case let .webSocketRelay(path, token) = settings.connection, ProxyServerWebSocketRelayValidation.isValid(host: settings.host, port: settings.port, path: path, token: token) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = self.scheme
        components.host = self.host
        components.queryItems = [
            URLQueryItem(name: "server", value: settings.host),
            URLQueryItem(name: "port", value: "\(settings.port)"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "token", value: token)
        ]
        return components.string
    }

    public static func parse(_ value: String) -> ProxyServerSettings? {
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == self.scheme, components.host?.lowercased() == self.host, components.user == nil, components.password == nil, components.path.isEmpty, components.fragment == nil, let queryItems = components.queryItems, queryItems.count == 4 else {
            return nil
        }
        var values: [String: String] = [:]
        let expectedNames: Set<String> = ["server", "port", "path", "token"]
        for item in queryItems {
            guard expectedNames.contains(item.name), values[item.name] == nil, let value = item.value else {
                return nil
            }
            values[item.name] = value
        }
        guard values.count == expectedNames.count, let server = values["server"], let portString = values["port"], let port = Int32(portString), String(port) == portString, let path = values["path"], let token = values["token"], ProxyServerWebSocketRelayValidation.isValid(host: server, port: port, path: path, token: token) else {
            return nil
        }
        return ProxyServerSettings(host: server, port: port, connection: .webSocketRelay(path: path, token: token))
    }
}

public struct ProxyServerSettings: Codable, Equatable, Hashable {
    public let host: String
    public let port: Int32
    public let connection: ProxyServerConnection
    
    public init(host: String, port: Int32, connection: ProxyServerConnection) {
        self.host = host
        if case .web = connection {
            self.port = 443
        } else {
            self.port = port
        }
        self.connection = connection
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        let host = (try? container.decode(String.self, forKey: "host")) ?? ""
        let port = (try? container.decode(Int32.self, forKey: "port")) ?? 0
        let connection: ProxyServerConnection
        if let username = try container.decodeIfPresent(String.self, forKey: "username") {
            connection = .socks5(username: username, password: try container.decodeIfPresent(String.self, forKey: "password"))
        } else {
            connection = (try? container.decodeIfPresent(ProxyServerConnection.self, forKey: "connection")) ?? ProxyServerConnection.socks5(username: nil, password: nil)
        }
        self.init(host: host, port: port, connection: connection)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode(self.host, forKey: "host")
        try container.encode(self.port, forKey: "port")
        try container.encode(self.connection, forKey: "connection")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.host)
        hasher.combine(self.port)
        hasher.combine(self.connection)
    }
}

/// The supported reconnect deadlines before trying the next saved proxy.
public enum ProxyAutoRotationPeriod: Int32, CaseIterable {
    case seconds5 = 5
    case seconds10 = 10
    case seconds15 = 15
    case seconds30 = 30
    case seconds45 = 45
    case seconds60 = 60
}

public struct ProxySettings: Codable, Equatable {
    public var enabled: Bool
    public var servers: [ProxyServerSettings]
    public var activeServer: ProxyServerSettings?
    public var useForCalls: Bool
    public var autoRotationEnabled: Bool
    public var autoRotationPeriod: ProxyAutoRotationPeriod
    
    public static var defaultSettings: ProxySettings {
        return ProxySettings(enabled: false, servers: [], activeServer: nil, useForCalls: false)
    }
    
    public init(enabled: Bool, servers: [ProxyServerSettings], activeServer: ProxyServerSettings?, useForCalls: Bool, autoRotationEnabled: Bool = false, autoRotationPeriod: ProxyAutoRotationPeriod = .seconds10) {
        self.enabled = enabled
        self.servers = servers
        self.activeServer = activeServer
        self.useForCalls = useForCalls
        self.autoRotationEnabled = autoRotationEnabled
        self.autoRotationPeriod = autoRotationPeriod
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.enabled = ((try? container.decode(Int32.self, forKey: "enabled")) ?? 0) != 0
        self.servers = try container.decode([ProxyServerSettings].self, forKey: "servers")
        self.activeServer = try container.decodeIfPresent(ProxyServerSettings.self, forKey: "activeServer")
        self.useForCalls = ((try? container.decode(Int32.self, forKey: "useForCalls")) ?? 0) != 0
        self.autoRotationEnabled = ((try? container.decode(Int32.self, forKey: "autoRotationEnabled")) ?? 0) != 0
        self.autoRotationPeriod = ProxyAutoRotationPeriod(rawValue: (try? container.decode(Int32.self, forKey: "autoRotationPeriod")) ?? 10) ?? .seconds10
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode((self.enabled ? 1 : 0) as Int32, forKey: "enabled")
        try container.encode(self.servers, forKey: "servers")
        try container.encodeIfPresent(self.activeServer, forKey: "activeServer")
        try container.encode((self.useForCalls ? 1 : 0) as Int32, forKey: "useForCalls")
        try container.encode((self.autoRotationEnabled ? 1 : 0) as Int32, forKey: "autoRotationEnabled")
        try container.encode(self.autoRotationPeriod.rawValue, forKey: "autoRotationPeriod")
    }
    
    public var effectiveActiveServer: ProxyServerSettings? {
        if self.enabled, let activeServer = self.activeServer {
            return activeServer
        } else {
            return nil
        }
    }

    /// The next distinct saved proxy, wrapping in the same order as the proxy list.
    public var nextAutoRotationServer: ProxyServerSettings? {
        guard self.autoRotationEnabled, let activeServer = self.effectiveActiveServer else {
            return nil
        }
        var seen = Set<ProxyServerSettings>()
        let servers = self.servers.filter { seen.insert($0).inserted }
        guard servers.count > 1, let index = servers.firstIndex(of: activeServer) else {
            return nil
        }
        return servers[(index + 1) % servers.count]
    }
}
