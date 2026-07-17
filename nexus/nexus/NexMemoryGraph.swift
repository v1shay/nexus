import AppKit
import SpriteKit
import SwiftUI

struct NexMemoryGraphNode: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let kind: NexMemoryKind
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

    init(documents: [NexCanonicalDocument]) {
        let memories = documents
            .filter { $0.type == .memory && $0.status == .active && $0.memoryKind != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        nodes = memories.compactMap { document in
            guard let kind = document.memoryKind else { return nil }
            return .init(
                id: document.id,
                title: document.title,
                kind: kind,
                importance: document.importance,
                relativePath: document.relativePath
            )
        }
        var builtEdges: [NexMemoryGraphEdge] = []
        for leftIndex in memories.indices {
            for rightIndex in memories.indices where rightIndex > leftIndex {
                let left = memories[leftIndex]
                let right = memories[rightIndex]
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
        edges = builtEdges
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NexMemoryPhysicsGraphView: NSViewRepresentable {
    let graph: NexMemoryGraphSnapshot
    let vaultURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SKView {
        let view = NexMemoryGraphSKView()
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        let scene = NexMemoryGraphScene(size: CGSize(width: 1_200, height: 800), vaultURL: vaultURL)
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.apply(graph)
        view.presentScene(scene)
        context.coordinator.scene = scene
        return view
    }

    func updateNSView(_ view: SKView, context: Context) {
        guard context.coordinator.graph != graph else { return }
        context.coordinator.graph = graph
        context.coordinator.scene?.apply(graph)
    }

    final class Coordinator {
        fileprivate var scene: NexMemoryGraphScene?
        var graph = NexMemoryGraphSnapshot.empty
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

    init(size: CGSize, vaultURL: URL) {
        self.vaultURL = vaultURL
        super.init(size: size)
        physicsWorld.gravity = .zero
        addChild(graphCamera)
        camera = graphCamera
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ graph: NexMemoryGraphSnapshot) {
        removeAllChildren()
        addChild(graphCamera)
        memoryNodes.removeAll()
        memoryPaths.removeAll()
        edgeNodes.removeAll()

        for (index, memory) in graph.nodes.enumerated() {
            let angle = Double(index) * 2.399963
            let spread = CGFloat(34 + sqrt(Double(index)) * 31)
            let radius = CGFloat(7 + min(9, max(0, memory.importance) * 8))
            let node = SKShapeNode(circleOfRadius: radius)
            node.name = memory.id.uuidString
            node.fillColor = color(for: memory.kind)
            node.strokeColor = node.fillColor.withAlphaComponent(0.35)
            node.glowWidth = 5
            node.position = CGPoint(x: cos(angle) * spread, y: sin(angle) * spread)
            node.physicsBody = SKPhysicsBody(circleOfRadius: radius + 3)
            node.physicsBody?.affectedByGravity = false
            node.physicsBody?.linearDamping = 3.1
            node.physicsBody?.restitution = 0.08
            node.physicsBody?.allowsRotation = false

            let label = SKLabelNode(text: memory.title)
            label.fontName = ".AppleSystemUIFont"
            label.fontSize = 11
            label.fontColor = NSColor.white.withAlphaComponent(0.72)
            label.verticalAlignmentMode = .top
            label.position = CGPoint(x: 0, y: -(radius + 8))
            label.preferredMaxLayoutWidth = 150
            label.numberOfLines = 2
            node.addChild(label)
            addChild(node)
            memoryNodes[memory.id] = node
            memoryPaths[memory.id] = memory.relativePath
        }

        for edge in graph.edges {
            let line = SKShapeNode()
            line.strokeColor = NSColor.systemPurple.withAlphaComponent(0.16 + edge.strength * 0.2)
            line.lineWidth = 0.7 + edge.strength
            line.zPosition = -1
            addChild(line)
            edgeNodes[edge] = line
        }
        graphCamera.position = .zero
        graphCamera.setScale(1)
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
                let force = min(14, 7_500 / distanceSquared)
                let vector = CGVector(dx: delta.dx / distance * force, dy: delta.dy / distance * force)
                left.physicsBody?.applyForce(vector)
                right.physicsBody?.applyForce(CGVector(dx: -vector.dx, dy: -vector.dy))
            }
        }

        for (edge, line) in edgeNodes {
            guard let source = memoryNodes[edge.source], let target = memoryNodes[edge.target] else { continue }
            let delta = CGVector(dx: target.position.x - source.position.x, dy: target.position.y - source.position.y)
            let distance = max(1, hypot(delta.dx, delta.dy))
            let desired: CGFloat = 92
            let force = (distance - desired) * 0.035 * edge.strength
            let vector = CGVector(dx: delta.dx / distance * force, dy: delta.dy / distance * force)
            source.physicsBody?.applyForce(vector)
            target.physicsBody?.applyForce(CGVector(dx: -vector.dx, dy: -vector.dy))
            let path = CGMutablePath(); path.move(to: source.position); path.addLine(to: target.position)
            line.path = path
        }

        for node in nodes where node !== draggedNode {
            node.physicsBody?.applyForce(CGVector(dx: -node.position.x * 0.014, dy: -node.position.y * 0.014))
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

    private func color(for kind: NexMemoryKind) -> NSColor {
        switch kind {
        case .preference, .personalContext: .systemPurple
        case .project: .systemCyan
        case .goal: .systemOrange
        case .person: .systemPink
        case .organization: .systemBlue
        case .decision: .systemGreen
        case .knowledge: .systemIndigo
        }
    }
}
