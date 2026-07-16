import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var viewModel: ModelDownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models").font(.headline)
                Spacer()
                Text("\(viewModel.memoryGB) GB available memory").font(.caption).foregroundStyle(.secondary)
            }
            if let connect = viewModel.connectController {
                NexusConnectSetupView(controller: connect)
                NexusModelRoutingView(controller: connect)
            }
            HStack {
                TextField("Search the registry or paste an exact model identifier", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await viewModel.refreshCatalog() } }
                Picker("Runtime", selection: $viewModel.backend) {
                    ForEach(ModelBackend.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 130)
                .onChange(of: viewModel.backend) { _, _ in viewModel.backendChanged() }
                Button("Search") { Task { await viewModel.refreshCatalog() } }
            }

            Text("Nexus recommends").font(.headline)
            List(selection: $viewModel.selectedModelID) {
                Section("Fits this Mac") {
                    ForEach(viewModel.recommended) { modelRow($0) }
                }
                Section("Full registry") {
                    ForEach(viewModel.visibleCatalog) { modelRow($0) }
                }
            }

            HStack {
                Text(viewModel.catalogMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if let selectedModel { actionButton(for: selectedModel) }
            }
        }
        .padding(18)
        .alert(item: $viewModel.pendingOllamaInstall) { model in
            Alert(
                title: Text("Install Ollama?"),
                message: Text("Nexus will download the official Ollama macOS app and install it in ~/Applications, then download \(model.name)."),
                primaryButton: .default(Text("Install and Continue"), action: viewModel.installOllamaAndContinue),
                secondaryButton: .cancel()
            )
        }
        .alert(item: $viewModel.pendingRemoteRuntimeInstall) { request in
            Alert(
                title: Text("Install Ollama remotely?"),
                message: Text("Nexus will install its supported Ollama runtime directly on \(request.deviceNames.joined(separator: ", ")). Model bytes will download from the internet to those Macs, never through this Mac."),
                primaryButton: .default(Text("Install and Continue"), action: viewModel.installRemoteRuntimeAndContinue),
                secondaryButton: .cancel()
            )
        }
    }

    private var selectedModel: LocalModel? {
        (viewModel.recommended + viewModel.visibleCatalog).first { $0.id == viewModel.selectedModelID }
    }

    private func modelRow(_ model: LocalModel) -> some View {
        ModelDownloadRow(
            model: model,
            state: viewModel.states[model.id] ?? .idle,
            placement: viewModel.placementDescription(for: model),
            cancel: { viewModel.cancel(model) },
            retry: { viewModel.retry(model) }
        )
        .tag(model.id)
    }

    @ViewBuilder
    private func actionButton(for model: LocalModel) -> some View {
        switch viewModel.states[model.id] ?? .idle {
        case .preparing, .downloading:
            Button("Cancel") { viewModel.cancel(model) }
        case .failed:
            Button("Retry") { viewModel.retry(model) }.keyboardShortcut(.defaultAction)
        case .installed:
            if viewModel.activeModel?.id == model.id && viewModel.isUsable(model) {
                Label("In Use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if !viewModel.isUsable(model) {
                Button("Download to Selected") { viewModel.download(model) }
            } else {
                Button("Use") { viewModel.use(model) }
            }
        case .idle:
            Button("Download") { viewModel.download(model) }.keyboardShortcut(.defaultAction)
        }
    }
}

private struct NexusModelRoutingView: View {
    @ObservedObject var controller: NexusConnectController

    var body: some View {
        HStack(spacing: 10) {
            Picker("Run models on", selection: Binding(
                get: { controller.modelRoute },
                set: { controller.setModelRoute($0) }
            )) {
                Text("Automatic").tag(NexusModelRoute.automatic)
                Text("This Mac").tag(NexusModelRoute.thisMac)
                ForEach(controller.pairedNodes) { node in
                    Text("\(node.displayName) · \(node.status.rawValue)")
                        .tag(NexusModelRoute.pairedNode(node.id))
                }
            }
            .frame(maxWidth: 310)

            Menu {
                Toggle("This Mac", isOn: targetBinding(.thisMac))
                Divider()
                ForEach(controller.pairedNodes) { node in
                    Toggle(isOn: targetBinding(.pairedNode(node.id))) {
                        Text("\(node.displayName) · \(node.status.rawValue)")
                    }
                }
            } label: {
                Label(downloadTargetSummary, systemImage: "arrow.down.circle")
            }
            .help("Choose one or more Macs. Each selected host downloads model bytes directly to its own disk.")
            Spacer()
        }
        .font(.caption)
    }

    private func targetBinding(_ target: NexusDownloadTarget) -> Binding<Bool> {
        Binding(
            get: { controller.downloadTargets.contains(target) },
            set: { controller.setDownloadTarget(target, selected: $0) }
        )
    }

    private var downloadTargetSummary: String {
        let count = controller.downloadTargets.count
        if count > 1 { return "Download to \(count) Macs" }
        guard let target = controller.downloadTargets.first else { return "Download target" }
        switch target {
        case .thisMac: return "Download to This Mac"
        case .pairedNode(let id):
            let name = controller.pairedNodes.first(where: { $0.id == id })?.displayName ?? "paired Mac"
            return "Download to \(name)"
        }
    }
}

private struct NexusConnectSetupView: View {
    @ObservedObject var controller: NexusConnectController
    @State private var expanded = false
    @State private var renamingNodeID: UUID?
    @State private var renameText = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Role", selection: Binding(
                        get: { controller.role },
                        set: { controller.setRole($0) }
                    )) {
                        ForEach(NexusConnectRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .frame(maxWidth: 260)
                    Toggle("Enable automatically", isOn: Binding(
                        get: { controller.enabled },
                        set: { controller.setEnabled($0) }
                    ))
                    Spacer()
                }

                if controller.role == .client {
                    HStack {
                        TextField("Paste NX2 code from another Mac", text: $controller.pairingCode)
                            .textFieldStyle(.roundedBorder)
                        Button("Pair device", action: controller.applyPairingCode)
                            .disabled(controller.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(controller.pairedNodes) { node in
                        HStack(spacing: 8) {
                            Circle().fill(statusColor(node.status)).frame(width: 7, height: 7)
                            if renamingNodeID == node.id {
                                TextField("Device name", text: $renameText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 210)
                                    .onSubmit { saveRename(node.id) }
                                Button("Save") { saveRename(node.id) }
                                Button("Cancel") { renamingNodeID = nil }
                            } else {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(node.displayName).font(.caption.weight(.medium))
                                    Text(nodeDetail(node)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Reconnect") { controller.reconnect(nodeID: node.id) }
                                    .disabled(node.status == .online)
                                Button("Rename") {
                                    renamingNodeID = node.id
                                    renameText = node.displayName
                                }
                                Button("Forget", role: .destructive) { controller.forget(nodeID: node.id) }
                            }
                        }
                    }
                } else {
                    HStack {
                        Button("Create one-time pairing code", action: controller.createPairingCode)
                        Button("Copy", action: controller.copyPairingCode)
                            .disabled(controller.pairingCode.isEmpty)
                        Button("Refresh devices", action: controller.refreshAuthorizedClients)
                    }
                    if !controller.pairingCode.isEmpty {
                        Text(controller.pairingCode)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    ForEach(controller.authorizedClients) { client in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(client.status == .authorized ? Color.green : (client.status == .revoked ? .red : .orange))
                                .frame(width: 7, height: 7)
                            if renamingNodeID == client.id {
                                TextField("Device name", text: $renameText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 210)
                                    .onSubmit { saveClientRename(client.id) }
                                Button("Save") { saveClientRename(client.id) }
                                Button("Cancel") { renamingNodeID = nil }
                            } else {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(client.displayName).font(.caption.weight(.medium))
                                    Text(authorizedClientDetail(client)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if client.status != .revoked {
                                    Button("Rename") {
                                        renamingNodeID = client.id
                                        renameText = client.displayName
                                    }
                                    Button("Revoke", role: .destructive) {
                                        controller.revokeAuthorizedClient(pairingID: client.id)
                                    }
                                }
                            }
                        }
                    }
                }
                Text(controller.setupMessage.isEmpty
                     ? defaultHelp
                     : controller.setupMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: connectIcon)
                    .foregroundStyle(connectColor)
                Text("Nexus Connect")
                    .font(.subheadline.weight(.medium))
                Text(controller.state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
    }

    private var defaultHelp: String {
        controller.role == .client
            ? "Pair each Studio or iMac once. Saved devices reconnect independently after either Mac restarts."
            : "The background Nexus Connect host stays available after the visible app quits. Create a separate code for each client you authorize."
    }

    private func saveRename(_ nodeID: UUID) {
        controller.rename(nodeID: nodeID, to: renameText)
        renamingNodeID = nil
    }

    private func saveClientRename(_ pairingID: UUID) {
        controller.renameAuthorizedClient(pairingID: pairingID, to: renameText)
        renamingNodeID = nil
    }

    private func authorizedClientDetail(_ client: NexusAuthorizedClient) -> String {
        var parts = [client.status.rawValue]
        if let last = client.lastAuthenticatedAt {
            parts.append("connected \(last.formatted(.relative(presentation: .numeric)))")
        } else {
            parts.append("not connected yet")
        }
        return parts.joined(separator: " · ")
    }

    private func nodeDetail(_ node: NexusPairedNode) -> String {
        var parts = [node.status.rawValue, node.endpoint]
        if let last = node.lastSuccessfulHealthCheck {
            parts.append("seen \(last.formatted(.relative(presentation: .numeric)))")
        }
        if node.status == .incompatible, let detail = node.statusDetail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ status: NexusPairedNodeStatus) -> Color {
        switch status {
        case .online: .green
        case .reconnecting: .orange
        case .offline: .secondary
        case .incompatible, .revoked: .red
        }
    }

    private var connectIcon: String {
        switch controller.state {
        case .ready, .hosting: "network.badge.shield.half.filled"
        case .discovering, .connecting, .reconnecting: "network"
        case .failed: "exclamationmark.triangle"
        case .off, .needsPairing: "network.slash"
        }
    }

    private var connectColor: Color {
        switch controller.state {
        case .ready, .hosting: .green
        case .discovering, .connecting, .reconnecting: .orange
        case .failed: .red
        case .off, .needsPairing: .secondary
        }
    }
}

private struct ModelDownloadRow: View {
    let model: LocalModel
    let state: ModelDownloadState
    let placement: String?
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let placement {
                    Text("On \(placement)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            stateView
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var detail: String {
        let memory = model.minimumRAMGB > 0 ? " · ~\(model.minimumRAMGB) GB RAM" : ""
        return "\(model.backend.title) · \(model.identifier)\(memory)"
    }

    @ViewBuilder
    private var stateView: some View {
        switch state {
        case .idle:
            EmptyView()
        case .preparing(let message):
            HStack(spacing: 7) { ProgressView().controlSize(.small); Text(message).font(.caption) }
        case .downloading(let progress, let completed, let total, let status):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress).frame(width: 110)
                    Text(progressText(progress: progress, completed: completed, total: total, status: status))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button(action: cancel) { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel")
            }
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.title3)
                .transition(.scale.combined(with: .opacity))
        case .failed(let message):
            HStack(spacing: 7) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
                Button("Retry", action: retry).controlSize(.small)
            }
        }
    }

    private func progressText(progress: Double, completed: Int64?, total: Int64?, status: String) -> String {
        if let completed, let total, total > 100 {
            return "\(Int(progress * 100))% · \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return progress > 0 ? "\(Int(progress * 100))%" : status
    }
}
