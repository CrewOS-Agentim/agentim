import Foundation

/// What a suggested model is good at; skills are matched to these.
enum ModelUse: String, CaseIterable, Hashable {
    case design, frontend, vision, coding, images

    var label: String {
        switch self {
        case .design: "UI/UX design"
        case .frontend: "Frontend code"
        case .vision: "Screenshots & wireframes"
        case .coding: "Coding"
        case .images: "Images & visual style"
        }
    }

    /// Words in a skill's name, description or triggers that call for this use.
    var keywords: [String] {
        switch self {
        case .design: ["design", "ui", "ux", "brand", "figma", "wireframe", "mockup", "prototype", "landing page", "visual"]
        case .frontend: ["frontend", "front-end", "react", "css", "tailwind", "html", "component", "web", "landing page", "website"]
        case .vision: ["screenshot", "wireframe", "mockup", "image", "visual", "design", "figma"]
        case .coding: ["code", "coding", "engineer", "developer", "debug", "review", "refactor", "api", "devops", "qa", "test"]
        case .images: ["image", "illustration", "logo", "thumbnail", "brand", "visual", "art", "style", "video"]
        }
    }
}

/// An open model worth suggesting for a skill, and how agentim can run it.
struct SuggestedModel: Identifiable, Hashable {
    enum Source: Hashable {
        /// Pulled into Docker (or a server) through the runner, with a memory check first.
        case ollama(String)
        /// Already in the cloud catalog (Hugging Face Inference Providers); this is its AIModel id.
        case cloud(String)
        /// Runs outside agentim (ComfyUI, diffusers); the Hub page explains how.
        case hub
    }

    var name: String
    /// The Hugging Face repo the model comes from.
    var repo: String
    var detail: String
    /// Download size in bytes (Q4_K_M GGUF), 0 when nothing downloads.
    var sizeBytes: Int64
    var source: Source
    var uses: Set<ModelUse>

    var id: String { "\(repo)|\(name)" }
    var hubURL: URL { URL(string: "https://huggingface.co/\(repo)")! }

    var ollamaRef: String? {
        if case .ollama(let ref) = source { return ref }
        return nil
    }
}

enum SkillModels {
    private static func gigabytes(_ value: Double) -> Int64 { Int64(value * 1_073_741_824) }

    /// Sizes are the real Q4_K_M files on Hugging Face (checked Oct 2026).
    static let all: [SuggestedModel] = [
        .init(name: "Qwen3.5 9B", repo: "unsloth/Qwen3.5-9B-GGUF",
              detail: "Natively multimodal: reads UI wireframes and screenshots and turns layouts into code.",
              sizeBytes: gigabytes(5.29), source: .ollama("hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M"),
              uses: [.design, .vision, .frontend]),
        .init(name: "Qwen3.5 27B", repo: "unsloth/Qwen3.5-27B-GGUF",
              detail: "The bigger multimodal Qwen3.5 for layouts to code. Needs 32 GB+.",
              sizeBytes: gigabytes(15.59), source: .ollama("hf.co/unsloth/Qwen3.5-27B-GGUF:Q4_K_M"),
              uses: [.design, .vision, .frontend, .coding]),
        .init(name: "Frontend Design Expert 8B", repo: "stefans71/frontend-design-expert-8b",
              detail: "Tuned to turn UI design concepts and screenshots into working frontend markup.",
              sizeBytes: gigabytes(4.68), source: .ollama("hf.co/stefans71/frontend-design-expert-8b:Q4_K_M"),
              uses: [.design, .frontend, .vision]),
        .init(name: "STARK-WEB 12B", repo: "Situus/STARK-WEB-12B-v1.7",
              detail: "Trained on web design and structure for UI/UX code and component work.",
              sizeBytes: gigabytes(6.87), source: .ollama("hf.co/Situus/STARK-WEB-12B-v1.7-gguf:Q4_K_M"),
              uses: [.design, .frontend, .coding]),
        .init(name: "DeepSeek V4 Flash", repo: "deepseek-ai/DeepSeek-V4-Flash",
              detail: "Reasons through complex React, CSS and Tailwind logic. Too big for a Mac, so it runs on Hugging Face.",
              sizeBytes: 0, source: .cloud("huggingface/deepseek-ai/DeepSeek-V4-Flash"),
              uses: [.coding, .frontend]),
        .init(name: "DeepSeek V4 Pro", repo: "deepseek-ai/DeepSeek-V4-Pro",
              detail: "DeepSeek's strongest coder for big refactors and reviews, on Hugging Face.",
              sizeBytes: 0, source: .cloud("huggingface/deepseek-ai/DeepSeek-V4-Pro"),
              uses: [.coding]),
        .init(name: "Qwen3.5 27B (Hugging Face)", repo: "Qwen/Qwen3.5-27B",
              detail: "Multimodal Qwen3.5 without the download, on Hugging Face.",
              sizeBytes: 0, source: .cloud("huggingface/Qwen/Qwen3.5-27B"),
              uses: [.design, .vision, .frontend]),
        .init(name: "FLUX.2 klein 4B", repo: "black-forest-labs/FLUX.2-klein-4B",
              detail: "Open image model for UI assets and style exploration. Runs in ComfyUI or diffusers; agentim makes images with LTX.",
              sizeBytes: 0, source: .hub, uses: [.images]),
        .init(name: "FLUX.2 dev", repo: "black-forest-labs/FLUX.2-dev",
              detail: "The full FLUX.2 for high-aesthetic visuals. Runs in ComfyUI or diffusers on a big GPU.",
              sizeBytes: 0, source: .hub, uses: [.images]),
    ]

    /// What a skill needs, from its name, description and triggers.
    static func uses(for skill: Skill) -> Set<ModelUse> {
        let text = ([skill.name, skill.summary] + skill.triggers).joined(separator: " ").lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init))
        return Set(ModelUse.allCases.filter { use in
            use.keywords.contains { $0.contains(" ") ? text.contains($0) : words.contains($0) }
        })
    }

    /// Models for these skills, best match first (most shared uses, then private before cloud, then smaller).
    static func suggestions(for skills: [Skill]) -> [SuggestedModel] {
        let wanted = skills.reduce(into: Set<ModelUse>()) { $0.formUnion(uses(for: $1)) }
        guard !wanted.isEmpty else { return [] }
        func rank(_ model: SuggestedModel) -> Int {
            switch model.source { case .ollama: 0; case .cloud: 1; case .hub: 2 }
        }
        return all
            .map { model in (model, model.uses.intersection(wanted).count) }
            .filter { $0.1 > 0 }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
                return a.0.sizeBytes < b.0.sizeBytes
            }
            .map(\.0)
    }
}
