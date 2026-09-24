import Foundation

/// Starts (or attaches to) the local Python backend and talks to its HTTP API.
final class Backend: @unchecked Sendable {
    static let shared = Backend()

    let base = URL(string: "http://127.0.0.1:8765")!
    private var process: Process?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    var logURL: URL { dataDir.appendingPathComponent("backend.log") }

    private var dataDir: URL {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Wayback")
        // Carry over an index built before the app was renamed from "Session Search".
        let legacy = support.appendingPathComponent("SessionSearch")
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
            try? fm.removeItem(at: dir.appendingPathComponent("venv"))  // has absolute paths; uv rebuilds it from cache
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: lifecycle

    func isHealthy() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Reuse a backend that is already running (e.g. a dev server), otherwise
    /// spawn the bundled one via `uv`, which creates its venv on first launch.
    func ensureRunning() async throws {
        if await isHealthy() { return }
        guard let backendDir = Bundle.main.resourceURL?.appendingPathComponent("backend"),
              FileManager.default.fileExists(atPath: backendDir.path) else {
            throw NSError(domain: "Wayback", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled backend not found"])
        }
        // Prefer the uv bundled in the app, so recipients don't need to install anything.
        let bundledUV = Bundle.main.url(forAuxiliaryExecutable: "uv")?.path ?? ""
        let uv = [bundledUV, "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv").path,
                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/uv").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let uv else {
            throw NSError(domain: "Wayback", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "uv not found. Reinstall Wayback or run `brew install uv`."])
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--frozen", "--project", backendDir.path, "python", "-m", "wayback.server"]
        p.currentDirectoryURL = backendDir
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = dataDir.appendingPathComponent("venv").path
        env["PYTHONPATH"] = backendDir.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin"
        env["TOKENIZERS_PARALLELISM"] = "false"
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        try p.run()
        process = p

        // First launch installs torch into the venv, which can take a while.
        for _ in 0..<900 {
            if await isHealthy() { return }
            if !p.isRunning {
                throw NSError(domain: "Wayback", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Backend exited. See \(logURL.path)"])
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw NSError(domain: "Wayback", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Backend did not start in time"])
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    // MARK: API

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { comps.queryItems = items }
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "Wayback", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"])
        }
        return try decoder.decode(T.self, from: data)
    }

    func status() async throws -> IndexStatus { try await get("status") }
    func projects() async throws -> [Project] { try await get("projects") }
    func providers() async throws -> [Provider] { try await get("providers") }
    func session(key: String) async throws -> SessionDetail {
        try await get("session", [URLQueryItem(name: "key", value: key)])
    }

    func search(_ q: String, mode: MatchMode, filters: [URLQueryItem]) async throws -> SearchResponse {
        try await get("search", [URLQueryItem(name: "q", value: q),
                                 URLQueryItem(name: "mode", value: mode.rawValue)] + filters)
    }

    func reindex() async {
        var req = URLRequest(url: base.appendingPathComponent("reindex"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    enum AskEvent {
        case sources([Hit])
        case delta(String)
        case done
    }

    func ask(_ body: [String: Any]) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("ask"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    req.timeoutInterval = 600
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = Data(line.dropFirst(6).utf8)
                        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "sources":
                            struct Wrap: Decodable { let sources: [Hit] }
                            continuation.yield(.sources(try decoder.decode(Wrap.self, from: data).sources))
                        case "delta":
                            continuation.yield(.delta(obj["text"] as? String ?? ""))
                        default:
                            continuation.yield(.done)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
