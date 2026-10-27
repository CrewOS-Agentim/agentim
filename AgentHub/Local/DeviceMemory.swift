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
    var hostLabel = "this Mac"

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

    /// Memory the Mac can hand out right now: free + inactive + purgeable + speculative pages
    /// (the same "available" figure Activity Monitor and `vm_stat` imply).
    static var availableToAppBytes: Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return appCeilingBytes / 2 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
        return Int64(pages * UInt64(vm_kernel_page_size))
    }

    /// Apple silicon lets the GPU wire roughly 75% of unified memory, which caps one model.
    static var appCeilingBytes: Int64 { Int64(Double(physicalBytes) * 0.75) }

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
