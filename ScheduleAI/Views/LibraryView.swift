//
//  LibraryView.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var engine: Engine
    @State private var isImporterPresented = false
    @State private var selectedDocument: Engine.DocumentSummary?

    var body: some View {
        NavigationStack {
            Group {
                if engine.documents.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Import PDF", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(item: $selectedDocument) { document in
                DocumentDetailView(document: document)
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Error", isPresented: errorBinding, presenting: engine.lastError) { _ in
            Button("OK", role: .cancel) {
                engine.lastError = nil
            }
        } message: { message in
            Text(message)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf]
        ) { result in
            switch result {
            case let .success(url):
                engine.importPDF(url: url)
            case let .failure(error):
                engine.lastError = error.localizedDescription
            }
        }
    }

    private var documentList: some View {
        List(engine.documents) { document in
            Button {
                selectedDocument = document
            } label: {
                DocumentRow(document: document)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { engine.lastError != nil },
            set: { newValue in
                if !newValue {
                    engine.lastError = nil
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Your library is empty")
                .font(.headline)
            Text("Import PDFs to start building an on-device knowledge base.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                isImporterPresented = true
            } label: {
                Label("Import your first PDF", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct DocumentRow: View {
    let document: Engine.DocumentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.headline)
                    detailLine
                }

                Spacer()

                statusBadge
            }

            if let (phase, progress) = progressInfo {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .accessibilityLabel(Text("Ingest progress"))
                Text(phase.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var detailLine: some View {
        let pageText = document.pageCount.map { "\($0) pages" } ?? "Page count pending"
        let sizeText = document.fileSizeDescription
        let updatedText = document.updatedAt.formatted(.relative(presentation: .named))

        return Text("\(pageText) • \(sizeText) • Updated \(updatedText)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var statusBadge: some View {
        switch document.status {
        case .idle:
            return AnyView(Text("Idle").font(.caption).padding(6).background(.thinMaterial).clipShape(Capsule()))
        case let .ingesting(phase, _):
            return AnyView(
                HStack(spacing: 4) {
                    ProgressView()
                    Text(phase.rawValue)
                        .font(.caption)
                }
                .padding(6)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            )
        case .ready:
            return AnyView(
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .padding(6)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
            )
        case let .failed(message):
            return AnyView(
                VStack(alignment: .trailing, spacing: 2) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                    Text(message)
                        .font(.caption2)
                        .lineLimit(2)
                }
                .font(.caption)
                .padding(6)
                .background(Color.red.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            )
        }
    }

    private var progressInfo: (Engine.DocumentSummary.IngestPhase, Double?)? {
        if case let .ingesting(phase, progress) = document.status {
            return (phase, progress)
        }
        return nil
    }
}

#Preview {
    NavigationStack {
        LibraryView()
            .environmentObject(Engine.preview)
    }
}
