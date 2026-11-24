import Foundation
public typealias FlutterResult = (Any?) -> Void
public let FlutterMethodNotImplemented = NSObject()
public final class FlutterMethodCall {
    public let method: String
    public let arguments: Any?
    public init(method: String, arguments: Any?) { self.method = method; self.arguments = arguments }
}
public final class FlutterError {
    public init(code: String, message: String?, details: Any?) {}
}
public final class FlutterMethodChannel {
    public init() {}
    public func invokeMethod(_ method: String, arguments: Any?) {}
}
