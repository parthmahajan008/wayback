// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Parth Mahajan

import SwiftUI

/// Search-only popover behind the menu bar icon, scoped to Claude Code sessions.
@MainActor
@Observable
final class MenuSearchModel {
    var query = ""
    var results: [Hit] = []
    var searching = false
    private var task: Task<Void, Never>?

    func search() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            searching = true
            defer { searching = false }
            let filters = [URLQueryItem(name: "source", value: "claude"),
                           URLQueryItem(name: "include_subagents", value: "true"),
                           URLQueryItem(name: "limit", value: "25")]
            if let r = try? await Backend.shared.search(q, mode: .hybrid, filters: filters), !Task.isCancelled {
                results = r.results
            }
        }
    }
}

struct MenuSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = MenuSearchModel()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Claude Code sessions…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onChange(of: model.query) { model.search() }
                    .onSubmit { if let first = model.results.first { open(first) } }
                if model.searching { ProgressView().controlSize(.small) }
            }
            .padding(12)

            if !model.results.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results) { hit in
                            Button { open(hit) } label: {
                                MenuHitRow(hit: hit, terms: queryTerms(model.query))
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(height: 420)
            }
        }
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private func open(_ hit: Hit) {
        dismiss()
        app.open(hit)
        AppDelegate.showMain()
    }
}

private struct MenuHitRow: View {
    let hit: Hit
    let terms: [String]
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(hit.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 6)
                Text(Dates.relative(hit.ts ?? hit.updatedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(highlight(hit.snippet.replacingOccurrences(of: "\n", with: " "), terms: terms))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor.opacity(0.15) : .clear)
        .onHover { hovering = $0 }
    }
}
