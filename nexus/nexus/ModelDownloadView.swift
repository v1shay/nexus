import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var viewModel: ModelDownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models").font(.headline)
                Spacer()
                Text("\(viewModel.memoryGB) GB memory").font(.caption).foregroundStyle(.secondary)
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
    }

    private var selectedModel: LocalModel? {
        (viewModel.recommended + viewModel.visibleCatalog).first { $0.id == viewModel.selectedModelID }
    }

    private func modelRow(_ model: LocalModel) -> some View {
        ModelDownloadRow(
            model: model,
            state: viewModel.states[model.id] ?? .idle,
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
            if viewModel.activeModel?.id == model.id {
                Label("In Use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Use") { viewModel.use(model) }
            }
        case .idle:
            Button("Download") { viewModel.download(model) }.keyboardShortcut(.defaultAction)
        }
    }
}

private struct ModelDownloadRow: View {
    let model: LocalModel
    let state: ModelDownloadState
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
