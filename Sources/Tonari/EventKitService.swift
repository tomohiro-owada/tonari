import EventKit
import Foundation

struct EventBrief: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let calendarName: String
    let url: URL?
}

struct ReminderBrief: Identifiable {
    let id: String
    let title: String
    let dueDate: Date?
    let isCompleted: Bool
    let notes: String?
    let listName: String
    let priority: Int
}

final class EventKitService {
    private let store = EKEventStore()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - Permission

    func requestCalendarAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch { return false }
    }

    func requestReminderAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch { return false }
    }

    // MARK: - Calendar (read)

    func events(from start: Date, to end: Date) -> [EventBrief] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(brief)
    }

    func todayEvents() -> [EventBrief] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return events(from: start, to: end)
    }

    func upcomingEvents(days: Int) -> [EventBrief] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: days, to: start)!
        return events(from: start, to: end)
    }

    private func brief(_ e: EKEvent) -> EventBrief {
        EventBrief(
            id: e.eventIdentifier ?? UUID().uuidString,
            title: e.title ?? "(無題)",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            location: e.location?.isEmpty == false ? e.location : nil,
            notes: e.notes?.isEmpty == false ? e.notes : nil,
            calendarName: e.calendar?.title ?? "",
            url: e.url
        )
    }

    // MARK: - Reminders (read)

    func incompleteReminders() async -> [ReminderBrief] {
        await withCheckedContinuation { (cont: CheckedContinuation<[ReminderBrief], Never>) in
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: nil
            )
            store.fetchReminders(matching: predicate) { reminders in
                let out = (reminders ?? [])
                    .map { ReminderBrief(
                        id: $0.calendarItemIdentifier,
                        title: $0.title ?? "(無題)",
                        dueDate: $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        isCompleted: $0.isCompleted,
                        notes: $0.notes?.isEmpty == false ? $0.notes : nil,
                        listName: $0.calendar?.title ?? "",
                        priority: $0.priority
                    )}
                cont.resume(returning: out)
            }
        }
    }

    // MARK: - Reminders (write)

    enum AddReminderError: Error {
        case noDefaultList
        case saveFailed(Error)
    }

    /// Create a new reminder. Returns the calendar-item-identifier on success.
    func addReminder(
        title: String,
        dueDate: Date? = nil,
        notes: String? = nil,
        listName: String? = nil
    ) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let notes { reminder.notes = notes }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        let targetList: EKCalendar?
        if let listName,
           let match = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
            targetList = match
        } else {
            targetList = store.defaultCalendarForNewReminders()
        }
        guard let cal = targetList else { throw AddReminderError.noDefaultList }
        reminder.calendar = cal

        do {
            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        } catch {
            throw AddReminderError.saveFailed(error)
        }
    }

    // MARK: - LLM-friendly text rendering

    func formatTodayBriefing() -> String {
        let events = todayEvents()
        if events.isEmpty { return "今日の予定はありません。" }
        return events.map { e -> String in
            let timing: String
            if e.isAllDay {
                timing = "終日"
            } else {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                timing = "\(f.string(from: e.start))–\(f.string(from: e.end))"
            }
            var line = "・[\(timing)] \(e.title)"
            if let loc = e.location { line += " @ \(loc)" }
            line += " (\(e.calendarName))"
            if let notes = e.notes, notes.count < 200 { line += "\n   メモ: \(notes)" }
            return line
        }.joined(separator: "\n")
    }

    func formatReminders(_ items: [ReminderBrief]) -> String {
        if items.isEmpty { return "未完了のリマインダーはありません。" }
        return items.prefix(20).map { r -> String in
            var line = "・\(r.title)"
            if let d = r.dueDate {
                line += " [期限: \(dateFormatter.string(from: d))]"
            }
            line += " (\(r.listName))"
            return line
        }.joined(separator: "\n")
    }
}
