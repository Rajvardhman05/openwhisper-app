import Foundation
import UserNotifications
import Observation

@Observable
@MainActor
final class ReminderManager {

    static let shared = ReminderManager()

    private let notificationCenter = UNUserNotificationCenter.current()
    private let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("OpenWhisper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reminders.json")
    }()

    // MARK: - Reminder Model

    struct Reminder: Codable, Identifiable {
        let id: String
        let task: String
        let fireDate: Date
        let createdAt: Date
    }

    private(set) var reminders: [Reminder] = []

    private init() {
        loadReminders()
        purgeFiredReminders()
    }

    /// Remove reminders that have already fired (called on app launch)
    func purgeFiredReminders() {
        let before = reminders.count
        reminders.removeAll { $0.fireDate <= Date() }
        if reminders.count < before {
            saveReminders()
            owLog("[Reminders] Purged \(before - reminders.count) fired reminder(s)")
        }
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            owLog("[Reminders] Notification permission: \(granted)")
            return granted
        } catch {
            owLog("[Reminders] Permission error: \(error)")
            return false
        }
    }

    // MARK: - Detection

    /// Check if transcribed text is a reminder command.
    /// Only matches when the sentence STARTS with a trigger phrase — avoids false positives
    /// when "remind" appears mid-sentence in normal dictation.
    static func isReminder(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = [
            "remind me",
            "set a reminder",
            "set reminder",
            "create a reminder",
            "add a reminder",
            "don't let me forget",
            "don't forget to"
        ]
        return triggers.contains(where: { lower.hasPrefix($0) })
    }

    // MARK: - Parse & Schedule

    /// Parse reminder text using Ollama and schedule a notification
    func handleReminder(text: String) async -> Bool {
        owLog("[Reminders] Processing: \(text)")

        // Parse via Ollama
        guard let parsed = await parseWithOllama(text: text) else {
            owLog("[Reminders] Failed to parse reminder")
            sendConfirmation(title: "Couldn't understand reminder", body: "Try: \"Remind me to [task] [when]\"")
            return false
        }

        owLog("[Reminders] Parsed — task: \(parsed.task), date: \(parsed.fireDate)")

        // If time is in the past, it will fire immediately — that's fine
        if parsed.fireDate <= Date() {
            owLog("[Reminders] Date is in the past, will fire immediately: \(parsed.fireDate)")
        }

        // Schedule notification
        let reminder = Reminder(
            id: UUID().uuidString,
            task: parsed.task,
            fireDate: parsed.fireDate,
            createdAt: Date()
        )

        let scheduled = await scheduleNotification(reminder: reminder)
        if scheduled {
            reminders.append(reminder)
            saveReminders()

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            sendConfirmation(
                title: "✓ Reminder Set",
                body: "\(reminder.task) — \(formatter.string(from: reminder.fireDate))"
            )
            owLog("[Reminders] Scheduled: \(reminder.task) at \(reminder.fireDate)")
        }
        return scheduled
    }

    // MARK: - Ollama Parsing

    private struct ParsedReminder {
        let task: String
        let fireDate: Date
    }

    private func parseWithOllama(text: String) async -> ParsedReminder? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }

        let now = Date()
        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        localFormatter.timeZone = TimeZone.current
        let currentTime = localFormatter.string(from: now)

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        let currentWeekday = weekdayFormatter.string(from: now)

        let prompt = """
            Extract the task and scheduled time from this voice reminder command.
            Current date/time: \(currentTime) (\(currentWeekday))

            Rules:
            - Return ONLY a JSON object: {"task": "...", "datetime": "YYYY-MM-DDTHH:MM:SS"}
            - Use 24-hour time format
            - "tomorrow" = next day, "tonight" = today evening
            - If user says "today", ALWAYS use today's date even if the time has already passed
            - If just a time is given with no date and no "today", assume today (or tomorrow if time has passed)
            - If no specific time given, default to 09:00 for morning, 18:00 for evening
            - "in X hours/minutes" = add X to the current time above
            - Extract the task description without the time parts
            - Do NOT include "remind me to" in the task
            - Output ONLY the JSON, nothing else

            Voice command: \(text)
            """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "qwen2.5:3b",
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": 100
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else { return nil }

            owLog("[Reminders] Ollama response: \(responseText)")

            // Extract JSON from response (handle possible markdown wrapping)
            let cleanedResponse = responseText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let responseData = cleanedResponse.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: String],
                  let task = parsed["task"],
                  let datetimeStr = parsed["datetime"] else { return nil }

            // Parse the datetime string (Ollama returns local time, not UTC)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone.current

            guard let fireDate = dateFormatter.date(from: datetimeStr) else {
                owLog("[Reminders] Failed to parse date: \(datetimeStr)")
                return nil
            }

            return ParsedReminder(task: task, fireDate: fireDate)
        } catch {
            owLog("[Reminders] Ollama parse error: \(error)")
            return nil
        }
    }

    // MARK: - Notification Scheduling

    private func scheduleNotification(reminder: Reminder) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "OpenWhisper Reminder"
        content.body = reminder.task
        content.sound = .default
        content.categoryIdentifier = "REMINDER"

        let triggerDate = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: reminder.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)

        let request = UNNotificationRequest(
            identifier: reminder.id,
            content: content,
            trigger: trigger
        )

        do {
            try await notificationCenter.add(request)
            return true
        } catch {
            owLog("[Reminders] Schedule error: \(error)")
            return false
        }
    }

    // MARK: - Instant Confirmation Notification

    private func sendConfirmation(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "confirmation-\(UUID().uuidString)",
            content: content,
            trigger: nil // fires immediately
        )

        notificationCenter.add(request) { error in
            if let error = error {
                owLog("[Reminders] Confirmation notification error: \(error)")
            }
        }
    }

    // MARK: - Persistence

    private func saveReminders() {
        // Clean up past reminders
        reminders = reminders.filter { $0.fireDate > Date() }
        do {
            let data = try JSONEncoder().encode(reminders)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            owLog("[Reminders] Save error: \(error)")
        }
    }

    private func loadReminders() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            reminders = try JSONDecoder().decode([Reminder].self, from: data)
            // Clean expired
            reminders = reminders.filter { $0.fireDate > Date() }
        } catch {
            owLog("[Reminders] Load error: \(error)")
        }
    }

    // MARK: - Cleanup

    func cancelReminder(id: String) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
        reminders.removeAll { $0.id == id }
        saveReminders()
    }

    func cancelAll() {
        notificationCenter.removeAllPendingNotificationRequests()
        reminders.removeAll()
        saveReminders()
    }
}
