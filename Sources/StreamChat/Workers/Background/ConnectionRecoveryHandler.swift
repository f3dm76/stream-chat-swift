//
// Copyright © 2024 Stream.io Inc. All rights reserved.
//

import CoreData
import Foundation

/// The type that keeps track of active chat components and asks them to reconnect when it's needed
protocol ConnectionRecoveryHandler: ConnectionStateDelegate {
    func start()
    func stop()
}

/// The type is designed to obtain missing events that happened in watched channels while user
/// was not connected to the web-socket.
///
/// The object listens for `ConnectionStatusUpdated` events
/// and remembers the `CurrentUserDTO.lastReceivedEventDate` when status becomes `connecting`.
///
/// When the status becomes `connected` the `/sync` endpoint is called
/// with `lastReceivedEventDate` and `cids` of watched channels.
///
/// We remember `lastReceivedEventDate` when state becomes `connecting` to catch the last event date
/// before the `HealthCheck` override the `lastReceivedEventDate` with the recent date.
///
final class DefaultConnectionRecoveryHandler: ConnectionRecoveryHandler {
    // MARK: - Properties

    private let webSocketClient: WebSocketClient
    private let eventNotificationCenter: EventNotificationCenter
    private let syncRepository: SyncRepository
    private let extensionLifecycle: NotificationExtensionLifecycle
    private let backgroundTaskScheduler: BackgroundTaskScheduler?
    private let internetConnection: InternetConnection
    private let reconnectionTimerType: Timer.Type
    private var reconnectionStrategy: RetryStrategy
    private var reconnectionTimer: TimerControl?
    private let keepConnectionAliveInBackground: Bool
    private var reconnectionTimeoutHandler: StreamTimer?

    // MARK: - Init

    init(
        webSocketClient: WebSocketClient,
        eventNotificationCenter: EventNotificationCenter,
        syncRepository: SyncRepository,
        extensionLifecycle: NotificationExtensionLifecycle,
        backgroundTaskScheduler: BackgroundTaskScheduler?,
        internetConnection: InternetConnection,
        reconnectionStrategy: RetryStrategy,
        reconnectionTimerType: Timer.Type,
        keepConnectionAliveInBackground: Bool,
        reconnectionTimeoutHandler: StreamTimer?
    ) {
        self.webSocketClient = webSocketClient
        self.eventNotificationCenter = eventNotificationCenter
        self.syncRepository = syncRepository
        self.extensionLifecycle = extensionLifecycle
        self.backgroundTaskScheduler = backgroundTaskScheduler
        self.internetConnection = internetConnection
        self.reconnectionStrategy = reconnectionStrategy
        self.reconnectionTimerType = reconnectionTimerType
        self.keepConnectionAliveInBackground = keepConnectionAliveInBackground
        self.reconnectionTimeoutHandler = reconnectionTimeoutHandler
    }

    func start() {
        subscribeOnNotifications()
    }

    func stop() {
        unsubscribeFromNotifications()
        cancelReconnectionTimer()
        reconnectionTimeoutHandler?.stop()
    }

    deinit {
        stop()
    }
}

// MARK: - Subscriptions

private extension DefaultConnectionRecoveryHandler {
    func subscribeOnNotifications() {
        backgroundTaskScheduler?.startListeningForAppStateUpdates(
            onEnteringBackground: { [weak self] in self?.appDidEnterBackground() },
            onEnteringForeground: { [weak self] in self?.appDidBecomeActive() }
        )

        internetConnection.notificationCenter.addObserver(
            self,
            selector: #selector(internetConnectionAvailabilityDidChange(_:)),
            name: .internetConnectionAvailabilityDidChange,
            object: nil
        )

        reconnectionTimeoutHandler?.onChange = { [weak self] in
            self?.webSocketClient.timeout()
            self?.cancelReconnectionTimer()
        }
    }

    func unsubscribeFromNotifications() {
        backgroundTaskScheduler?.stopListeningForAppStateUpdates()

        internetConnection.notificationCenter.removeObserver(
            self,
            name: .internetConnectionStatusDidChange,
            object: nil
        )
    }
}

// MARK: - Event handlers

extension DefaultConnectionRecoveryHandler {
    private func appDidBecomeActive() {
        log.debug("App -> ✅", subsystems: .webSocket)

        backgroundTaskScheduler?.endTask()

        if canReconnectFromOffline {
            webSocketClient.connect()
        }
    }

    private func appDidEnterBackground() {
        log.debug("App -> 💤", subsystems: .webSocket)

        guard canBeDisconnected else {
            // Client is not trying to connect nor connected
            return
        }

        guard keepConnectionAliveInBackground else {
            // We immediately disconnect
            disconnectIfNeeded()
            return
        }

        guard let scheduler = backgroundTaskScheduler else { return }

        let succeed = scheduler.beginTask { [weak self] in
            log.debug("Background task -> ❌", subsystems: .webSocket)

            self?.disconnectIfNeeded()
        }

        if succeed {
            log.debug("Background task -> ✅", subsystems: .webSocket)
        } else {
            // Can't initiate a background task, close the connection
            disconnectIfNeeded()
        }
    }

    @objc private func internetConnectionAvailabilityDidChange(_ notification: Notification) {
        guard let isAvailable = notification.internetConnectionStatus?.isAvailable else {
            return
        }

        log.debug("Internet -> \(isAvailable ? "✅" : "❌")", subsystems: .webSocket)

        if isAvailable {
            if canReconnectFromOffline {
                webSocketClient.connect()
            }
        } else {
            disconnectIfNeeded()
        }
    }

    func webSocketClient(_ client: WebSocketClient, didUpdateConnectionState state: WebSocketConnectionState) {
        log.debug("Connection state: \(state)", subsystems: .webSocket)

        switch state {
        case .connecting:
            cancelReconnectionTimer()
            if reconnectionTimeoutHandler?.isRunning == false {
                reconnectionTimeoutHandler?.start()
            }

        case .connected:
            extensionLifecycle.setAppState(isReceivingEvents: true)
            reconnectionStrategy.resetConsecutiveFailures()
            syncRepository.syncLocalState {
                log.info("Local state sync completed", subsystems: .offlineSupport)
            }
            reconnectionTimeoutHandler?.stop()

        case .disconnected:
            extensionLifecycle.setAppState(isReceivingEvents: false)
            scheduleReconnectionTimerIfNeeded()
        case .initialized, .waitingForConnectionId, .disconnecting:
            break
        }
    }

    var canReconnectFromOffline: Bool {
        guard backgroundTaskScheduler?.isAppActive ?? true else {
            log.debug("Reconnection is not possible (app 💤)", subsystems: .webSocket)
            return false
        }

        switch webSocketClient.connectionState {
        case .disconnected(let source) where source == .userInitiated:
            return false
        case .initialized, .connected:
            return false
        default:
            break
        }

        return true
    }
}

// MARK: - Disconnection

private extension DefaultConnectionRecoveryHandler {
    func disconnectIfNeeded() {
        guard canBeDisconnected else { return }

        webSocketClient.disconnect(source: .systemInitiated) {
            log.debug("Did disconnect automatically", subsystems: .webSocket)
        }
    }

    var canBeDisconnected: Bool {
        let state = webSocketClient.connectionState

        switch state {
        case .connecting, .waitingForConnectionId, .connected:
            log.debug("Will disconnect automatically from \(state) state", subsystems: .webSocket)

            return true
        default:
            log.debug("Disconnect is not needed in \(state) state", subsystems: .webSocket)

            return false
        }
    }
}

// MARK: - Reconnection Timer

private extension DefaultConnectionRecoveryHandler {
    func scheduleReconnectionTimerIfNeeded() {
        guard canReconnectAutomatically else { return }

        scheduleReconnectionTimer()
    }

    func scheduleReconnectionTimer() {
        let delay = reconnectionStrategy.getDelayAfterTheFailure()

        log.debug("Timer ⏳ \(delay) sec", subsystems: .webSocket)

        reconnectionTimer = reconnectionTimerType.schedule(
            timeInterval: delay,
            queue: .main,
            onFire: { [weak self] in
                log.debug("Timer 🔥", subsystems: .webSocket)

                if self?.canReconnectAutomatically == true {
                    self?.webSocketClient.connect()
                }
            }
        )
    }

    func cancelReconnectionTimer() {
        guard reconnectionTimer != nil else { return }

        log.debug("Timer ❌", subsystems: .webSocket)

        reconnectionTimer?.cancel()
        reconnectionTimer = nil
    }

    var canReconnectAutomatically: Bool {
        guard webSocketClient.connectionState.isAutomaticReconnectionEnabled else {
            log.debug("Reconnection is not required (\(webSocketClient.connectionState))", subsystems: .webSocket)
            return false
        }

        guard backgroundTaskScheduler?.isAppActive ?? true else {
            log.debug("Reconnection is not possible (app 💤)", subsystems: .webSocket)
            return false
        }

        log.debug("Will reconnect automatically", subsystems: .webSocket)

        return true
    }
}
