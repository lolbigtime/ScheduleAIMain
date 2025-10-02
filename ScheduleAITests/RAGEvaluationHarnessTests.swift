import XCTest
@testable import ScheduleAI

final class RAGEvaluationHarnessTests: XCTestCase {
    func testHarnessIngestsAndEvaluatesQueries() async throws {
        let engine = Engine()
        let harness = RAGEvaluationHarness(engine: engine, ingestTimeout: 10, defaultSearchLimit: 5)

        let fixtures: [RAGEvaluationHarness.DocumentFixture] = [
            .init(
                label: "Concurrency",
                source: .text(
                    title: "Swift Concurrency Overview",
                    content: "Swift concurrency relies on structured concurrency, async/await, and actors to prevent data races."
                )
            ),
            .init(
                label: "Ranking",
                source: .text(
                    title: "BM25 Ranking",
                    content: "BM25 is a probabilistic ranking function that scores terms with idf and term frequency weights."
                )
            )
        ]

        let mapping = try await harness.importDocuments(fixtures)
        XCTAssertEqual(mapping.count, fixtures.count)

        let concurrencyID = try XCTUnwrap(mapping.first(where: { $0.value.label == "Concurrency" })?.key)
        let rankingID = try XCTUnwrap(mapping.first(where: { $0.value.label == "Ranking" })?.key)

        let queries = [
            RAGEvaluationQuery(text: "How does BM25 work?", relevantDocumentIDs: [rankingID]),
            RAGEvaluationQuery(text: "What does Swift concurrency provide?", relevantDocumentIDs: [concurrencyID])
        ]

        let result = try await harness.evaluate(queries: queries, limit: 5)

        XCTAssertEqual(result.perQuery.count, queries.count)
        XCTAssertEqual(result.documents.count, fixtures.count)

        for perQuery in result.perQuery {
            XCTAssertGreaterThanOrEqual(perQuery.precisionAtK, 0)
            XCTAssertLessThanOrEqual(perQuery.precisionAtK, 1)
            XCTAssertGreaterThanOrEqual(perQuery.recallAtK, 0)
            XCTAssertLessThanOrEqual(perQuery.recallAtK, 1)
            XCTAssertGreaterThanOrEqual(perQuery.reciprocalRank, 0)
            XCTAssertLessThanOrEqual(perQuery.reciprocalRank, 1)
        }

        XCTAssertGreaterThanOrEqual(result.overall.meanPrecisionAtK, 0)
        XCTAssertLessThanOrEqual(result.overall.meanPrecisionAtK, 1)
        XCTAssertGreaterThanOrEqual(result.overall.meanRecallAtK, 0)
        XCTAssertLessThanOrEqual(result.overall.meanRecallAtK, 1)
        XCTAssertGreaterThanOrEqual(result.overall.meanReciprocalRank, 0)
        XCTAssertLessThanOrEqual(result.overall.meanReciprocalRank, 1)
    }
}
