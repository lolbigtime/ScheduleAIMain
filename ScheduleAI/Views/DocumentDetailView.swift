//
//  DocumentDetailView.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import SwiftUI

struct DocumentDetailView: View {
    let document: Engine.DocumentSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                metadata
                Divider()
                statusSection
                if let detail = document.detail {
                    Divider()
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title)
                .font(.title2)
                .fontWeight(.semibold)
            if let pages = document.pageCount {
                Text("\(pages) pages")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(document.fileSizeDescription, systemImage: "doc.richtext")
            Label(document.updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch document.status {
        case .idle:
            Label("Waiting for ingest", systemImage: "hourglass")
        case let .ingesting(phase, progress):
            VStack(alignment: .leading, spacing: 8) {
                Label("Ingesting", systemImage: "gear")
                ProgressView(value: progress)
                Text("Phase: \(phase.rawValue)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready for search", systemImage: "checkmark.seal")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Ingest failed", systemImage: "exclamationmark.triangle")
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        DocumentDetailView(document: Engine.preview.documents.first!)
    }
}
