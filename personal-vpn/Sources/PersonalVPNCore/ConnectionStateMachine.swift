import Foundation

public enum ConnectionEvent: Sendable, Equatable {
    case requestDirect
    case requestConnect(mode: VPNMode, routeName: String)
    case engineStarted
    case probeSucceeded(ip: String?, latencyMilliseconds: Int?)
    case probeFailed(reason: String)
    case retryStarted(attempt: Int)
    case retriesExhausted(reason: String)
    case engineStopped
}

public enum ConnectionStateMachine {
    public static func reduce(_ current: ConnectionSnapshot, event: ConnectionEvent) -> ConnectionSnapshot {
        var next = current
        switch event {
        case .requestDirect:
            next.phase = current.mode == .direct ? .direct : .stopping
            next.failureReason = nil
        case .requestConnect(let mode, let routeName):
            next.mode = mode
            next.phase = .preparing
            next.routeName = routeName
            next.failureReason = nil
            next.reconnectAttempt = 0
        case .engineStarted:
            next.phase = .connecting
        case .probeSucceeded(let ip, let latency):
            next.phase = .connected
            next.egressIP = ip
            next.latencyMilliseconds = latency
            next.lastHealthyAt = Date()
            next.failureReason = nil
            next.reconnectAttempt = 0
        case .probeFailed(let reason):
            next.phase = .degraded
            next.failureReason = reason
        case .retryStarted(let attempt):
            next.phase = .reconnecting
            next.reconnectAttempt = attempt
        case .retriesExhausted(let reason):
            next.mode = .direct
            next.phase = .errorDirect
            next.routeName = "Direct"
            next.failureReason = reason
        case .engineStopped:
            next.mode = .direct
            next.phase = .direct
            next.routeName = "Direct"
            next.egressIP = nil
            next.latencyMilliseconds = nil
            next.reconnectAttempt = 0
        }
        return next
    }

    public static let reconnectDelays: [TimeInterval] = [1, 2, 5, 10, 30]
}
