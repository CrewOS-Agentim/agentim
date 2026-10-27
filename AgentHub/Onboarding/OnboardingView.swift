import AppKit
import SwiftUI

/// First-run setup, full window: Welcome → Docker → Models → Install → Done.
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(HostController.self) private var host
    @Bindable var model: OnboardingModel
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StepDots(step: model.step)
                .padding(.top, 22)
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .docker: DockerStep(docker: model.docker)
                case .models: ModelsStep(model: model)
                case .install: InstallStep(model: model)
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            footer
        }
        .background(
            LinearGradient(colors: [Color(red: 0.98, green: 0.96, blue: 1), .white], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
        .task { if model.step == .docker || model.docker.state == .checking { await model.docker.check() } }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .done && !model.isInstalling {
                Button("Back") { go(-1) }.controlSize(.large)
            }
            Spacer()
            switch model.step {
            case .welcome:
                Button("Get started") { go(1) }.buttonStyle(.borderedProminent).controlSize(.large)
            case .docker:
                Button("Continue") { go(1) }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.docker.isReady)
            case .models:
                Button("Continue") { go(1) }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.enoughDisk)
            case .install:
                Button(model.isInstalling ? "Installing…" : "Install") {
                    Task { await model.install(host: host, store: store) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.isInstalling)
            case .done:
                Button("Open agentim") { onFinish() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 22)
        .background(.bar)
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingModel.Step(rawValue: model.step.rawValue + delta) else { return }
        withAnimation(.snappy) { model.step = next }
        if next == .docker { Task { await model.docker.check() } }
    }
}

private struct StepDots: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: s == step ? 28 : 8, height: 8)
            }
        }
        .animation(.snappy, value: step)
    }
}

private struct Hero: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(title).font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 150, height: 150)
                .shadow(color: .purple.opacity(0.35), radius: 30, y: 12)
            Text("Hi, I'm Agent Tim.").font(.system(size: 44, weight: .bold))
            Text("Let's set up your private AI switchboard. It takes about five minutes.")
                .font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Bullet(symbol: "shippingbox.fill", title: "Docker", text: "We'll install it if you need it")
                Bullet(symbol: "cpu.fill", title: "Your models", text: "Chat, coding, voice, video")
                Bullet(symbol: "lock.fill", title: "Private", text: "Everything runs on this Mac")
            }
            .padding(.top, 10)
            Spacer()
        }
    }
}

private struct Bullet: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 180)
    }
}

private struct DockerStep: View {
    let docker: DockerSetup

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Hero(symbol: "shippingbox.fill", title: "Docker runs your models",
                 subtitle: "Hugging Face models, the gateway and the voice service run in Docker containers, isolated from the rest of your Mac.")
            Group {
                switch docker.state {
                case .checking:
                    ProgressView("Looking for Docker…")
                case .notInstalled:
                    VStack(spacing: 12) {
                        Text("Docker Desktop isn't installed yet.").font(.headline)
                        Button("Download & install Docker Desktop") { Task { await docker.install() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Text("About 550 MB, from docker.com. It's free for personal use and small businesses.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .downloading(let progress):
                    VStack(spacing: 8) {
                        ProgressView(value: progress).frame(width: 360)
                        Text("Downloading Docker Desktop… \(Int(progress * 100))%").foregroundStyle(.secondary)
                    }
                case .installing:
                    ProgressView("Installing Docker into Applications…")
                case .starting:
                    VStack(spacing: 8) {
                        ProgressView("Starting Docker…")
                        Text("If Docker asks, accept its terms. agentim continues as soon as the engine is up.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .ready(let memory):
                    VStack(spacing: 6) {
                        Label("Docker is ready", systemImage: "checkmark.seal.fill")
                            .font(.title2.bold()).foregroundStyle(.green)
                        Text("\(MemoryAssessment.format(memory)) of memory available for models")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Try again") { Task { await docker.check() } }
                    }
                }
            }
            .frame(minHeight: 120)
            Spacer()
        }
    }
}

private struct ModelsStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Pick your models").font(.system(size: 30, weight: .bold))
                Text("Recommended picks fit this Mac. You can change them any time.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], alignment: .center, spacing: 16) {
                    ForEach(ModelCategory.allCases) { category in
                        CategoryCard(model: model, category: category)
                    }
                }
                .padding(.bottom, 8)
            }
            summary
        }
    }

    private var summary: some View {
        HStack(spacing: 22) {
            Label("Download \(MemoryAssessment.format(model.plan.downloadBytes))", systemImage: "arrow.down.circle")
            Label("\(MemoryAssessment.format(model.freeDiskBytes)) free on disk", systemImage: "internaldrive")
                .foregroundStyle(model.enoughDisk ? Color.secondary : Color.red)
            Label("\(MemoryAssessment.format(model.memoryBudget)) for models in Docker", systemImage: "memorychip")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct CategoryCard: View {
    @Bindable var model: OnboardingModel
    let category: ModelCategory

    var body: some View {
        let selected = model.choice(for: category)
        let recommended = model.recommended(category)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: category.symbol).font(.title2).foregroundStyle(.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title).font(.title3.bold())
                    Text(category.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            ForEach(ModelCatalog.options(for: category)) { option in
                OptionRow(option: option, isSelected: option.id == selected.id, isRecommended: option.id == recommended.id,
                          fits: ModelCatalog.fits(option, memory: model.memoryBudget),
                          unavailable: option.kind == .ltx && !model.ltxInstalled) {
                    model.selections[category] = option.id
                }
            }
            if category == .media && !model.ltxInstalled {
                Link("Get LTX Desktop (free) ›", destination: URL(string: "https://ltx.studio")!).font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

private struct OptionRow: View {
    let option: ModelChoice
    let isSelected: Bool
    let isRecommended: Bool
    let fits: Bool
    let unavailable: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.name).font(.callout.weight(.semibold))
                        if isRecommended { Badge(text: "Recommended", color: .purple) }
                        if !fits { Badge(text: "Too big", color: .red) }
                        if unavailable { Badge(text: "Not installed", color: .orange) }
                    }
                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if option.sizeBytes > 0 {
                    Text(MemoryAssessment.format(option.sizeBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!fits || unavailable)
        .opacity(!fits || unavailable ? 0.45 : 1)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }
}

private struct InstallStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            Hero(symbol: "sparkles", title: model.tasks.isEmpty ? "Ready to install" : "Setting things up",
                 subtitle: model.tasks.isEmpty
                    ? "agentim will start its containers, download your models and keep everything running in the background."
                    : "Grab a coffee. Big models take a few minutes on the first download.")
                .padding(.top, 24)
            if model.tasks.isEmpty {
                PlanSummary(plan: model.plan).frame(maxWidth: 560)
                Toggle(isOn: $model.keepAwake) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stay awake with the lid closed while charging")
                        Text("Asks for your password once in Terminal. On battery your Mac sleeps normally.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .frame(maxWidth: 560)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.tasks) { task in TaskRow(task: task) }
                }
                .frame(maxWidth: 560)
            }
            Spacer()
        }
    }
}

private struct PlanSummary: View {
    let plan: OnboardingPlan

    var body: some View {
        VStack(spacing: 8) {
            row(.chat, plan.chat)
            row(.coding, plan.coding)
            row(.voice, plan.voice)
            row(.media, plan.media)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ category: ModelCategory, _ choice: ModelChoice) -> some View {
        HStack {
            Label(category.title, systemImage: category.symbol).frame(width: 170, alignment: .leading)
            Text(choice.name).fontWeight(.semibold)
            Spacer()
            if choice.sizeBytes > 0 { Text(MemoryAssessment.format(choice.sizeBytes)).foregroundStyle(.secondary) }
        }
    }
}

private struct TaskRow: View {
    let task: OnboardingModel.SetupTask

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch task.status {
                case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                switch task.status {
                case .running(let progress?):
                    ProgressView(value: progress).frame(maxWidth: 360)
                case .failed(let message), .skipped(let message):
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                default:
                    EmptyView()
                }
            }
        }
    }
}

private struct DoneStep: View {
    @Environment(HostController.self) private var host

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            Text("Agent Tim is on duty 🎉").font(.system(size: 36, weight: .bold))
            Text("Your models are running privately on this Mac. Now give Tim a way to reach you:")
                .font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button("Add Telegram or Slack tokens", systemImage: "paperplane.fill") { host.editSettings() }
                Button("Link WhatsApp", systemImage: "qrcode") { host.openWhatsAppQR() }
            }
            .controlSize(.large)
            Spacer()
        }
    }
}
