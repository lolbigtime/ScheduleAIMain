import Combine
import Foundation
import Folio

public struct RAGEvaluationQuery: Sendable, Hashable {
    public let text: String
    public let relevantDocumentIDs: Set<String>

    public init(text: String, relevantDocumentIDs: Set<String>) {
        self.text = text
        self.relevantDocumentIDs = relevantDocumentIDs
    }
}

public struct RAGEvaluationPerQuery: Sendable {
    public let query: RAGEvaluationQuery
    public let hits: [Snippet]
    public let relevantRetrievedCount: Int
    public let precisionAtK: Double
    public let recallAtK: Double
    public let reciprocalRank: Double
}

public struct RAGEvaluationMetrics: Sendable {
    public let meanPrecisionAtK: Double
    public let meanRecallAtK: Double
    public let meanReciprocalRank: Double
}

public struct RAGEvaluationResult: Sendable {
    public let perQuery: [RAGEvaluationPerQuery]
    public let overall: RAGEvaluationMetrics
    public let documents: [Engine.DocumentSummary]
}

public enum RAGEvaluationError: Error, LocalizedError, Sendable {
    case timeout(documentID: String, timeout: TimeInterval)
    case ingestFailed(documentID: String, reason: String)
    case progressStreamEnded(documentID: String)

    public var errorDescription: String? {
        switch self {
        case let .timeout(documentID, timeout):
            return "Timed out waiting for ingest of document \(documentID) after \(timeout) seconds."
        case let .ingestFailed(documentID, reason):
            return "Ingest failed for document \(documentID): \(reason)"
        case let .progressStreamEnded(documentID):
            return "Ingest progress stream ended unexpectedly for document \(documentID)."
        }
    }
}

public final class RAGEvaluationHarness: @unchecked Sendable {
    public struct DocumentFixture: Sendable {
        public enum Source: Sendable {
            case file(url: URL, kind: Engine.DocumentKind)
            case text(title: String, content: String)
        }

        public let label: String
        public let source: Source

        public init(label: String, source: Source) {
            self.label = label
            self.source = source
        }
    }

    private let engine: Engine
    private let ingestTimeout: TimeInterval
    private let defaultSearchLimit: Int

    public init(engine: Engine, ingestTimeout: TimeInterval = 120, defaultSearchLimit: Int = 10) {
        self.engine = engine
        self.ingestTimeout = ingestTimeout
        self.defaultSearchLimit = defaultSearchLimit
    }

    @discardableResult
    public func importDocuments(_ fixtures: [DocumentFixture]) async throws -> [String: DocumentFixture] {
        var mapping: [String: DocumentFixture] = [:]

        for fixture in fixtures {
            let identifier: String
            switch fixture.source {
            case let .file(url, kind):
                switch kind {
                case .pdf:
                    identifier = try await engine.importPDF(at: url)
                case .text:
                    identifier = try await engine.importDocument(at: url)
                }
            case let .text(title, content):
                identifier = try await engine.importText(title: title, content: content)
            }

            mapping[identifier] = fixture
        }

        try await waitForIngestCompletion(documentIDs: Array(mapping.keys))
        return mapping
    }

    public func waitForIngestCompletion(documentIDs: [String]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for documentID in documentIDs {
                group.addTask { try await self.waitForCompletion(documentID: documentID) }
            }

            while try await group.next() != nil {}
        }
    }

    public func snapshotDocuments() async -> [Engine.DocumentSummary] {
        await MainActor.run { engine.documents }
    }

    public func evaluate(queries: [RAGEvaluationQuery], limit: Int? = nil) async throws -> RAGEvaluationResult {
        guard !queries.isEmpty else {
            return RAGEvaluationResult(
                perQuery: [],
                overall: RAGEvaluationMetrics(meanPrecisionAtK: 0, meanRecallAtK: 0, meanReciprocalRank: 0),
                documents: await snapshotDocuments()
            )
        }

        let searchLimit = limit ?? defaultSearchLimit
        var perQuery: [RAGEvaluationPerQuery] = []
        var precisionSum = 0.0
        var recallSum = 0.0
        var reciprocalRankSum = 0.0

        for query in queries {
            let hits = try await engine.search(query: query.text, limit: searchLimit)
            let relevantRetrieved = hits.filter { query.relevantDocumentIDs.contains($0.sourceId) }
            let relevantRetrievedCount = relevantRetrieved.count
            let precisionDenominator = max(1, min(searchLimit, hits.count))
            let precision = Double(relevantRetrievedCount) / Double(precisionDenominator)
            let recall: Double
            if query.relevantDocumentIDs.isEmpty {
                recall = 1.0
            } else {
                recall = Double(relevantRetrievedCount) / Double(query.relevantDocumentIDs.count)
            }

            let reciprocalRank: Double
            if let index = hits.firstIndex(where: { query.relevantDocumentIDs.contains($0.sourceId) }) {
                reciprocalRank = 1.0 / Double(index + 1)
            } else {
                reciprocalRank = 0.0
            }

            precisionSum += precision
            recallSum += recall
            reciprocalRankSum += reciprocalRank

            perQuery.append(
                RAGEvaluationPerQuery(
                    query: query,
                    hits: hits,
                    relevantRetrievedCount: relevantRetrievedCount,
                    precisionAtK: precision,
                    recallAtK: recall,
                    reciprocalRank: reciprocalRank
                )
            )
        }

        let total = Double(perQuery.count)
        let metrics = RAGEvaluationMetrics(
            meanPrecisionAtK: precisionSum / total,
            meanRecallAtK: recallSum / total,
            meanReciprocalRank: reciprocalRankSum / total
        )

        let documents = await snapshotDocuments()
        return RAGEvaluationResult(perQuery: perQuery, overall: metrics, documents: documents)
    }

    private func waitForCompletion(documentID: String) async throws {
        try await withThrowingTaskGroup(of: Engine.IngestProgress.self) { group in
            group.addTask {
                let stream = await self.progressStream(for: documentID)
                for await progress in stream {
                    if progress.phase.isTerminal {
                        return progress
                    }
                }
                throw RAGEvaluationError.progressStreamEnded(documentID: documentID)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.ingestTimeout * 1_000_000_000))
                throw RAGEvaluationError.timeout(documentID: documentID, timeout: self.ingestTimeout)
            }

            guard let result = try await group.next() else {
                throw RAGEvaluationError.progressStreamEnded(documentID: documentID)
            }
            group.cancelAll()

            switch result.phase {
            case .completed:
                return
            case let .failed(reason):
                throw RAGEvaluationError.ingestFailed(documentID: documentID, reason: reason)
            default:
                throw RAGEvaluationError.progressStreamEnded(documentID: documentID)
            }
        }
    }

    private func progressStream(for documentID: String) async -> AsyncStream<Engine.IngestProgress> {
        let publisher = await MainActor.run { engine.observeProgress(for: documentID) }
        return AsyncStream { continuation in
            var cancellable: AnyCancellable?
            cancellable = publisher.sink { progress in
                continuation.yield(progress)
                if progress.phase.isTerminal {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                cancellable?.cancel()
            }
        }
    }
}
