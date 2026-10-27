import Foundation
import os

/// Can this device run a model of a given size?
struct MemoryAssessment: Equatable {
    enum Verdict: Equatable {
        /// Fits in memory the app can use right now.
        case fits
        /// Fits the device, but not with what's free now. Closing other apps may help.
        case tight
        /// Larger than the device can ever give one app.
        case tooLarge
        /// Not enough free storage to download it.
        case notEnoughDisk
    }

    var verdict: Verdict
    var requiredBytes: Int64
    var availableBytes: Int64
    var deviceBytes: Int64
    var freeDiskBytes: Int64
    var hostLabel = "this device"

    var canDownload: Bool { verdict == .fits || verdict == .tight }

    var message: String {
        let need = Self.format(requiredBytes)
        switch verdict {
        case .fits: return "Needs ~\(need) of memory. \(Self.format(availableBytes)) available."
        case .tight: return "Needs ~\(need); only \(Self.format(availableBytes)) free right now. Close other apps before running it."
        case .tooLarge: return "Needs ~\(need), but \(hostLabel) can give a model at most ~\(Self.format(deviceBytes))."
        case .notEnoughDisk: return "Download needs more storage than the \(Self.format(freeDiskBytes)) free."
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

enum DeviceMemory {
    /// Physical RAM.
    static var physicalBytes: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// What this process may still allocate before jetsam kills it.
    static var availableToAppBytes: Int64 {
        #if os(iOS) && !targetEnvironment(simulator)
        return Int64(os_proc_available_memory())
        #else
        // The simulator has no jetsam limit; use the iOS rule of thumb instead.
        return appCeilingBytes
        #endif
    }

    /// iOS lets one foreground app use roughly 60% of RAM with the
    /// increased-memory-limit entitlement (about 50% without it).
    static var appCeilingBytes: Int64 { Int64(Double(physicalBytes) * 0.6) }

    static var freeDiskBytes: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Memory needed to run a model: the weights, plus KV cache / activations
    /// (~20%), plus a fixed runtime overhead for MLX and the app itself.
    static func requiredBytes(weightBytes: Int64) -> Int64 {
        Int64(Double(weightBytes) * 1.2) + 400 * 1_024 * 1_024
    }

    static func assess(
        weightBytes: Int64,
        available: Int64 = availableToAppBytes,
        ceiling: Int64 = appCeilingBytes,
        freeDisk: Int64 = freeDiskBytes
    ) -> MemoryAssessment {
        let required = requiredBytes(weightBytes: weightBytes)
        let verdict: MemoryAssessment.Verdict
        if required > ceiling {
            verdict = .tooLarge
        } else if weightBytes + 200 * 1_024 * 1_024 > freeDisk {
            verdict = .notEnoughDisk
        } else if required > available {
            verdict = .tight
        } else {
            verdict = .fits
        }
        return MemoryAssessment(
            verdict: verdict, requiredBytes: required, availableBytes: available,
            deviceBytes: ceiling, freeDiskBytes: freeDisk)
    }
}
