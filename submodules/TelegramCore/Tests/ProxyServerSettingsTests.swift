import Foundation
import XCTest
import MtProtoKit
import SwiftSignalKit
@testable import TelegramCore

private final class ManagedProxySettingsTestHarness {
    private(set) var currentSettings: MTSocksProxySettings?
    private(set) var updateCount: Int = 0
    private(set) var connectionStatusDropCount: Int = 0

    init(currentSettings: MTSocksProxySettings?) {
        self.currentSettings = currentSettings
    }

    func update(
        settings: MTSocksProxySettings?,
        shouldUpdate: @escaping (MTSocksProxySettings?) -> Bool
    ) {
        if shouldUpdate(self.currentSettings) {
            self.connectionStatusDropCount += 1
            self.updateCount += 1
            self.currentSettings = settings
        }
    }
}

final class ProxyServerSettingsTests: XCTestCase {
    private func token(byteCount: Int = 32) -> String {
        let data = Data((0 ..< byteCount).map { UInt8($0 & 0xff) })
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    func testLegacySocks5FixtureDecodesUnchanged() throws {
        let data = Data(#"{"_t":0,"username":"alice","password":"secret"}"#.utf8)
        let connection = try JSONDecoder().decode(ProxyServerConnection.self, from: data)
        XCTAssertEqual(connection, .socks5(username: "alice", password: "secret"))
    }
    
    func testLegacyMtProxyFixtureDecodesUnchanged() throws {
        let data = Data(#"{"_t":1,"secret":"AQIDBA=="}"#.utf8)
        let connection = try JSONDecoder().decode(ProxyServerConnection.self, from: data)
        XCTAssertEqual(connection, .mtp(secret: Data([1, 2, 3, 4])))
    }
    
    func testUnknownConnectionDiscriminatorKeepsSafeFallback() throws {
        let data = Data(#"{"_t":99}"#.utf8)
        let connection = try JSONDecoder().decode(ProxyServerConnection.self, from: data)
        XCTAssertEqual(connection, .socks5(username: nil, password: nil))
    }
    
    func testWebSocketRelaySettingsRoundTrip() throws {
        let settings = ProxyServerSettings(
            host: "relay.example.com",
            port: 443,
            connection: .webSocketRelay(path: "/relay/v1/0123456789abcdef", token: self.token())
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ProxyServerSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let connection = try XCTUnwrap(object["connection"] as? [String: Any])
        XCTAssertEqual(connection["_t"] as? Int, 2)
        XCTAssertEqual(connection["webSocketPath"] as? String, "/relay/v1/0123456789abcdef")
        XCTAssertEqual(connection["webSocketToken"] as? String, self.token())
    }
    
    func testWebSocketRelayConfigurationLinkRoundTrip() throws {
        let settings = ProxyServerSettings(
            host: "relay.example.com",
            port: 443,
            connection: .webSocketRelay(path: "/relay/v1/0123456789abcdef", token: self.token())
        )
        let link = try XCTUnwrap(ProxyServerWebSocketRelayConfigurationLink.string(for: settings))
        XCTAssertTrue(link.hasPrefix("tg://wssproxy?"))
        XCTAssertEqual(ProxyServerWebSocketRelayConfigurationLink.parse(link), settings)
        XCTAssertNil(ProxyServerWebSocketRelayValidation.validatedURL(host: settings.host, port: settings.port, path: "/relay/v1/0123456789abcdef", token: self.token())?.query)
    }

    func testWebSocketRelayConfigurationLinkRejectsMalformedOrMixedParameters() throws {
        let token = self.token()
        let valid = "tg://wssproxy?server=relay.example.com&port=443&path=%2Frelay%2Fv1%2Fa&token=\(token)"
        XCTAssertNotNil(ProxyServerWebSocketRelayConfigurationLink.parse(valid))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse("https://wssproxy?server=relay.example.com&port=443&path=%2Frelay%2Fv1%2Fa&token=\(token)"))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse("tg://proxy?server=relay.example.com&port=443&path=%2Frelay%2Fv1%2Fa&token=\(token)"))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse("tg://wssproxy?server=relay.example.com&port=443&path=%2Frelay%2Fv1%2Fa"))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse(valid + "&server=other.example.com"))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse(valid + "&secret=001122"))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse(valid + "&username=user"))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse(valid.replacingOccurrences(of: "port=443", with: "port=0443")))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.parse(valid.replacingOccurrences(of: "%2Frelay%2Fv1%2Fa", with: "%2Frelay%2F..%2Fa")))
    }

    func testWebSocketRelayConfigurationLinkSerializerRejectsOtherProxyModes() {
        let socks = ProxyServerSettings(host: "relay.example.com", port: 443, connection: .socks5(username: nil, password: nil))
        let mtp = ProxyServerSettings(host: "relay.example.com", port: 443, connection: .mtp(secret: Data(repeating: 1, count: 16)))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.string(for: socks))
        XCTAssertNil(ProxyServerWebSocketRelayConfigurationLink.string(for: mtp))
    }

    func testWebSocketRelayBridgeUsesDedicatedFieldsAndRedactsToken() {
        let token = self.token()
        let settings = ProxyServerSettings(
            host: "relay.example.com",
            port: 443,
            connection: .webSocketRelay(path: "/relay/v1/0123456789abcdef", token: token)
        ).mtProxySettings
        
        XCTAssertEqual(settings.ip, "relay.example.com")
        XCTAssertEqual(settings.port, 443)
        XCTAssertNil(settings.username)
        XCTAssertNil(settings.password)
        XCTAssertNil(settings.secret)
        XCTAssertEqual(settings.webSocketPath, "/relay/v1/0123456789abcdef")
        XCTAssertEqual(settings.webSocketToken, token)
        XCTAssertFalse(settings.description.contains(token))
        XCTAssertTrue(settings.description.contains("<redacted>"))
    }
    
    func testWebSocketRelayBridgeEqualityIncludesPathAndToken() {
        let token = self.token()
        let settings = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/a", webSocketToken: token)
        let same = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/a", webSocketToken: token)
        let differentPath = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/b", webSocketToken: token)
        let differentToken = MTSocksProxySettings(ip: "relay.example.com", port: 443, webSocketPath: "/relay/v1/a", webSocketToken: self.token(byteCount: 33))
        
        XCTAssertTrue(settings.isEqual(same))
        XCTAssertFalse(settings.isEqual(differentPath))
        XCTAssertFalse(settings.isEqual(differentToken))
    }
    
    func testManagedProxySettingsSuppressesInitialNilAndEquivalentSettings() {
        let settingsPipe = ValuePipe<MTSocksProxySettings?>()
        let harness = ManagedProxySettingsTestHarness(currentSettings: nil)
        let disposable = managedProxySettings(settingsPipe.signal(), update: harness.update)
        defer {
            disposable.dispose()
        }

        settingsPipe.putNext(nil)
        XCTAssertEqual(harness.updateCount, 0)
        XCTAssertEqual(harness.connectionStatusDropCount, 0)

        let settings = MTSocksProxySettings(
            ip: "relay.example.com",
            port: 443,
            webSocketPath: "/relay/test/a",
            webSocketToken: self.token()
        )
        settingsPipe.putNext(settings)
        XCTAssertEqual(harness.updateCount, 1)
        XCTAssertEqual(harness.connectionStatusDropCount, 1)
        XCTAssertTrue(harness.currentSettings?.isEqual(settings) == true)

        settingsPipe.putNext(MTSocksProxySettings(
            ip: "relay.example.com",
            port: 443,
            webSocketPath: "/relay/test/a",
            webSocketToken: self.token()
        ))
        XCTAssertEqual(harness.updateCount, 1)
        XCTAssertEqual(harness.connectionStatusDropCount, 1)
    }

    func testManagedProxySettingsDetectsEveryWebSocketIdentityChange() {
        let token = self.token()
        let initial = MTSocksProxySettings(
            ip: "relay.example.com",
            port: 443,
            webSocketPath: "/relay/test/a",
            webSocketToken: token
        )
        let settingsPipe = ValuePipe<MTSocksProxySettings?>()
        let harness = ManagedProxySettingsTestHarness(currentSettings: initial)
        let disposable = managedProxySettings(settingsPipe.signal(), update: harness.update)
        defer {
            disposable.dispose()
        }

        settingsPipe.putNext(MTSocksProxySettings(
            ip: "relay.example.com",
            port: 443,
            webSocketPath: "/relay/test/a",
            webSocketToken: token
        ))
        XCTAssertEqual(harness.updateCount, 0)
        XCTAssertEqual(harness.connectionStatusDropCount, 0)

        let replacements = [
            MTSocksProxySettings(ip: "other.example.com", port: 443, webSocketPath: "/relay/test/a", webSocketToken: token),
            MTSocksProxySettings(ip: "other.example.com", port: 8443, webSocketPath: "/relay/test/a", webSocketToken: token),
            MTSocksProxySettings(ip: "other.example.com", port: 8443, webSocketPath: "/relay/test/b", webSocketToken: token),
            MTSocksProxySettings(ip: "other.example.com", port: 8443, webSocketPath: "/relay/test/b", webSocketToken: self.token(byteCount: 33))
        ]
        for (index, replacement) in replacements.enumerated() {
            settingsPipe.putNext(replacement)
            XCTAssertEqual(harness.updateCount, index + 1)
            XCTAssertEqual(harness.connectionStatusDropCount, index + 1)
            XCTAssertTrue(harness.currentSettings?.isEqual(replacement) == true)
        }
    }

    func testManagedProxySettingsSwitchesProxyTypesAndDisablesProxy() {
        let webSocket = MTSocksProxySettings(
            ip: "relay.example.com",
            port: 443,
            webSocketPath: "/relay/test/a",
            webSocketToken: self.token()
        )
        let socks5 = MTSocksProxySettings(
            ip: "proxy.example.com",
            port: 1080,
            username: "synthetic-user",
            password: "synthetic-password",
            secret: nil
        )
        let mtProxy = MTSocksProxySettings(
            ip: "mtp.example.com",
            port: 443,
            username: nil,
            password: nil,
            secret: Data(repeating: 1, count: 16)
        )
        let settingsPipe = ValuePipe<MTSocksProxySettings?>()
        let harness = ManagedProxySettingsTestHarness(currentSettings: webSocket)
        let disposable = managedProxySettings(settingsPipe.signal(), update: harness.update)
        defer {
            disposable.dispose()
        }

        settingsPipe.putNext(socks5)
        XCTAssertEqual(harness.updateCount, 1)
        XCTAssertTrue(harness.currentSettings?.isEqual(socks5) == true)

        settingsPipe.putNext(mtProxy)
        XCTAssertEqual(harness.updateCount, 2)
        XCTAssertTrue(harness.currentSettings?.isEqual(mtProxy) == true)

        settingsPipe.putNext(nil)
        XCTAssertEqual(harness.updateCount, 3)
        XCTAssertEqual(harness.connectionStatusDropCount, 3)
        XCTAssertNil(harness.currentSettings)
    }

    func testManagedProxySettingsDisposalStopsUpdates() {
        let settingsPipe = ValuePipe<MTSocksProxySettings?>()
        let harness = ManagedProxySettingsTestHarness(currentSettings: nil)
        let disposable = managedProxySettings(settingsPipe.signal(), update: harness.update)

        disposable.dispose()
        settingsPipe.putNext(MTSocksProxySettings(
            ip: "relay.example.com",
            port: 443,
            webSocketPath: "/relay/test/a",
            webSocketToken: self.token()
        ))
        XCTAssertEqual(harness.updateCount, 0)
        XCTAssertEqual(harness.connectionStatusDropCount, 0)
    }

    func testWebSocketRelayValidationAcceptsCanonicalSettings() throws {
        let token = self.token()
        let url = try XCTUnwrap(ProxyServerWebSocketRelayValidation.validatedURL(
            host: "relay.example.com",
            port: 443,
            path: "/relay/v1/0123456789abcdef",
            token: token
        ))
        XCTAssertEqual(url.absoluteString, "wss://relay.example.com:443/relay/v1/0123456789abcdef")
        XCTAssertFalse(url.absoluteString.contains(token))
    }
    
    func testWebSocketRelayValidationRejectsInvalidHostsAndPorts() {
        let token = self.token()
        let invalidHosts = [
            "",
            "localhost",
            "127.0.0.1",
            "relay..example.com",
            "-relay.example.com",
            "relay-.example.com",
            "relay.example.com.",
            "relay_1.example.com",
            "релей.example.com"
        ]
        for host in invalidHosts {
            XCTAssertFalse(ProxyServerWebSocketRelayValidation.isValid(host: host, port: 443, path: "/relay/v1/a", token: token), host)
        }
        XCTAssertFalse(ProxyServerWebSocketRelayValidation.isValid(host: "relay.example.com", port: 0, path: "/relay/v1/a", token: token))
        XCTAssertFalse(ProxyServerWebSocketRelayValidation.isValid(host: "relay.example.com", port: 65536, path: "/relay/v1/a", token: token))
    }
    
    func testWebSocketRelayValidationRejectsInvalidPaths() {
        let token = self.token()
        let invalidPaths = [
            "",
            "relay/v1/a",
            "/relay/v1/a?query",
            "/relay/v1/a#fragment",
            "/relay/v1/%61",
            "/relay/v1/../a",
            "/relay/v1/./a",
            "/relay/v1/a\r\nInjected: value",
            "/relay/v1/релей"
        ]
        for path in invalidPaths {
            XCTAssertFalse(ProxyServerWebSocketRelayValidation.isValid(host: "relay.example.com", port: 443, path: path, token: token), path)
        }
        let oversizedPath = "/" + String(repeating: "a", count: ProxyServerWebSocketRelayValidation.maximumPathLength)
        XCTAssertFalse(ProxyServerWebSocketRelayValidation.isValid(host: "relay.example.com", port: 443, path: oversizedPath, token: token))
    }
    
    func testWebSocketRelayValidationRejectsInvalidTokens() {
        let invalidTokens = [
            "",
            self.token(byteCount: 31),
            self.token(byteCount: 65),
            self.token() + "=",
            "+" + self.token().dropFirst(),
            self.token() + "\r\nInjected: value"
        ]
        for token in invalidTokens {
            XCTAssertFalse(ProxyServerWebSocketRelayValidation.isValid(host: "relay.example.com", port: 443, path: "/relay/v1/a", token: token), token)
        }
    }
}
