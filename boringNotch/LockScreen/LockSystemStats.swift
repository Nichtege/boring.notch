//
//  LockSystemStats.swift
//  boringNotch
//
//  Processor, memory and disk use for the system widget. Only measures while someone is looking.
//

import Foundation

@MainActor
final class LockSystemStats: ObservableObject {
    static let shared = LockSystemStats()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0
    @Published private(set) var disk: Double = 0
    @Published private(set) var diskFree: Int64 = 0

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?

    private init() {}

    var isRunning: Bool {
        get { timer != nil }
        set {
            guard newValue != isRunning else { return }
            timer?.invalidate()
            timer = nil
            lastTicks = nil
            guard newValue else { return }
            measure()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.measure() }
            }
        }
    }

    private func measure() {
        if let ticks = Self.cpuTicks() {
            if let lastTicks, ticks.total > lastTicks.total {
                cpu = Double(ticks.busy - lastTicks.busy) / Double(ticks.total - lastTicks.total)
            }
            lastTicks = ticks
        }
        if let used = Self.memoryUsed() {
            memory = Double(used) / Double(ProcessInfo.processInfo.physicalMemory)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           let total = values.volumeTotalCapacity, total > 0 {
            diskFree = free
            disk = 1 - Double(free) / Double(total)
        }
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    private static func memoryUsed() -> UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }
}
