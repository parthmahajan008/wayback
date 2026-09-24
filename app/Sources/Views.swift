import SwiftUI

// MARK: - Root

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } content: {
            VStack(spacing: 0) {
                QueryBar()
                Divider()
                switch model.backendState {
                case .starting:
                    StartingView()
                case .failed(let msg):
                    FailedView(message: msg)
                case .ready:
                    if model.mode == .search { ResultsView() } else { AskView() }
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 480)
        } detail: {
            TranscriptView()
        }
        .onAppear { WindowOpener.shared.open = { openWindow(id: "main") } }
        // wayback://search?q=...   wayback://ask?q=...
        .onReceive(NotificationCenter.default.publisher(for: .openQueryURL)) { note in
            guard let url = note.object as? URL, let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value else { return }
            model.mode = url.host() == "ask" ? .ask : .search
            model.query = q
            model.submit()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section("Sources") {
                ForEach(SourceFilter.allCases) { s in
                    Button {
                        model.source = s
                        model.filtersChanged()
                    } label: {
                        HStack {
                            Label(s.label, systemImage: s.icon)
                            Spacer()
                            Text(count(for: s)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(model.source == s ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Section("Filters") {
                Picker("When", selection: $model.timeRange) {
                    ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: model.timeRange) { model.filtersChanged() }

                Picker("Project", selection: $model.project) {
                    Text("All projects").tag(String?.none)
                    Divider()
                    ForEach(model.projects.prefix(60)) { p in
                        Text("\(p.name)  ·  \(p.n)").tag(Optional(p.cwd)).help(p.cwd)
                    }
                }
                .onChange(of: model.project) { model.filtersChanged() }

                Toggle("Subagent sessions", isOn: $model.includeSubagents)
                    .onChange(of: model.includeSubagents) { model.filtersChanged() }
                Toggle("Automated runs (codex exec)", isOn: $model.includeExec)
                    .onChange(of: model.includeExec) { model.filtersChanged() }
            }
            Section("Matching") {
                Picker("Match", selection: $model.matchMode) {
                    ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)  // fit the row instead of overflowing the sidebar edge
                .onChange(of: model.matchMode) { model.filtersChanged() }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { IndexStatusCard().padding(10) }
    }

    private func count(for s: SourceFilter) -> String {
        guard let st = model.status else { return "" }
        switch s {
        case .all: return "\(st.sessions)"
        case .claude: return "\(st.claude)"
        case .codex: return "\(st.codex)"
        }
    }
}

struct IndexStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.status {
                HStack(spacing: 6) {
                    Circle().fill(s.phase == "idle" ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(phaseText(s)).font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        model.reindex()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(s.phase != "idle")
                    .help("Scan for new sessions now")
                }
                if s.phase == "embedding", s.toEmbed > 0 {
                    ProgressView(value: Double(s.embedded), total: Double(max(s.toEmbed, 1)))
                        .controlSize(.small)
                } else if s.phase == "parsing", s.filesTotal > 0 {
                    ProgressView(value: Double(s.filesDone), total: Double(max(s.filesTotal, 1)))
                        .controlSize(.small)
                }
                Text("\(s.chunks.formatted()) chunks · \(s.vectorsLoaded.formatted()) vectors")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(s.model.split(separator: "/").last ?? "") on \(s.device.uppercased())")
                    .font(.caption2).foregroundStyle(.tertiary)
                if let e = s.error { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2) }
            } else {
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func phaseText(_ s: IndexStatus) -> String {
        switch s.phase {
        case "scanning": return "Scanning transcripts…"
        case "parsing": return "Reading \(s.filesDone)/\(s.filesTotal) files"
        case "embedding": return "Embedding \(s.embedded.formatted())/\(s.toEmbed.formatted())"
        default:
            if s.lastRun == nil { return "Starting indexer…" }
            if let t = s.lastRun {
                return "Indexed " + Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named))
            }
            return "Up to date"
        }
    }
}

// MARK: - Query bar

struct QueryBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.mode == .search ? "magnifyingglass" : "sparkles")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                    .frame(width: 22)
                TextField(model.mode == .search ? "Search every Claude Code & Codex session…"
                                                : "Ask a question about your past sessions…",
                          text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { model.submit() }
                    .onChange(of: model.query) {
                        if model.mode == .search { model.runSearch(debounce: true) }
                    }
                if model.searching || model.asking {
                    ProgressView().controlSize(.small)
                }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))

            HStack {
                Picker("Mode", selection: $model.mode) {
                    Label("Search", systemImage: "magnifyingglass").tag(AppMode.search)
                    Label("Ask", systemImage: "sparkles").tag(AppMode.ask)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.mode) { if model.mode == .search { model.runSearch(debounce: false) } }

                Spacer()
                if model.mode == .ask {
                    ProviderPicker()
                } else if !model.lastSearched.isEmpty {
                    Text("\(model.results.count) results · \(model.tookMs) ms")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(12)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focused = true }
    }
}

struct ProviderPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Picker("Answer with", selection: $model.provider) {
                ForEach(model.providers) { Text($0.label).tag($0.id) }
            }
            .fixedSize()
            .onChange(of: model.provider) {
                if let p = model.providers.first(where: { $0.id == model.provider }), !p.models.contains(model.model) {
                    model.model = p.models.first ?? ""
                }
            }
            if let p = model.providers.first(where: { $0.id == model.provider }), p.models.count > 1 {
                Picker("Model", selection: $model.model) {
                    ForEach(p.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Results

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.results.isEmpty {
            EmptyState(
                icon: model.lastSearched.isEmpty ? "text.magnifyingglass" : "questionmark.folder",
                title: model.lastSearched.isEmpty ? "Search your agent history" : "No matches",
                subtitle: model.lastSearched.isEmpty
                    ? "Hybrid semantic + keyword search over every Claude Code and Codex session on this Mac. Try “why did the lint middleware not run” or a command, file or ticket ID."
                    : "Try different words, switch to Semantic, or widen the filters."
            )
        } else {
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(model.results) { hit in
                    HitRow(hit: hit, terms: queryTerms(model.lastSearched)).tag(hit.id)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct HitRow: View {
    let hit: Hit
    let terms: [String]
    var number: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let number {
                    Text("\(number)")
                        .font(.caption2.bold()).monospacedDigit()
                        .frame(width: 18, height: 18)
                        .background(Color.accentColor.opacity(0.2), in: Circle())
                }
                SourceBadge(source: hit.source)
                Text(hit.title).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(Dates.relative(hit.ts ?? hit.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label((hit.cwd as NSString).lastPathComponent.isEmpty ? "~" : (hit.cwd as NSString).lastPathComponent,
                      systemImage: "folder")
                if let b = hit.gitBranch, !b.isEmpty, b != "HEAD" { Label(b, systemImage: "arrow.triangle.branch").lineLimit(1) }
                RoleTag(role: hit.role)
                if hit.kind != "interactive" { Text(hit.kind).foregroundStyle(.orange) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(highlight(hit.snippet.replacingOccurrences(of: "\n", with: " "), terms: terms))
                .font(.callout)
                .lineLimit(4)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(.vertical, 5)
    }
}

struct SourceBadge: View {
    let source: String
    var body: some View {
        Text(source == "claude" ? "Claude" : "Codex")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(source == "claude" ? Color(red: 0.80, green: 0.42, blue: 0.25) : Color(red: 0.25, green: 0.55, blue: 0.95))
            .background((source == "claude" ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.3, green: 0.6, blue: 1)).opacity(0.15),
                        in: Capsule())
    }
}

struct RoleTag: View {
    let role: String
    var body: some View {
        Label(role == "user" ? "you" : role == "tool" ? "tool calls" : "agent",
              systemImage: role == "user" ? "person" : role == "tool" ? "terminal" : "cpu")
    }
}

// MARK: - Ask

struct AskView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.askedQuestion.isEmpty {
            EmptyState(
                icon: "sparkles",
                title: "Ask your sessions",
                subtitle: "Retrieves the most relevant excerpts locally, then answers with citations using \(model.providers.first(where: { $0.id == model.provider })?.label ?? "a local CLI"). Try “what did we decide about the shard budget in harbor?”"
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.askedQuestion).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if model.answer.isEmpty && model.asking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.askSources.isEmpty ? "Retrieving…" : "Reading \(model.askSources.count) excerpts…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        MarkdownView(text: model.answer, linkCitations: true)
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "cite", let n = Int(url.host() ?? "") {
                                    model.openSource(number: n)
                                    return .handled
                                }
                                return .systemAction
                            })
                    }
                    if model.asking && !model.answer.isEmpty {
                        Button("Stop", systemImage: "stop.circle") { model.stopAsk() }.controlSize(.small)
                    }
                    if !model.askSources.isEmpty {
                        Divider()
                        Text("Sources").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(model.askSources) { hit in
                                Button { model.open(hit) } label: {
                                    HitRow(hit: hit, terms: queryTerms(model.askedQuestion), number: hit.n)
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                        .background(model.selection == hit.id ? Color.accentColor.opacity(0.12) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.session {
            VStack(spacing: 0) {
                TranscriptHeader(session: s)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(s.messages.enumerated()), id: \.offset) { idx, m in
                                MessageView(message: m, focused: idx == model.focusMsgIdx,
                                            terms: queryTerms(model.mode == .search ? model.lastSearched : model.askedQuestion))
                                    .id(idx)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear { scroll(proxy) }
                    .onChange(of: model.focusMsgIdx) { scroll(proxy) }
                    .onChange(of: model.session?.key) { scroll(proxy) }
                }
            }
            .overlay { if model.loadingSession { ProgressView() } }
        } else {
            EmptyState(icon: "bubble.left.and.text.bubble.right", title: "No session selected",
                       subtitle: "Pick a result to read the full transcript, jump to the match and resume the session.")
                .overlay { if model.loadingSession { ProgressView() } }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let idx = model.focusMsgIdx else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(idx, anchor: .center) }
        }
    }
}

struct TranscriptHeader: View {
    @Environment(AppModel.self) private var model
    let session: SessionDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SourceBadge(source: session.source)
                Text(session.title.isEmpty ? "(untitled)" : session.title)
                    .font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Label(session.cwd.isEmpty ? "~" : session.cwd, systemImage: "folder").lineLimit(1).truncationMode(.head)
                if let b = session.gitBranch, !b.isEmpty, b != "HEAD" { Label(b, systemImage: "arrow.triangle.branch") }
                Label(Dates.full(session.startedAt), systemImage: "clock")
                Label("\(session.messages.count)", systemImage: "text.bubble")
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Resume in Terminal", systemImage: "terminal") { model.resume(session) }
                    .disabled(session.kind == "exec")
                Button("Reveal Transcript", systemImage: "doc.text.magnifyingglass") { model.reveal(session.path) }
                Button("Copy ID", systemImage: "doc.on.doc") { model.copy(session.id) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageView: View {
    let message: TranscriptMessage
    let focused: Bool
    let terms: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoleTag(role: message.role).font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == "user" ? Color.accentColor : .secondary)
                Spacer()
                Text(Dates.full(message.ts)).font(.caption2).foregroundStyle(.tertiary)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.yellow.opacity(0.8) : .clear, lineWidth: 2))
    }

    @ViewBuilder private var content: some View {
        let long = message.text.count > 1800 && !focused
        let text = long && !expanded ? String(message.text.prefix(1800)) + "…" : message.text
        switch message.role {
        case "tool":
            Text(highlight(text, terms: terms))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case "assistant":
            MarkdownView(text: text, terms: terms)
        default:
            Text(highlight(text, terms: terms)).textSelection(.enabled)
        }
        if long {
            Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                .buttonStyle(.link).font(.caption)
        }
    }

    private var background: some ShapeStyle {
        switch message.role {
        case "user": return AnyShapeStyle(Color.accentColor.opacity(0.10))
        case "tool": return AnyShapeStyle(Color.primary.opacity(0.035))
        default: return AnyShapeStyle(Color.primary.opacity(0.06))
        }
    }
}

// MARK: - Shared

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StartingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting local search engine…").font(.headline)
            Text("The first launch sets up a Python environment with the embedding model. This can take a few minutes.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text("Couldn't start the search backend").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                Button("Open Log") { NSWorkspace.shared.open(Backend.shared.logURL) }
                Button("Retry") {
                    model.backendState = .starting
                    Task { await model.start() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Text helpers

private let stopWords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "was", "we", "what", "when", "where", "which", "who", "why", "with", "you", "your", "did", "do", "does", "not", "no", "can", "could", "should", "would", "have", "has", "had", "but", "if", "then", "so", "there", "their", "they"]

func queryTerms(_ q: String) -> [String] {
    q.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./")).inverted)
        .filter { $0.count > 1 && !stopWords.contains($0) }
}

/// Ranges where `term` matches at a word start ("pr" matches "PR #12", not "production" or "prior").
func wordStartRanges(of term: String, in lower: String) -> [Range<String.Index>] {
    var out: [Range<String.Index>] = []
    var start = lower.startIndex
    while let r = lower.range(of: term, range: start..<lower.endIndex) {
        let startsWord = r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter
        // Short terms ("pr", "db") must be whole words; longer ones may be prefixes ("review" → "reviewing").
        let endsWord = term.count > 3 || r.upperBound == lower.endIndex || !lower[r.upperBound].isLetter
        if startsWord && endsWord { out.append(r) }
        start = r.upperBound
    }
    return out
}

func highlight(_ text: String, terms: [String]) -> AttributedString {
    var attr = AttributedString(text)
    guard !terms.isEmpty else { return attr }
    let lower = text.lowercased()
    for term in terms {
        for r in wordStartRanges(of: term, in: lower) {
            if let lo = AttributedString.Index(r.lowerBound, within: attr),
               let hi = AttributedString.Index(r.upperBound, within: attr) {
                attr[lo..<hi].backgroundColor = Color.yellow.opacity(0.35)
                attr[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
            }
        }
    }
    return attr
}

/// Small block-level Markdown renderer: headings, bullets, code fences and
/// inline formatting. Citations like [3] become clickable `cite://3` links.
struct MarkdownView: View {
    let text: String
    var terms: [String] = []
    var linkCitations = false

    private enum Block: Hashable {
        case heading(String, Int)
        case code(String)
        case bullet(String, Int, String)
        case para(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t, let level):
                    Text(inline(t)).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 4)
                case .code(let t):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(t).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8)
                    }
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                case .bullet(let t, let indent, let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(t))
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .para(let t):
                    Text(inline(t))
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        func flush() {
            if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces), level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                flush()
                let indent = raw.prefix(while: { $0 == " " }).count / 2
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    out.append(.bullet(String(line.dropFirst(2)), indent, "•"))
                } else {
                    let num = line.prefix(while: { $0.isNumber })
                    out.append(.bullet(String(line.dropFirst(num.count + 1)).trimmingCharacters(in: .whitespaces), indent, "\(num)."))
                }
            } else {
                para.append(raw)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        var src = s
        if linkCitations {
            src = src.replacingOccurrences(of: #"\[(\d{1,2})\]"#, with: "[[$1]](cite://$1)", options: .regularExpression)
        }
        var attr = (try? AttributedString(markdown: src, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        if !terms.isEmpty {
            let plain = String(attr.characters).lowercased()
            for term in terms {
                for r in wordStartRanges(of: term, in: plain) {
                    let lo = attr.index(attr.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: r.lowerBound))
                    let hi = attr.index(lo, offsetByCharacters: term.count)
                    attr[lo..<hi].backgroundColor = Color.yellow.opacity(0.35)
                }
            }
        }
        return attr
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("WaybackFocusSearch")
    static let openQueryURL = Notification.Name("WaybackOpenQueryURL")
}

final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?
}
