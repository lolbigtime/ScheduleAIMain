//
//  SearchView.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SearchView: View {
    @EnvironmentObject private var engine: Engine
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if engine.searchResults.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search library")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) {
            engine.search(query: query)
        }
        .onChange(of: query) { newValue in
            if newValue.isEmpty {
                engine.search(query: "")
            } else {
                engine.search(query: newValue)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Search your library")
                .font(.headline)
            Text("Enter a query to run BM25 retrieval across ingested documents.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var resultsList: some View {
        List(engine.searchResults) { result in
            SearchResultRow(result: result, query: query)
        }
        .listStyle(.plain)
    }

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

private struct SearchResultRow: View {
    let result: Engine.SearchResult
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.documentTitle)
                    .font(.headline)
                Spacer()
                Text(result.pageRangeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            highlightedSnippet
            Text("Score: \(result.score, format: .number.precision(.fractionLength(2)))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private var highlightedSnippet: some View {
        snippetText
            .font(.subheadline)
            .lineLimit(4)
    }

    private var snippetText: Text {
        result
            .snippetPieces(for: query)
            .map { piece -> Text in
                var segment = Text(piece.text)
                if piece.isHighlight {
                    segment = segment
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                } else {
                    segment = segment.foregroundStyle(.secondary)
                }
                return segment
            }
            .reduce(Text(""), +)
    }
}

private struct SnippetPiece: Hashable {
    let text: String
    let isHighlight: Bool
}

private extension Engine.SearchResult {
    var pageRangeDescription: String {
        if pageRange.lowerBound == pageRange.upperBound {
            return "p. \(pageRange.lowerBound)"
        }
        return "pp. \(pageRange.lowerBound)–\(pageRange.upperBound)"
    }

    func snippetPieces(for query: String) -> [SnippetPiece] {
        guard !query.isEmpty else {
            return [SnippetPiece(text: snippet, isHighlight: false)]
        }
        var pieces: [SnippetPiece] = []
        var searchRange: Range<String.Index>? = snippet.startIndex..<snippet.endIndex
        while
            let range = snippet.range(of: query, options: [.caseInsensitive], range: searchRange, locale: nil),
            let currentRange = searchRange
        {
            if range.lowerBound > currentRange.lowerBound {
                let prefix = snippet[currentRange.lowerBound..<range.lowerBound]
                pieces.append(SnippetPiece(text: String(prefix), isHighlight: false))
            }
            let highlightRange = snippet[range]
            pieces.append(SnippetPiece(text: String(highlightRange), isHighlight: true))
            searchRange = range.upperBound..<snippet.endIndex
        }
        if let searchRange, searchRange.lowerBound < searchRange.upperBound {
            let suffix = snippet[searchRange]
            pieces.append(SnippetPiece(text: String(suffix), isHighlight: false))
        }
        if pieces.isEmpty {
            pieces.append(SnippetPiece(text: snippet, isHighlight: false))
        }
        return pieces
    }
}

#Preview {
    NavigationStack {
        SearchView()
            .environmentObject(Engine.preview)
    }
}
