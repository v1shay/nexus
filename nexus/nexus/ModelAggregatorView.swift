import AppKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

enum Nexus3DLayout {
    static let computerCameraDistance: Float = 2.55
    static let globeCameraDistance: Float = 3.18
    static let connectDeviceCameraDistance: Float = 4.52
}

struct ModelAggregatorView: View {
    @ObservedObject var viewModel: ModelDownloadViewModel
    @ObservedObject var connect: NexusConnectController
    @ObservedObject var memory: NexMemoryController
    @ObservedObject var settings: NexusAppSettings
    @ObservedObject var cli: NexCLITaskController
    @ObservedObject var cliSettings: NexCLITaskSettings
    @ObservedObject var connectorAuth: NexConnectorAuthController
    @ObservedObject var automations: NexusAutomationController
    @State private var page: NexusAppPage = .models

    var body: some View {
        ZStack {
            NexusLiquidGlassBackground(theme: settings.glassTheme)

            HStack(spacing: 0) {
                NexusAppRail(page: $page, theme: settings.glassTheme)
                    .nexusGlassPanel(theme: settings.glassTheme, role: .sidebar, radius: 0)
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 1)
            Group {
                switch page {
                case .models:
                    NexusModelsPage(viewModel: viewModel, theme: settings.glassTheme)
                case .connect:
                    NexusConnectPage(controller: connect, theme: settings.glassTheme)
                case .memory:
                    NexusMemoryPage(memory: memory, theme: settings.glassTheme)
                case .settings:
                    NexusExperienceSettingsPage(settings: settings, viewModel: viewModel)
                case .connectors:
                    NexusConnectorsPage(connectorAuth: connectorAuth, theme: settings.glassTheme)
                case .cli:
                    NexCLIWorkspacePage(controller: cli, settings: cliSettings, theme: settings.glassTheme)
                case .automations:
                    NexusAutomationsPage(controller: automations, viewModel: viewModel, theme: settings.glassTheme)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        }
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
    }
}

private enum NexusAppPage: String, CaseIterable, Identifiable {
    case models
    case connect
    case memory
    case settings
    case connectors
    case cli
    case automations

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .models: "cube.transparent"
        case .connect: "point.3.connected.trianglepath.dotted"
        case .memory: "circle.hexagongrid"
        case .settings: "gearshape"
        case .connectors: "point.3.connected.trianglepath.dotted"
        case .cli: "terminal"
        case .automations: "clock.arrow.circlepath"
        }
    }
}

/// A native terminal-style renderer for the managed NexCLI task API. It is not
/// an embedded external terminal: every line is derived from the same
/// authenticated `/nex/tasks` SSE stream used by Nexus tools.
private struct NexCLIWorkspacePage: View {
    @ObservedObject var controller: NexCLITaskController
    @ObservedObject var settings: NexCLITaskSettings
    let theme: NexusGlassTheme
    @State private var input = ""
    @State private var error: String?
    @State private var isSubmitting = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NexCLIConsoleHeader(
                workspace: settings.directory,
                runtimeDetail: managedServiceDetail,
                modelID: NexApiClient.Model.localCodingDefault.modelID
            )
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.25)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("Managed workspace  \(settings.directory)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.38))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ForEach(controller.tasks.reversed()) { task in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("NEX > \(task.title)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text(task.detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(task.state == .failed ? .red : .white.opacity(0.56))
                                    .textSelection(.enabled)
                                if !task.finalText.isEmpty {
                                    Text(task.finalText)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.82))
                                        .textSelection(.enabled)
                                }
                                if let outputURL = task.outputURL {
                                    Link("Open output", destination: outputURL)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                }
                            }
                            Divider().opacity(0.15)
                        }
                        Color.clear.frame(height: 1).id("terminal-bottom")
                    }
                    .padding(22)
                }
                .onChange(of: controller.tasks) { _, _ in
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                Text("NEX >")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                TextField("Describe a coding task…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($isInputFocused)
                    .onSubmit(submit)
                    .disabled(isSubmitting)
                if isSubmitting { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 26)
            .frame(height: 52)
            .background(.black.opacity(0.28))
            .onTapGesture { isInputFocused = true }
            .onAppear { isInputFocused = true }
        }
        .nexusGlassPanel(theme: theme, role: .terminal, radius: 26)
    }

    private func submit() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSubmitting else { return }
        input = ""
        error = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await NexCLITaskService.shared.runFromConsole(prompt: prompt)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var managedServiceDetail: String {
        guard let status = NexCLIHostManager.shared.currentStatus() else {
            return "Nexus will start NexCLI automatically in the background."
        }
        return status.state == "ready" ? "NexCLI is running locally." : (status.detail ?? "Starting NexCLI…")
    }
}

/// Persistent terminal masthead. The selected pet is the exact atlas-backed
/// pet used by the notch, so a Command-click remains the same familiar way to
/// cycle it everywhere in Nexus.
private struct NexCLIConsoleHeader: View {
    @EnvironmentObject private var notch: NotchController

    let workspace: String
    let runtimeDetail: String
    let modelID: String

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 15) {
                NexWordmark(color: Color(red: 0.53, green: 0.80, blue: 0.82))
                    .frame(width: 98, height: 40, alignment: .leading)

                Text(shortWorkspace)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 9) {
                    Text(modelID)
                    Circle()
                        .fill(.white.opacity(0.42))
                        .frame(width: 3, height: 3)
                    Text(runtimeDetail)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NexusPetView(pet: notch.selectedPet, activity: .idle, height: 92)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard NSEvent.modifierFlags.contains(.command) else { return }
                    notch.cyclePet()
                }
                .help("Command-click to change pet")
                .accessibilityHint("Command-click to change the current pet")
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [8, 5]))
        }
        .accessibilityIdentifier("nex-cli-console-header")
        .accessibilityElement(children: .contain)
    }

    private var shortWorkspace: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return workspace.hasPrefix(home)
            ? "~" + String(workspace.dropFirst(home.count))
            : workspace
    }
}

private struct NexusExperienceSettingsPage: View {
    @ObservedObject var settings: NexusAppSettings
    @ObservedObject var viewModel: ModelDownloadViewModel
    @ObservedObject private var duplexRuntime = NexusDuplexVoiceRuntime.shared
    @ObservedObject private var permissionCoordinator = NexusPermissionCoordinator.shared
    @State private var piperVoices: [PiperVoice] = []
    @State private var isImportingPiperVoice = false
    @State private var secureVaultMessage = NexusUnifiedKeychainVault.shared.isConfigured
        ? "Shared credential vault is active"
        : "Migrate existing Nexus credentials into the shared vault"

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NexusSettingsLine(label: "Glass") {
                    Picker("Glass", selection: $settings.glassTheme) {
                        ForEach(NexusGlassTheme.allCases) { theme in Text(theme.title).tag(theme) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Codex tasks") {
                    Picker("Codex task marks", selection: $settings.codexTaskMarkStyle) {
                        ForEach(NexusCodexTaskMarkStyle.allCases) { style in Text(style.title).tag(style) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .help("Choose colored Codex marks or animated installed pets for the three most recent Codex tasks.")
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Status") {
                    Picker("Status", selection: $settings.statusMode) {
                        ForEach(NexusStatusGenerationMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                if settings.statusMode == .secondaryModel {
                    NexusHairline(axis: .horizontal)
                    NexusSettingsLine(label: "Model") {
                        Picker("Status model", selection: $settings.secondaryStatusModelID) {
                            Text("Choose model").tag("")
                            ForEach(viewModel.installedModels) { model in Text(model.name).tag(model.id) }
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Dictation") {
                    Picker("Dictation", selection: $settings.speechEngine) {
                        ForEach(NexusSpeechEngine.allCases) { engine in Text(engine.title).tag(engine) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Response voice") {
                    HStack(spacing: 8) {
                        Picker("Response voice", selection: $settings.piperVoiceModelPath) {
                            Text("Automatic").tag("")
                            ForEach(piperVoices) { voice in
                                Text(voice.displayName).tag(voice.model.path)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Button("Add…") { isImportingPiperVoice = true }
                        Button("Refresh") { refreshPiperVoices() }
                        Image(systemName: PiperVoiceConfiguration.hasRuntime()
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(PiperVoiceConfiguration.hasRuntime() ? Color.green : Color.orange)
                            .help(PiperVoiceConfiguration.hasRuntime()
                                  ? "The local Piper runtime is installed."
                                  : "Piper is not installed. Run scripts/install-piper-runtime.sh once on this Mac.")
                    }
                    .help("Choose a local Piper voice. Each voice needs its .onnx model and matching .onnx.json config file.")
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Always on") {
                    Toggle("Hands-free voice", isOn: $settings.alwaysOnVoiceMode)
                        .toggleStyle(.switch)
                        .help("Hold Command once to start. Nexus sends after 0.7 seconds of silence, listens for interruptions, and double-Command exits the session.")
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Global paste") {
                    Toggle("Hold Globe/Fn to dictate", isOn: $settings.globalPasteDictationEnabled)
                        .toggleStyle(.switch)
                        .help("Hold Globe/Fn in any editable field, then release to paste clean dictation.")
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Credentials") {
                    VStack(alignment: .trailing, spacing: 7) {
                        HStack(spacing: 8) {
                            Image(systemName: NexusUnifiedKeychainVault.shared.isConfigured ? "lock.fill" : "lock.badge.plus")
                                .foregroundStyle(NexusUnifiedKeychainVault.shared.isConfigured ? .green : .orange)
                            Button(NexusUnifiedKeychainVault.shared.isConfigured ? "Run migration again" : "Migrate credentials") {
                                do {
                                    let migration = try NexusUnifiedKeychainVault.shared.prepare()
                                    secureVaultMessage = migration.skippedServices == 0
                                        ? "Shared vault is active — migrated \(migration.copiedEntries) existing Nexus entries"
                                        : "Migrated \(migration.copiedEntries) entries; \(migration.skippedServices) protected service(s) will retry when available"
                                } catch {
                                    secureVaultMessage = "Migration needs macOS Keychain authorization: \(error.localizedDescription)"
                                }
                            }
                        }
                        Text(secureVaultMessage)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 390, alignment: .trailing)
                    }
                    .help("Migrates the Nexus credentials already on this Mac into one Keychain record. Nexus never stores your Mac password.")
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Nexus setup") {
                    VStack(alignment: .trailing, spacing: 7) {
                        ForEach(permissionCoordinator.setupCapabilities, id: \.id) { capability in
                            HStack(spacing: 8) {
                                Text(capability.displayName)
                                Text(permissionCoordinator.state(for: capability).rawValue)
                                    .foregroundStyle(permissionCoordinator.isVerified(capability) ? .green : .secondary)
                                if !permissionCoordinator.isVerified(capability) {
                                    if case .protectedResource = capability {
                                        Button("Open + add Nexus") { permissionCoordinator.openSystemSettings(for: capability) }
                                        Button("Reveal app") { permissionCoordinator.revealCurrentAppForFullDiskAccess() }
                                    } else {
                                        Button("Allow") { Task { _ = await permissionCoordinator.request(capability) } }
                                        Button("Settings") { permissionCoordinator.openSystemSettings(for: capability) }
                                    }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Start / continue setup") { Task { await permissionCoordinator.startOrContinueSetup() } }
                            Button("Refresh") { Task { await permissionCoordinator.resumeAtLaunch() } }
                            Button("Ask remaining app approvals") { Task { await permissionCoordinator.requestRemainingAutomationApprovals() } }
                            if permissionCoordinator.state(for: .screenRecording) == .waitingForRestart {
                                Button("Restart Nexus") { permissionCoordinator.restartToFinishScreenRecording() }
                            }
                        }
                        Text(permissionCoordinator.statusMessage())
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 390, alignment: .trailing)
                        Text("Automation is granted separately by macOS for each installed app Nexus can control; it is not a universal switch.")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 390, alignment: .trailing)
                    }
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Screen context") {
                    Toggle("Share with vision models", isOn: $settings.shareScreenWithVisionModels)
                        .toggleStyle(.switch)
                        .help("Screen Recording is requested through Nexus setup and live-verified with ScreenCaptureKit.")
                }
                NexusHairline(axis: .horizontal)
                NexusSettingsLine(label: "Duplex") {
                    Picker("Duplex voice", selection: $settings.duplexVoiceEngine) {
                        ForEach(NexusDuplexVoiceEngine.allCases) { engine in Text(engine.title).tag(engine) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .onChange(of: settings.duplexVoiceEngine) { _, engine in
                        Task {
                            await duplexRuntime.reconcile(
                                with: engine,
                                personaPlexEndpoint: settings.personaPlexRemoteEndpoint,
                                nemotronVoiceChatEndpoint: settings.nemotronVoiceChatRemoteEndpoint
                            )
                        }
                    }
                }
                if settings.duplexVoiceEngine == .moshiMLXQ4 {
                    NexusHairline(axis: .horizontal)
                    NexusSettingsLine(label: "Moshi") {
                        HStack(spacing: 10) {
                            Text(duplexRuntime.state.label)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(duplexRuntime.state == .ready ? .green : .secondary)
                                .lineLimit(1)
                            if duplexRuntime.state != .ready {
                                Button("Install & start") {
                                    Task { await duplexRuntime.installMoshiAndStart() }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    NexusSettingsLine(label: "Note") {
                        Text(NexusDuplexVoiceEngine.moshiMLXQ4.detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 360, alignment: .trailing)
                    }
                }
                if settings.duplexVoiceEngine == .personaPlexRemoteCUDA {
                    NexusHairline(axis: .horizontal)
                    NexusSettingsLine(label: "CUDA host") {
                        TextField("https://cuda-host.example", text: $settings.personaPlexRemoteEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                            .onChange(of: settings.personaPlexRemoteEndpoint) { _, endpoint in
                                Task { await duplexRuntime.reconcile(with: .personaPlexRemoteCUDA, personaPlexEndpoint: endpoint) }
                            }
                    }
                    NexusSettingsLine(label: "Note") {
                        Text(NexusDuplexVoiceEngine.personaPlexRemoteCUDA.detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 360, alignment: .trailing)
                    }
                }
                if settings.duplexVoiceEngine == .nemotronVoiceChatRemoteCUDA {
                    NexusHairline(axis: .horizontal)
                    NexusSettingsLine(label: "CUDA host") {
                        TextField("https://voicechat-host:9000", text: $settings.nemotronVoiceChatRemoteEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                            .onChange(of: settings.nemotronVoiceChatRemoteEndpoint) { _, endpoint in
                                Task {
                                    await duplexRuntime.reconcile(
                                        with: .nemotronVoiceChatRemoteCUDA,
                                        personaPlexEndpoint: settings.personaPlexRemoteEndpoint,
                                        nemotronVoiceChatEndpoint: endpoint
                                    )
                                }
                            }
                    }
                    NexusSettingsLine(label: "VoiceChat") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(duplexRuntime.state.label)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(duplexRuntime.state == .ready ? .green : .secondary)
                            Text("Connects to NVIDIA's /v1/realtime WebSocket. Use headphones to prevent acoustic feedback.")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 360, alignment: .trailing)
                        }
                    }
                }
            }
            .nexusGlassPanel(theme: settings.glassTheme, role: .content, radius: 10)
            .padding(.top, 18)
        }
        .fileImporter(
            isPresented: $isImportingPiperVoice,
            allowedContentTypes: [UTType(filenameExtension: "onnx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let model = urls.first else { return }
            let config = URL(fileURLWithPath: model.path + ".json")
            guard FileManager.default.fileExists(atPath: config.path) else { return }
            let directory = model.deletingLastPathComponent().path
            if !settings.piperVoiceDirectories.contains(directory) {
                settings.piperVoiceDirectories.append(directory)
            }
            settings.piperVoiceModelPath = model.path
            refreshPiperVoices()
        }
        .onAppear {
            refreshPiperVoices()
            Task { await permissionCoordinator.resumeAtLaunch() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionCoordinator.resumeAtLaunch() }
        }
    }

    private func refreshPiperVoices() {
        piperVoices = PiperVoiceCatalog.voices(
            additionalDirectories: settings.piperVoiceDirectories
        )
    }
}

private struct NexusSettingsLine<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.58))
            Spacer()
            content
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
    }
}

private struct NexusConnectorsPage: View {
    @ObservedObject var connectorAuth: NexConnectorAuthController
    let theme: NexusGlassTheme

    var body: some View {
        ScrollView {
            NexConnectionsSettingsView(controller: connectorAuth)
                .padding(16)
                .nexusGlassPanel(theme: theme, role: .content, radius: 10)
                .padding(.top, 18)
        }
    }
}

private struct NexusAutomationsPage: View {
    @ObservedObject var controller: NexusAutomationController
    @ObservedObject var viewModel: ModelDownloadViewModel
    let theme: NexusGlassTheme

    @State private var prompt = ""
    @State private var frequency: NexusAutomationFrequency = .daily
    @State private var hour = 7
    @State private var minute = 0
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var oneTimeDate = Date().addingTimeInterval(3600)
    @State private var selectedModelID = ""
    @State private var approvedActions: Set<String> = []
    @State private var error = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automations").font(.title2.weight(.semibold))
                        Text("Reviewed, multi-step workflows that run through the signed Nexus host.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Nexus browser") {
                        Task { await controller.openNexusBrowserForSignIn() }
                    }
                    .controlSize(.small)
                    Button("Set up OS wake") { controller.installPowerHelper() }
                        .controlSize(.small)
                }
                if !controller.browserSetupStatus.isEmpty {
                    Label(controller.browserSetupStatus, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(controller.browserSetupStatus.hasPrefix("Could not") ? .red : .secondary)
                }

                HStack(spacing: 10) {
                    Text("Model").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Picker("Automation model", selection: $selectedModelID) {
                        Text(activeModelLabel).tag("")
                        if viewModel.apiProvider.enabled {
                            Text("Configured API · \(viewModel.apiProvider.model)")
                                .tag(NexusAutomation.activeAPIModelID)
                        }
                        ForEach(viewModel.installedModels) { model in
                            Text("\(model.name) · \(model.backend.title)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 340)
                    Spacer()
                    Text("\(TimeZone.current.identifier) · \(controller.powerStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("Describe an automation — for example, every weekday at 7 AM, prepare my Gmail, calendar, weather, and portfolio briefing.")
                                .foregroundStyle(.secondary).padding(16).allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 12) {
                    Picker("Schedule", selection: $frequency) {
                        ForEach(NexusAutomationFrequency.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 140)
                    Stepper("Hour \(hour)", value: $hour, in: 0...23).frame(width: 120)
                    Stepper("Minute \(minute)", value: $minute, in: 0...59).frame(width: 140)
                    Spacer()
                    Button(controller.isBuildingDraft ? "Building…" : "Build automation") { build() }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isBuildingDraft || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if frequency == .weekly {
                    HStack(spacing: 6) {
                        ForEach(Array(1...7), id: \.self) { day in
                            Button(Self.weekdaySymbol(day)) {
                                if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                            }
                            .buttonStyle(.bordered)
                            .tint(weekdays.contains(day) ? theme.mainLight : .gray)
                            .controlSize(.small)
                        }
                        Text("Runs on the selected days.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if frequency == .once {
                    DatePicker("Run once", selection: $oneTimeDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                }
                Text("Schedule preview: \(selectedSchedule.summary)").font(.caption).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                if !controller.buildError.isEmpty { Text(controller.buildError).font(.caption).foregroundStyle(.red) }

                if !controller.runEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(controller.isRunning ? "Live automation run" : "Latest automation run")
                                    .font(.headline)
                                Text(controller.activeAutomationTitle.isEmpty ? "Progress is redacted; source data stays private." : controller.activeAutomationTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if controller.isRunning {
                                ProgressView().controlSize(.small)
                                Text("Running").font(.caption.weight(.medium)).foregroundStyle(theme.mainLight)
                            }
                        }
                        ForEach(Array(controller.runEvents.suffix(12))) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: event.phase.icon)
                                    .foregroundStyle(runEventColor(event.phase))
                                    .frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.subheadline.weight(.medium))
                                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(Self.runEventTimeFormatter.string(from: event.occurredAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                }

                if !controller.buildEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Live automation canvas").font(.headline)
                            Spacer()
                            if controller.isBuildingDraft { ProgressView().controlSize(.small) }
                        }
                        ForEach(controller.buildEvents) { event in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 0) {
                                    Image(systemName: canvasIcon(for: event.stage))
                                        .foregroundStyle(event.stage == .ready ? .green : theme.mainLight)
                                        .frame(width: 22, height: 22)
                                    if event.id != controller.buildEvents.last?.id {
                                        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 20)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.subheadline.weight(.medium))
                                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                }

                if let draft = controller.draft {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(draft.title).font(.headline)
                                Text("\(draft.schedule.summary) · \(modelLabel(draft.modelID))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Review before enabling").font(.caption.weight(.medium)).foregroundStyle(.green)
                        }
                        ForEach(draft.blueprint.steps) { step in
                            HStack(spacing: 10) {
                                Image(systemName: step.requiresApproval ? "exclamationmark.shield" : "checkmark.circle")
                                    .foregroundStyle(step.requiresApproval ? .orange : .green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.tool).font(.subheadline.monospaced())
                                    Text(step.purpose).font(.caption).foregroundStyle(.secondary)
                                    Text(step.arguments.isEmpty ? "No inputs" : "Inputs: \(step.arguments.keys.sorted().joined(separator: ", "))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if step.requiresApproval {
                                    Toggle("Approve", isOn: approvalBinding(for: step.tool)).toggleStyle(.switch).labelsHidden()
                                }
                            }
                        }
                        ForEach(draft.blueprint.setupNotes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Discard") { controller.discardDraft() }
                            Spacer()
                            Button("Save & enable") { saveReviewedDraft() }
                                .buttonStyle(.borderedProminent)
                            Button("Save & test now") { saveAndTestDraft() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(15)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }

                Divider()
                if controller.automations.isEmpty {
                    ContentUnavailableView("No automations yet", systemImage: "clock.badge.questionmark", description: Text("Create one above or ask Nexus to build one from a prompt."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(controller.automations) { automation in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(automation.title).font(.headline)
                                Spacer()
                                Text(automation.enabled ? "Enabled" : "Paused")
                                    .foregroundStyle(automation.enabled ? .green : .secondary)
                                Button(controller.activeAutomationID == automation.id ? "Running…" : "Test now") {
                                    Task { await controller.testNow(automation) }
                                }
                                .disabled(controller.isRunning)
                                Button(automation.enabled ? "Pause" : "Resume") {
                                    Task { try? await controller.setEnabled(automation, enabled: !automation.enabled) }
                                }
                                Button(role: .destructive) { Task { try? await controller.delete(automation) } } label: { Image(systemName: "trash") }
                            }
                            Text(automation.prompt).lineLimit(2).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text("Run model").font(.caption).foregroundStyle(.secondary)
                                Picker("Run model", selection: savedModelBinding(for: automation)) {
                                    Text("Use current active model").tag("")
                                    if viewModel.apiProvider.enabled {
                                        Text("Configured API · \(viewModel.apiProvider.model)")
                                            .tag(NexusAutomation.activeAPIModelID)
                                    }
                                    ForEach(viewModel.installedModels) { model in
                                        Text("\(model.name) · \(model.backend.title)").tag(model.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }
                            HStack(spacing: 8) {
                                Text("Briefing voice").font(.caption).foregroundStyle(.secondary)
                                Picker("Briefing voice", selection: savedVoiceBinding(for: automation)) {
                                    Text("Nexus default voice").tag("")
                                    ForEach(controller.availableVoices) { voice in
                                        Text(voice.displayName).tag(voice.model.path)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }
                            Text("\(automation.schedule.summary)  ·  \(modelLabel(automation.modelID))  ·  Next: \(automation.nextRun.map { Self.dateFormatter.string(from: $0) } ?? "not scheduled")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let blueprint = automation.blueprint {
                                Text("Plan: \(blueprint.steps.map(\.tool).joined(separator: " → "))")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(14)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(22)
            .nexusGlassPanel(theme: theme, role: .content, radius: 20)
            .padding(.top, 18)
        }
        .onAppear {
            controller.start()
            if selectedModelID.isEmpty, !viewModel.apiProvider.enabled { selectedModelID = viewModel.activeModel?.id ?? "" }
            Task { await controller.reload() }
        }
        .onChange(of: controller.draft?.id) { _, _ in
            approvedActions = []
        }
    }

    private var selectedSchedule: NexusSchedule {
        .init(
            frequency: frequency,
            hour: hour,
            minute: minute,
            weekdays: weekdays,
            oneTimeDate: frequency == .once ? oneTimeDate : nil
        )
    }

    private var activeModelLabel: String {
        if viewModel.apiProvider.enabled { return "Active API · \(viewModel.apiProvider.model)" }
        return viewModel.activeModel.map { "Active · \($0.name)" } ?? "Select a model"
    }

    private func build() {
        error = ""
        Task {
            do {
                _ = try await controller.buildDraft(
                    prompt: prompt,
                    modelID: selectedModelID,
                    fallbackSchedule: selectedSchedule
                )
            } catch let saveError { error = saveError.localizedDescription }
        }
    }

    private func saveReviewedDraft() {
        error = ""
        Task {
            do {
                _ = try await controller.saveReviewedDraft(approvedActionIDs: approvedActions)
                prompt = ""
            } catch let failure { error = failure.localizedDescription }
        }
    }

    private func saveAndTestDraft() {
        error = ""
        Task {
            do {
                if let automation = try await controller.saveReviewedDraft(approvedActionIDs: approvedActions) {
                    prompt = ""
                    await controller.testNow(automation)
                }
            } catch let failure { error = failure.localizedDescription }
        }
    }

    private func approvalBinding(for action: String) -> Binding<Bool> {
        Binding(
            get: { approvedActions.contains(action) },
            set: { enabled in
                if enabled { approvedActions.insert(action) } else { approvedActions.remove(action) }
            }
        )
    }

    private func savedModelBinding(for automation: NexusAutomation) -> Binding<String> {
        Binding(
            get: { automation.modelID },
            set: { modelID in
                Task {
                    do {
                        try await controller.setModel(automation, modelID: modelID)
                    } catch let failure {
                        error = failure.localizedDescription
                    }
                }
            }
        )
    }

    private func savedVoiceBinding(for automation: NexusAutomation) -> Binding<String> {
        Binding(
            get: { automation.voiceModelPath ?? "" },
            set: { voicePath in
                Task {
                    do {
                        try await controller.setVoice(automation, voiceModelPath: voicePath)
                    } catch let failure {
                        error = failure.localizedDescription
                    }
                }
            }
        )
    }

    private func modelLabel(_ modelID: String) -> String {
        if modelID == NexusAutomation.activeAPIModelID {
            return viewModel.apiProvider.enabled
                ? "API · \(viewModel.apiProvider.model)"
                : "Configured API (not enabled)"
        }
        if modelID.isEmpty { return activeModelLabel }
        return viewModel.installedModels.first(where: { $0.id == modelID })?.name ?? modelID
    }

    private func canvasIcon(for stage: NexusAutomationBuildStage) -> String {
        switch stage {
        case .interpreting: "text.magnifyingglass"
        case .selectingTools: "shippingbox"
        case .designing: "point.3.connected.trianglepath.dotted"
        case .ready: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func runEventColor(_ phase: NexusAutomationRunEventPhase) -> Color {
        switch phase {
        case .evidence, .delivery: .green
        case .failed: .red
        case .retry: .orange
        case .started, .tool, .progress, .composing: theme.mainLight
        }
    }

    private static func weekdaySymbol(_ day: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        guard symbols.indices.contains(day - 1) else { return "?" }
        return symbols[day - 1]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter
    }()

    private static let runEventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.timeStyle = .medium; formatter.dateStyle = .none; return formatter
    }()
}

private struct NexusAppRail: View {
    @Binding var page: NexusAppPage
    let theme: NexusGlassTheme

    var body: some View {
        VStack(spacing: 10) {
            ForEach(NexusAppPage.allCases) { item in
                Button { page = item } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(page == item ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .foregroundStyle(page == item ? .white : .secondary)
                .help(item.rawValue.capitalized)
                .accessibilityIdentifier("nexus-page-\(item.rawValue)")
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 62)
    }
}

private struct NexusModelsPage: View {
    @ObservedObject var viewModel: ModelDownloadViewModel
    let theme: NexusGlassTheme
    @State private var isShowingAPISettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                activeModelLabel
                Spacer()
                Button("API") { isShowingAPISettings = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.apiProvider.enabled ? .green : .secondary)
                    .help("Choose and configure an OpenAI, Gemini, NVIDIA NIM, Groq, or OpenRouter API model")
            }
            .padding(.horizontal, 22)
            .frame(height: 28)
            GeometryReader { proxy in
                let topHeight = max(250, proxy.size.height * 0.54)
                let lowerHeight = max(220, proxy.size.height - topHeight)
                // The two rows deliberately have different proportions: the
                // LM Studio library needs more width, while the Moon Globe is
                // visually smaller than Computer and should not dominate it.
                // Cloud runtimes intentionally share the same canvas width.
                // Keeping NIM/Groq and Gemini/OpenRouter equal makes them read
                // as a paired, balanced part of the model surface.
                let cloudRuntimeWidth = min(270, max(205, proxy.size.width * 0.16))
                let computerWidth = max(380, proxy.size.width * 0.43)
                // The globe is deliberately compact. LM Studio owns the
                // remaining lower-row space because its model names benefit
                // from the extra width.
                let globeWidth = min(300, max(230, proxy.size.width * 0.17))
                let lmStudioWidth = max(420, proxy.size.width - cloudRuntimeWidth - globeWidth - 2)
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ModelSceneCard(asset: "Computer", accent: theme.mainLight, theme: theme)
                                .frame(width: computerWidth)
                            NexusHairline(axis: .vertical)
                            NexusCloudRuntimePanel(
                                providers: [.nvidiaNIM, .groq],
                                store: viewModel.apiProvider,
                                theme: theme,
                                showSettings: { isShowingAPISettings = true }
                            )
                            .frame(width: cloudRuntimeWidth)
                            NexusHairline(axis: .vertical)
                            ModelLibraryCard(backend: .ollama, viewModel: viewModel, theme: theme)
                        }
                        .frame(height: topHeight)
                        NexusHairline(axis: .horizontal)
                        HStack(spacing: 0) {
                            ModelLibraryCard(backend: .lmStudio, viewModel: viewModel, theme: theme)
                                .frame(width: lmStudioWidth)
                            NexusHairline(axis: .vertical)
                            NexusCloudRuntimePanel(
                                providers: [.gemini, .openRouter],
                                store: viewModel.apiProvider,
                                theme: theme,
                                showSettings: { isShowingAPISettings = true }
                            )
                            .frame(width: cloudRuntimeWidth)
                            NexusHairline(axis: .vertical)
                            ModelSceneCard(asset: "Moon_Globe", accent: theme.sidebarLight, theme: theme)
                                .frame(width: globeWidth)
                        }
                        .frame(height: lowerHeight)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingAPISettings) { NexusAPIProviderView(store: viewModel.apiProvider, theme: theme) }
    }

    @ViewBuilder
    private var activeModelLabel: some View {
        if let cloud = viewModel.activeCloudProvider {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Image(systemName: cloud == .nvidiaNIM ? "bolt.fill" : "sparkles")
                    .font(.caption)
                Text("Using \(cloud.model)").lineLimit(1)
                Text(cloud.title).foregroundStyle(.secondary)
            }
                .foregroundStyle(.green)
                .help("A selected API provider falls back to your selected local model if it fails")
        } else if viewModel.apiProvider.enabled {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                ModelProviderIcon(
                    identity: ModelProviderResolver.identity(
                        for: viewModel.apiProvider.kind,
                        modelID: viewModel.apiProvider.model,
                        baseURL: viewModel.apiProvider.baseURL
                    ),
                    size: 16
                )
                Text("Using \(viewModel.apiProvider.model)").lineLimit(1)
                Text(viewModel.apiProvider.kind.title).foregroundStyle(.secondary)
            }
                .foregroundStyle(.green)
                .help("Current model in use via API")
        } else if let model = viewModel.activeModel {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                ModelBrandIcon(model: model, size: 16)
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

/// Two cloud runtimes share each intentional canvas column: NIM/Groq in the
/// upper column and Gemini/OpenRouter in the lower one. This avoids turning
/// cloud providers into a generic settings list while keeping each mark and
/// its active model centered in the available space.
private struct NexusCloudRuntimePanel: View {
    let providers: [NexusAPIProviderKind]
    @ObservedObject var store: NexusAPIProviderStore
    let theme: NexusGlassTheme
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(providers) { provider in
                NexusCloudRuntimeSlot(
                    provider: provider,
                    store: store,
                    theme: theme,
                    showSettings: showSettings
                )
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                if provider != providers.last! {
                    NexusHairline(axis: .horizontal)
                        .padding(.horizontal, 16)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A text-sized, centered cloud-runtime control. Artwork is intentionally raw
/// provider artwork—no shared rounded-square tile or background shape.
private struct NexusCloudRuntimeSlot: View {
    let provider: NexusAPIProviderKind
    @ObservedObject var store: NexusAPIProviderStore
    let theme: NexusGlassTheme
    let showSettings: () -> Void

    private var isActive: Bool {
        store.kind == provider && store.enabled
    }

    var body: some View {
        Button {
            let previous = store.kind
            store.selectKind(provider, replacing: previous)
            if !store.savedKey { showSettings() }
        } label: {
            VStack(alignment: .center, spacing: 7) {
                HStack(spacing: 9) {
                    ModelProviderIcon(
                        identity: ModelProviderResolver.identity(
                            for: provider,
                            modelID: provider.defaultModel,
                            baseURL: provider.defaultBaseURL
                        ),
                        size: 18
                    )
                    Text(provider.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(0.4)
                }
                Text(provider.defaultModel)
                    .font(.caption)
                    .foregroundStyle(isActive ? .green : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Use \(provider.title) when it has a saved API key")
    }
}

private struct NexusAPIProviderView: View {
    @ObservedObject var store: NexusAPIProviderStore
    let theme: NexusGlassTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("API model").font(.headline); Spacer(); Toggle("Use", isOn: $store.enabled).labelsHidden() }
            Picker("Provider", selection: $store.kind) {
                ForEach(NexusAPIProviderKind.supportedPresets) { provider in
                    APIProviderPickerLabel(provider: provider)
                        .tag(provider)
                }
            }
            .onChange(of: store.kind) { previous, next in
                store.selectKind(next, replacing: previous)
            }
            .labelsHidden()

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Endpoint") {
                    Text(store.baseURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                LabeledContent("Model") {
                    if store.kind == .openAI {
                        TextField("OpenAI model ID", text: $store.model)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: 250)
                            .accessibilityIdentifier("nexus-openai-model-id")
                    } else {
                        Text(store.model)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            SecureField(store.savedKey ? "API key (saved — enter to replace)" : "API key", text: $store.apiKeyInput)
            Text(store.kind.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if let connection = store.connectionMessage { Text(connection).font(.caption).foregroundStyle(.green) }
            HStack {
                Button("Disable") { store.disable(); dismiss() }
                Spacer()
                Button(store.isTestingConnection ? "Testing…" : "Test") {
                    Task { await store.testConnection() }
                }
                .disabled(store.isTestingConnection)
                Button("Save") {
                    do { try store.save(); dismiss() }
                    catch { store.recordError(error) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .nexusGlassPanel(theme: theme, role: .content, radius: 26)
    }
}

/// Deliberately rasterized, text-sized marks. Supplying an SVG directly to an
/// AppKit Picker can make it use its CSS/intrinsic canvas instead of the SwiftUI
/// frame, which is why Gemini previously filled the entire menu.
private struct APIProviderPickerLabel: View {
    let provider: NexusAPIProviderKind

    var body: some View {
        HStack(spacing: 6) {
            ModelProviderIcon(
                identity: ModelProviderResolver.identity(
                    for: provider,
                    modelID: provider.defaultModel,
                    baseURL: provider.defaultBaseURL
                ),
                size: 14
            )
            Text(provider.title)
        }
    }
}

private struct ModelSceneCard: View {
    let asset: String
    let accent: Color
    let theme: NexusGlassTheme

    var body: some View {
        ZStack {
            NexusFloatingScene(theme: theme, accent: accent) {
            SpinningUSDZView(
            assetName: asset,
            cameraDistance: asset == "Computer"
                ? Nexus3DLayout.computerCameraDistance
                : Nexus3DLayout.globeCameraDistance
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModelLibraryCard: View {
    let backend: ModelBackend
    @ObservedObject var viewModel: ModelDownloadViewModel
    let theme: NexusGlassTheme
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
            ModelBrandIcon(model: model, size: 24)
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
        .frame(minHeight: 52)
        .foregroundStyle(viewModel.activeModel?.id == model.id ? .white : .white.opacity(0.82))
    }

    @ViewBuilder private var action: some View {
        switch viewModel.states[model.id] ?? .idle {
        case .preparing(let status):
            activeDownload(status: status, progress: nil, completed: nil, total: nil)
        case .downloading(let progress, let completed, let total, let status):
            activeDownload(status: status, progress: progress, completed: completed, total: total)
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

    private func activeDownload(
        status: String,
        progress: Double?,
        completed: Int64?,
        total: Int64?
    ) -> some View {
        HStack(spacing: 7) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.cyan.opacity(0.9))
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 76)
                    Text(downloadDetail(progress: progress, completed: completed, total: total))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            Button { viewModel.cancel(model) } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Cancel download")
        }
    }

    private func downloadDetail(progress: Double, completed: Int64?, total: Int64?) -> String {
        if let completed, let total, total > 100 {
            return "\(Int(progress * 100))% · \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return "\(Int(progress * 100))%"
    }
}

private struct NexusConnectPage: View {
    @ObservedObject var controller: NexusConnectController
    let theme: NexusGlassTheme

    var body: some View {
        GeometryReader { proxy in
            let footerHeight: CGFloat = 58
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    DeviceCard(device: localDevice, controller: controller, theme: theme)
                    NexusHairline(axis: .vertical)
                    DeviceCard(device: remoteDevice(kind: .studio), controller: controller, theme: theme)
                    NexusHairline(axis: .vertical)
                    DeviceCard(device: remoteDevice(kind: .imac), controller: controller, theme: theme)
                }
                .frame(height: max(260, proxy.size.height - footerHeight - 1))
                .layoutPriority(1)
                NexusHairline(axis: .horizontal)
                pairingFooter
                    .frame(height: footerHeight)
            }
        }
        .nexusGlassPanel(theme: theme, role: .content, radius: 10)
    }

    private var pairingFooter: some View {
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
        .padding(.horizontal, 14)
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
    let theme: NexusGlassTheme

    var body: some View {
        VStack(spacing: 8) {
            SpinningUSDZView(
                assetName: device.asset,
                cameraDistance: device.kind == .imac
                    ? Nexus3DLayout.connectDeviceCameraDistance
                    : Nexus3DLayout.connectDeviceCameraDistance + 0.18,
                presentationTilt: 0.11
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
        .padding(18)
        .contentShape(Rectangle())
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
    let theme: NexusGlassTheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                MemoryCard(title: "Current", theme: theme) {
                    CurrentConversationView(snapshot: memory.activeConversation)
                }
                NexusHairline(axis: .horizontal)
                MemoryCard(title: "Previous", theme: theme) {
                    SavedConversationList(memory: memory)
                }
            }
            .frame(width: 270)
            NexusHairline(axis: .vertical)
            NexusObsidianBrainView(graph: memory.memoryGraph, vaultURL: memory.vaultURL, theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            NexusHairline(axis: .vertical)
            MemoryCard(title: "Vault", theme: theme) {
                NexVaultOutlineView(vaultURL: memory.vaultURL)
            }
            .frame(width: 240)
        }
        .nexusGlassPanel(theme: theme, role: .content, radius: 10)
        .task { await memory.refreshSavedConversations() }
    }
}

private struct MemoryCard<Content: View>: View {
    let title: String
    let theme: NexusGlassTheme
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

// MARK: - App glass system

/// Refractive, grainy glass built from ordinary SwiftUI primitives. This is
/// intentionally not `Material` or a macOS 26-only API, so the full visual
/// language is present on the Air as well as the Studio. Newer macOS releases
/// receive a little more highlight energy through the availability branch.
private enum NexusGlassRole {
    case sidebar
    case content
    case active
    case terminal
}

private struct NexusLiquidGlassBackground: View {
    let theme: NexusGlassTheme

    var body: some View {
        ZStack {
            NexusBackdropMaterial()
            Color.black.opacity(0.34)
            // These are broad, physical-looking studio reflections—not a
            // colored background. The selected theme only varies their tint.
            LinearGradient(
                colors: [.clear, theme.mainLight.opacity(0.055), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [.clear, theme.sidebarLight.opacity(0.028), .clear],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            NexusGrain(opacity: 0.018)
            Rectangle().stroke(.white.opacity(0.16), lineWidth: 0.7)
        }
        .ignoresSafeArea()
    }
}

/// NSVisualEffectView gives the app actual behind-window blur on every
/// supported macOS release. It is intentionally not a macOS 26-only effect.
private struct NexusBackdropMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.state = .active
    }
}

private struct NexusGrain: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var state: UInt64 = 0x9E3779B97F4A7C15
            for index in 0..<900 {
                state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                let x = CGFloat(state & 0xFFFF) / 65_535 * size.width
                state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                let y = CGFloat(state & 0xFFFF) / 65_535 * size.height
                let alpha = (index.isMultiple(of: 4) ? 0.85 : 0.30) * opacity
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.8, height: 0.8)), with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
        .blendMode(.overlay)
    }
}

private struct NexusGlassPanel: ViewModifier {
    let theme: NexusGlassTheme
    let role: NexusGlassRole
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(baseFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [highlight.opacity(0.08), .clear, .white.opacity(0.025)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                .white.opacity(role == .active ? 0.24 : 0.115),
                                lineWidth: 0.8
                            )
                    }
                    .overlay { NexusGrain(opacity: 0.012).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)) }
                    .shadow(color: .black.opacity(role == .sidebar ? 0.18 : 0.13), radius: role == .terminal ? 16 : 8, y: 4)
            }
    }

    private var highlight: Color { role == .sidebar ? theme.sidebarLight : theme.mainLight }

    private var baseFill: Color {
        switch role {
        case .sidebar:
            Color.black.opacity(0.12)
        case .active:
            Color.white.opacity(0.085)
        case .terminal:
            Color.black.opacity(0.42)
        case .content:
            Color.white.opacity(0.035)
        }
    }
}

private extension View {
    func nexusGlassPanel(theme: NexusGlassTheme, role: NexusGlassRole = .content, radius: CGFloat = 22) -> some View {
        modifier(NexusGlassPanel(theme: theme, role: role, radius: radius))
    }

    func nexusGlassCard(theme: NexusGlassTheme, role: NexusGlassRole = .content) -> some View {
        nexusGlassPanel(theme: theme, role: role, radius: 22)
    }
}

private struct NexusGlassCard<Content: View>: View {
    let theme: NexusGlassTheme
    let role: NexusGlassRole
    @ViewBuilder let content: Content

    init(theme: NexusGlassTheme, role: NexusGlassRole = .content, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.role = role
        self.content = content()
    }

    var body: some View { content.nexusGlassCard(theme: theme, role: role) }
}

private struct GlassSectionHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NexusFloatingScene<Content: View>: View {
    let theme: NexusGlassTheme
    let accent: Color
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 2 : 0.08)) { timeline in
            let float = reduceMotion ? 0 : sin(timeline.date.timeIntervalSinceReferenceDate * 0.65) * 7
            ZStack {
                Ellipse()
                    .fill(.black.opacity(0.28))
                    .frame(width: 170, height: 26)
                    .blur(radius: 11)
                    .offset(y: 92 - float * 0.30)
                content
                    .offset(y: float)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
            }
        }
    }
}

private struct NexusHairline: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.095))
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

private struct NexusObsidianBrainView: View {
    let graph: NexMemoryGraphSnapshot
    let vaultURL: URL
    let theme: NexusGlassTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEX").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(3)
                    Text("\(graph.nodes.count) indexed notes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            ZStack {
                NexusHolographicBrainMesh(theme: theme, reduceMotion: reduceMotion)
                    .padding(4)
                    .allowsHitTesting(false)
                NexMemoryPhysicsGraphView(graph: graph, vaultURL: vaultURL, theme: theme)
                    .padding(4)
            }
        }
        .padding(16)
    }
}

private struct NexusHolographicBrainMesh: View {
    let theme: NexusGlassTheme
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 3 : 0.08)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 0.22
            Canvas { context, size in
                let side = min(size.width, size.height) * 0.92
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for latitude in -5...5 {
                    let vertical = CGFloat(latitude) / 7
                    let width = sqrt(max(0.05, 1 - vertical * vertical)) * side / 2
                    let y = center.y + vertical * side / 2
                    var path = Path()
                    path.addEllipse(in: CGRect(x: center.x - width, y: y - side * 0.055, width: width * 2, height: side * 0.11))
                    context.stroke(path, with: .color(.white.opacity(0.10)), lineWidth: 0.55)
                }
                for longitude in 0..<13 {
                    let phase = CGFloat(angle) + CGFloat(longitude) * .pi / 13
                    let xScale = abs(cos(phase)) * 0.92 + 0.06
                    var path = Path()
                    path.addEllipse(in: CGRect(x: center.x - side * xScale / 2, y: center.y - side / 2, width: side * xScale, height: side))
                    context.stroke(path, with: .color(.white.opacity(0.065)), lineWidth: 0.45)
                }
                for point in 0..<170 {
                    let phi = CGFloat(point) * 2.39996 + CGFloat(angle)
                    let height = 1 - 2 * CGFloat(point) / 169
                    let radius = sqrt(max(0, 1 - height * height))
                    let x = center.x + cos(phi) * radius * side * 0.47
                    let y = center.y + height * side * 0.47
                    let alpha = 0.12 + Double((point % 5)) * 0.035
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(.white.opacity(alpha)))
                }
            }
            .shadow(color: .white.opacity(0.10), radius: 14)
        }
    }
}

private struct NexVaultOutlineView: View {
    let vaultURL: URL
    @State private var entries: [NexVaultOutlineEntry] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if entries.isEmpty {
                    Text("Indexing vault…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    Button {
                        NSWorkspace.shared.open(entry.url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                .font(.caption2)
                                .foregroundStyle(entry.isDirectory ? .yellow.opacity(0.9) : .white.opacity(0.58))
                            Text(entry.name)
                                .lineLimit(1)
                                .font(.caption)
                        }
                        .padding(.leading, CGFloat(entry.depth) * 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .help(entry.url.path)
                }
            }
        }
        .task(id: vaultURL) { entries = NexVaultOutlineEntry.scan(root: vaultURL) }
    }
}

private struct NexVaultOutlineEntry: Identifiable {
    let url: URL
    let name: String
    let depth: Int
    let isDirectory: Bool
    var id: String { url.path }

    static func scan(root: URL) -> [Self] {
        var output: [Self] = []
        func visit(_ directory: URL, depth: Int) {
            guard output.count < 450,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: [.skipsPackageDescendants]
                  ) else { return }
            for url in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                guard values?.isHidden != true else { continue }
                let isDirectory = values?.isDirectory == true
                guard isDirectory || url.pathExtension.lowercased() == "md" else { continue }
                output.append(.init(url: url, name: url.deletingPathExtension().lastPathComponent, depth: depth, isDirectory: isDirectory))
                if isDirectory { visit(url, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return output
    }
}

private struct SpinningUSDZView: NSViewRepresentable {
    let assetName: String
    var cameraDistance: Float = 3.1
    var presentationTilt: Float = 0

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
        // A tiny consistent downward cant makes the three Connect machines
        // read as physical objects without giving one node a different light.
        spinner.eulerAngles.x = CGFloat(presentationTilt)
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

    private var viewIdentifier: String { "\(assetName):\(cameraDistance):\(presentationTilt)" }

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
