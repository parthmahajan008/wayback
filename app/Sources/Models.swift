import Foundation

struct Hit: Codable, Identifiable, Hashable {
    let chunkId: Int
    let score: Double
    let similarity: Double
    let role: String
    let ts: String?
    let text: String
    let snippet: String
    let msgIdx: Int
    let seq: Int
    let sessionKey: String
    let sessionId: String
    let source: String
    let title: String
    let cwd: String
    let kind: String
    let path: String
    let updatedAt: String?
    let gitBranch: String?
    let n: Int?

    var id: Int { chunkId }
}

struct SearchResponse: Codable {
    let results: [Hit]
    let tookMs: Int
}

struct IndexStatus: Codable {
    let phase: String
    let filesTotal: Int
    let filesDone: Int
    let toEmbed: Int
    let embedded: Int
    let sessions: Int
    let claude: Int
    let codex: Int
    let chunks: Int
    let embeddings: Int
    let vectorsLoaded: Int
    let model: String
    let device: String
    let error: String?
    let lastRun: Double?
}

struct Project: Codable, Identifiable, Hashable {
    let cwd: String
    let n: Int
    let last: String?
    var id: String { cwd }
    var name: String { (cwd as NSString).lastPathComponent }
}

struct Provider: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let models: [String]
}

struct TranscriptMessage: Codable, Hashable {
    let role: String
    let text: String
    let ts: String?
}

struct SessionDetail: Codable {
    let key: String
    let id: String
    let source: String
    let title: String
    let cwd: String
    let kind: String
    let path: String
    let startedAt: String?
    let updatedAt: String?
    let gitBranch: String?
    let messages: [TranscriptMessage]
}

enum SourceFilter: String, CaseIterable, Identifiable {
    case all, claude, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All sessions"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
    var icon: String {
        switch self {
        case .all: "tray.full"
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum TimeRange: Int, CaseIterable, Identifiable {
    case any = 0, day = 1, week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .any: "Any time"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 90 days"
        }
    }
}

enum MatchMode: String, CaseIterable, Identifiable {
    case hybrid, semantic, keyword
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum AppMode: String, CaseIterable, Identifiable {
    case search, ask
    var id: String { rawValue }
}

enum Dates {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func relative(_ s: String?) -> String {
        guard let d = parse(s) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func full(_ s: String?) -> String {
        guard let d = parse(s) else { return "" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
