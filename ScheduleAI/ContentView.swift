//
//  ContentView.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import SwiftUI
import Folio
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = Engine()
    @State private var activeImporter: ImportIntent?
    @State private var showFileImporter = false
    @State private var showTextComposer = false
    @State private var composerTitle: String = "Quick Notes"
    @State private var composerBody: String = SampleContent.demoText
    @State private var searchQuery: String = ""
    @State private var searchResults: [SearchDisplayResult] = []
    @State private var isSearching = false
    @State private var isProcessingImport = false
    @State private var alertInfo: AlertInfo?

    var body: some View {
        ZStack {
            AngularGradient(gradient: Gradient(colors: [Color(#colorLiteral(red: 0.121, green: 0.153, blue: 0.298, alpha: 1)),
                                                        Color(#colorLiteral(red: 0.071, green: 0.188, blue: 0.365, alpha: 1)),
                                                        Color(#colorLiteral(red: 0.282, green: 0.094, blue: 0.329, alpha: 1)),
                                                        Color(#colorLiteral(red: 0.078, green: 0.216, blue: 0.345, alpha: 1))]),
                            center: .center).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    header
                    ingestCard
                    databaseCard
                    retrievalCard
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: activeImporter?.contentTypes ?? [.pdf]) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task { await handleImport(of: url, intent: activeImporter ?? .pdf) }
            case let .failure(error):
                alertInfo = AlertInfo(title: "Import Failed", message: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showTextComposer) {
            NavigationView {
                VStack(spacing: 16) {
                    TextField("Title", text: $composerTitle)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                    TextEditor(text: $composerBody)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal)
                    Spacer()
                }
                .padding(.top)
                .background(Color(.systemBackground))
                .navigationTitle("Paste Text")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showTextComposer = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Ingest") {
                            Task { await handleTextImport() }
                        }
                        .disabled(composerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert(item: $alertInfo) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text("On-Device RAG Lab")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 10)

            Text("Ingest PDFs & text, peek at the Folio database, and sanity-check retrieval — all wrapped in a glassy iOS 17 aesthetic.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
    }

    private var ingestCard: some View {
        GlassCard(icon: "square.and.arrow.down.on.square",
                  title: "Quick Ingest",
                  subtitle: "Drop in a PDF or raw text to kick off Folio's pipeline.") {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Button(action: { presentImporter(.pdf) }) {
                        Label {
                            Text("Import PDF")
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                        } icon: {
                            Image(systemName: "doc.richtext")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button(action: { presentImporter(.textFile) }) {
                        Label {
                            Text("Import Text")
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button(action: { showTextComposer = true }) {
                        Label {
                            Text("Paste Snippet")
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                        } icon: {
                            Image(systemName: "square.and.pencil")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(GlassButtonStyle())
                }

                if isProcessingImport {
                    ProgressView("Processing import…")
                        .tint(.white)
                } else if let lastError = engine.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                } else {
                    Text("Supports PDFKit extraction with OCR fallback and plain-text drops. Duplicates are deduped by SHA-256.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private var databaseCard: some View {
        GlassCard(icon: "internaldrive",
                  title: "RAG Library",
                  subtitle: "All indexed sources stored in Application Support/Folio.") {
            VStack(alignment: .leading, spacing: 20) {
                metricsRow
                if engine.documents.isEmpty {
                    Text("No documents yet. Import a PDF or paste text to populate the on-device index.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(engine.documents) { doc in
                            DocumentRow(document: doc,
                                        progress: engine.progress[doc.id],
                                        isActive: engine.inFlightDocumentIDs.contains(doc.id))
                        }
                    }
                }
            }
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 16) {
            MetricChip(title: "Documents",
                       value: "\(engine.documents.count)")
            MetricChip(title: "Chunks",
                       value: "\(engine.documents.reduce(0) { $0 + $1.chunkCount })")
            let totalPages = engine.documents.compactMap(\.pageCount).reduce(0, +)
            MetricChip(title: "Pages",
                       value: totalPages == 0 ? "—" : "\(totalPages)")
        }
    }

    private var retrievalCard: some View {
        GlassCard(icon: "magnifyingglass.circle.fill",
                  title: "Retrieval Sandbox",
                  subtitle: "Run a BM25 query against the Folio snippet index.") {
            VStack(alignment: .leading, spacing: 20) {
                QueryField(query: $searchQuery,
                           isSearching: isSearching,
                           onSubmit: performSearch)

                if isSearching {
                    ProgressView("Searching…")
                        .tint(.white)
                } else if searchResults.isEmpty {
                    Text("Try searching for a phrase from one of your documents to verify BM25 hits and excerpts.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(searchResults) { result in
                            ResultRow(result: result)
                        }
                    }
                }
            }
        }
    }

    private func presentImporter(_ intent: ImportIntent) {
        activeImporter = intent
        showFileImporter = true
    }

    @MainActor
    private func handleImport(of url: URL, intent: ImportIntent) async {
        guard !isProcessingImport else { return }
        isProcessingImport = true
        defer { isProcessingImport = false }

        do {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            switch intent {
            case .pdf:
                _ = try await engine.importPDF(at: url)
            case .textFile:
                _ = try await engine.importDocument(at: url)
            }
        } catch {
            alertInfo = AlertInfo(title: "Import Failed", message: error.localizedDescription)
        }
    }

    @MainActor
    private func handleTextImport() async {
        guard !composerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        showTextComposer = false
        isProcessingImport = true
        defer { isProcessingImport = false }

        do {
            _ = try await engine.importText(title: composerTitle, content: composerBody)
        } catch {
            alertInfo = AlertInfo(title: "Import Failed", message: error.localizedDescription)
        }
    }

    private func performSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation { searchResults = [] }
            return
        }

        isSearching = true
        Task {
            do {
                let snippets = try await engine.search(query: trimmed, limit: 12)
                let docs = await MainActor.run { engine.documents }
                let mapped = snippets.map { snippet in
                    let match = docs.first(where: { $0.id == snippet.sourceId })
                    return SearchDisplayResult(snippet: snippet,
                                               title: match?.title ?? "Untitled",
                                               kind: match?.kind ?? .pdf)
                }
                await MainActor.run {
                    withAnimation(.easeInOut) {
                        self.searchResults = mapped
                    }
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    self.alertInfo = AlertInfo(title: "Search Error", message: error.localizedDescription)
                    self.isSearching = false
                }
            }
        }
    }
}

// MARK: - Supporting Views & Models

private struct GlassCard<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .font(.system(size: 32))
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
            }
            content
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 25, x: 0, y: 18)
        )
    }
}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(configuration.isPressed ? 0.6 : 0.3), lineWidth: 1)
                    )
            )
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(configuration.isPressed ? 0.15 : 0.25), radius: configuration.isPressed ? 5 : 12, x: 0, y: configuration.isPressed ? 3 : 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct MetricChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(title.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .tracking(1.5)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

private struct DocumentRow: View {
    let document: Engine.DocumentSummary
    let progress: Engine.IngestProgress?
    let isActive: Bool

    private var sizeFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: document.kind.iconName)
                    .foregroundStyle(.white)
                    .font(.title3)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(sizeLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                StatusBadge(status: document.status, isActive: isActive)
            }

            if let message = progress?.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 16) {
                InfoPill(icon: "doc", label: document.kind.displayName)
                InfoPill(icon: "number.square", label: "\(document.chunkCount) chunks")
                InfoPill(icon: "book", label: pagesLabel)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var sizeLine: String {
        let formatter = sizeFormatter
        let sizeString = formatter.string(fromByteCount: document.fileSize)
        let dateString = document.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "Updated \(dateString) • \(sizeString)"
    }

    private var pagesLabel: String {
        if let pages = document.pageCount {
            return pages == 1 ? "1 page" : "\(pages) pages"
        }
        return "—"
    }
}

private struct StatusBadge: View {
    let status: Engine.DocumentStatus
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isActive {
                ProgressView()
                    .tint(status.accentColor)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: status.icon)
            }
            Text(status.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(status.accentColor.opacity(0.18))
        .foregroundStyle(status.accentColor)
        .clipShape(Capsule())
    }
}

private struct InfoPill: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
        .foregroundStyle(.white)
    }
}

private struct QueryField: View {
    @Binding var query: String
    var isSearching: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.8))
            TextField("Search indexed chunks", text: $query, onCommit: onSubmit)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
            Button("Go") { onSubmit() }
                .buttonStyle(GlassButtonStyle())
                .disabled(isSearching)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

private struct ResultRow: View {
    let result: SearchDisplayResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: result.kind.iconName)
                    .foregroundStyle(.white.opacity(0.9))
                Text(result.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(result.scoreString)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }
            if let page = result.pageLabel {
                Text(page)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(result.excerpt)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

// MARK: - Models & Extensions

private struct SearchDisplayResult: Identifiable {
    let id = UUID()
    let snippet: Snippet
    let title: String
    let kind: Engine.DocumentKind

    var excerpt: String { snippet.excerpt }
    var scoreString: String { String(format: "%.3f", snippet.score) }
    var pageLabel: String? {
        guard let page = snippet.page else { return nil }
        return "Page \(page)"
    }
}

private struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum ImportIntent {
    case pdf
    case textFile

    var contentTypes: [UTType] {
        switch self {
        case .pdf:
            return [.pdf]
        case .textFile:
            return [.plainText, .utf8PlainText]
        }
    }
}

private enum SampleContent {
    static let demoText = """
    Folio keeps everything on-device. Paste any notes, transcripts, or scratch docs here and we'll chunk them with ~1K token windows, ready for BM25 retrieval and future hybrid search.
    """
}

private extension Engine.DocumentKind {
    var iconName: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        }
    }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .text: return "Text"
        }
    }
}

private extension Engine.DocumentStatus {
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .queued: return "Queued"
        case .extracting: return "Extracting"
        case .ocr: return "OCR"
        case .chunking: return "Chunking"
        case .writing: return "Writing"
        case .completed: return "Ready"
        case .failed(_): return "Failed"
        }
    }

    var accentColor: Color {
        switch self {
        case .idle, .queued: return .white
        case .extracting, .ocr, .chunking, .writing: return Color(#colorLiteral(red: 0.42, green: 0.75, blue: 1, alpha: 1))
        case .completed: return Color(#colorLiteral(red: 0.36, green: 0.84, blue: 0.56, alpha: 1))
        case .failed(_): return Color(#colorLiteral(red: 0.96, green: 0.47, blue: 0.44, alpha: 1))
        }
    }

    var icon: String {
        switch self {
        case .completed: return "checkmark"
        case .failed(_): return "xmark.octagon.fill"
        case .idle: return "pause"
        case .queued: return "clock"
        case .extracting: return "doc.text.magnifyingglass"
        case .ocr: return "eye"
        case .chunking: return "square.stack.3d.forward.dottedline"
        case .writing: return "externaldrive"
        }
    }
}

#Preview {
    ContentView()
}
