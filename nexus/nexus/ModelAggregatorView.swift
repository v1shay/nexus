import AppKit
import SceneKit
import SwiftUI

enum Nexus3DLayout {
    static let computerCameraDistance: Float = 2.55
    static let globeCameraDistance: Float = 2.70
    static let connectDeviceCameraDistance: Float = 4.15
}

struct ModelAggregatorView: View {
    @ObservedObject var viewModel: ModelDownloadViewModel
    @ObservedObject var connect: NexusConnectController
    @ObservedObject var memory: NexMemoryController
    @ObservedObject var settings: NexusAppSettings
    @State private var page: NexusAppPage = .models

    var body: some View {
        HStack(spacing: 0) {
            NexusAppRail(page: $page)
            Group {
                switch page {
                case .models:
                    NexusModelsPage(viewModel: viewModel)
                case .connect:
                    NexusConnectPage(controller: connect)
                case .memory:
                    NexusMemoryPage(memory: memory)
                case .settings:
                    NexusSettingsPage(settings: settings, viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 620)
        .alert(item: $viewModel.pendingOllamaInstall) { model in
            Alert(
                title: Text("Install Ollama?"),
                message: Text("Nexus will install the official Ollama app, then download \(model.name)."),
                primaryButton: .default(Text("Install"), action: viewModel.installOllamaAndContinue),
                secondaryButton: .cancel()
            )
        }
        .alert(item: $viewModel.pendingRemoteRuntimeInstall) { request in
            Alert(
                title: Text("Install Ollama on \(request.deviceNames.joined(separator: ", "))?"),
                message: Text("The model will download directly to the selected Mac."),
                primaryButton: .default(Text("Install"), action: viewModel.installRemoteRuntimeAndContinue),
                secondaryButton: .cancel()
            )
        }
    }
}

private enum NexusAppPage: String, CaseIterable, Identifiable {
    case models
    case connect
    case memory
    case settings

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .models: "cube.transparent"
        case .connect: "point.3.connected.trianglepath.dotted"
        case .memory: "circle.hexagongrid"
        case .settings: "gearshape"
        }
    }
}

private struct NexusSettingsPage: View {
    @ObservedObject var settings: NexusAppSettings
    @ObservedObject var viewModel: ModelDownloadViewModel

    var body: some View {
        Form {
            Section("Status") {
                Picker("Generator", selection: $settings.statusMode) {
                    ForEach(NexusStatusGenerationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if settings.statusMode == .secondaryModel {
                    Picker("Status model", selection: $settings.secondaryStatusModelID) {
                        Text("Choose a local model").tag("")
                        ForEach(viewModel.installedModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            }

            Section("Dictation") {
                Picker("Engine", selection: $settings.speechEngine) {
                    ForEach(NexusSpeechEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                if settings.speechEngine == .parakeetLocal {
                    Text("Runs the open-source Parakeet CoreML model locally. Its Hugging Face weights download once on first use; no transcription endpoint or API key is used.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(28)
    }
}

private struct NexusAppRail: View {
    @Binding var page: NexusAppPage

    var body: some View {
        VStack(spacing: 10) {
            ForEach(NexusAppPage.allCases) { item in
                Button { page = item } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(page == item ? .white.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(page == item ? .white : .secondary)
                .help(item.rawValue.capitalized)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 62)
    }
}

private struct NexusModelsPage: View {
    @ObservedObject var viewModel: ModelDownloadViewModel
    @State private var isShowingAPISettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                activeModelLabel
                Spacer()
                Button("API") { isShowingAPISettings = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.apiProvider.enabled ? .green : .secondary)
                    .help("Use an OpenAI-compatible or Gemini API model")
            }
            .padding(.horizontal, 22)
            .frame(height: 28)
            GeometryReader { proxy in
                let rowHeight = max(260, (proxy.size.height - 42) / 2)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ModelSceneCard(asset: "Computer", accent: .cyan)
                        ModelLibraryCard(backend: .ollama, viewModel: viewModel)
                    }
                    .frame(height: rowHeight)
                    HStack(spacing: 0) {
                        ModelLibraryCard(backend: .lmStudio, viewModel: viewModel)
                        ModelSceneCard(asset: "Moon_Globe", accent: .indigo)
                    }
                    .frame(height: rowHeight)
                }
            }
        }
        .sheet(isPresented: $isShowingAPISettings) { NexusAPIProviderView(store: viewModel.apiProvider) }
    }

    @ViewBuilder
    private var activeModelLabel: some View {
        if viewModel.apiProvider.enabled {
            Label("Using \(viewModel.apiProvider.model)", systemImage: "bolt.fill")
                .foregroundStyle(.green)
                .help("Current model in use via API")
        } else if let model = viewModel.activeModel {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("Using \(model.name)")
                    .lineLimit(1)
                Text(model.backend.title)
                    .foregroundStyle(.secondary)
                if viewModel.activeModelSupportsThinking {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.purple.opacity(0.9))
                        .help("Supports streamed thinking")
                }
            }
            .help("Current model in use")
        } else {
            Text("No model selected")
                .foregroundStyle(.secondary)
        }
    }
}

private struct NexusAPIProviderView: View {
    @ObservedObject var store: NexusAPIProviderStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("API model").font(.headline); Spacer(); Toggle("Use", isOn: $store.enabled).labelsHidden() }
            Picker("Provider", selection: $store.kind) {
                ForEach(NexusAPIProviderKind.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: store.kind) { previous, next in
                store.selectKind(next, replacing: previous)
            }
            TextField("Base URL", text: $store.baseURL)
            TextField("Model", text: $store.model)
            SecureField(store.savedKey ? "API key (saved — enter to replace)" : "API key", text: $store.apiKeyInput)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Disable") { store.disable(); dismiss() }
                Spacer()
                Button("Save") {
                    do { try store.save(); dismiss() }
                    catch { store.recordError(error) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct ModelSceneCard: View {
    let asset: String
    let accent: Color

    var body: some View {
        SpinningUSDZView(
            assetName: asset,
            cameraDistance: asset == "Computer"
                ? Nexus3DLayout.computerCameraDistance
                : Nexus3DLayout.globeCameraDistance
        )
            .background(
                RadialGradient(
                    colors: [accent.opacity(0.17), .clear],
                    center: .center,
                    startRadius: 10,
                    endRadius: 220
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModelLibraryCard: View {
    let backend: ModelBackend
    @ObservedObject var viewModel: ModelDownloadViewModel
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(backend.title).font(.headline)
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(width: 150, height: 28)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 1) }
                    .onSubmit { Task { await viewModel.refreshCatalog(for: backend, query: query) } }
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(viewModel.models(for: backend, matching: query)) { model in
                        NexusModelRow(model: model, viewModel: viewModel)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NexusModelRow: View {
    let model: LocalModel
    @ObservedObject var viewModel: ModelDownloadViewModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).lineLimit(1)
                Text(model.identifier).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                if viewModel.isRecommended(model) {
                    Image(systemName: "sparkles").foregroundStyle(.yellow.opacity(0.85)).help("Recommended for available memory")
                }
                if model.supportsImageInput {
                    Image(systemName: "photo").foregroundStyle(.cyan.opacity(0.85)).help("Supports image input")
                }
                if case .installed = viewModel.states[model.id] ?? .idle {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).help("Downloaded")
                }
                if viewModel.activeModel?.id == model.id {
                    Image(systemName: "bolt.circle.fill").foregroundStyle(.green).help("In use")
                    if viewModel.activeModelSupportsThinking {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.purple.opacity(0.9))
                            .help("Supports streamed thinking")
                    }
                }
            }
            .font(.caption)
            action
        }
        .padding(.horizontal, 8)
        .frame(height: 43)
        .foregroundStyle(viewModel.activeModel?.id == model.id ? .white : .white.opacity(0.82))
    }

    @ViewBuilder private var action: some View {
        switch viewModel.states[model.id] ?? .idle {
        case .preparing, .downloading:
            Button { viewModel.cancel(model) } label: { ProgressView().controlSize(.small) }
                .buttonStyle(.plain).help("Cancel")
        case .installed:
            if viewModel.activeModel?.id == model.id {
                EmptyView()
            } else if viewModel.isUsable(model) {
                Button("Use") { viewModel.use(model) }.controlSize(.small)
            } else {
                Button("Download") { viewModel.download(model) }.controlSize(.small)
            }
        case .failed:
            Button("Retry") { viewModel.retry(model) }.controlSize(.small)
        case .idle:
            Button("Download") { viewModel.download(model) }.controlSize(.small)
        }
    }
}

private struct NexusConnectPage: View {
    @ObservedObject var controller: NexusConnectController

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                DeviceCard(device: localDevice, controller: controller)
                DeviceCard(device: remoteDevice(kind: .studio), controller: controller)
                DeviceCard(device: remoteDevice(kind: .imac), controller: controller)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { controller.enabled },
                    set: { controller.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                TextField("Pairing code", text: $controller.pairingCode)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 1) }
                Button("Pair") { controller.applyPairingCode() }
                    .disabled(controller.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !controller.setupMessage.isEmpty {
                    Text(controller.setupMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var localDevice: NexusDeviceCardModel {
        .init(
            kind: .macbook,
            nodeID: nil,
            name: Host.current().localizedName ?? "This Mac",
            memoryGB: max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)),
            status: "Connected",
            isOnline: true,
            isSelected: controller.modelRoute == .thisMac
        )
    }

    private func remoteDevice(kind: NexusDeviceKind) -> NexusDeviceCardModel {
        let match = controller.pairedNodes.first { node in
            let name = node.displayName.lowercased()
            return kind == .studio ? name.contains("studio") : name.contains("imac")
        }
        guard let node = match else {
            return .init(
                kind: kind,
                nodeID: nil,
                name: kind == .studio ? "Mac Studio" : "iMac",
                memoryGB: nil,
                status: "Not paired",
                isOnline: false,
                isSelected: false
            )
        }
        return .init(
            kind: kind,
            nodeID: node.id,
            name: node.displayName,
            memoryGB: node.totalMemoryBytes.map { max(1, Int($0 / 1_073_741_824)) },
            status: node.status == .online ? "Connected" : node.status.rawValue.capitalized,
            isOnline: node.status == .online,
            isSelected: controller.modelRoute == .pairedNode(node.id)
        )
    }
}

private enum NexusDeviceKind { case macbook, studio, imac }

private struct NexusDeviceCardModel {
    let kind: NexusDeviceKind
    let nodeID: UUID?
    let name: String
    let memoryGB: Int?
    let status: String
    let isOnline: Bool
    let isSelected: Bool

    var asset: String {
        switch kind {
        case .macbook: "macbook_pro_M3_16_inch_2024"
        case .studio: "Apple_Mac_Studio"
        case .imac: "iMac_24_M1_Green_2021"
        }
    }
}

private struct DeviceCard: View {
    let device: NexusDeviceCardModel
    @ObservedObject var controller: NexusConnectController

    var body: some View {
        VStack(spacing: 8) {
            SpinningUSDZView(
                assetName: device.asset,
                cameraDistance: Nexus3DLayout.connectDeviceCameraDistance
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(device.name).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(device.isOnline ? .green : .secondary).frame(width: 7, height: 7)
                Text(device.status)
                if let memory = device.memoryGB { Text("· \(memory) GB") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let id = device.nodeID, !device.isOnline {
                Button("Reconnect") { controller.reconnect(nodeID: id) }.controlSize(.small)
            }
        }
        .padding(14)
        .background {
            if device.isSelected {
                RadialGradient(colors: [.cyan.opacity(0.08), .clear], center: .center, startRadius: 30, endRadius: 320)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            guard device.isOnline else { return }
            if let id = device.nodeID {
                controller.setModelRoute(.pairedNode(id))
                controller.useOnlyDownloadTarget(.pairedNode(id))
            } else {
                controller.setModelRoute(.thisMac)
                controller.useOnlyDownloadTarget(.thisMac)
            }
        }
    }
}

private struct NexusMemoryPage: View {
    @ObservedObject var memory: NexMemoryController

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 14) {
                MemoryCard(title: "Current") {
                    CurrentConversationView(snapshot: memory.activeConversation)
                }
                MemoryCard(title: "Previous") {
                    SavedConversationList(memory: memory)
                }
            }
            .frame(width: 390)
            MemoryCard(title: "Obsidian") {
                NexMemoryPhysicsGraphView(graph: memory.memoryGraph, vaultURL: memory.vaultURL)
            }
        }
        .padding(14)
        .task { await memory.refreshSavedConversations() }
    }
}

private struct MemoryCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
    }
}

private struct CurrentConversationView: View {
    let snapshot: NexConversationSnapshot?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot?.turns.suffix(12) ?? []) { turn in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.role == .user ? "You" : "Nex")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(turn.text).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct SavedConversationList: View {
    @ObservedObject var memory: NexMemoryController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(memory.savedConversations) { chat in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.title).lineLimit(1)
                        Text(chat.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
        }
    }
}

private struct SpinningUSDZView: NSViewRepresentable {
    let assetName: String
    var cameraDistance: Float = 3.1

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.rendersContinuously = true
        loadScene(into: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard view.accessibilityIdentifier() != viewIdentifier else { return }
        loadScene(into: view)
    }

    private func loadScene(into view: SCNView) {
        view.setAccessibilityIdentifier(viewIdentifier)
        guard let url = Bundle.main.url(
            forResource: assetName,
            withExtension: "usdz",
            subdirectory: "Nexus3D"
        ) else {
            NSLog("Nexus 3D asset is missing from the app bundle: %@", assetName)
            return
        }
        let source: SCNScene
        do {
            source = try SCNScene(url: url, options: nil)
        } catch {
            NSLog("Nexus could not decode 3D asset %@: %@", assetName, error.localizedDescription)
            return
        }

        let scene = SCNScene()
        let content = SCNNode()
        source.rootNode.childNodes.forEach {
            $0.removeFromParentNode()
            content.addChildNode($0)
        }
        let bounds = Self.bounds(of: content)
        let center = bounds.center
        let radius = max(bounds.radius, 1)
        content.position = SCNVector3(-center.x, -center.y, -center.z)

        let spinner = SCNNode()
        spinner.addChildNode(content)
        spinner.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12)))
        scene.rootNode.addChildNode(spinner)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        // USDZ files use their own real-world scales. These models place the
        // camera 200–1,000 scene units away, beyond SceneKit's default zFar.
        // Derive both clipping planes from the measured model radius so the
        // geometry remains visible regardless of the asset's authored scale.
        camera.camera?.zNear = Double(max(radius * 0.01, 0.01))
        camera.camera?.zFar = Double(max(radius * 10, 1_000))
        camera.position = SCNVector3(0, radius * 0.15, radius * cameraDistance)
        camera.constraints = [SCNLookAtConstraint(target: spinner)]
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 480
        ambient.light?.color = NSColor(white: 0.72, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 900
        key.position = SCNVector3(radius * 2, radius * 2, radius * 2)
        scene.rootNode.addChildNode(key)
        view.scene = scene
    }

    private var viewIdentifier: String { "\(assetName):\(cameraDistance)" }

    private static func bounds(of root: SCNNode) -> (center: SCNVector3, radius: Float) {
        var minimum = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maximum = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        var foundGeometry = false
        root.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            foundGeometry = true
            let box = node.boundingBox
            let corners = [
                SCNVector3(box.min.x, box.min.y, box.min.z), SCNVector3(box.max.x, box.min.y, box.min.z),
                SCNVector3(box.min.x, box.max.y, box.min.z), SCNVector3(box.max.x, box.max.y, box.min.z),
                SCNVector3(box.min.x, box.min.y, box.max.z), SCNVector3(box.max.x, box.min.y, box.max.z),
                SCNVector3(box.min.x, box.max.y, box.max.z), SCNVector3(box.max.x, box.max.y, box.max.z)
            ]
            for corner in corners {
                let point = node.convertPosition(corner, to: root)
                minimum.x = min(minimum.x, point.x); minimum.y = min(minimum.y, point.y); minimum.z = min(minimum.z, point.z)
                maximum.x = max(maximum.x, point.x); maximum.y = max(maximum.y, point.y); maximum.z = max(maximum.z, point.z)
            }
        }
        guard foundGeometry else { return (SCNVector3Zero, 1) }
        let center = SCNVector3(
            (minimum.x + maximum.x) / 2,
            (minimum.y + maximum.y) / 2,
            (minimum.z + maximum.z) / 2
        )
        let dx = maximum.x - minimum.x
        let dy = maximum.y - minimum.y
        let dz = maximum.z - minimum.z
        let squaredRadius = dx * dx + dy * dy + dz * dz
        let radius = Float(sqrt(Double(squaredRadius)) / 2)
        return (center, radius)
    }
}
