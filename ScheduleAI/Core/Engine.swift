//
//  Engine.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import Foundation
import Combine
import Folio
#if canImport(PDFKit)
import PDFKit
#endif

@MainActor
public final class Engine: ObservableObject {
    public struct DocumentSummary: Identifiable, Hashable {
        public enum Status: Hashable {
            case idle
            case ingesting(phase: IngestPhase, progress: Double?)
            case ready
            case failed(message: String)
        }

        public enum IngestPhase: String, CaseIterable, Hashable {
            case queued = "Queued"
            case extracting = "Extracting"
            case ocr = "OCR"
            case chunking = "Chunking"
            case writing = "Writing"
        }

        public let id: UUID
        public var title: String
        public var pageCount: Int?
        public var fileSize: Int64
        public var status: Status
        public var updatedAt: Date
        public var detail: String?

        public init(
            id: UUID = UUID(),
            title: String,
            pageCount: Int? = nil,
            fileSize: Int64 = 0,
            status: Status = .idle,
            updatedAt: Date = .now,
            detail: String? = nil
        ) {
            self.id = id
            self.title = title
            self.pageCount = pageCount
            self.fileSize = fileSize
            self.status = status
            self.updatedAt = updatedAt
            self.detail = detail
        }

        public var fileSizeDescription: String {
            guard fileSize > 0 else { return "—" }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: fileSize)
        }
    }

    public struct SearchResult: Identifiable, Hashable {
        public let id: UUID
        public let documentID: UUID
        public var documentTitle: String
        public var pageRange: ClosedRange<Int>
        public var snippet: String
        public var score: Double

        public init(
            id: UUID = UUID(),
            documentID: UUID,
            documentTitle: String,
            pageRange: ClosedRange<Int>,
            snippet: String,
            score: Double
        ) {
            self.id = id
            self.documentID = documentID
            self.documentTitle = documentTitle
            self.pageRange = pageRange
            self.snippet = snippet
            self.score = score
        }
    }

    @Published
    public private(set) var documents: [DocumentSummary]

    @Published
    public private(set) var searchResults: [SearchResult]

    @Published
    public var lastError: String?

    @Published
    public var selectedDocument: DocumentSummary?

    public private(set) var folio: FolioEngine?

    private let fileManager: FileManager
    private let appSupportURL: URL

    public init(
        fileManager: FileManager = .default,
        documents: [DocumentSummary] = [],
        searchResults: [SearchResult] = []
    ) {
        self.fileManager = fileManager
        self.documents = documents
        self.searchResults = searchResults
        self.lastError = nil

        do {
            self.appSupportURL = try Engine.makeAppSupportURL(using: fileManager)
        } catch {
            self.appSupportURL = FileManager.default.temporaryDirectory
            self.lastError = error.localizedDescription
        }

        self.folio = nil
        configureFolioIfPossible()
    }

    private func configureFolioIfPossible() {
        // Folio's default loaders are currently internal. Provide a hook for when
        // public factory methods become available without failing compilation today.
        // Once Folio exposes those factories we can configure the engine here.
        // For now we simply create the directory eagerly so that future work can reuse it.
        do {
            let folioDirectory = appSupportURL.appendingPathComponent("Folio", isDirectory: true)
            try fileManager.createDirectory(at: folioDirectory, withIntermediateDirectories: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func makeAppSupportURL(using fileManager: FileManager) throws -> URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let baseURL = urls.first else {
            struct MissingURL: LocalizedError {
                var errorDescription: String? { "Unable to locate Application Support directory." }
            }
            throw MissingURL()
        }

        let appDirectory = baseURL.appendingPathComponent("ScheduleAI", isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory
    }

    private var documentsDirectory: URL {
        appSupportURL.appendingPathComponent("Docs", isDirectory: true)
    }

    // MARK: - Public API

    public func importPDF(url: URL) {
        do {
            let destinationDirectory = documentsDirectory
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            let destinationURL = destinationDirectory.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)

            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            let detailIdentifier = "Imported PDF: \(destinationURL.lastPathComponent)"
            documents.removeAll { $0.detail == detailIdentifier }

            var detectedPageCount: Int?
#if canImport(PDFKit)
            if let pdfDocument = PDFDocument(url: destinationURL) {
                detectedPageCount = pdfDocument.pageCount
            }
#endif

            let summary = DocumentSummary(
                title: destinationURL.deletingPathExtension().lastPathComponent,
                pageCount: detectedPageCount,
                fileSize: fileSize,
                status: .ingesting(phase: .queued, progress: 0),
                updatedAt: .now,
                detail: detailIdentifier
            )

            documents.append(summary)
            simulateIngest(for: summary.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func search(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }

        let loweredQuery = query.lowercased()
        let totalCount = max(documents.count, 1)
        searchResults = documents.enumerated().compactMap { index, document in
            let snippetSource = (document.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let baseSnippet: String
            let matchRange = snippetSource.range(of: query, options: [.caseInsensitive])

            if let matchRange {
                let lowerBound = snippetSource.distance(from: snippetSource.startIndex, to: matchRange.lowerBound)
                let start = max(0, lowerBound - 40)
                let end = min(snippetSource.count, lowerBound + query.count + 40)
                let startIndex = snippetSource.index(snippetSource.startIndex, offsetBy: start)
                let endIndex = snippetSource.index(snippetSource.startIndex, offsetBy: end)
                baseSnippet = String(snippetSource[startIndex..<endIndex])
            } else if snippetSource.isEmpty {
                baseSnippet = "No snippet available yet."
            } else if !snippetSource.lowercased().contains(loweredQuery) {
                return nil
            } else {
                baseSnippet = snippetSource
            }

            let occurrenceScore: Double
            if let matchRange {
                let occurrences = snippetSource.lowercased().components(separatedBy: loweredQuery).count - 1
                occurrenceScore = max(1, occurrences)
            } else {
                occurrenceScore = 0.1
            }

            let normalizedIndex = Double(totalCount - index) / Double(totalCount)
            let score = occurrenceScore + normalizedIndex

            return SearchResult(
                documentID: document.id,
                documentTitle: document.title,
                pageRange: 1...max(1, document.pageCount ?? 1),
                snippet: baseSnippet,
                score: score
            )
        }
        searchResults.sort { $0.score > $1.score }
    }

    public func ingestProgress(for document: DocumentSummary) -> (DocumentSummary.IngestPhase, Double?)? {
        guard case let .ingesting(phase, progress) = document.status else { return nil }
        return (phase, progress)
    }

    // MARK: - Helpers

    private func simulateIngest(for documentID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let phases: [DocumentSummary.IngestPhase] = [.queued, .extracting, .ocr, .chunking, .writing]
            for (index, phase) in phases.enumerated() {
                try await Task.sleep(nanoseconds: 600_000_000)
                if let docIndex = self.documents.firstIndex(where: { $0.id == documentID }) {
                    var document = self.documents[docIndex]
                    let progress = Double(index + 1) / Double(phases.count + 1)
                    document.status = .ingesting(phase: phase, progress: progress)
                    document.updatedAt = .now
                    self.documents[docIndex] = document
                }
            }

            try await Task.sleep(nanoseconds: 600_000_000)
            if let docIndex = self.documents.firstIndex(where: { $0.id == documentID }) {
                var document = self.documents[docIndex]
                document.status = .ready
                document.updatedAt = .now
                self.documents[docIndex] = document
            }
        }
    }
}

#if DEBUG
public extension Engine {
    static let preview: Engine = {
        let summaries: [DocumentSummary] = [
            DocumentSummary(
                title: "On-Device Retrieval",
                pageCount: 182,
                fileSize: 2_560_000,
                status: .ready,
                updatedAt: Date().addingTimeInterval(-3_600),
                detail: "On-device retrieval keeps private documents secure by avoiding server round trips. BM25 offers strong sparse retrieval, while embeddings enable semantic recall."
            ),
            DocumentSummary(
                title: "Gemma Embedding Guide",
                pageCount: 96,
                fileSize: 1_200_000,
                status: .ingesting(phase: .chunking, progress: 0.65),
                updatedAt: Date().addingTimeInterval(-900),
                detail: "Embedding Gemma produces high-quality vector representations for semantic and hybrid retrieval. Configure batch size, quantization, and normalization for optimal throughput."
            ),
            DocumentSummary(
                title: "OCR Cookbook",
                pageCount: 48,
                fileSize: 860_000,
                status: .failed(message: "Vision failed to detect text on page 12."),
                updatedAt: Date().addingTimeInterval(-12_000),
                detail: "Vision OCR handles scanned PDFs by rasterizing pages with sparse text density and running text recognition incrementally."
            )
        ]

        let engine = Engine(documents: summaries)
        engine.search(query: "retrieval")
        return engine
    }()
}
#endif
