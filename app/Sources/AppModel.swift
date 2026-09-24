import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    // Connection
    var backendState: BackendState = .starting
    enum BackendState: Equatable { case starting, ready, failed(String) }

    // Query + filters
    var query = ""
    var mode: AppMode = .search
    var source: SourceFilter = .all
    var timeRange: TimeRange = .any
    var project: String? = nil
    var includeSubagents = true
    var includeExec = false
    var matchMode: MatchMode = .hybrid

    // Search results
    var results: [Hit] = []
    var searching = false
    var tookMs = 0
    var lastSearched = ""
    var errorText: String?

    // Ask
    var answer = ""
    var askSources: [Hit] = []
    var asking = false
    var askedQuestion = ""
    var providers: [Provider] = []
    var provider = UserDefaults.standard.string(forKey: "provider") ?? "claude" {
        didSet { UserDefaults.standard.set(provider, forKey: "provider") }
    }
    var model = UserDefaults.standard.string(forKey: "model") ?? "haiku" {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }

    // Detail
    var selection: Hit.ID?
    var session: SessionDetail?
    var focusMsgIdx: Int?
    var loadingSession = false

    // Index
    var status: IndexStatus?
    var projects: [Project] = []

    private let api = Backend.shared
    private var searchTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?

    var allHits: [Hit] { mode == .search ? results : askSources }

    func start() async {
        do {
            try await api.ensureRunning()
            backendState = .ready
            await refreshMeta()
            pollStatus()
        } catch {
            backendState = .failed(error.localizedDescription)
        }
    }

    func refreshMeta() async {
        projects = (try? await api.projects()) ?? projects
        providers = (try? await api.providers()) ?? providers
        if !providers.isEmpty, !providers.contains(where: { $0.id == provider }) {
            provider = providers[0].id
            model = providers[0].models.first ?? ""
        }
    }

    private func pollStatus() {
        Task {
            var lastPhase = ""
            while true {
                if let s = try? await api.status() {
                    status = s
                    if s.phase == "idle" && lastPhase != "idle" && !lastPhase.isEmpty {
                        await refreshMeta()
                    }
                    lastPhase = s.phase
                }
                try? await Task.sleep(for: .seconds(status?.phase == "idle" ? 10 : 2))
            }
        }
    }

    func reindex() {
        Task { await api.reindex(); status = try? await api.status() }
    }

    // MARK: filters

    var filterItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "include_exec", value: includeExec ? "true" : "false"),
            URLQueryItem(name: "include_subagents", value: includeSubagents ? "true" : "false"),
        ]
        if source != .all { items.append(URLQueryItem(name: "source", value: source.rawValue)) }
        if timeRange != .any { items.append(URLQueryItem(name: "days", value: String(timeRange.rawValue))) }
        if let project { items.append(URLQueryItem(name: "cwd", value: project)) }
        return items
    }

    func filtersChanged() {
        if mode == .search, !query.trimmingCharacters(in: .whitespaces).isEmpty { runSearch(debounce: false) }
    }

    // MARK: search

    func runSearch(debounce: Bool) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; lastSearched = ""; return }
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(280)) }
            if Task.isCancelled { return }
            searching = true
            defer { searching = false }
            do {
                let r = try await api.search(q, mode: matchMode, filters: filterItems)
                if Task.isCancelled { return }
                results = r.results
                tookMs = r.tookMs
                lastSearched = q
                errorText = nil
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }

    func submit() {
        if mode == .search { runSearch(debounce: false) } else { runAsk() }
    }

    // MARK: ask

    func runAsk() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askTask?.cancel()
        answer = ""
        askSources = []
        askedQuestion = q
        asking = true
        var body: [String: Any] = [
            "question": q, "provider": provider, "model": model,
            "include_exec": includeExec, "include_subagents": includeSubagents,
        ]
        if source != .all { body["source"] = source.rawValue }
        if timeRange != .any { body["days"] = timeRange.rawValue }
        if let project { body["cwd"] = project }
        askTask = Task {
            defer { asking = false }
            do {
                for try await ev in api.ask(body) {
                    switch ev {
                    case .sources(let s): askSources = s
                    case .delta(let t): answer += t
                    case .done: break
                    }
                }
            } catch {
                if !Task.isCancelled { answer += "\n\n**Error:** \(error.localizedDescription)" }
            }
        }
    }

    func stopAsk() {
        askTask?.cancel()
        asking = false
    }

    // MARK: detail

    func select(_ id: Hit.ID?) {
        selection = id
        guard let id, let hit = allHits.first(where: { $0.id == id }) else { return }
        open(hit)
    }

    func open(_ hit: Hit) {
        selection = hit.id
        focusMsgIdx = hit.msgIdx
        if session?.key == hit.sessionKey { return }
        loadingSession = true
        Task {
            defer { loadingSession = false }
            do { session = try await api.session(key: hit.sessionKey) } catch { errorText = error.localizedDescription }
        }
    }

    func openSource(number n: Int) {
        if let hit = askSources.first(where: { $0.n == n }) { open(hit) }
    }

    // MARK: actions

    func resume(_ s: SessionDetail) {
        let cwd = s.cwd.isEmpty ? NSHomeDirectory() : s.cwd
        let cmd = s.source == "claude" ? "claude --resume \(s.id)" : "codex resume \(s.id)"
        let script = "#!/bin/zsh -l\ncd \(shellQuote(cwd)) && \(cmd)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(s.id).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
