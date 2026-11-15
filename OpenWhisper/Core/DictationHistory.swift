import Foundation

struct DictationEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    var text: String
    var failed: Bool
}

/// Recent dictations. Text is saved to disk so a failed paste never loses words;
/// audio is kept in memory only (last few, this session) so an entry can be re-transcribed.
@MainActor
final class DictationHistory {
    private(set) var entries: [DictationEntry] = []
    private var audio: [UUID: [Float]] = [:]

    private let maxEntries = 20
    private let maxAudio = 5
    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DictationEntry].self, from: data) {
            entries = saved
        }
    }

    @discardableResult
    func add(text: String, failed: Bool, audio samples: [Float]) -> DictationEntry {
        let entry = DictationEntry(id: UUID(), date: Date(), text: text, failed: failed)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }

        audio[entry.id] = samples
        let keep = Set(entries.prefix(maxAudio).map(\.id))
        audio = audio.filter { keep.contains($0.key) }

        save()
        return entry
    }

    func update(_ id: UUID, text: String, failed: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].text = text
        entries[i].failed = failed
        save()
    }

    func audio(for id: UUID) -> [Float]? { audio[id] }

    func clear() {
        entries = []
        audio = [:]
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
