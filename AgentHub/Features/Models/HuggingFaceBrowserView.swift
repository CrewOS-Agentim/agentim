import SwiftUI

/// Search MLX models on the Hub and download ones that fit this device.
struct HuggingFaceBrowserView: View {
    @Environment(AppStore.self) private var store
    @State private var query = "Instruct 4bit"
    @State private var results: [HuggingFaceClient.ModelSummary] = []
    @State private var error: String?
    @State private var isSearching = false

    var body: some View {
        List {
            if let account = store.huggingFaceAccount {
                Label("Signed in as \(account.name)", systemImage: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.green)
            } else {
                Label("Public models only. Connect your account in Settings for gated models.",
                      systemImage: "info.circle")
                    .font(.footnote)
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(results) { model in
                NavigationLink { LocalModelDetailView(repo: model.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.id).font(.subheadline)
                        HStack(spacing: 12) {
                            Label("\(model.downloads ?? 0)", systemImage: "arrow.down.circle")
                            Label("\(model.likes ?? 0)", systemImage: "heart")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay { if isSearching { ProgressView() } }
        .searchable(text: $query, prompt: "Search MLX models")
        .onSubmit(of: .search) { Task { await search() } }
        .task { if results.isEmpty { await search() } }
        .navigationTitle("Hugging Face")
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await HuggingFaceClient(token: store.huggingFaceToken).searchMLXModels(query)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Fetches the repo's real file sizes, runs the memory check, then offers the download.
struct LocalModelDetailView: View {
    @Environment(AppStore.self) private var store
    let repo: String
    @State private var candidate: LocalModelManager.Candidate?
    @State private var error: String?

    var body: some View {
        List {
            Section("Model") {
                LabeledContent("Repository", value: repo)
                if let candidate {
                    LabeledContent("Download size",
                                   value: MemoryAssessment.format(candidate.files.reduce(0) { $0 + ($1.size ?? 0) }))
                    LabeledContent("Files", value: "\(candidate.files.count)")
                }
            }
            Section("Will it run on this device?") {
                if let assessment = candidate?.assessment {
                    Label(title(assessment.verdict), systemImage: symbol(assessment.verdict))
                        .foregroundStyle(color(assessment.verdict))
                        .font(.headline)
                    Text(assessment.message).font(.subheadline)
                    LabeledContent("Memory needed", value: MemoryAssessment.format(assessment.requiredBytes))
                    LabeledContent("Free for apps now", value: MemoryAssessment.format(assessment.availableBytes))
                    LabeledContent("Device app limit", value: MemoryAssessment.format(assessment.deviceBytes))
                    LabeledContent("Free storage", value: MemoryAssessment.format(assessment.freeDiskBytes))
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView("Checking size…")
                }
            }
            Section { action }
        }
        .navigationTitle(repo.split(separator: "/").last.map(String.init) ?? repo)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                candidate = try await store.localModels.inspect(repo: repo, token: store.huggingFaceToken)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if LocalModelManager.isInstalled(repo) {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if case .downloading(let progress)? = store.localModels.downloads[repo] {
            ProgressView(value: progress) { Text("Downloading…") }
        } else if case .failed(let message)? = store.localModels.downloads[repo] {
            Text(message).foregroundStyle(.red)
        } else if let candidate {
            Button {
                store.localModels.download(candidate, token: store.huggingFaceToken) { store.registerInstalled(repo: $0) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
            }
            .disabled(!candidate.assessment.canDownload)
        }
    }

    private func title(_ verdict: MemoryAssessment.Verdict) -> String {
        switch verdict {
        case .fits: "Fits"
        case .tight: "Tight fit"
        case .tooLarge: "Too large for this device"
        case .notEnoughDisk: "Not enough storage"
        }
    }

    private func symbol(_ verdict: MemoryAssessment.Verdict) -> String {
        switch verdict {
        case .fits: "checkmark.circle.fill"
        case .tight: "exclamationmark.triangle.fill"
        case .tooLarge, .notEnoughDisk: "xmark.octagon.fill"
        }
    }

    private func color(_ verdict: MemoryAssessment.Verdict) -> Color {
        switch verdict {
        case .fits: .green
        case .tight: .orange
        case .tooLarge, .notEnoughDisk: .red
        }
    }
}
