import Foundation
import NaturalLanguage

enum NexToolSearchAvailabilityPolicy: Equatable, Sendable {
    case omitUnavailable
    case includeUnavailable
}

struct NexToolSearchCandidate: Codable, Equatable, Sendable {
    let tool: String
    let description: String
    let application: String
    let provider: String
    let isAvailable: Bool
    let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case tool, description, application, provider
        case isAvailable = "is_available"
        case unavailableReason = "unavailable_reason"
    }
}

struct NexToolSearchResult: Codable, Equatable, Sendable {
    let query: String
    let candidates: [NexToolSearchCandidate]
}

/// Local hybrid retrieval over semantic action metadata. It intentionally has
/// no app-name routing table: ranking comes from each action's own manifest.
/// Lexical matches win when present; a small on-device embedding fallback
/// covers natural capability wording such as “text someone” → Messages.
struct NexToolSearchEngine: Sendable {
    struct Document: Sendable {
        let tool: NexRegisteredTool
        let isAvailable: Bool
        let unavailableReason: String?

        init(
            tool: NexRegisteredTool,
            isAvailable: Bool = true,
            unavailableReason: String? = nil
        ) {
            self.tool = tool
            self.isAvailable = isAvailable
            self.unavailableReason = unavailableReason
        }
    }

    private struct RankedDocument {
        let document: Document
        let score: Double
    }

    static let defaultMaximumResults = 5
    static let maximumResults = 8

    func search(
        query: String,
        documents: [Document],
        maximumResults: Int = Self.defaultMaximumResults,
        availabilityPolicy: NexToolSearchAvailabilityPolicy = .omitUnavailable
    ) -> NexToolSearchResult {
        let limit = min(Self.maximumResults, max(1, maximumResults))
        let segments = Self.querySegments(query)
        guard !segments.isEmpty else { return .init(query: query, candidates: []) }

        let eligible = deduplicated(documents).filter {
            $0.tool.name != NexToolSearchService.actionName
                && (availabilityPolicy == .includeUnavailable || $0.isAvailable)
        }
        var bestScores: [String: RankedDocument] = [:]
        for segment in segments {
            let ranked = eligible.compactMap { document -> RankedDocument? in
                let score = score(document, for: segment)
                guard score >= 4 else { return nil }
                return RankedDocument(document: document, score: score)
            }
            .sorted(by: Self.rankOrder)

            // Retain at least one strong candidate per independent clause, then
            // globally rerank. This keeps compound requests from being consumed
            // by several near-identical actions from only one app.
            for candidate in ranked.prefix(max(1, min(3, limit))) {
                let name = candidate.document.tool.name
                if let existing = bestScores[name], existing.score >= candidate.score { continue }
                bestScores[name] = candidate
            }
        }

        let ranked = bestScores.values.sorted(by: Self.rankOrder).prefix(limit)
        return .init(
            query: query,
            candidates: ranked.map {
                .init(
                    tool: $0.document.tool.name,
                    description: $0.document.tool.description,
                    application: $0.document.tool.application,
                    provider: $0.document.tool.provider,
                    isAvailable: $0.document.isAvailable,
                    unavailableReason: $0.document.unavailableReason
                )
            }
        )
    }

    private func score(_ document: Document, for query: String) -> Double {
        let tool = document.tool
        let queryPhrase = Self.normalizedPhrase(query)
        let queryTerms = Set(Self.tokens(query))
        guard !queryTerms.isEmpty else { return 0 }

        let action = Self.normalizedPhrase(tool.name)
        let aliases = tool.aliases.map(Self.normalizedPhrase)
        let tags = tool.tags.map(Self.normalizedPhrase)
        let appProvider = [tool.application, tool.provider].map(Self.normalizedPhrase)
        let narratives = [tool.description] + tool.examples + tool.supportedWorkflows
        let fields = tool.schema.fields.flatMap { name, field in
            [name, field.description ?? ""] + field.allowedValues
        }

        var weightedTerms: [String: Double] = [:]
        Self.addTerms(from: [tool.name], weight: 9, into: &weightedTerms)
        Self.addTerms(from: tool.aliases, weight: 8, into: &weightedTerms)
        Self.addTerms(from: tool.tags, weight: 6, into: &weightedTerms)
        Self.addTerms(from: [tool.application, tool.provider], weight: 5, into: &weightedTerms)
        Self.addTerms(from: narratives, weight: 3, into: &weightedTerms)
        Self.addTerms(from: fields, weight: 2, into: &weightedTerms)

        let exactMatched = queryTerms.filter { weightedTerms[$0] != nil }
        let fuzzyMatches: [(String, Double)] = queryTerms
            .subtracting(exactMatched)
            .compactMap { queryTerm in
                guard queryTerm.count >= 5,
                      let match = weightedTerms
                        .filter({ Self.editDistance(queryTerm, $0.key) <= 1 })
                        .max(by: { $0.value < $1.value }) else { return nil }
                return (queryTerm, match.value * 0.7)
            }
        if exactMatched.isEmpty, fuzzyMatches.isEmpty {
            // The action manifests are canonical, but users naturally ask for
            // capabilities rather than the exact app or tool wording. Only
            // use embedding similarity as a fallback, so exact registry
            // matches remain deterministic and higher-confidence.
            let semanticScore = Self.semanticCapabilityScore(
                query: query,
                manifestValues: [
                    tool.name,
                    tool.application,
                    tool.provider,
                    tool.description
                ] + tool.aliases + tool.tags + narratives
            )
            guard semanticScore >= Self.minimumSemanticCapabilityScore else { return 0 }
            return 4 + semanticScore * 8
        }
        var score = exactMatched.reduce(0) { $0 + (weightedTerms[$1] ?? 0) }
        score += fuzzyMatches.reduce(0) { $0 + $1.1 }
        score += Double(exactMatched.count + fuzzyMatches.count) / Double(queryTerms.count) * 6

        if action == queryPhrase { score += 20 }
        if aliases.contains(queryPhrase) { score += 18 }
        if tags.contains(queryPhrase) { score += 12 }
        if appProvider.contains(where: { queryPhrase.contains($0) || $0.contains(queryPhrase) }) {
            score += 8
        }
        if aliases.contains(where: { queryPhrase.contains($0) || $0.contains(queryPhrase) }) {
            score += 10
        }
        return score
    }

    /// A deliberately conservative semantic fallback. We compare only the
    /// meaningful noun-like request terms with vocabulary supplied by a tool's
    /// registered manifest. That avoids a hidden, app-specific keyword router
    /// while allowing related language to discover the right capability.
    private static func semanticCapabilityScore(
        query: String,
        manifestValues: [String]
    ) -> Double {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return 0 }
        let queryTerms = semanticTokens(query)
            .filter { !$0.isEmpty && !semanticActionWords.contains($0) }
            .sorted()
            .prefix(8)
        let candidates = Array(Set(manifestValues.flatMap(semanticTokens)))
            .filter { $0.count > 2 && !semanticActionWords.contains($0) }
            .sorted()
            .prefix(72)
        guard !queryTerms.isEmpty, !candidates.isEmpty else { return 0 }

        var strongestMatch = 0.0
        for queryTerm in queryTerms where embedding.contains(queryTerm) {
            var nearestDistance: Double?
            for candidateTerm in candidates where embedding.contains(candidateTerm) {
                let distance = embedding.distance(between: queryTerm, and: candidateTerm)
                nearestDistance = min(nearestDistance ?? distance, distance)
            }
            guard let nearestDistance else { continue }

            // Distances near 0.95 capture related concepts such as
            // “text” and “message”; unrelated vocabulary is normally beyond
            // the 1.2 cutoff. Keep this intentionally strict.
            let similarity = max(0, min(1, (1.2 - nearestDistance) / 0.5))
            strongestMatch = max(strongestMatch, similarity)
        }
        return strongestMatch
    }

    private static let minimumSemanticCapabilityScore = 0.35
    private static let semanticActionWords: Set<String> = [
        "ask", "build", "can", "check", "create", "do", "find", "get", "help",
        "look", "make", "need", "open", "please", "run", "search", "send", "show",
        "start", "stop", "tell", "try", "use", "want", "write"
    ]

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return 2 }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                current[j + 1] = min(
                    min(current[j] + 1, previous[j + 1] + 1),
                    previous[j] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    private func deduplicated(_ documents: [Document]) -> [Document] {
        var retained: [String: Document] = [:]
        for document in documents.sorted(by: { $0.tool.name < $1.tool.name }) {
            let tool = document.tool
            let descriptionTerms = Set(Self.tokens(tool.description))
            let signature = [
                Self.normalizedPhrase(tool.application),
                Self.normalizedPhrase(tool.provider),
                tool.schema.fields.keys.sorted().joined(separator: ","),
                descriptionTerms.sorted().joined(separator: " ")
            ].joined(separator: "|")
            if retained[signature] == nil { retained[signature] = document }
        }
        return retained.values.sorted { $0.tool.name < $1.tool.name }
    }

    private static func rankOrder(_ lhs: RankedDocument, _ rhs: RankedDocument) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.document.isAvailable != rhs.document.isAvailable { return lhs.document.isAvailable }
        return lhs.document.tool.name < rhs.document.tool.name
    }

    private static func addTerms(
        from values: [String],
        weight: Double,
        into result: inout [String: Double]
    ) {
        for term in values.flatMap(tokens) {
            result[term] = max(result[term] ?? 0, weight)
        }
    }

    private static func querySegments(_ query: String) -> [String] {
        query
            .components(separatedBy: try! NSRegularExpression(
                pattern: #"\s+(?:and|then|also)\s+|[,;]"#,
                options: [.caseInsensitive]
            ))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !tokens($0).isEmpty }
    }

    private static func normalizedPhrase(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    private static func tokens(_ text: String) -> [String] {
        semanticTokens(text).map(stem)
    }

    /// Keeps the original word for embedding lookup. The lexical index uses
    /// `tokens(_:)` above and may stem words; embeddings must receive natural
    /// forms such as “messages,” not the index-only form “messag.”
    private static func semanticTokens(_ text: String) -> [String] {
        return text
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "do", "for",
        "from", "i", "in", "is", "it", "me", "my", "of", "on", "or", "please",
        "that", "the", "this", "to", "with", "you"
    ]

    private static func stem(_ token: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where token.count > suffix.count + 3 {
            if token.hasSuffix(suffix) { return String(token.dropLast(suffix.count)) }
        }
        return token
    }
}

/// Owns the internal `search_tools` action and snapshots the shared registry.
/// It never executes a discovered tool; it only returns an explicit allowlist.
actor NexToolSearchService {
    static let actionName = "search_tools"

    private let registry: NexToolRegistry
    private let computerRegistry: NexComputerRegistry?
    private let engine = NexToolSearchEngine()
    private var isRegistered = false

    init(registry: NexToolRegistry, computerRegistry: NexComputerRegistry? = nil) {
        self.registry = registry
        self.computerRegistry = computerRegistry
    }

    func registerIfNeeded() async throws {
        guard !isRegistered else { return }
        let service = self
        do {
            try await registry.register(.init(
                name: Self.actionName,
                description: "Discover the small set of registered semantic actions relevant to a request. This action retrieves tool definitions; it does not perform the requested work.",
                statusLabel: "Finding the right capability…",
                completionLabel: "Found relevant capabilities",
                spokenStatus: "Finding the right capability.",
                iconSystemName: "sparkle.magnifyingglass",
                permission: .automation,
                schema: .init(fields: [
                    "query": .init(.string, required: true, description: "Standalone description of the capability or workflow needed."),
                    "max_results": .init(.integer, description: "Maximum strong matches to return.", minimum: 1, maximum: Double(NexToolSearchEngine.maximumResults))
                ]),
                application: "Nex",
                provider: "Nexus Tool Registry",
                examples: ["Find an action that can play a playlist", "Find actions needed to research and email a summary"],
                aliases: ["find tools", "discover capabilities", "search actions"],
                tags: ["tool discovery", "capability search"]
            ) { arguments, _ in
                guard let query = arguments["query"]?.string else {
                    throw NexToolError.missingField("query")
                }
                let maximum = arguments["max_results"]?.integer ?? NexToolSearchEngine.defaultMaximumResults
                return await service.searchJSON(query: query, maximumResults: maximum)
            })
            isRegistered = true
        } catch NexToolError.duplicateRegistration(Self.actionName) {
            isRegistered = true
        }
    }

    func search(
        query: String,
        maximumResults: Int = NexToolSearchEngine.defaultMaximumResults,
        availabilityPolicy: NexToolSearchAvailabilityPolicy = .omitUnavailable
    ) async -> NexToolSearchResult {
        let definitions = await registry.definitions()
        let availability = await computerRegistry?.availabilitySnapshot() ?? [:]
        let documents = definitions.map { tool -> NexToolSearchEngine.Document in
            guard let state = availability[tool.name] else { return .init(tool: tool) }
            return .init(
                tool: tool,
                isAvailable: state.isAvailable,
                unavailableReason: state.reason
            )
        }
        return engine.search(
            query: query,
            documents: documents,
            maximumResults: maximumResults,
            availabilityPolicy: availabilityPolicy
        )
    }

    func definitions(for result: NexToolSearchResult) async -> [NexRegisteredTool] {
        let names = Set(result.candidates.filter(\.isAvailable).map(\.tool))
        return await registry.definitions().filter { names.contains($0.name) }
    }

    private func searchJSON(query: String, maximumResults: Int) async -> NexJSONValue {
        let result = await search(
            query: query,
            maximumResults: maximumResults,
            availabilityPolicy: .includeUnavailable
        )
        return .object([
            "query": .string(result.query),
            "candidates": .array(result.candidates.map { candidate in
                .object([
                    "tool": .string(candidate.tool),
                    "description": .string(candidate.description),
                    "application": .string(candidate.application),
                    "provider": .string(candidate.provider),
                    "is_available": .bool(candidate.isAvailable),
                    "unavailable_reason": candidate.unavailableReason.map(NexJSONValue.string) ?? .null
                ])
            })
        ])
    }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..<endIndex, in: self)
        var result: [String] = []
        var cursor = startIndex
        for match in expression.matches(in: self, range: range) {
            guard let matchRange = Range(match.range, in: self) else { continue }
            result.append(String(self[cursor..<matchRange.lowerBound]))
            cursor = matchRange.upperBound
        }
        result.append(String(self[cursor...]))
        return result
    }
}
