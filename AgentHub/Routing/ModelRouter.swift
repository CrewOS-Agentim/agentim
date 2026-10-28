import Foundation

/// User-level routing preferences (Settings ▸ Router).
struct RouterSettings: Codable, Hashable {
    enum Priority: String, Codable, CaseIterable, Identifiable {
        case economy, balanced, quality
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var priority: Priority = .balanced
    /// Route sensitive-looking prompts to an installed local model.
    var keepSensitiveLocal = true
    /// Prefer local models for everything they can handle.
    var preferLocal = false
    /// Model used when nothing else fits. nil = best available.
    var fallbackModelID: String?
}

struct RoutingRequest {
    var text: String
    var history: [ChatMessage] = []
    var agent: Agent?
    var conversationPin: String?
    var isOnline = true
}

struct RoutingDecision: Equatable {
    var model: AIModel
    /// Ranked alternatives to try if the chosen model errors.
    var fallbacks: [AIModel]
    var reason: String
    /// The prompt with any "@alias" override removed.
    var cleanedText: String
    var profile: TaskProfile
}

enum RoutingError: LocalizedError, Equatable {
    case noModelsAvailable
    case unknownOverride(String)

    var errorDescription: String? {
        switch self {
        case .noModelsAvailable:
            "No model is available. Connect a provider in Settings or download a local model."
        case .unknownOverride(let alias):
            "No available model matches @\(alias)."
        }
    }
}

/// Picks the model for a message. Order of precedence:
/// 1. `@alias` in the message
/// 2. the conversation's pinned model
/// 3. the agent's pinned model
/// 4. offline → best local model
/// 5. sensitive content → local model (if enabled)
/// 6. capability scoring against the task profile
struct ModelRouter {
    /// Models the user can actually call right now (provider connected or weights installed).
    var available: [AIModel]
    var settings: RouterSettings

    func route(_ request: RoutingRequest) throws -> RoutingDecision {
        let (alias, cleaned) = Self.extractOverride(request.text)
        var profile = PromptClassifier.classify(cleaned, history: request.history)
        // Asked for media but nothing can make it: answer in text instead.
        if profile.primary.isMedia, !available.contains(where: { $0.capabilities.contains(profile.primary) }) {
            profile.primary = .creative
        }

        func decide(_ model: AIModel, _ reason: String) -> RoutingDecision {
            RoutingDecision(
                model: model, fallbacks: ranked(for: profile, request: request).filter { $0.id != model.id },
                reason: reason, cleanedText: cleaned, profile: profile)
        }

        if let alias {
            guard let model = available.first(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame || $0.id == alias })
            else { throw RoutingError.unknownOverride(alias) }
            return decide(model, "You asked for @\(model.alias)")
        }
        if let pin = request.conversationPin, let model = available.first(where: { $0.id == pin }) {
            return decide(model, "Pinned for this conversation")
        }
        if case .pinned(let id)? = request.agent?.modelPreference, let model = available.first(where: { $0.id == id }) {
            return decide(model, "\(request.agent?.name ?? "Agent") is pinned to this model")
        }

        // Your own computers count as private; with no network only the phone itself is reachable.
        let locals = candidates(for: profile).filter { request.isOnline ? $0.isLocal : $0.isOnDevice }
        if !request.isOnline {
            guard let best = bestLocal(locals, profile) else { throw RoutingError.noModelsAvailable }
            return decide(best, "Offline, using on-device model")
        }
        if profile.isSensitive, settings.keepSensitiveLocal, let best = bestLocal(locals, profile) {
            return decide(best, best.isOnDevice ? "Looks sensitive, kept on-device" : "Looks sensitive, kept on your server")
        }
        if request.agent?.preferLocal == true, let best = bestLocal(locals, profile) {
            return decide(best, "\(request.agent?.name ?? "Agent") prefers private models")
        }

        let ranking = ranked(for: profile, request: request)
        guard let best = ranking.first else {
            if let id = settings.fallbackModelID, let model = available.first(where: { $0.id == id }) {
                return decide(model, "Fallback model")
            }
            throw RoutingError.noModelsAvailable
        }
        return RoutingDecision(
            model: best, fallbacks: Array(ranking.dropFirst()),
            reason: explain(best, profile), cleanedText: cleaned, profile: profile)
    }

    /// All usable models for the task, best first. Models whose context window
    /// can't hold the conversation are excluded.
    func ranked(for profile: TaskProfile, request: RoutingRequest) -> [AIModel] {
        let fitting = candidates(for: profile).filter { model in
            model.contextWindow >= profile.estimatedTokens + 1_024 && (request.isOnline || model.isOnDevice)
        }
        let scored: [(model: AIModel, score: Double)] = fitting.map { ($0, score($0, profile)) }
        return scored
            .sorted { a, b in a.score != b.score ? a.score > b.score : a.model.displayName < b.model.displayName }
            .map(\.model)
    }

    func score(_ model: AIModel, _ profile: TaskProfile) -> Double {
        var score = Double(model.qualityTier)
        if model.capabilities.contains(profile.primary) { score += 4 }
        if model.capabilities.contains(.general) { score += 0.5 }

        switch settings.priority {
        case .economy: score -= Double(model.costTier) * 1.5
        case .balanced: score -= Double(model.costTier) * 0.75
        case .quality: score += Double(model.qualityTier) * 0.75
        }

        // Quick questions don't need the heavyweights.
        if profile.primary == .fast { score -= Double(max(0, model.qualityTier - 3)) * 1.5 }
        // Hard tasks shouldn't land on tiny models.
        if [.reasoning, .coding, .longContext].contains(profile.primary) {
            score -= Double(max(0, 3 - model.qualityTier)) * 2
        }
        if settings.preferLocal && model.isLocal { score += 3 }
        return score
    }

    /// Media requests only go to media models; text requests never do.
    private func candidates(for profile: TaskProfile) -> [AIModel] {
        if profile.primary.isMedia { return available.filter { $0.capabilities.contains(profile.primary) } }
        return available.filter { !$0.isExplicitOnly }
    }

    private func bestLocal(_ locals: [AIModel], _ profile: TaskProfile) -> AIModel? {
        locals.max { score($0, profile) < score($1, profile) }
    }

    private func explain(_ model: AIModel, _ profile: TaskProfile) -> String {
        let task = profile.primary == .fast ? "Quick question" : "\(profile.primary.label) task"
        let fit = model.capabilities.contains(profile.primary) ? "strong at \(profile.primary.label.lowercased())" : "best available"
        return "\(task) → \(model.displayName) (\(fit), \(settings.priority.label.lowercased()) mode)"
    }

    /// Splits a leading or inline "@alias" from the prompt.
    static func extractOverride(_ text: String) -> (alias: String?, cleaned: String) {
        guard let range = text.range(of: #"(?:^|\s)@([A-Za-z0-9._\-/]+)"#, options: .regularExpression) else {
            return (nil, text)
        }
        let token = text[range].trimmingCharacters(in: .whitespaces)
        let alias = String(token.dropFirst())
        var cleaned = text
        cleaned.replaceSubrange(range, with: " ")
        return (alias, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
