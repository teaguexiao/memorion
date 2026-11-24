// Deterministic transport double. Production source is compiled unchanged against
// this module; platform type checking is performed separately with Apple's SDKs.
import Foundation
public protocol WCSessionDelegate: AnyObject {}
public enum WCSessionActivationState: Int { case notActivated, inactive, activated }
public final class WCSessionFile {
    public let fileURL: URL
    public let metadata: [String: Any]?
    public init(_ url: URL, metadata: [String: Any]? = nil) { fileURL = url; self.metadata = metadata }
}
public final class WCSessionFileTransfer {
    public let file: WCSessionFile
    public var cancelled = false
    public init(_ file: WCSessionFile) { self.file = file }
    public func cancel() { cancelled = true }
}
public final class WCSessionUserInfoTransfer {
    public let userInfo: [String: Any]
    public init(_ info: [String: Any]) { userInfo = info }
}
public final class WCSession {
    public static var `default` = WCSession()
    public static func isSupported() -> Bool { true }
    public weak var delegate: WCSessionDelegate?
    public var activationState = WCSessionActivationState.activated
    public var applicationContext: [String: Any] = [:]
    public var receivedApplicationContext: [String: Any] = [:]
    public var isReachable = true
    public var isPaired = true
    public var isWatchAppInstalled = true
    public var outstandingFileTransfers: [WCSessionFileTransfer] = []
    public var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] = []
    public var messageHandler: (([String: Any], (([String: Any]) -> Void)?, ((Error) -> Void)?) -> Void)?
    public init() {}
    public func activate() {}
    public func transferFile(_ url: URL, metadata: [String: Any]?) {
        outstandingFileTransfers.append(WCSessionFileTransfer(WCSessionFile(url, metadata: metadata)))
    }
    @discardableResult public func transferUserInfo(_ info: [String: Any]) -> WCSessionUserInfoTransfer {
        let transfer = WCSessionUserInfoTransfer(info)
        outstandingUserInfoTransfers.append(transfer)
        return transfer
    }
    public func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?,
                            errorHandler: ((Error) -> Void)?) {
        messageHandler?(message, replyHandler, errorHandler)
    }
    public func updateApplicationContext(_ context: [String: Any]) throws { applicationContext = context }
}
