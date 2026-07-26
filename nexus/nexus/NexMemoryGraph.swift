import AppKit
import SpriteKit
import SwiftUI

struct NexMemoryGraphNode: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let kind: NexMemoryKind?
    let documentType: NexMemoryDocumentType
    let importance: Double
    let relativePath: String
}

struct NexMemoryGraphEdge: Identifiable, Equatable, Hashable, Sendable {
    var id: String { "\(source.uuidString.lowercased()):\(target.uuidString.lowercased())" }
    let source: UUID
    let target: UUID
    let strength: Double
}

struct NexMemoryGraphSnapshot: Equatable, Sendable {
    let nodes: [NexMemoryGraphNode]
    let edges: [NexMemoryGraphEdge]

    static let empty = NexMemoryGraphSnapshot(nodes: [], edges: [])

    init(nodes: [NexMemoryGraphNode], edges: [NexMemoryGraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    init(documents: [NexCanonicalDocument], rawNotes: [NexVaultGraphNote] = []) {
        // The graph is the vault graph, not a graph of just one memory
        // folder. Chats and every active durable note get a stable clickable
        // node; the canvas can therefore mirror the files a user sees in
        // Obsidian instead of hiding most of the vault behind a RAG filter.
        let visibleDocuments = documents
            .filter { $0.status == .active }
            .sorted { $0.updatedAt > $1.updatedAt }
        let canonicalNodes: [NexMemoryGraphNode] = visibleDocuments.map { document in
            return .init(
                id: document.id,
                title: document.title,
                kind: document.memoryKind,
                documentType: document.type,
                importance: document.importance,
                relativePath: document.relativePath
            )
        }
        let indexedPaths = Set(visibleDocuments.map(\.relativePath))
        let handwrittenNodes: [NexMemoryGraphNode] = rawNotes
            .filter { !indexedPaths.contains($0.relativePath) }
            .map { note in
                .init(
                    id: NexObsidianVault.stableUUID(for: "vault-graph:\(note.relativePath)"),
                    title: note.title,
                    kind: nil,
                    documentType: .memory,
                    importance: 0.34,
                    relativePath: note.relativePath
                )
            }
        // Use one representative retrieval unit per note and only shared
        // front-matter relationships. Every node remains real, but the globe
        // stays readable instead of displaying every sentence and one-off tag.
        var indexedUnitNodes: [NexMemoryGraphNode] = []
        var metadataNodes: [UUID: NexMemoryGraphNode] = [:]
        var metadataEdges: [NexMemoryGraphEdge] = []
        var metadataUseCount: [String: Int] = [:]
        for document in visibleDocuments {
            let categories: [(String, [String])] = [
                ("project", document.projects),
                ("topic", document.topics),
                ("entity", document.entities),
                ("decision", document.decisions),
                ("thread", document.openThreads)
            ]
            for (category, values) in categories {
                for value in Set(values.map(Self.normalize)).filter({ !$0.isEmpty }) {
                    metadataUseCount["\(category):\(value)", default: 0] += 1
                }
            }
        }

        func appendMetadata(
            _ values: [String],
            category: String,
            kind: NexMemoryKind,
            document: NexCanonicalDocument
        ) {
            for value in Set(values.map(Self.normalize)).filter({ !$0.isEmpty }) {
                // Values attached to only one note are already represented by
                // that note. Shared values become useful graph bridges.
                guard metadataUseCount["\(category):\(value)", default: 0] > 1 else { continue }
                let id = NexObsidianVault.stableUUID(for: "vault-metadata:\(category):\(value)")
                if metadataNodes[id] == nil {
                    metadataNodes[id] = .init(
                        id: id,
                        title: "\(category.capitalized): \(value)",
                        kind: kind,
                        documentType: .memory,
                        importance: 0.42,
                        relativePath: document.relativePath
                    )
                }
                metadataEdges.append(.init(source: document.id, target: id, strength: 0.34))
            }
        }

        for document in visibleDocuments {
            let representativeChunks = document.chunks
                .filter { $0.kind == "summary" || $0.kind == "memory" }
                .prefix(1)
            for chunk in representativeChunks {
                let id = NexObsidianVault.stableUUID(for: "vault-chunk:\(document.id.uuidString):\(chunk.id)")
                indexedUnitNodes.append(.init(
                    id: id,
                    title: "\(document.title) · \(chunk.kind) \(chunk.ordinal + 1)",
                    kind: document.memoryKind,
                    documentType: document.type,
                    importance: max(0.22, document.importance * 0.56),
                    relativePath: document.relativePath
                ))
                metadataEdges.append(.init(source: document.id, target: id, strength: 0.40))
            }
            appendMetadata(document.projects, category: "project", kind: .project, document: document)
            appendMetadata(document.topics, category: "topic", kind: .knowledge, document: document)
            appendMetadata(document.entities, category: "entity", kind: .person, document: document)
            appendMetadata(document.decisions, category: "decision", kind: .decision, document: document)
            appendMetadata(document.openThreads, category: "thread", kind: .goal, document: document)
        }

        nodes = canonicalNodes
            + handwrittenNodes
            + indexedUnitNodes
            + metadataNodes.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        var builtEdges: [NexMemoryGraphEdge] = []
        for leftIndex in visibleDocuments.indices {
            for rightIndex in visibleDocuments.indices where rightIndex > leftIndex {
                let left = visibleDocuments[leftIndex]
                let right = visibleDocuments[rightIndex]
                let sharedProjects = Set(left.projects.map(Self.normalize)).intersection(right.projects.map(Self.normalize))
                let sharedEntities = Set(left.entities.map(Self.normalize)).intersection(right.entities.map(Self.normalize))
                let sharedTopics = Set(left.topics.map(Self.normalize)).intersection(right.topics.map(Self.normalize))
                let relationshipCount = sharedProjects.count * 3 + sharedEntities.count * 2 + sharedTopics.count
                guard relationshipCount > 0 else { continue }
                builtEdges.append(.init(
                    source: left.id,
                    target: right.id,
                    strength: min(1, 0.3 + Double(relationshipCount) * 0.16)
                ))
            }
        }
        // A node pair can share several front-matter fields. Keep the
        // strongest relationship and eliminate visually duplicated lines.
        for edge in metadataEdges {
            if let index = builtEdges.firstIndex(where: { $0.id == edge.id }) {
                if edge.strength > builtEdges[index].strength { builtEdges[index] = edge }
            } else {
                builtEdges.append(edge)
            }
        }
        edges = builtEdges
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NexMemoryPhysicsGraphView: NSViewRepresentable {
    let graph: NexMemoryGraphSnapshot
    let vaultURL: URL
    let theme: NexusGlassTheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SKView {
        let view = NexMemoryGraphSKView()
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        let scene = NexMemoryGraphScene(size: CGSize(width: 1_200, height: 800), vaultURL: vaultURL, theme: theme)
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.apply(graph)
        view.presentScene(scene)
        context.coordinator.scene = scene
        // `makeNSView` already applied this graph. Persist it in the
        // coordinator so SwiftUI's first update does not reset the physics
        // scene and replay its opening animation.
        context.coordinator.graph = graph
        context.coordinator.theme = theme
        return view
    }

    func updateNSView(_ view: SKView, context: Context) {
        guard context.coordinator.graph != graph || context.coordinator.theme != theme else { return }
        context.coordinator.graph = graph
        context.coordinator.theme = theme
        context.coordinator.scene?.apply(graph, theme: theme)
    }

    final class Coordinator {
        fileprivate var scene: NexMemoryGraphScene?
        var graph = NexMemoryGraphSnapshot.empty
        var theme: NexusGlassTheme = .graphite
    }
}

private final class NexMemoryGraphSKView: SKView {
    private var pointerTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }
}

private final class NexMemoryGraphScene: SKScene {
    private let graphCamera = SKCameraNode()
    private let vaultURL: URL
    private var memoryNodes: [UUID: SKShapeNode] = [:]
    private var memoryPaths: [UUID: String] = [:]
    private var edgeNodes: [NexMemoryGraphEdge: SKShapeNode] = [:]
    private var draggedNode: SKShapeNode?
    private var dragOffset = CGPoint.zero
    private var previousPointer = CGPoint.zero
    private var isPanning = false
    private var theme: NexusGlassTheme

    init(size: CGSize, vaultURL: URL, theme: NexusGlassTheme) {
        self.vaultURL = vaultURL
        self.theme = theme
        super.init(size: size)
        physicsWorld.gravity = .zero
        addChild(graphCamera)
        camera = graphCamera
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ graph: NexMemoryGraphSnapshot, theme: NexusGlassTheme? = nil) {
        if let theme { self.theme = theme }
        removeAllChildren()
        addChild(graphCamera)
        memoryNodes.removeAll()
        memoryPaths.removeAll()
        edgeNodes.removeAll()

        for (index, memory) in graph.nodes.enumerated() {
            // Seed every note across the full globe rather than clustering
            // important notes in its center. Physics keeps the arrangement
            // alive without turning it into a pile of labels.
            let angle = Double(index) * 2.399963
            let normalized = sqrt(Double(index + 1) / Double(max(graph.nodes.count, 1)))
            let radiusX = CGFloat(330 * normalized)
            let radiusY = CGFloat(285 * normalized)
            let radius = CGFloat(2.8 + min(3.0, max(0, memory.importance) * 3.0))
            let node = SKShapeNode(circleOfRadius: radius)
            node.name = memory.id.uuidString
            node.fillColor = color(for: memory)
            node.strokeColor = node.fillColor.withAlphaComponent(0.35)
            node.glowWidth = 0.7
            node.position = CGPoint(x: cos(angle) * radiusX, y: sin(angle) * radiusY)
            node.physicsBody = SKPhysicsBody(circleOfRadius: radius + 1.5)
            node.physicsBody?.affectedByGravity = false
            node.physicsBody?.linearDamping = 5.6
            node.physicsBody?.restitution = 0.08
            node.physicsBody?.allowsRotation = false

            addChild(node)
            addLabel(for: memory, to: node, radius: radius)
            memoryNodes[memory.id] = node
            memoryPaths[memory.id] = memory.relativePath
        }

        for edge in graph.edges {
            let line = SKShapeNode()
            line.strokeColor = palette.edge.withAlphaComponent(0.07 + edge.strength * 0.10)
            line.lineWidth = 0.35 + edge.strength * 0.35
            line.zPosition = -1
            addChild(line)
            edgeNodes[edge] = line
        }
        graphCamera.position = .zero
        graphCamera.setScale(1.14)
    }

    override func update(_ currentTime: TimeInterval) {
        let nodes = Array(memoryNodes.values)
        for leftIndex in nodes.indices {
            for rightIndex in nodes.indices where rightIndex > leftIndex {
                let left = nodes[leftIndex]
                let right = nodes[rightIndex]
                let delta = CGVector(dx: left.position.x - right.position.x, dy: left.position.y - right.position.y)
                let distanceSquared = max(625, delta.dx * delta.dx + delta.dy * delta.dy)
                let distance = sqrt(distanceSquared)
                let force = min(6, 2_050 / distanceSquared)
                let vector = CGVector(dx: delta.dx / distance * force, dy: delta.dy / distance * force)
                left.physicsBody?.applyForce(vector)
                right.physicsBody?.applyForce(CGVector(dx: -vector.dx, dy: -vector.dy))
            }
        }

        for (edge, line) in edgeNodes {
            guard let source = memoryNodes[edge.source], let target = memoryNodes[edge.target] else { continue }
            let delta = CGVector(dx: target.position.x - source.position.x, dy: target.position.y - source.position.y)
            let distance = max(1, hypot(delta.dx, delta.dy))
            let desired: CGFloat = 180
            let force = (distance - desired) * 0.012 * edge.strength
            let vector = CGVector(dx: delta.dx / distance * force, dy: delta.dy / distance * force)
            source.physicsBody?.applyForce(vector)
            target.physicsBody?.applyForce(CGVector(dx: -vector.dx, dy: -vector.dy))
            let path = CGMutablePath(); path.move(to: source.position); path.addLine(to: target.position)
            line.path = path
        }

        for node in nodes where node !== draggedNode {
            node.physicsBody?.applyForce(CGVector(dx: -node.position.x * 0.0025, dy: -node.position.y * 0.0025))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = scenePoint(for: event)
        previousPointer = point
        if let node = nodes(at: point).compactMap({ $0 as? SKShapeNode }).first(where: { $0.name != nil }) {
            if event.clickCount == 2,
               let name = node.name,
               let id = UUID(uuidString: name),
               let relativePath = memoryPaths[id] {
                NSWorkspace.shared.open(vaultURL.appendingPathComponent(relativePath))
                return
            }
            draggedNode = node
            dragOffset = CGPoint(x: node.position.x - point.x, y: node.position.y - point.y)
            node.physicsBody?.isDynamic = false
            node.run(.scale(to: 1.2, duration: 0.12))
        } else {
            isPanning = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = scenePoint(for: event)
        if let draggedNode {
            draggedNode.position = CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y)
        } else if isPanning {
            graphCamera.position.x -= event.deltaX * graphCamera.xScale
            graphCamera.position.y += event.deltaY * graphCamera.yScale
        }
        previousPointer = point
    }

    override func mouseUp(with event: NSEvent) {
        draggedNode?.physicsBody?.isDynamic = true
        draggedNode?.run(.scale(to: 1, duration: 0.12))
        draggedNode = nil
        isPanning = false
    }

    override func scrollWheel(with event: NSEvent) {
        let next = min(2.4, max(0.35, graphCamera.xScale * (1 + event.scrollingDeltaY * 0.012)))
        graphCamera.setScale(next)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = scenePoint(for: event)
        let hovered = nodes(at: point)
            .compactMap { $0 as? SKShapeNode }
            .compactMap(\.name)
            .compactMap(UUID.init(uuidString:))
            .first
        applyFocus(hovered)
    }

    override func mouseExited(with event: NSEvent) {
        applyFocus(nil)
    }

    private func applyFocus(_ hovered: UUID?) {
        guard let hovered else {
            memoryNodes.values.forEach { $0.alpha = 1 }
            edgeNodes.values.forEach { $0.alpha = 1 }
            return
        }
        let connected = edgeNodes.keys.reduce(into: Set([hovered])) { result, edge in
            if edge.source == hovered { result.insert(edge.target) }
            if edge.target == hovered { result.insert(edge.source) }
        }
        for (id, node) in memoryNodes {
            node.alpha = connected.contains(id) ? 1 : 0.16
        }
        for (edge, line) in edgeNodes {
            line.alpha = edge.source == hovered || edge.target == hovered ? 1 : 0.08
        }
    }

    private func scenePoint(for event: NSEvent) -> CGPoint {
        guard let view else { return .zero }
        let viewPoint = view.convert(event.locationInWindow, from: nil)
        return convertPoint(fromView: viewPoint)
    }

    private func addLabel(for memory: NexMemoryGraphNode, to node: SKShapeNode, radius: CGFloat) {
        // Mirrors the small monospaced labels used in the Experience controls,
        // rather than the system body font used by picker values.
        let label = SKLabelNode(fontNamed: "SF Mono Semibold")
        label.text = compactTitle(memory.title)
        label.fontSize = 8
        label.fontColor = palette.label
        label.verticalAlignmentMode = .top
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: -(radius + 7))
        label.zPosition = 1
        label.alpha = 0.88
        node.addChild(label)
    }

    private func compactTitle(_ title: String) -> String {
        let normalized = title
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 25 else { return normalized }
        return String(normalized.prefix(23)) + "…"
    }

    private var palette: NexMemoryGraphPalette {
        NexMemoryGraphPalette(theme: theme)
    }

    private func color(for node: NexMemoryGraphNode) -> NSColor {
        if node.documentType == .chat { return palette.chat }
        guard let kind = node.kind else { return palette.knowledge }
        switch kind {
        case .preference, .personalContext: return palette.profile
        case .project: return palette.project
        case .goal: return palette.goal
        case .person: return palette.person
        case .organization: return palette.organization
        case .decision: return palette.decision
        case .knowledge: return palette.knowledge
        }
    }
}

private struct NexMemoryGraphPalette {
    let profile: NSColor
    let project: NSColor
    let goal: NSColor
    let person: NSColor
    let organization: NSColor
    let decision: NSColor
    let knowledge: NSColor
    let chat: NSColor
    let edge: NSColor
    let label: NSColor

    init(theme: NexusGlassTheme) {
        switch theme {
        case .graphite:
            profile = .init(srgbRed: 0.66, green: 0.75, blue: 0.77, alpha: 1)
            project = .init(srgbRed: 0.69, green: 0.71, blue: 0.66, alpha: 1)
            goal = .init(srgbRed: 0.80, green: 0.74, blue: 0.58, alpha: 1)
            person = .init(srgbRed: 0.72, green: 0.67, blue: 0.66, alpha: 1)
            organization = .init(srgbRed: 0.61, green: 0.70, blue: 0.70, alpha: 1)
            decision = .init(srgbRed: 0.84, green: 0.78, blue: 0.67, alpha: 1)
            knowledge = .init(white: 0.68, alpha: 1)
            chat = .init(white: 0.80, alpha: 1)
            edge = .init(white: 0.75, alpha: 1)
            label = .init(white: 0.84, alpha: 1)
        case .silver:
            profile = .init(srgbRed: 0.37, green: 0.62, blue: 0.70, alpha: 1)
            project = .init(srgbRed: 0.31, green: 0.61, blue: 0.58, alpha: 1)
            goal = .init(srgbRed: 0.68, green: 0.59, blue: 0.37, alpha: 1)
            person = .init(srgbRed: 0.68, green: 0.46, blue: 0.42, alpha: 1)
            organization = .init(srgbRed: 0.44, green: 0.56, blue: 0.72, alpha: 1)
            decision = .init(srgbRed: 0.72, green: 0.63, blue: 0.42, alpha: 1)
            knowledge = .init(srgbRed: 0.50, green: 0.61, blue: 0.65, alpha: 1)
            chat = .init(srgbRed: 0.76, green: 0.82, blue: 0.84, alpha: 1)
            edge = .init(srgbRed: 0.62, green: 0.72, blue: 0.75, alpha: 1)
            label = .init(white: 0.88, alpha: 1)
        case .warmGlass:
            profile = .init(srgbRed: 0.48, green: 0.65, blue: 0.50, alpha: 1)
            project = .init(srgbRed: 0.62, green: 0.69, blue: 0.46, alpha: 1)
            goal = .init(srgbRed: 0.74, green: 0.64, blue: 0.38, alpha: 1)
            person = .init(srgbRed: 0.68, green: 0.52, blue: 0.42, alpha: 1)
            organization = .init(srgbRed: 0.45, green: 0.65, blue: 0.61, alpha: 1)
            decision = .init(srgbRed: 0.76, green: 0.67, blue: 0.43, alpha: 1)
            knowledge = .init(srgbRed: 0.59, green: 0.68, blue: 0.55, alpha: 1)
            chat = .init(srgbRed: 0.82, green: 0.84, blue: 0.75, alpha: 1)
            edge = .init(srgbRed: 0.68, green: 0.72, blue: 0.60, alpha: 1)
            label = .init(white: 0.88, alpha: 1)
        case .frost:
            profile = .init(white: 0.83, alpha: 1)
            project = .init(white: 0.70, alpha: 1)
            goal = .init(white: 0.76, alpha: 1)
            person = .init(white: 0.64, alpha: 1)
            organization = .init(white: 0.58, alpha: 1)
            decision = .init(white: 0.88, alpha: 1)
            knowledge = .init(white: 0.73, alpha: 1)
            chat = .init(white: 0.81, alpha: 1)
            edge = .init(white: 0.70, alpha: 1)
            label = .init(white: 0.88, alpha: 1)
        }
    }
}
