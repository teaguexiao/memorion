import Foundation
import EventKit
import Flutter

class AppleRemindersService {
    private let eventStore = EKEventStore()
    
    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasPermission":
            hasRemindersPermission(result: result)
        case "requestPermission":
            requestRemindersPermission(result: result)
        case "addReminder":
            addReminder(call: call, result: result)
        case "getReminders":
            getReminders(call: call, result: result)
        case "completeReminder":
            completeReminder(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func hasRemindersPermission(result: @escaping FlutterResult) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        result(status == .authorized)
    }
    
    private func requestRemindersPermission(result: @escaping FlutterResult) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        
        if status == .authorized {
            result(true)
            return
        }
        
        if status == .denied || status == .restricted {
            result(false)
            return
        }
        
        // Request permission
        eventStore.requestAccess(to: .reminder) { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error requesting reminders permission: \(error.localizedDescription)")
                    result(false)
                    return
                }
                result(granted)
            }
        }
    }
    
    private func addReminder(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }
        
        guard let title = args["title"] as? String else {
            result(FlutterError(code: "MISSING_TITLE", message: "Title is required", details: nil))
            return
        }
        
        let notes = args["notes"] as? String
        let listName = args["listName"] as? String ?? "Reminders"
        let dueDate: Date? = {
            if let dueDateMs = args["dueDate"] as? Int64 {
                return Date(timeIntervalSince1970: TimeInterval(dueDateMs) / 1000.0)
            }
            return nil
        }()
        
        // Check permission
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .authorized else {
            result(FlutterError(code: "PERMISSION_DENIED", message: "Reminders permission not granted", details: nil))
            return
        }
        
        // 用已存在的同名列表，否则直接用系统默认列表——**不新建**。
        //
        // 原先找不到就 EKCalendar(...) + saveCalendar 造一个，但那样每次调用都可能
        // 再造一个（saveCalendar 成功却未必立刻出现在 calendars(for:) 里），结果提醒
        // 散落在一堆同名列表中、读取端一条都匹配不上，去重彻底失效、重复写入。
        // 写进用户默认列表也更符合预期：一键导入不该在提醒事项里凭空多出一个列表。
        let calendars = eventStore.calendars(for: .reminder)
        let targetCalendar = calendars.first { $0.title == listName }
            ?? eventStore.defaultCalendarForNewReminders()
        
        guard let calendar = targetCalendar else {
            result(FlutterError(code: "NO_CALENDAR", message: "Could not find or create calendar", details: nil))
            return
        }
        
        // Create the reminder
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendar
        
        if let dueDate = dueDate {
            let dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            reminder.dueDateComponents = dueDateComponents
        }
        
        // Save the reminder
        do {
            try eventStore.save(reminder, commit: true)
            result(true)
        } catch {
            print("Error saving reminder: \(error.localizedDescription)")
            result(FlutterError(code: "SAVE_FAILED", message: "Failed to save reminder: \(error.localizedDescription)", details: nil))
        }
    }
    
    private func getReminders(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }
        
        let listName = args["listName"] as? String ?? "Reminders"
        
        // Check permission
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .authorized else {
            result([]) // Return empty array if no permission
            return
        }
        
        // 与 addReminder 用同一套列表解析（同名 → 默认），否则读写不在同一个列表，
        // 拿这个结果做去重就会漏判、重复写入。
        let calendars = eventStore.calendars(for: .reminder)
        guard let targetCalendar = calendars.first(where: { $0.title == listName })
            ?? eventStore.defaultCalendarForNewReminders() else {
            result([]) // No reminder list at all
            return
        }

        // Create predicate to fetch reminders from this calendar
        let predicate = eventStore.predicateForReminders(in: [targetCalendar])
        
        eventStore.fetchReminders(matching: predicate) { reminders in
            DispatchQueue.main.async {
                // 只回未完成的：已勾掉的提醒不该拦住同一件事重新加入。
                let reminderTitles = reminders?.filter { !$0.isCompleted }.compactMap { $0.title } ?? []
                result(reminderTitles)
            }
        }
    }
    
    private func completeReminder(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }
        
        guard let title = args["title"] as? String else {
            result(FlutterError(code: "MISSING_TITLE", message: "Title is required", details: nil))
            return
        }
        
        let listName = args["listName"] as? String ?? "Reminders"
        
        // Check permission
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .authorized else {
            result(false) // Return false if no permission
            return
        }
        
        // Find the calendar
        let calendars = eventStore.calendars(for: .reminder)
        guard let targetCalendar = calendars.first(where: { $0.title == listName }) else {
            result(false) // Return false if calendar not found
            return
        }
        
        // Create predicate to fetch reminders from this calendar
        let predicate = eventStore.predicateForReminders(in: [targetCalendar])
        
        eventStore.fetchReminders(matching: predicate) { reminders in
            DispatchQueue.main.async {
                guard let targetReminder = reminders?.first(where: { $0.title == title && !$0.isCompleted }) else {
                    result(false) // Reminder not found or already completed
                    return
                }
                
                // Mark the reminder as completed
                targetReminder.isCompleted = true
                
                do {
                    try self.eventStore.save(targetReminder, commit: true)
                    result(true)
                } catch {
                    print("Error completing reminder: \(error.localizedDescription)")
                    result(false)
                }
            }
        }
    }
} 