// Public-API sensors: everything macOS exposes without private frameworks.
// The private-API half (power, temps, fan, GPU, DRAM bandwidth) is vendored in sensors/.

import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - cpu

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return 0 }
    return Int(v)
}

/// "Apple M1 Pro" -> "M1 Pro"
func chipName() -> String {
    let brand = sysctlString("machdep.cpu.brand_string")
    guard !brand.isEmpty else { return sysctlString("hw.model") }
    return brand.hasPrefix("Apple ") ? String(brand.dropFirst(6)) : brand
}

func cpuTicks() -> (busy: Double, total: Double)? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    let user = Double(info.cpu_ticks.0), sys = Double(info.cpu_ticks.1)
    let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
    let busy = user + sys + nice
    return (busy, busy + idle)
}

/// Same counters as cpuTicks(), but one entry per logical core.
func coreTicks() -> [(busy: Double, total: Double)] {
    var cores: natural_t = 0
    var info: processor_info_array_t?
    var n: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &n) == KERN_SUCCESS,
          let info else { return [] }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                      vm_size_t(Int(n) * MemoryLayout<integer_t>.size))
    }
    return (0..<Int(cores)).map { i in
        let b = i * Int(CPU_STATE_MAX)
        let busy = Double(info[b + Int(CPU_STATE_USER)]) + Double(info[b + Int(CPU_STATE_SYSTEM)])
                 + Double(info[b + Int(CPU_STATE_NICE)])
        return (busy, busy + Double(info[b + Int(CPU_STATE_IDLE)]))
    }
}

/// % busy between two tick snapshots. 0 if the counters didn't move.
func cpuPercent(_ a: (busy: Double, total: Double), _ b: (busy: Double, total: Double)) -> Double {
    let dt = b.total - a.total
    guard dt > 0 else { return 0 }
    return max(0, min(100, (b.busy - a.busy) / dt * 100))
}

/// perflevel0 is the fast tier on Apple Silicon, perflevel1 the efficient one.
/// Intel Macs report neither, so both come back 0 and the caller skips the split.
func clusterSizes() -> (p: Int, e: Int) {
    (sysctlInt("hw.perflevel0.logicalcpu"), sysctlInt("hw.perflevel1.logicalcpu"))
}

// MARK: - memory

func memoryUsedGB() -> Double {
    var st = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &st) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let pages = Double(st.active_count) + Double(st.wire_count) + Double(st.compressor_page_count)
    return pages * Double(vm_page_size) / 1_073_741_824
}

func swapUsedGB() -> Double {
    var xsw = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return 0 }
    return Double(xsw.xsu_used) / 1_073_741_824
}

// MARK: - battery

struct Battery {
    var percent = 0.0
    var health = 0.0        // full-charge vs design capacity, %
    var cycles = 0
    var mAh = 0, designMAh = 0
    var charging = false, plugged = false
    var watts = 0.0         // + into the battery, - out of it
    var adapterWatts = 0.0
    var tempC = 0.0
}

/// nil on machines with no battery (Mac mini / Studio / Pro).
func battery() -> Battery? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let p = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

    var b = Battery()
    let now = p["AppleRawCurrentCapacity"] as? Int ?? p["CurrentCapacity"] as? Int ?? 0
    let full = p["AppleRawMaxCapacity"] as? Int ?? p["MaxCapacity"] as? Int ?? 0
    let design = p["DesignCapacity"] as? Int ?? 0
    b.mAh = now
    b.designMAh = design
    b.percent = full > 0 ? Double(now) / Double(full) * 100 : 0
    b.health = design > 0 ? Double(full) / Double(design) * 100 : 0
    b.cycles = p["CycleCount"] as? Int ?? 0
    b.charging = p["IsCharging"] as? Bool ?? false
    b.plugged = p["ExternalConnected"] as? Bool ?? false
    // Amperage is signed mA, Voltage mV — their product is the real charge/drain rate.
    let mA = Double(p["Amperage"] as? Int ?? 0), mV = Double(p["Voltage"] as? Int ?? 0)
    b.watts = mA * mV / 1_000_000
    b.tempC = Double(p["Temperature"] as? Int ?? 0) / 100
    if let adapter = p["AdapterDetails"] as? [String: Any] {
        b.adapterWatts = Double(adapter["Watts"] as? Int ?? 0)
    }
    return b
}

// MARK: - network + disk throughput

/// Cumulative byte counters; the UI turns consecutive samples into a rate.
struct Counters { var read: Double = 0, write: Double = 0 }

/// Bytes in/out summed over every non-loopback interface.
func networkCounters() -> Counters {
    var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return Counters() }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return Counters() }

    var c = Counters()
    buf.withUnsafeBytes { raw in
        var off = 0
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
            guard hdr.ifm_msglen > 0 else { break }
            if hdr.ifm_type == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                if m.ifm_data.ifi_type != IFT_LOOP {     // lo0 traffic isn't network traffic
                    c.read += Double(m.ifm_data.ifi_ibytes)
                    c.write += Double(m.ifm_data.ifi_obytes)
                }
            }
            off += Int(hdr.ifm_msglen)
        }
    }
    return c
}

/// Bytes read/written summed over every block storage driver.
func diskCounters() -> Counters {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else {
        return Counters()
    }
    defer { IOObjectRelease(it) }

    var c = Counters()
    while case let drive = IOIteratorNext(it), drive != 0 {
        defer { IOObjectRelease(drive) }
        guard let stats = IORegistryEntryCreateCFProperty(drive, "Statistics" as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { continue }
        c.read += Double(stats["Bytes (Read)"] as? Int64 ?? 0)
        c.write += Double(stats["Bytes (Write)"] as? Int64 ?? 0)
    }
    return c
}

/// Per-second rate between two cumulative snapshots. Counter resets (device
/// unplugged, driver reload) read as 0 rather than a huge negative spike.
func rate(_ a: Counters, _ b: Counters, seconds: Double) -> Counters {
    guard seconds > 0 else { return Counters() }
    return Counters(read: max(0, b.read - a.read) / seconds,
                    write: max(0, b.write - a.write) / seconds)
}

// MARK: - processes

struct AppUsage: Identifiable {
    let id: String
    var cpu = 0.0       // summed %, 100 == one full core (same as Activity Monitor)
    var memMB = 0.0
    var procs = 0
    var pids: [pid_t] = []
    /// Subset of `pids` belonging to a quittable windowed app. Filled in once per
    /// sample so the view never does an IOKit lookup while drawing a row.
    var quitTargets: [pid_t] = []
}

/// "Google Chrome Helper (Renderer)" -> "Google Chrome", so a multi-process app
/// shows up as one row instead of eight.
/// ponytail: string heuristic, not the real bundle identity. Walk the process
/// tree to responsible-PID only if a helper ever groups under the wrong app.
func appName(_ comm: String) -> String {
    var s = Substring(comm)
    if let r = s.range(of: " Helper") { s = s[..<r.lowerBound] }
    if let r = s.range(of: " (") { s = s[..<r.lowerBound] }
    return s.trimmingCharacters(in: .whitespaces)
}

func appUsage() -> [AppUsage] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Aceo", "pid,pcpu,rss,comm", "-r"]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()

    var byApp: [String: AppUsage] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4, let pid = pid_t(f[0]), let cpu = Double(f[1]), let rssKB = Double(f[2]) else { continue }
        let name = appName(String(f[3]))
        guard !name.isEmpty else { continue }
        var u = byApp[name] ?? AppUsage(id: name)
        u.cpu += cpu
        u.memMB += rssKB / 1024
        u.procs += 1
        u.pids.append(pid)
        byApp[name] = u
    }
    return byApp.values.sorted { $0.cpu > $1.cpu }
}

// MARK: - formatting

/// 1024-based, auto-scaled: "0 B/s", "912 KB/s", "1.4 GB/s"
func rateText(_ bytesPerSec: Double) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var v = bytesPerSec, i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? String(format: "%.0f %@/s", v, units[i])
                  : String(format: v >= 100 ? "%.0f %@/s" : "%.1f %@/s", v, units[i])
}

func memText(_ mb: Double) -> String {
    mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}
