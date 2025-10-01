//
//  Engine.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import Foundation
import Folio
import Combine
import CryptoKit
import OSLog

public final class Engine: ObservableObject {

    public enum DocumentKind: String, CaseIterable, Equatable {
        case pdf
        case text

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .text: return "txt"
            }
        }

        init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "pdf": self = .pdf
            case "txt", "text": self = .text
            default: return nil
            }
        }
    }

    public struct DocumentSummary: Identifiable, Equatable {
        public let id: String
        public var title: String
        public var pageCount: Int?
        public var chunkCount: Int
        public var fileSize: Int64
        public var status: DocumentStatus
        public var updatedAt: Date
        public var fileURL: URL
        public var kind: DocumentKind

        public init(id: String,
                    title: String,
                    pageCount: Int?,
                    chunkCount: Int,
                    fileSize: Int64,
                    status: DocumentStatus,
                    updatedAt: Date,
                    fileURL: URL,
                    kind: DocumentKind) {
            self.id = id
            self.title = title
            self.pageCount = pageCount
            self.chunkCount = chunkCount
            self.fileSize = fileSize
            self.status = status
            self.updatedAt = updatedAt
            self.fileURL = fileURL
            self.kind = kind
        }
    }

    public enum DocumentStatus: Equatable {
        case idle
        case queued
        case extracting
        case ocr
        case chunking
        case writing
        case completed
        case failed(reason: String)

        var isTerminal: Bool {
            switch self {
            case .completed, .failed:
                return true
            default:
                return false
            }
        }
    }

    public struct IngestProgress: Equatable {
        public let phase: DocumentStatus
        public let message: String?
        public let updatedAt: Date

        public init(phase: DocumentStatus, message: String?, updatedAt: Date = Date()) {
            self.phase = phase
            self.message = message
            self.updatedAt = updatedAt
        }

        public static func idle() -> IngestProgress {
            .init(phase: .idle, message: nil)
        }
    }

    enum EngineError: Error {
        case engineReleased
    }

    @Published public private(set) var documents: [DocumentSummary] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var inFlightDocumentIDs: Set<String> = []
    @Published public private(set) var progress: [String: IngestProgress] = [:]

    public let folio: FolioEngine

    private let docsDirectory: URL
    private enum SourceKind: String, CaseIterable {
        case pdf
        case text

        init(documentKind: DocumentKind) {
            switch documentKind {
            case .pdf: self = .pdf
            case .text: self = .text
            }
        }

        var documentKind: DocumentKind {
            switch self {
            case .pdf: return .pdf
            case .text: return .text
            }
        }

        var fileExtension: String { documentKind.fileExtension }

        init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "pdf": self = .pdf
            case "txt", "text": self = .text
            default: return nil
            }
        }
    }
    private let ingestQueue = DispatchQueue(label: "com.scheduleai.engine.ingest", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.scheduleai.engine", category: "Engine")
    private var progressSubjects: [String: CurrentValueSubject<IngestProgress, Never>] = [:]
    private let isoFormatter: ISO8601DateFormatter
    private var ingestConfig: FolioConfig

    public init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folioDir = appSupport.appendingPathComponent("Folio", isDirectory: true)
        let docsDir = appSupport.appendingPathComponent("Docs", isDirectory: true)

        try? fileManager.createDirectory(at: folioDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let dbURL = folioDir.appendingPathComponent("folio.sqlite")
        let pdfLoader = PDFDocumentLoader()
        let textLoader = TextDocumentLoader()
        let chunker = UniversalChunker()

        self.docsDirectory = docsDir
        do {
            self.folio = try FolioEngine(databaseURL: dbURL,
                                         loaders: [pdfLoader, textLoader],
                                         chunker: chunker,
                                         embedder: nil)
        } catch {
            fatalError("Failed to initialize FolioEngine: \(error)")
        }

        var config = FolioConfig()
        config.chunking.maxTokensPerChunk = 1000
        config.chunking.overlapTokens = 150
        self.ingestConfig = config

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter

        refreshDocuments()
        resumePendingIngestions()
    }

    @discardableResult
    public func importPDF(at sourceURL: URL) async throws -> String {
        try await importDocument(from: sourceURL, kind: .pdf, preferredTitle: sourceURL.deletingPathExtension().lastPathComponent)
    }

    @discardableResult
    public func importDocument(at sourceURL: URL) async throws -> String {
        let ext = sourceURL.pathExtension.lowercased()
        let kind: SourceKind = SourceKind(fileExtension: ext) ?? .pdf
        return try await importDocument(from: sourceURL, kind: kind, preferredTitle: sourceURL.deletingPathExtension().lastPathComponent)
    }

    @discardableResult
    public func importText(title: String, content: String) async throws -> String {
        let data = Data(content.utf8)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SourceKind.text.fileExtension)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await importDocument(from: tempURL, kind: .text, preferredTitle: title)
    }

    public func observeProgress(for documentId: String) -> AnyPublisher<IngestProgress, Never> {
        if Thread.isMainThread {
            return subject(for: documentId).eraseToAnyPublisher()
        } else {
            var publisher: AnyPublisher<IngestProgress, Never>!
            DispatchQueue.main.sync {
                publisher = self.subject(for: documentId).eraseToAnyPublisher()
            }
            return publisher
        }
    }

    public func search(query: String, limit: Int = 10) async throws -> [Snippet] {
        try await withCheckedThrowingContinuation { continuation in
            ingestQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: EngineError.engineReleased)
                    return
                }

                do {
                    let hits = try self.folio.search(query, limit: limit)
                    continuation.resume(returning: hits)
                } catch {
                    self.publishError(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteDocument(id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ingestQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: EngineError.engineReleased)
                    return
                }

                do {
                    try self.folio.deleteSource(id)
                    let fm = FileManager.default
                    for kind in SourceKind.allCases {
                        let fileURL = self.fileURL(for: id, kind: kind)
                        let markerURL = self.pendingMarkerURL(for: id, kind: kind)
                        try? fm.removeItem(at: fileURL)
                        try? fm.removeItem(at: markerURL)
                    }

                    self.publishOnMain {
                        self.progress.removeValue(forKey: id)
                        self.progressSubjects.removeValue(forKey: id)
                        self.inFlightDocumentIDs.remove(id)
                        self.documents.removeAll { $0.id == id }
                    }

                    continuation.resume()
                } catch {
                    self.publishError(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func importDocument(from sourceURL: URL, kind: SourceKind, preferredTitle: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ingestQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: EngineError.engineReleased)
                    return
                }

                do {
                    let preparation = try self.prepareDocument(at: sourceURL, kind: kind)

                    if preparation.isDuplicate {
                        self.logger.debug("Duplicate import detected for \(preparation.id, privacy: .public). Skipping ingest.")
                        self.emitProgress(.completed, message: "Duplicate import skipped.", for: preparation.id)
                        self.refreshDocuments()
                        continuation.resume(returning: preparation.id)
                        return
                    }

                    self.publishOnMain {
                        let placeholder = self.makePlaceholderSummary(id: preparation.id,
                                                                       fileURL: preparation.destination,
                                                                       size: preparation.size,
                                                                       kind: kind.documentKind,
                                                                       preferredTitle: preferredTitle)
                        self.upsertDocument(placeholder)
                    }

                    self.writePendingMarker(for: preparation.id, kind: kind)

                    self.enqueueIngest(sourceId: preparation.id,
                                       fileURL: preparation.destination,
                                       kind: kind,
                                       isResuming: false)

                    continuation.resume(returning: preparation.id)
                } catch {
                    self.publishError(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enqueueIngest(sourceId: String, fileURL: URL, kind: SourceKind, isResuming: Bool) {
        emitProgress(.queued, message: isResuming ? "Resuming pending import…" : "Queued for ingest", for: sourceId)

        ingestQueue.async { [weak self] in
            guard let self else { return }

            self.logger.debug("Starting ingest for \(sourceId, privacy: .public) (resume: \(isResuming, privacy: .public))")
            self.emitProgress(.extracting, message: "Extracting text…", for: sourceId)

            do {
                let result: (pages: Int, chunks: Int)
                switch kind {
                case .pdf:
                    result = try self.folio.ingest(.pdf(fileURL),
                                                    sourceId: sourceId,
                                                    config: self.ingestConfig)
                case .text:
                    let text = try self.loadTextContents(from: fileURL)
                    result = try self.folio.ingest(.text(text, name: fileURL.lastPathComponent),
                                                    sourceId: sourceId,
                                                    config: self.ingestConfig)
                }

                self.emitProgress(.chunking, message: "Chunked \(result.chunks) segments", for: sourceId)
                self.emitProgress(.writing, message: "Persisting index…", for: sourceId)

                self.handleIngestSuccess(sourceId: sourceId,
                                         fileURL: fileURL,
                                         kind: kind.documentKind,
                                         pages: result.pages,
                                         chunks: result.chunks)
            } catch {
                self.handleIngestFailure(sourceId: sourceId, error: error)
            }
        }
    }

    private func loadTextContents(from fileURL: URL) throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            let data = try Data(contentsOf: fileURL)
            if let string = String(data: data, encoding: .utf8) {
                return string
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func handleIngestSuccess(sourceId: String, fileURL: URL, kind: DocumentKind, pages: Int, chunks: Int) {
        removePendingMarker(for: sourceId)

        emitProgress(.completed,
                     message: "Indexed \(chunks) chunks across \(pages) pages",
                     for: sourceId)

        publishOnMain {
            if let index = self.documents.firstIndex(where: { $0.id == sourceId }) {
                self.documents[index].fileURL = fileURL
                self.documents[index].kind = kind
                self.documents[index].pageCount = pages
                self.documents[index].chunkCount = chunks
            }
        }

        logger.info("Completed ingest for \(sourceId, privacy: .public) — pages: \(pages), chunks: \(chunks)")
        refreshDocuments()
    }

    private func handleIngestFailure(sourceId: String, error: Error) {
        removePendingMarker(for: sourceId)
        logger.error("Failed ingest for \(sourceId, privacy: .public): \(error.localizedDescription, privacy: .public)")

        emitProgress(.failed(reason: error.localizedDescription),
                     message: "Import failed",
                     for: sourceId)
    }

    private func refreshDocuments() {
        ingestQueue.async { [weak self] in
            guard let self else { return }

            do {
                let sources = try self.folio.listSources()
                let fileManager = FileManager.default
                var progressSnapshot: [String: IngestProgress] = [:]

                DispatchQueue.main.sync {
                    progressSnapshot = self.progress
                }

                let summaries: [DocumentSummary] = sources.map { source in
                    let fileURL = self.resolveFileURL(for: source.id, fileNameHint: source.filePath)
                    let attributes = (try? fileManager.attributesOfItem(atPath: fileURL.path)) ?? [:]
                    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    let updated = self.isoFormatter.date(from: source.importedAt) ?? Date()
                    let currentStatus = progressSnapshot[source.id]?.phase ?? .completed
                    let kind = DocumentKind(fileExtension: fileURL.pathExtension) ?? .pdf

                    return DocumentSummary(id: source.id,
                                            title: source.displayName,
                                            pageCount: source.pages,
                                            chunkCount: source.chunks,
                                            fileSize: size,
                                            status: currentStatus,
                                            updatedAt: updated,
                                            fileURL: fileURL,
                                            kind: kind)
                }

                self.publishOnMain {
                    var merged = summaries

                    let transient = self.documents.filter { existing in
                        !summaries.contains(where: { $0.id == existing.id })
                    }

                    merged.append(contentsOf: transient)
                    merged.sort { $0.updatedAt > $1.updatedAt }
                    self.documents = merged
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    private func resumePendingIngestions() {
        ingestQueue.async { [weak self] in
            guard let self else { return }

            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(at: self.docsDirectory,
                                                                      includingPropertiesForKeys: nil) else { return }

            let pendingMarkers = contents.filter { $0.pathExtension == "pending" }
            if !pendingMarkers.isEmpty {
                self.logger.notice("Resuming \(pendingMarkers.count) pending ingest task(s) after relaunch.")
            }

            for marker in pendingMarkers {
                let withoutPending = marker.deletingPathExtension()
                let id = withoutPending.deletingPathExtension().lastPathComponent
                let ext = withoutPending.pathExtension

                guard let kind = SourceKind(fileExtension: ext) else {
                    try? fileManager.removeItem(at: marker)
                    continue
                }

                let docURL = self.fileURL(for: id, kind: kind)

                guard fileManager.fileExists(atPath: docURL.path) else {
                    try? fileManager.removeItem(at: marker)
                    continue
                }

                let attributes = (try? fileManager.attributesOfItem(atPath: docURL.path)) ?? [:]
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

                self.publishOnMain {
                    let placeholder = self.makePlaceholderSummary(id: id,
                                                                   fileURL: docURL,
                                                                   size: size,
                                                                   kind: kind.documentKind,
                                                                   preferredTitle: nil)
                    self.upsertDocument(placeholder)
                }

                self.enqueueIngest(sourceId: id, fileURL: docURL, kind: kind, isResuming: true)
            }
        }
    }

    private func prepareDocument(at url: URL, kind: SourceKind) throws -> (id: String, destination: URL, size: Int64, isDuplicate: Bool) {
        let fileManager = FileManager.default
        let fingerprint = try fingerprint(forFileAt: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        if let existing = existingFileURLIfExists(for: fingerprint) {
            return (fingerprint, existing, size, true)
        }

        let destination = fileURL(for: fingerprint, kind: kind)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            let wrapped = NSError(domain: "Engine",
                                   code: 500,
                                   userInfo: [NSLocalizedDescriptionKey: "Unable to copy document into library: \(error.localizedDescription)"])
            throw wrapped
        }

        return (fingerprint, destination, size, false)
    }

    private func fingerprint(forFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            do {
                if let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    return true
                }
                return false
            } catch {
                return false
            }
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for id: String, kind: SourceKind) -> URL {
        docsDirectory.appendingPathComponent("\(id).\(kind.fileExtension)")
    }

    private func resolveFileURL(for id: String, fileNameHint: String?) -> URL {
        let fm = FileManager.default

        if let hint = fileNameHint,
           let ext = hint.split(separator: ".").last.map(String.init),
           let kind = SourceKind(fileExtension: ext) {
            let candidate = fileURL(for: id, kind: kind)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        for kind in SourceKind.allCases {
            let candidate = fileURL(for: id, kind: kind)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return fileURL(for: id, kind: .pdf)
    }

    private func existingFileURLIfExists(for id: String) -> URL? {
        let fm = FileManager.default
        for kind in SourceKind.allCases {
            let candidate = fileURL(for: id, kind: kind)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func pendingMarkerURL(for id: String, kind: SourceKind) -> URL {
        fileURL(for: id, kind: kind).appendingPathExtension("pending")
    }

 
    private func writePendingMarker(for id: String, kind: SourceKind) {
        let marker = pendingMarkerURL(for: id, kind: kind)
        try? "pending".data(using: .utf8)?.write(to: marker, options: .atomic)
    }

    private func removePendingMarker(for id: String) {
        for kind in SourceKind.allCases {
            let marker = pendingMarkerURL(for: id, kind: kind)
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private func makePlaceholderSummary(id: String, fileURL: URL, size: Int64, kind: DocumentKind, preferredTitle: String?) -> DocumentSummary {
        DocumentSummary(id: id,
                        title: preferredTitle ?? fileURL.deletingPathExtension().lastPathComponent,
                        pageCount: nil,
                        chunkCount: 0,
                        fileSize: size,
                        status: .queued,
                        updatedAt: Date(),
                        fileURL: fileURL,
                        kind: kind)
    }

    private func upsertDocument(_ summary: DocumentSummary) {
        if let index = documents.firstIndex(where: { $0.id == summary.id }) {
            documents[index] = summary
        } else {
            documents.append(summary)
        }
        documents.sort { $0.updatedAt > $1.updatedAt }
    }

    private func updateDocument(_ id: String, with progress: IngestProgress) {
        if let index = documents.firstIndex(where: { $0.id == id }) {
            documents[index].status = progress.phase
            documents[index].updatedAt = progress.updatedAt
        }
    }

    private func emitProgress(_ status: DocumentStatus, message: String?, for id: String) {
        let update = IngestProgress(phase: status, message: message)
        setProgress(update, for: id)
    }

    private func setProgress(_ update: IngestProgress, for id: String) {
        publishOnMain {
            self.progress[id] = update
            self.subject(for: id).send(update)

            if update.phase.isTerminal {
                self.inFlightDocumentIDs.remove(id)
            } else if update.phase != .idle {
                self.inFlightDocumentIDs.insert(id)
            }

            self.updateDocument(id, with: update)
        }
    }
    

    private func subject(for id: String) -> CurrentValueSubject<IngestProgress, Never> {
        assert(Thread.isMainThread, "Progress subjects must be accessed on the main thread")
        if let existing = progressSubjects[id] {
            return existing
        }

        let initial = progress[id] ?? IngestProgress.idle()
        let subject = CurrentValueSubject<IngestProgress, Never>(initial)
        progressSubjects[id] = subject
        return subject
    }

    private func publishOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func publishError(_ error: Error) {
        logger.error("Engine error: \(error.localizedDescription, privacy: .public)")
        publishOnMain {
            self.lastError = error.localizedDescription
        }
    }
}
