import Foundation
import SwiftSignalKit
import XCTest
@testable import TelegramCore

private final class RotationDeadline {
    let seconds: Double
    let subscriber: Subscriber<Void, NoError>
    var cancelled = false

    init(seconds: Double, subscriber: Subscriber<Void, NoError>) {
        self.seconds = seconds
        self.subscriber = subscriber
    }

    func fire() {
        self.subscriber.putNext(())
        self.subscriber.putCompletion()
    }
}

private final class RotationFixture {
    let settings: ValuePromise<ProxySettings>
    let status = ValuePromise<ConnectionStatus>(.connecting(proxyAddress: "one.example", proxyHasConnectionIssues: false))
    let active = ValuePromise<Bool>(true)
    var current: ProxySettings
    var deadlines: [RotationDeadline] = []
    var rotations: [ProxyServerSettings] = []
    var deferWrites = false
    var pendingWrite: (() -> Void)?
    let disposable = MetaDisposable()

    init(servers: [ProxyServerSettings]) {
        self.current = ProxySettings(enabled: true, servers: servers, activeServer: servers.first, useForCalls: false, autoRotationEnabled: true)
        self.settings = ValuePromise(self.current)
        self.disposable.set(proxyAutoRotation(settings: self.settings.get(), connectionStatus: self.status.get(), isActive: self.active.get(), wait: { [unowned self] seconds in
            return Signal { subscriber in
                let deadline = RotationDeadline(seconds: seconds, subscriber: subscriber)
                self.deadlines.append(deadline)
                return ActionDisposable { deadline.cancelled = true }
            }
        }, rotate: { [unowned self] expected, isValid in
            return Signal { subscriber in
                let write = {
                    // Model the asynchronous AccountManager persistence boundary.
                    if isValid(), self.current == expected, let next = self.current.nextAutoRotationServer {
                        self.rotations.append(next)
                        self.update { $0.activeServer = next }
                    }
                    subscriber.putCompletion()
                }
                if self.deferWrites {
                    self.pendingWrite = write
                } else {
                    write()
                }
                return EmptyDisposable
            }
        }).start())
    }

    func update(_ f: (inout ProxySettings) -> Void) {
        f(&self.current)
        self.settings.set(self.current)
    }

    deinit {
        self.disposable.dispose()
    }
}

final class ProxyAutoRotationTests: XCTestCase {
    private var servers: [ProxyServerSettings] {
        return ["one.example", "two.example", "three.example"].map {
            ProxyServerSettings(host: $0, port: 443, connection: .webSocketRelay(path: "/relay", token: "test-token"))
        }
    }

    func testSavedSettingsAreBackwardCompatibleAndValidateThePeriod() throws {
        let legacy = Data(#"{"enabled":0,"servers":[],"useForCalls":0}"#.utf8)
        let defaults = try JSONDecoder().decode(ProxySettings.self, from: legacy)
        XCTAssertFalse(defaults.autoRotationEnabled)
        XCTAssertEqual(defaults.autoRotationPeriod, .seconds10)

        for period in ProxyAutoRotationPeriod.allCases {
            let settings = ProxySettings(enabled: true, servers: self.servers, activeServer: self.servers[1], useForCalls: false, autoRotationEnabled: true, autoRotationPeriod: period)
            XCTAssertEqual(try JSONDecoder().decode(ProxySettings.self, from: JSONEncoder().encode(settings)), settings)
        }
        for value in [0, 4, 7, 61, 999] {
            let data = Data("{\"enabled\":0,\"servers\":[],\"autoRotationPeriod\":\(value)}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(ProxySettings.self, from: data).autoRotationPeriod, .seconds10)
        }
    }

    func testFailedProxiesCycleInOrderAndSuccessfulConnectionStopsRotation() {
        Queue.mainQueue().sync {
            let fixture = RotationFixture(servers: self.servers)
            XCTAssertTrue(fixture.rotations.isEmpty)
            XCTAssertEqual(fixture.deadlines.last?.seconds, 10)
            for _ in 0 ..< 4 {
                fixture.deadlines.last?.fire()
            }
            XCTAssertEqual(fixture.rotations, [self.servers[1], self.servers[2], self.servers[0], self.servers[1]])
            let deadline = fixture.deadlines.last
            fixture.status.set(.online(proxyAddress: self.servers[1].host))
            XCTAssertEqual(deadline?.cancelled, true)
            deadline?.fire()
            XCTAssertEqual(fixture.rotations.count, 4)
            XCTAssertEqual(fixture.current.activeServer, self.servers[1])
        }
    }

    func testConnectionIssueUpdatesDoNotPostponeTheDeadline() {
        Queue.mainQueue().sync {
            let fixture = RotationFixture(servers: self.servers)
            fixture.status.set(.connecting(proxyAddress: "one.example", proxyHasConnectionIssues: true))
            fixture.status.set(.connecting(proxyAddress: "one.example", proxyHasConnectionIssues: false))
            XCTAssertEqual(fixture.deadlines.count, 1)
            XCTAssertFalse(fixture.deadlines[0].cancelled)
            fixture.deadlines[0].fire()
            XCTAssertEqual(fixture.current.activeServer, self.servers[1])
        }
    }

    func testUpdatingOfflineAndBackgroundCancelAndResumeWithAFullPeriod() {
        Queue.mainQueue().sync {
            let fixture = RotationFixture(servers: self.servers)
            for status: ConnectionStatus in [.updating(proxyAddress: "one.example"), .waitingForNetwork, .online(proxyAddress: "one.example")] {
                let deadline = fixture.deadlines.last
                fixture.status.set(status)
                XCTAssertEqual(deadline?.cancelled, true)
                deadline?.fire()
                XCTAssertTrue(fixture.rotations.isEmpty)
                fixture.status.set(.connecting(proxyAddress: "one.example", proxyHasConnectionIssues: false))
                XCTAssertEqual(fixture.deadlines.last?.seconds, 10)
                XCTAssertEqual(fixture.deadlines.last?.cancelled, false)
            }
            let deadline = fixture.deadlines.last
            fixture.active.set(false)
            XCTAssertEqual(deadline?.cancelled, true)
            deadline?.fire()
            XCTAssertTrue(fixture.rotations.isEmpty)
            fixture.active.set(true)
            fixture.deadlines.last?.fire()
            XCTAssertEqual(fixture.rotations, [self.servers[1]])
        }
    }

    func testManualSelectionPeriodAndListChangesReplaceTheDeadline() {
        Queue.mainQueue().sync {
            let fixture = RotationFixture(servers: self.servers)
            let original = fixture.deadlines.last
            fixture.update {
                $0.activeServer = self.servers[2]
                $0.autoRotationPeriod = .seconds45
            }
            XCTAssertEqual(original?.cancelled, true)
            original?.fire()
            XCTAssertTrue(fixture.rotations.isEmpty)
            XCTAssertEqual(fixture.deadlines.last?.seconds, 45)
            fixture.update { $0.servers = [self.servers[2], self.servers[1], self.servers[0]] }
            fixture.deadlines.last?.fire()
            XCTAssertEqual(fixture.rotations, [self.servers[1]])
        }
    }

    func testDisabledOrInsufficientProxyListCancelsRotation() {
        Queue.mainQueue().sync {
            let fixture = RotationFixture(servers: self.servers)
            let deadline = fixture.deadlines.last
            fixture.update { $0.autoRotationEnabled = false }
            deadline?.fire()
            XCTAssertTrue(fixture.rotations.isEmpty)
            fixture.update { $0.autoRotationEnabled = true }
            fixture.update { $0.enabled = false }
            XCTAssertEqual(fixture.deadlines.last?.cancelled, true)
            fixture.update {
                $0.enabled = true
                $0.servers = [self.servers[0], self.servers[0]]
            }
            XCTAssertNil(fixture.current.nextAutoRotationServer)
            XCTAssertEqual(fixture.deadlines.last?.cancelled, true)
            fixture.update { $0.servers = [self.servers[1], self.servers[2]] }
            XCTAssertNil(fixture.current.nextAutoRotationServer)
        }
    }

    func testMixedTypesAndDuplicateEntriesKeepVisibleListOrder() {
        let socks = ProxyServerSettings(host: "socks.example", port: 1080, connection: .socks5(username: nil, password: nil))
        let web = ProxyServerSettings(host: "web.example", port: 443, connection: .web(secret: Data(repeating: 1, count: 16), path: "relay"))
        Queue.mainQueue().sync {
            let fixture = RotationFixture(servers: [self.servers[0], socks, self.servers[0], web, socks])
            for _ in 0 ..< 3 {
                fixture.deadlines.last?.fire()
            }
            XCTAssertEqual(fixture.rotations, [socks, web, self.servers[0]])
        }
    }

    func testQueuedWriteIsInvalidatedByReconnectOrOwnerDisposal() {
        Queue.mainQueue().sync {
            let fixture = RotationFixture(servers: self.servers)
            fixture.deferWrites = true
            fixture.deadlines.last?.fire()
            XCTAssertNotNil(fixture.pendingWrite)
            fixture.status.set(.online(proxyAddress: "one.example"))
            fixture.pendingWrite?()
            fixture.pendingWrite = nil
            XCTAssertTrue(fixture.rotations.isEmpty)

            fixture.status.set(.connecting(proxyAddress: "one.example", proxyHasConnectionIssues: false))
            fixture.deadlines.last?.fire()
            fixture.disposable.dispose()
            fixture.pendingWrite?()
            fixture.pendingWrite = nil
            XCTAssertTrue(fixture.rotations.isEmpty)
        }
    }
}
