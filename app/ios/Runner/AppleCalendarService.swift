import Foundation
import EventKit
import Flutter

/// 只读访问系统日历（EventKit `.event`）。
///
/// 与 `AppleRemindersService` 是镜像关系但方向相反：提醒事项**只写**，日历**只读**。
/// 这里不提供任何 save/remove 接口，授权页和隐私页对用户的承诺就是这一条
/// （"不会新增、修改或删除"），所以约束落在代码层面而不只是文案上。
class AppleCalendarService {
    private let eventStore = EKEventStore()

    /// 一次 fetch 最多回多少条，防一个共享日历把 method channel 塞爆。
    private static let maxEvents = 500

    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasPermission":
            hasCalendarPermission(result: result)
        case "requestPermission":
            requestCalendarPermission(result: result)
        case "getEvents":
            getEvents(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Permission

    /// iOS 17 起读日历要的是 `.fullAccess`；它的 rawValue 与旧的 `.authorized`
    /// 相同（都是 3），所以一个 `== .authorized` 判断在两代系统上都成立。
    /// 写成显式函数是为了让这个"看起来漏了 iOS 17"的判断有个交代。
    private func isReadAuthorized() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    private func hasCalendarPermission(result: @escaping FlutterResult) {
        result(isReadAuthorized())
    }

    private func requestCalendarPermission(result: @escaping FlutterResult) {
        if isReadAuthorized() {
            result(true)
            return
        }

        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            // 系统不会再弹框，交给 Dart 侧引导去设置。
            result(false)
            return
        }
        // iOS 17 的 writeOnly 也走一次 full access 请求：用户之前只给了写权限，
        // 我们要的是读，必须重新问。

        let completion: (Bool, Error?) -> Void = { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("[calendar] request access failed: \(error.localizedDescription)")
                    result(false)
                    return
                }
                result(granted)
            }
        }

        if #available(iOS 17.0, *) {
            eventStore.requestFullAccessToEvents(completion: completion)
        } else {
            eventStore.requestAccess(to: .event, completion: completion)
        }
    }

    // MARK: - Read

    private func getEvents(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let startMs = (args["startMs"] as? NSNumber)?.doubleValue,
              let endMs = (args["endMs"] as? NSNumber)?.doubleValue else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "startMs and endMs are required", details: nil))
            return
        }

        guard isReadAuthorized() else {
            result(FlutterError(code: "PERMISSION_DENIED", message: "Calendar permission not granted", details: nil))
            return
        }

        let start = Date(timeIntervalSince1970: startMs / 1000.0)
        let end = Date(timeIntervalSince1970: endMs / 1000.0)
        guard end > start else {
            result(FlutterError(code: "INVALID_RANGE", message: "endMs must be after startMs", details: nil))
            return
        }

        // events(matching:) 同步阻塞且可能扫几百条，别占着主线程。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { result([]) }
                return
            }
            // calendars: nil = 用户所有日历（含订阅/共享的）。
            let predicate = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = self.eventStore.events(matching: predicate)
                .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                .prefix(Self.maxEvents)

            let payload = events.compactMap { self.serialize($0) }
            DispatchQueue.main.async { result(payload) }
        }
    }

    /// 全天日程的当地日期（`2026-08-06`）。
    private static let localDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 浮动日程的当地墙上时间（`2026-08-06T14:30:00`）。
    private static let localDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 把日期渲染成当地表示。
    ///
    /// 两个 formatter 的 `timeZone` 都不设，于是跟随 `TimeZone.current` —— 这正是
    /// 我们要的：EventKit 返回的全天/浮动日程本就是"当前设备时区的墙上时间"。
    private func localString(_ date: Date, allDay: Bool) -> String {
        let formatter = allDay ? Self.localDateFormatter : Self.localDateTimeFormatter
        return formatter.string(from: date)
    }

    /// 只序列化行程"骨架"：标题、时间、地点、所属日历。
    ///
    /// **刻意不带 notes/attendees/URL** —— 这些字段会上传到服务端，而备注里常有
    /// 会议密码、电话号码、私人细节。agent 判断"我什么时候有空、要去哪"用不到它们。
    /// 以后真需要再单独评估，不要顺手加。
    ///
    /// ## 为什么全天/浮动日程不能只用时间戳表达
    ///
    /// `EKEvent.timeZone == nil` 表示浮动日程（Apple 的例子是"中午吃饭"）——它不绑
    /// 任何时区，"start/end 按系统时区解读"。全天日程同理，`startDate` 是**当前设备
    /// 时区**的当地 00:00。也就是说用户从北京飞到旧金山、日历一条没改，这些日程的
    /// epoch 毫秒会整体平移。
    ///
    /// 如果 `instance_id` 和内容指纹都建在毫秒上，那次飞行会让整窗 id 全变、指纹全部
    /// 失效 —— 白重传一次，而且服务端会以为用户把所有行程都改了。所以这类日程额外
    /// 上传当地表示（`local_start` / `local_end`），并用它而非毫秒做实例键。
    private func serialize(_ event: EKEvent) -> [String: Any]? {
        guard let start = event.startDate else { return nil }
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else { return nil }

        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs: Int64? = event.endDate.map { Int64($0.timeIntervalSince1970 * 1000) }

        let allDay = event.isAllDay
        // timeZone 为 nil ⇒ 浮动日程。全天日程通常也是 nil，但不保证，所以两个条件都判。
        let isFloating = allDay || event.timeZone == nil
        let localStart = localString(start, allDay: allDay)

        // 重复日程的每个实例共用同一个 eventIdentifier，必须拼上实例起始时刻才唯一。
        // 绑时区的日程用毫秒（绝对时刻稳定）；浮动的用当地表示（毫秒会随设备时区漂）。
        let instanceKey = isFloating ? localStart : String(startMs)

        var payload: [String: Any] = [
            "instance_id": "\(identifier)|\(instanceKey)",
            "event_identifier": identifier,
            "title": event.title ?? "",
            "start_ms": startMs,
            "all_day": allDay,
            "is_floating": isFloating,
            "local_start": localStart,
            "is_recurring": event.hasRecurrenceRules,
            "status": statusName(event.status),
        ]
        if let endMs = endMs {
            payload["end_ms"] = endMs
        }
        if let end = event.endDate {
            payload["local_end"] = localString(end, allDay: allDay)
        }
        // 绑了时区就带上，服务端渲染"下午 3 点"时才知道是哪个下午 3 点。
        if let timeZone = event.timeZone {
            payload["time_zone"] = timeZone.identifier
        }
        if let location = event.location, !location.isEmpty {
            payload["location"] = location
        }
        if let calendarTitle = event.calendar?.title, !calendarTitle.isEmpty {
            payload["calendar_title"] = calendarTitle
        }
        if let lastModified = event.lastModifiedDate {
            payload["last_modified_ms"] = Int64(lastModified.timeIntervalSince1970 * 1000)
        }
        return payload
    }

    private func statusName(_ status: EKEventStatus) -> String {
        switch status {
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        case .none: return "none"
        @unknown default: return "none"
        }
    }
}
