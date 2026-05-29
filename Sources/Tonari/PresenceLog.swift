import Foundation

enum PresenceStatus: String, Codable {
    case present       // working at desk
    case away          // no person
    case eating        // eating or drinking
    case onPhone       = "on_phone"
    case talking       // talking / on call
    case other
    case error         // capture or LLM failed

    var emoji: String {
        switch self {
        case .present:  return "🟢"
        case .away:     return "⚪️"
        case .eating:   return "🍴"
        case .onPhone:  return "📱"
        case .talking:  return "💬"
        case .other:    return "🟡"
        case .error:    return "⚠️"
        }
    }

    var label: String {
        switch self {
        case .present:  return "在席"
        case .away:     return "不在"
        case .eating:   return "食事中"
        case .onPhone:  return "スマホ"
        case .talking:  return "通話中"
        case .other:    return "他"
        case .error:    return "エラー"
        }
    }
}

struct PresenceLogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let status: PresenceStatus
    let note: String
    let model: String
    /// Full LLM raw text for debugging. Optional so we can omit if it gets huge.
    let rawResponse: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        status: PresenceStatus,
        note: String,
        model: String,
        rawResponse: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.status = status
        self.note = note
        self.model = model
        self.rawResponse = rawResponse
    }
}

/// JSON-backed presence log stored under Application Support/Tonari/.
struct PresenceLogStore {
    static let maxEntries = 500  // cap to avoid unbounded growth

    private let url: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Tonari", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("presence-log.json")
    }

    func load() -> [PresenceLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PresenceLogEntry].self, from: data)) ?? []
    }

    func save(_ entries: [PresenceLogEntry]) {
        let capped = entries.suffix(Self.maxEntries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Array(capped)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    var fileURL: URL { url }
}
