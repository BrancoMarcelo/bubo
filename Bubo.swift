import SwiftUI
import Charts
import AppKit
import ServiceManagement
import Darwin

// Sensors split two ways: public APIs in Sensors.swift, everything macOS keeps
// private (power, temps, fan, GPU, DRAM bandwidth) in the vendored sensors/ layer.

// MARK: - model

struct Sample {
    var cpu = 0.0            // % across all cores
    var cores: [Double] = [] // % per logical core
    var ramUsed = 0.0, ramTotal = 1.0, swapUsed = 0.0   // GB
    var thermal = "nominal"
    var apps: [AppUsage] = []
    var io = IOReportData()  // power / temps / GPU / fan / DRAM bandwidth
    var battery: Battery?
    var net = Counters()     // bytes per second
    var disk = Counters()    // bytes per second
    var dram = Counters()    // bytes per second
    var ramPercent: Double { ramUsed / ramTotal * 100 }

    /// Board power if the chip exposes PSTR, otherwise the sum of the rails.
    var totalWatts: Double {
        io.systemPower > 0 ? io.systemPower : io.cpuPower + io.gpuPower + io.anePower + io.dramPower
    }
}

/// 0 clear, 1 moderate, 2 heavy — drives every colour in the UI.
func loadLevel(_ pct: Double) -> Int { pct >= 80 ? 2 : (pct >= 50 ? 1 : 0) }

/// A colour that resolves per appearance, so light mode gets a darker, less
/// saturated tone and dark mode a lighter one.
func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
    NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }
}

/// Muted on purpose: the system .green/.yellow/.red are built for badges on a
/// coloured chip and are too loud at text size.
///
/// Text and fills need different tones of the same hue. Measured against white,
/// the amber that looks right as a bar scores 2.5:1 as text — well under the 4.5:1
/// readability floor — while a text-dark amber turns the bars muddy. Green (4.6:1)
/// and red (5.3:1) were already fine, which is why only yellow read as broken.
let loadTextNSColors = [
    adaptive(light: (0.16, 0.52, 0.33), dark: (0.42, 0.80, 0.56)),   // clear, sage green
    adaptive(light: (0.62, 0.39, 0.02), dark: (0.94, 0.72, 0.31)),   // moderate, amber  4.9:1
    adaptive(light: (0.74, 0.25, 0.23), dark: (0.94, 0.47, 0.44)),   // heavy, clay red
]

/// Bars, per-core capsules, row backgrounds, the menu bar dot — shapes, not text,
/// so they can stay bright.
let loadNSColors = [
    adaptive(light: (0.18, 0.58, 0.36), dark: (0.42, 0.80, 0.56)),
    adaptive(light: (0.88, 0.63, 0.16), dark: (0.94, 0.72, 0.31)),
    adaptive(light: (0.78, 0.28, 0.25), dark: (0.94, 0.47, 0.44)),
]

let loadColors = loadTextNSColors.map(Color.init(nsColor:))       // text
let loadFillColors = loadNSColors.map(Color.init(nsColor:))       // shapes

func loadColor(_ pct: Double) -> Color { loadColors[loadLevel(pct)] }
func loadFill(_ pct: Double) -> Color { loadFillColors[loadLevel(pct)] }

/// Read from the bundle, which mk-app.sh stamps from the git tag — so the panel
/// always shows the version you actually installed, not one hardcoded in source.
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

func freqText(_ mhz: Int32) -> String {
    mhz >= 1000 ? String(format: "%.1f GHz", Double(mhz) / 1000) : "\(mhz) MHz"
}

/// The quittable windowed apps behind a row. Daemons and helper processes have no
/// .regular activation policy, so they get no quit button — no SIGTERM-ing mds.
func quittable(_ pids: [pid_t]) -> [NSRunningApplication] {
    pids.compactMap { NSRunningApplication(processIdentifier: $0) }
        .filter { $0.activationPolicy == .regular }
}

/// Sampling is expensive: IOReport's first call spends over a second enumerating
/// SMC keys and every later one costs ~130 ms, plus ~95 ms to run `ps`. Running
/// that on the main thread every 2 s was enough to make the popover feel frozen,
/// so all of it lives on this serial queue — serial because the vendored
/// IOReport wrapper keeps its subscription in static state.
final class Sampler: @unchecked Sendable {
    private let q = DispatchQueue(label: "local.bubo.sampler", qos: .utility)
    private let smc = SMCOpen()
    private var last = cpuTicks() ?? (0, 0)
    private var lastCores = coreTicks()
    private var lastNet = networkCounters()
    private var lastDisk = diskCounters()
    private var lastAt = Date()
    /// The first collect() runs milliseconds after init, so its elapsed is ~0 and
    /// every rate derived from it explodes (a 16 GB/s "disk peak"). The first IOReport
    /// call is a priming call with a meaningless delta too. Report zero rates until
    /// there's a real interval behind them.
    private var primed = false
    private let ramTotal = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    func sample(_ done: @escaping @Sendable (Sample) -> Void) {
        q.async { done(self.collect()) }
    }

    private func collect() -> Sample {
        var s = Sample()
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(lastAt))
        lastAt = now

        if let t = cpuTicks() {
            s.cpu = cpuPercent(last, t)
            last = t
        }
        let nowCores = coreTicks()
        if nowCores.count == lastCores.count {
            s.cores = zip(lastCores, nowCores).map(cpuPercent)
        }
        lastCores = nowCores

        s.ramUsed = memoryUsedGB()
        s.ramTotal = ramTotal
        s.swapUsed = swapUsedGB()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s.thermal = "nominal"
        case .fair:    s.thermal = "fair"
        case .serious: s.thermal = "serious"
        case .critical: s.thermal = "critical"
        @unknown default: s.thermal = "unknown"
        }

        // one call returns the delta since the previous call, so it tracks our interval
        s.io = IOReportWrapper.fetchIOReportData(withSMC: smc)

        let net = networkCounters(), disk = diskCounters()
        if primed {
            s.dram = Counters(read: Double(s.io.dramReadBytes) / elapsed,
                              write: Double(s.io.dramWriteBytes) / elapsed)
            s.net = rate(lastNet, net, seconds: elapsed)
            s.disk = rate(lastDisk, disk, seconds: elapsed)
        }
        lastNet = net; lastDisk = disk
        primed = true

        s.battery = battery()
        s.apps = appUsage()
        return s
    }
}

/// Tag every row with the pids that belong to a quittable windowed app — one
/// NSWorkspace scan per sample, instead of an NSRunningApplication lookup per pid
/// per row on every redraw.
@MainActor func annotateQuitTargets(_ apps: [AppUsage]) -> [AppUsage] {
    let regular = Set(NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .map(\.processIdentifier))
    return apps.map { a in
        var a = a
        a.quitTargets = a.pids.filter(regular.contains)
        return a
    }
}

@MainActor final class Monitor: ObservableObject {
    @Published var s = Sample()
    @Published var history: [(cpu: Double, ram: Double)] = []   // last 2 minutes
    /// throughput history for the network / disk sparklines, same 2-minute window
    @Published var ioHistory: [(nd: Double, nu: Double, dr: Double, dw: Double)] = []

    let chip = chipName()
    let clusters = clusterSizes()
    /// Called after every sample so the status item can refresh its title.
    var onUpdate: (() -> Void)?
    private let sampler = Sampler()
    private var pending = false

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// A slow sample must not queue up behind itself — under swap pressure a tick
    /// can outlast the 2 s interval.
    private func refresh() {
        guard !pending else { return }
        pending = true
        sampler.sample { new in
            Task { @MainActor in
                self.pending = false
                self.apply(new)
            }
        }
    }

    private func apply(_ new: Sample) {
        var new = new
        new.apps = annotateQuitTargets(new.apps)
        s = new
        history.append((s.cpu, s.ramPercent))
        if history.count > 60 { history.removeFirst() }
        ioHistory.append((s.net.read, s.net.write, s.disk.read, s.disk.write))
        if ioHistory.count > 60 { ioHistory.removeFirst() }
        onUpdate?()
    }

    var hot: Bool { s.thermal == "serious" || s.thermal == "critical" }

    /// The one status both the menu bar dot and the panel badge report, plus the
    /// metric that caused it. Previously the dot showed the worst of CPU/RAM/thermal
    /// while the badge showed thermal alone, so a machine at 78% RAM had a yellow
    /// dot next to a green "NOMINAL" and neither told you which to believe.
    var status: (level: Int, reason: String) {
        if hot { return (2, "thermal \(s.thermal)") }
        return s.ramPercent >= s.cpu
            ? (loadLevel(s.ramPercent), "RAM \(Int(s.ramPercent))%")
            : (loadLevel(s.cpu), "CPU \(Int(s.cpu))%")
    }

    var level: Int { status.level }
}

// MARK: - bits

/// Horizontal fill bar. `v` is 0...1, clamped.
struct Bar: View {
    var v: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: max(2, g.size.width * min(1, max(0, v))))
            }
        }
        .frame(height: height)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(.tertiary)
    }
}

/// Section title on the left, headline number on the right.
struct SectionHead: View {
    let title: String
    var value: String
    var color: Color = .primary
    var big = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel(text: title)
            Spacer()
            Text(value)
                .font(.system(size: big ? 22 : 12, weight: big ? .semibold : .medium,
                              design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

/// A row of label/value pairs under a section head. Each pair takes an equal
/// slice of the width, so values line up in columns down the panel instead of
/// running together in a "712 MHz · 30 °C · 0.16 W" string the eye has to parse.
struct Facts: View {
    /// Label, value, and an optional tint for a value that deserves attention
    /// (heavy swap, a draining battery).
    struct Item {
        let key: String, value: String
        var tint: Color?
        init(_ key: String, _ value: String, _ tint: Color? = nil) {
            self.key = key; self.value = value; self.tint = tint
        }
    }

    let items: [Item]

    /// Every row is padded to the same column count. Rows with different item
    /// counts got different column widths, so the battery's "state / rate" line
    /// never lined up with the "cycles / health / temp" line under it.
    /// Narrow this when the labels are short ("E 4×") and the values are long,
    /// or the value gets truncated inside its third of the width.
    var keyWidth: CGFloat = 44

    init(_ items: [Item], columns: Int = 3, keyWidth: CGFloat = 44) {
        self.items = items + Array(repeating: Item("", ""), count: max(0, columns - items.count))
        self.keyWidth = keyWidth
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                // Fixed-width label, value immediately after it. Labels differ in
                // length ("cycles" vs "temp"), so packing both left started the
                // numbers at random offsets; right-aligning the value instead
                // pushed it against the *next* column's label ("1.49 GHz P 4×").
                // A reserved label column fixes the ragged numbers and keeps each
                // value next to the word it belongs to.
                HStack(spacing: 4) {
                    Text(item.key)
                        .foregroundStyle(.tertiary)
                        .frame(width: keyWidth, alignment: .leading)
                    Text(item.value).foregroundStyle(item.tint ?? .secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 10, design: .rounded).monospacedDigit())
        .lineLimit(1)
    }
}

/// Throughput sparkline for one in/out pair. Scaled to the window's own peak,
/// since rates run from a few B/s to GB/s and a fixed axis would flatline almost
/// always. The peak is printed so the shape has a number to read against.
struct Spark: View {
    let title: String
    let inn: (label: String, series: [Double], color: Color)
    let out: (label: String, series: [Double], color: Color)

    var body: some View {
        let peak = max(inn.series.max() ?? 0, out.series.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                SectionLabel(text: title)
                Spacer()
                Text(rateText(peak))
                    .font(.system(size: 8, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Chart {
                ForEach(Array(inn.series.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v), series: .value("s", "in"))
                        .foregroundStyle(.linearGradient(colors: [inn.color.opacity(0.35), inn.color.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", i), y: .value("v", v), series: .value("s", "in"))
                        .foregroundStyle(inn.color)
                }
                ForEach(Array(out.series.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("t", i), y: .value("v", v), series: .value("s", "out"))
                        .foregroundStyle(out.color)
                        .lineStyle(.init(lineWidth: 1, dash: [3, 2]))
                }
            }
            .chartYScale(domain: 0...peak)
            .chartXScale(domain: 0...Double(max(1, inn.series.count - 1)))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 26)

            HStack(spacing: 0) {
                legend(inn.label, inn.series.last ?? 0, inn.color)
                Spacer(minLength: 4)
                legend(out.label, out.series.last ?? 0, out.color)
            }
        }
    }

    private func legend(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(label).foregroundStyle(.tertiary)
            Text(rateText(value)).foregroundStyle(.secondary)
        }
        .font(.system(size: 9, design: .rounded).monospacedDigit())
    }
}

/// A single dim line, for the few places a column layout would be overkill.
struct Detail: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .rounded).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

// MARK: - panel

struct Panel: View {
    @ObservedObject var m: Monitor

    var body: some View {
        ScrollView { PanelContent(m: m) }
            .frame(width: 360)
            .frame(maxHeight: 700)
    }
}

/// Which column the TOP APPS list is locked to. nil means free — the list keeps
/// its natural cpu order, the same way it opens.
enum AppSort { case proc, cpu, mem }

struct PanelContent: View {
    @ObservedObject var m: Monitor
    @State private var sort: AppSort?

    init(m: Monitor, initialSort: AppSort? = nil) {
        self.m = m
        _sort = State(initialValue: initialSort)   // snapshots lock a column to show the ▾
    }

    var body: some View {
        // CPU → memory → apps first: naming the heavy app is what this app is for,
        // so that list stays above the fold and the sensor detail scrolls under it.
        VStack(alignment: .leading, spacing: 9) {
            header
            cpuSection
            memorySection
            appSection
            gpuSection
            if m.s.io.fanRPM > 0 { fanSection }        // hidden on fanless models
            if let b = m.s.battery { batterySection(b) }
            ioSection
            powerSection
            optimizeSection
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: 360)
    }

    // pieces the --bench flag renders on their own
    var benchChart: some View { chart.frame(width: 332) }
    var benchApps: some View { appSection.frame(width: 332) }
    var benchCPU: some View { cpuSection.frame(width: 332) }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Bubo").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(appVersion)
                        .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                // total power lives in POWER RAILS; repeating it here was noise
                Detail(text: "\(m.chip)  ·  \(m.s.cores.count) cores")
            }
            Spacer()
            // same level as the menu bar dot, and it names what drove it
            HStack(spacing: 4) {
                Text(["NORMAL", "BUSY", "HEAVY"][m.status.level])
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                Text(m.status.reason)
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    .opacity(0.85)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(loadFillColors[m.status.level].opacity(0.16)))
            .foregroundStyle(loadColors[m.status.level])
        }
    }

    // MARK: cpu

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHead(title: "CPU", value: "\(Int(m.s.cpu))%", color: loadColor(m.s.cpu), big: true)
            Bar(v: m.s.cpu / 100, color: loadFill(m.s.cpu), height: 7)
            cores
            Facts(clusterFacts, keyWidth: 26)
            Facts(thermalFacts + pressureFacts)
            chart
        }
    }

    /// E/P/S split from IOReport, with the core counts sysctl reports per tier.
    private var clusterFacts: [Facts.Item] {
        let io = m.s.io
        var f = [Facts.Item("E \(m.clusters.e)×", "\(Int(io.eClusterActive))%  \(freqText(io.eClusterFreqMHz))"),
                 Facts.Item("P \(m.clusters.p)×", "\(Int(io.pClusterActive))%  \(freqText(io.pClusterFreqMHz))")]
        if io.sClusterFreqMHz > 0 {     // M5+ only
            f.append(.init("S", "\(Int(io.sClusterActive))%  \(freqText(io.sClusterFreqMHz))"))
        }
        return f
    }

    private var thermalFacts: [Facts.Item] {
        let io = m.s.io
        var f: [Facts.Item] = []
        if io.cpuTemp > 0 { f.append(.init("temp", String(format: "%.0f °C", io.cpuTemp))) }
        if io.cpuDieHotspot > 0 { f.append(.init("hotspot", String(format: "%.0f °C", io.cpuDieHotspot))) }
        // CPU watts are already the first entry under POWER RAILS; no need twice
        return f
    }

    /// macOS thermal *pressure*, not a temperature: it says whether the system is
    /// asking apps to back off. It can read "nominal" with the die at 100 °C, so it
    /// sits next to the real temps rather than alone in a headline badge.
    private var pressureFacts: [Facts.Item] {
        [.init("pressure", m.s.thermal,
               m.hot ? loadColors[2] : (m.s.thermal == "fair" ? loadColors[1] : nil))]
    }

    /// one vertical bar per logical core
    private var cores: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(m.s.cores.enumerated()), id: \.offset) { _, c in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(loadFill(c)).frame(height: max(2, 20 * c / 100))
                }
                .frame(height: 20)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Chart {
                // the plot always spans the full width, so a freshly-opened panel
                // shows a real line instead of a mostly-empty box
                ForEach(Array(m.history.enumerated()), id: \.offset) { i, h in
                    let x = i
                    AreaMark(x: .value("t", x), y: .value("%", h.cpu), series: .value("s", "CPU"))
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.45), .accentColor.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", x), y: .value("%", h.cpu), series: .value("s", "CPU"))
                        .foregroundStyle(Color.accentColor)
                    LineMark(x: .value("t", x), y: .value("%", h.ram), series: .value("s", "RAM"))
                        .foregroundStyle(.orange)
                        .lineStyle(.init(lineWidth: 1, dash: [3, 2]))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: 0...Double(max(1, m.history.count - 1)))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)

            // legend by colour instead of by glyph: the ▬ / ▭ pair read as noise
            HStack(spacing: 4) {
                Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                Text("CPU")
                Circle().fill(.orange).frame(width: 4, height: 4)
                Text("RAM")
                Spacer()
                // the window only reaches 2 min once 60 samples are in
                Text(m.history.count >= 60 ? "last 2 min" : "last \(m.history.count * 2)s")
            }
            .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    // MARK: gpu / fan

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHead(title: "GPU", value: "\(Int(m.s.io.gpuUsage))%", color: loadColor(m.s.io.gpuUsage))
            Bar(v: m.s.io.gpuUsage / 100, color: loadFill(m.s.io.gpuUsage))
            Facts(gpuFacts)
        }
    }

    private var gpuFacts: [Facts.Item] {
        let io = m.s.io
        var f = [Facts.Item("freq", freqText(io.gpuFreqMHz))]
        if io.gpuTemp > 0 { f.append(.init("temp", String(format: "%.0f °C", io.gpuTemp))) }
        f.append(.init("power", String(format: "%.2f W", io.gpuPower)))
        return f
    }

    private var fanSection: some View {
        SectionHead(title: "FAN", value: "\(m.s.io.fanRPM) RPM")
    }

    // MARK: memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHead(title: "MEMORY",
                        value: String(format: "%.1f / %.0f GB", m.s.ramUsed, m.s.ramTotal),
                        color: loadColor(m.s.ramPercent))
            Bar(v: m.s.ramPercent / 100, color: loadFill(m.s.ramPercent))
            Facts([.init("read", rateText(m.s.dram.read)),
                   .init("write", rateText(m.s.dram.write)),
                   // heavy swap is the usual cause of a slow Mac, so it stays loud
                   .init("swap", String(format: "%.1f GB", m.s.swapUsed),
                         m.s.swapUsed > 2 ? loadColors[1] : nil)])
        }
    }

    // MARK: battery

    private func batterySection(_ b: Battery) -> some View {
        let low = b.percent < 20 && !b.plugged
        return VStack(alignment: .leading, spacing: 5) {
            SectionHead(title: "BATTERY", value: String(format: "%.0f%%", b.percent),
                        color: low ? loadColors[2] : .primary)
            Bar(v: b.percent / 100,
                color: b.charging ? loadFillColors[0] : (low ? loadFillColors[2] : .accentColor))
            Facts(batteryFacts(b))
            Facts([.init("cycles", "\(b.cycles)"),
                   .init("health", String(format: "%.0f%%", b.health)),
                   .init("temp", String(format: "%.0f °C", b.tempC))])
        }
    }

    private func batteryFacts(_ b: Battery) -> [Facts.Item] {
        var f = [Facts.Item("state", b.charging ? "charging" : (b.plugged ? "plugged" : "battery"))]
        if b.watts != 0 { f.append(.init("rate", String(format: "%+.1f W", b.watts))) }
        if b.adapterWatts > 0 { f.append(.init("adapter", String(format: "%.0f W", b.adapterWatts))) }
        return f
    }

    // MARK: network + disk

    /// Side-by-side sparklines. Throughput is a shape over time, not a number:
    /// the ragged "down 2.5 MB/s   up 67 KB/s" rows told you nothing about whether
    /// a transfer was ramping or already done.
    private var ioSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Spark(title: "NETWORK",
                  inn: ("down", m.ioHistory.map(\.nd), .accentColor),
                  out: ("up", m.ioHistory.map(\.nu), .orange))
            Spark(title: "DISK I/O",
                  inn: ("read", m.ioHistory.map(\.dr), .accentColor),
                  out: ("write", m.ioHistory.map(\.dw), .orange))
        }
    }

    // MARK: power rails

    private var powerSection: some View {
        // M2+ exposes up to five rails; chunking keeps every row three columns wide
        let rows = stride(from: 0, to: railFacts.count, by: 3).map {
            Array(railFacts[$0..<min($0 + 3, railFacts.count)])
        }
        return VStack(alignment: .leading, spacing: 5) {
            SectionHead(title: "POWER RAILS", value: String(format: "%.2f W", m.s.totalWatts))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Facts(row) }
        }
    }

    /// Rails a chip doesn't expose read exactly 0 (M1 has no DRAM/PSTR reading),
    /// so they are dropped instead of printed as a fake 0.00 W.
    private var railFacts: [Facts.Item] {
        let io = m.s.io
        let rails = [("CPU", io.cpuPower), ("GPU", io.gpuPower), ("ANE", io.anePower),
                     ("DRAM", io.dramPower), ("SYS", io.systemPower)]
        return rails.filter { $0.0 == "ANE" || $0.1 > 0 }
            .map { Facts.Item($0.0, String(format: "%.2f W", $0.1)) }
    }

    // MARK: processes

    // one set of widths for both the header and the rows, so the columns line up
    private let procW: CGFloat = 46, cpuW: CGFloat = 52, memW: CGFloat = 58, quitW: CGFloat = 20

    private var appSection: some View {
        let shown = Array(sortedApps.prefix(8))
        // the sorted column sets the bar scale, so the bar always shows the ranking
        // you asked for; its colour still reads CPU heat regardless of sort
        let top = max(shown.map(sortValue).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                SectionLabel(text: "TOP APPS").frame(maxWidth: .infinity, alignment: .leading)
                sortHead("PROC", .proc, procW)
                sortHead("CPU", .cpu, cpuW)
                sortHead("MEM", .mem, memW)
                Spacer().frame(width: quitW)     // the quit-button column
            }
            .padding(.horizontal, 4)

            ForEach(shown) { a in
                HStack(spacing: 0) {
                    Text(a.id).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(a.procs)").frame(width: procW, alignment: .trailing).foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", a.cpu)).frame(width: cpuW, alignment: .trailing)
                        .foregroundStyle(loadColor(a.cpu))
                    Text(memText(a.memMB)).frame(width: memW, alignment: .trailing).foregroundStyle(.secondary)
                    quitButton(a)
                }
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(alignment: .leading) {
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(loadFillColors[loadLevel(a.cpu)].opacity(0.17))
                            .frame(width: g.size.width * sortValue(a) / top)
                    }
                }
            }
        }
    }

    private var sortedApps: [AppUsage] {
        switch sort {
        case .proc: return m.s.apps.sorted { $0.procs > $1.procs }
        case .cpu:  return m.s.apps.sorted { $0.cpu > $1.cpu }
        case .mem:  return m.s.apps.sorted { $0.memMB > $1.memMB }
        case nil:   return m.s.apps            // free — natural cpu order
        }
    }

    private func sortValue(_ a: AppUsage) -> Double {
        switch sort {
        case .proc:     return Double(a.procs)
        case .mem:      return a.memMB
        case .cpu, nil: return a.cpu
        }
    }

    /// A clickable column header. Tapping it locks the sort to that column and
    /// shows a ▾; tapping the locked column again frees it. Trailing-aligned over
    /// the values under it, same dim look as the other section labels.
    private func sortHead(_ text: String, _ key: AppSort, _ width: CGFloat) -> some View {
        Button { sort = (sort == key) ? nil : key } label: {
            HStack(spacing: 2) {
                Text(text).lineLimit(1).fixedSize()
                // always reserve the arrow's slot, only toggle its visibility, so
                // locking a column doesn't nudge the header widths
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(sort == key ? 1 : 0)
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    /// terminate() is the graceful quit — the app still gets to prompt about
    /// unsaved work. Nothing is force-killed from here.
    private func quitButton(_ a: AppUsage) -> some View {
        // resolving the pids is deferred to the click; drawing only reads a flag
        Button {
            quittable(a.quitTargets).forEach { $0.terminate() }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(a.quitTargets.isEmpty ? .clear : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(a.quitTargets.isEmpty)
        .help(a.quitTargets.isEmpty ? "" : "Quit \(a.id)")
        .frame(width: 20)
    }

    // MARK: optimize + footer

    private var optimizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "OPTIMIZE")
            HStack {
                Button("Purge disk cache") { purgeDiskCache() }
                Button("Quit heavy apps") { quitHeavyApps(m.s.apps) }
                    .disabled(heavyApps(m.s.apps).isEmpty)
            }
            .font(.caption)
            Divider()
            HStack {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
            .font(.caption)
        }
    }
}

// MARK: - optimize actions

/// Apps worth offering to quit: windowed, and burning at least half a core.
func heavyApps(_ apps: [AppUsage]) -> [NSRunningApplication] {
    quittable(apps.filter { $0.cpu >= 50 }.flatMap(\.quitTargets))
}

/// Quitting loses unsaved work in the general case, so this always asks first
/// and names every app it is about to close.
@MainActor func quitHeavyApps(_ apps: [AppUsage]) {
    let targets = heavyApps(apps)
    guard !targets.isEmpty else { return }
    let names = targets.compactMap(\.localizedName).joined(separator: ", ")
    let alert = NSAlert()
    alert.messageText = "Quit \(targets.count) app\(targets.count == 1 ? "" : "s")?"
    alert.informativeText = "\(names)\n\nEach app is asked to quit normally and can still prompt to save."
    alert.addButton(withTitle: "Quit Apps")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    targets.forEach { $0.terminate() }
}

/// `purge` is root-only, so this goes through the standard macOS auth prompt.
/// ponytail: osascript instead of a privileged helper — a helper tool is a whole
/// install/codesign story for one button.
func purgeDiskCache() {
    DispatchQueue.global(qos: .userInitiated).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - app

/// Coloured dot for the menu bar. Symbols there render as templates (monochrome)
/// unless the NSImage carries its own palette and opts out of template mode.
func dotImage(_ color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: 7, weight: .black)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "load")?
        .withSymbolConfiguration(cfg) else { return nil }
    img.isTemplate = false
    return img
}

/// NSStatusItem rather than SwiftUI's MenuBarExtra for two reasons: MenuBarExtra
/// builds its panel on the click that opens it, and SwiftUI's first render of this
/// view tree costs ~400 ms (measured — see --bench), so every first open felt
/// frozen. Owning the popover lets us build and warm the panel at launch. It also
/// makes the button's right-click reachable, which MenuBarExtra never exposes.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let m = Monitor()
    private var item: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.target = self
        item.button?.action = #selector(clicked)

        let host = NSHostingController(rootView: Panel(m: m))
        host.view.layoutSubtreeIfNeeded()          // pay the ~400 ms now, not on first click
        host.preferredContentSize = NSSize(width: 360, height: min(700, host.view.fittingSize.height))
        popover.behavior = .transient
        popover.contentViewController = host

        m.onUpdate = { [weak self] in self?.updateLabel() }
        updateLabel()
    }

    private func updateLabel() {
        item.button?.image = dotImage([.systemGreen, .systemYellow, .systemRed][m.level])
        item.button?.attributedTitle = menuBarTitle()
    }

    /// Numbers in monospaced digits so the item keeps a fixed width instead of
    /// nudging its neighbours every 2 seconds as digits change width.
    ///
    /// Everything uses labelColor. secondaryLabelColor is meant for content
    /// inside a window; in the menu bar it resolves to a washed-out grey with
    /// poor contrast, so the labels are set apart by size and weight instead of
    /// by colour.
    private func menuBarTitle() -> NSAttributedString {
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let out = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont) {
            out.append(NSAttributedString(string: text,
                                          attributes: [.font: font,
                                                       .foregroundColor: NSColor.labelColor]))
        }
        add(" CPU ", labelFont)
        add(String(format: "%3d%%", Int(m.s.cpu)), valueFont)
        add("  RAM ", labelFont)
        add(String(format: "%3d%%", Int(m.s.ramPercent)), valueFont)
        return out
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { togglePanel() }
    }

    private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let b = item.button {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
            .target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Bubo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // attaching the menu makes the next click show it; detaching restores left-click
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    /// SMAppService registers the login item with the OS — it shows up under
    /// System Settings › General › Login Items, and the user can revoke it there.
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            // most often: the app is still on the DMG / in Downloads, not installed
            let a = NSAlert()
            a.messageText = "Couldn't change the login item"
            a.informativeText = "Move Bubo to your Applications folder first, then try again."
            a.runModal()
        }
    }
}

@main
enum Bubo {
    static func main() {
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
            if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
                snapshot(to: CommandLine.arguments[i + 1],
                         dark: CommandLine.arguments.contains("--dark")); exit(0)
            }
            if CommandLine.arguments.contains("--bench") { bench(); exit(0) }
            if let i = CommandLine.arguments.firstIndex(of: "--icon") {
                renderIcons(to: CommandLine.arguments[i + 1]); exit(0)
            }

            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

/// Render the panel straight to a PNG. `screencapture` of the real popover needs
/// Screen Recording + Accessibility grants; ImageRenderer needs neither.
@MainActor func snapshot(to path: String, dark: Bool = false) {
    NSApplication.shared.setActivationPolicy(.accessory)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    NSApplication.shared.appearance = appearance
    let m = Monitor()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 12))   // ~6 ticks, enough for a chart

    var png: Data?
    // the adaptive load colours resolve against the *drawing* appearance, so the
    // render has to happen inside it or dark mode comes out with light-mode colours
    appearance.performAsCurrentDrawingAppearance {
        // explicit background: windowBackgroundColor resolves against the app
        // appearance, not the renderer's, and came out white behind dark-mode text
        let r = ImageRenderer(content: PanelContent(m: m, initialSort: .cpu)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : .white))
        r.scale = 2
        if let tiff = r.nsImage?.tiffRepresentation {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
    }
    guard let png else { print("snapshot failed"); exit(1) }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

/// What opening the popover actually costs. Renders each piece in isolation so a
/// slow panel points at a specific view instead of a guess.
@MainActor func bench() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let m = Monitor()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 6))   // let history fill

    func time(_ name: String, _ make: @escaping @autoclosure () -> AnyView) {
        for i in 0..<3 {
            let t = Date()
            let r = ImageRenderer(content: make())
            _ = r.nsImage
            print(String(format: "  %-12s render %d: %6.1f ms", (name as NSString).utf8String!,
                         i, Date().timeIntervalSince(t) * 1000))
        }
    }
    let panel = PanelContent(m: m)
    time("full panel", AnyView(panel))
    time("chart", AnyView(panel.benchChart))
    time("app rows", AnyView(panel.benchApps))
    time("cpu section", AnyView(panel.benchCPU))
}

func selfTest() {
    precondition(cpuPercent((100, 200), (150, 300)) == 50, "half the delta busy → 50%")
    precondition(cpuPercent((100, 200), (100, 200)) == 0, "no tick movement → 0, not NaN")
    precondition(cpuPercent((100, 200), (100, 300)) == 0, "idle-only delta → 0%")
    precondition(cpuTicks() != nil, "host_statistics reachable")

    let cores = coreTicks()
    precondition(cores.count == ProcessInfo.processInfo.processorCount, "one entry per logical core")
    precondition(cores.allSatisfy { $0.total >= $0.busy && $0.busy > 0 }, "per-core counters sane")
    let (p, e) = clusterSizes()
    precondition(p + e == 0 || p + e == cores.count, "cluster sizes add up to the core count")

    precondition(loadLevel(0) == 0 && loadLevel(49.9) == 0, "under 50 is clear")
    precondition(loadLevel(50) == 1 && loadLevel(79.9) == 1, "50–80 is moderate")
    precondition(loadLevel(80) == 2 && loadLevel(999) == 2, "80+ is heavy, no upper clamp needed")
    precondition(dotImage(.systemRed) != nil, "menu bar dot renders")
    precondition(!chipName().isEmpty, "chip name readable")
    precondition(freqText(712) == "712 MHz" && freqText(3204) == "3.2 GHz", "freq scales at 1 GHz")

    precondition(rateText(0) == "0 B/s", "zero rate")
    precondition(rateText(1536) == "1.5 KB/s", "scales to KB")
    precondition(rateText(5_368_709_120) == "5.0 GB/s", "scales to GB")
    precondition(memText(512) == "512 MB" && memText(2048) == "2.0 GB", "mem scales at 1 GB")

    let ram = memoryUsedGB()
    precondition(ram > 0.1 && ram < 1024, "ram used sane: \(ram) GB")
    precondition(swapUsedGB() >= 0, "swap non-negative")

    let net = networkCounters(), disk = diskCounters()
    precondition(net.read > 0 && net.write > 0, "network counters move")
    precondition(disk.read > 0 && disk.write > 0, "disk counters move")
    let flat = rate(net, net, seconds: 2)
    precondition(flat.read == 0 && flat.write == 0, "identical snapshots → zero rate")
    precondition(rate(net, Counters(), seconds: 2).read == 0, "counter reset clamps to 0, not negative")

    // two IOReport calls: the first primes the subscription, the second is a real delta
    let smc = SMCOpen()
    _ = IOReportWrapper.fetchIOReportData(withSMC: smc)
    usleep(400_000)
    let io = IOReportWrapper.fetchIOReportData(withSMC: smc)
    precondition(io.cpuPower > 0, "CPU power reads non-zero")
    precondition(io.eClusterFreqMHz > 0 && io.pClusterFreqMHz > 0, "cluster frequencies read")
    precondition(io.cpuDieHotspot > 0 && io.cpuDieHotspot < 130, "die hotspot sane: \(io.cpuDieHotspot)")
    precondition(io.dramReadBytes > 0, "DRAM bandwidth counters move")

    let apps = appUsage()
    precondition(apps.count > 5, "ps grouped into apps")
    precondition(apps[0].cpu >= apps[1].cpu, "sorted by cpu desc")
    precondition(apps.allSatisfy { $0.procs >= 1 && $0.memMB >= 0 }, "every row has >=1 proc")
    precondition(apps.allSatisfy { $0.pids.count == $0.procs }, "one pid captured per process")
    precondition(quittable([]).isEmpty, "no pids → nothing to quit")
    precondition(quittable([getpid()]).isEmpty, "Bubo is LSUIElement, so not its own quit target")

    let tagged = MainActor.assumeIsolated { annotateQuitTargets(apps) }
    precondition(tagged.allSatisfy { a in a.quitTargets.allSatisfy(a.pids.contains) },
                 "quit targets are always a subset of the row's own pids")
    precondition(tagged.contains { !$0.quitTargets.isEmpty }, "some windowed app is quittable")
    precondition(heavyApps(tagged).allSatisfy { $0.activationPolicy == .regular }, "only windowed apps get quit")

    if let b = battery() {
        precondition(b.percent >= 0 && b.percent <= 100, "charge % in range: \(b.percent)")
        precondition(b.health > 0 && b.health <= 110, "health sane: \(b.health)")
        precondition(b.tempC > 0 && b.tempC < 80, "cell temp sane: \(b.tempC)")
        print(String(format: "  battery %.0f%% · %.0f%% health · %d cycles · %.1f °C · %+.1f W",
                     b.percent, b.health, b.cycles, b.tempC, b.watts))
    } else {
        print("  battery: none (desktop)")
    }

    print("selftest OK — \(chipName()) \(cores.count) cores (\(p)P/\(e)E), ram=\(String(format: "%.1f", ram))GB apps=\(apps.count)")
    print(String(format: "  cpu %.2f W %.0f°C hotspot %.0f°C · gpu %.0f%% @%dMHz %.2f W · fan %d RPM",
                 io.cpuPower, io.cpuTemp, io.cpuDieHotspot, io.gpuUsage, io.gpuFreqMHz, io.gpuPower, io.fanRPM))
    print("  net \(rateText(net.read)) cumulative · dram R \(rateText(Double(io.dramReadBytes) / 0.4))")
    for a in apps.prefix(5) { print(String(format: "  %-24s %2d proc  %5.1f%%  %6.0f MB", (a.id as NSString).utf8String!, a.procs, a.cpu, a.memMB)) }
    SMCClose(smc)
}
