import Foundation
import Postbox
import SwiftSignalKit

/// Own one subscription in the main app: proxy settings are shared by every account.
/// Switching accounts disposes the old account's deadline before observing the new one.
public func managedProxyAutoRotation(accountManager: AccountManager<TelegramAccountManagerTypes>, network: Signal<Network?, NoError>, inForeground: Signal<Bool, NoError>) -> Signal<Never, NoError> {
    let settings = accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
    |> map { $0.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? .defaultSettings }

    return network
    |> distinctUntilChanged(isEqual: { $0 === $1 })
    |> deliverOnMainQueue
    |> mapToSignal { network -> Signal<Never, NoError> in
        guard let network else {
            return .never()
        }
        let isActive = combineLatest(inForeground, network.shouldKeepConnection.get())
        |> map { $0 && $1 }
        return proxyAutoRotation(settings: settings, connectionStatus: network.connectionStatus, isActive: isActive, rotate: { expected, isValid in
            return updateProxySettingsInteractively(accountManager: accountManager, { current in
                // A timer must never overwrite a manual selection, edited list, or a
                // successful reconnect that arrived while this transaction was queued.
                guard isValid(), current == expected, let next = current.nextAutoRotationServer else {
                    return current
                }
                var updated = current
                updated.activeServer = next
                return updated
            })
            |> map { _ in () }
        })
    }
}

// The injected wait lets integration tests drive the real subscription/cancellation
// flow without sleeping through each user-configured reconnect period.
func proxyAutoRotation(settings: Signal<ProxySettings, NoError>, connectionStatus: Signal<ConnectionStatus, NoError>, isActive: Signal<Bool, NoError>, wait: @escaping (Double) -> Signal<Void, NoError> = { seconds in
    return Signal<Void, NoError>.single(()) |> delay(seconds, queue: Queue.mainQueue())
}, rotate: @escaping (ProxySettings, @escaping () -> Bool) -> Signal<Void, NoError>) -> Signal<Never, NoError> {
    return combineLatest(queue: Queue.mainQueue(), settings, connectionStatus, isActive)
    |> map { settings, status, isActive -> ProxySettings? in
        guard isActive, settings.nextAutoRotationServer != nil else {
            return nil
        }
        switch status {
        case .connecting:
            return settings
        case .waitingForNetwork, .updating, .online:
            // Updating is already a connected transport. Neither synchronization
            // nor the device being offline is a reason to abandon a working proxy.
            return nil
        }
    }
    |> distinctUntilChanged
    |> mapToSignal { settings -> Signal<Never, NoError> in
        guard let settings else {
            return .never()
        }
        return Signal { _ in
            let valid = Atomic(value: true)
            let disposable = (wait(Double(settings.autoRotationPeriod.rawValue))
            |> take(1)
            |> deliverOnMainQueue
            |> mapToSignal { _ in
                return rotate(settings, { valid.with { $0 } })
            }).start()
            return ActionDisposable {
                let _ = valid.swap(false)
                disposable.dispose()
            }
        }
    }
}
