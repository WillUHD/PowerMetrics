import SwiftUI
import AppKit
import Combine

// MARK: - Safe Sendable UI Models

enum SeriesType: Sendable {
    case pkg, cpu, gpu, ane, dram, clusterS, clusterP, clusterE
}

struct ChartPoint: Identifiable, Sendable {
    let id: Int
    let x: Int
    let y: Double
    let yMin: Double?
    let yMax: Double?
}

struct UIChartSeries: Identifiable, Sendable {
    let id: String
    let name: String
    let seriesType: SeriesType
    let points: [ChartPoint]
    let cur: Double
    let minCur: Double?
    let maxCur: Double?
    let yDomain: ClosedRange<Double>
    let mainTicks: [Double]
    let subTicks: [Double]
    let hasFractionalValue: Bool
}

struct PresentationSnapshot: Sendable {
    let snap: HardwareSnapshot
    let powerSeries: [UIChartSeries]
    let freqSeries: [UIChartSeries]
    let tempSeries: [UIChartSeries]
    let utilSeries: [UIChartSeries]
}

// MARK: - State Management & History Buffer

@MainActor
final class MonitorState: ObservableObject {
    static let shared = MonitorState()
    
    @Published var presentation: PresentationSnapshot?
    @Published var errorMessage: String?
    
    private let runner = BackgroundMonitorRunner()
    private var isPolling = false
    private var cancellables = Set<AnyCancellable>()
    
    private var lastInterval: Double = 1.0
    private var lastCapacity: Int = 180
    
    @AppStorage("updateInterval") private var updateInterval: Double = 1.0
    @AppStorage("chartCapacity") private var chartCapacity: Int = 180
    @AppStorage("isPinned") var isPinned: Bool = false {
        didSet {
            updatePinning()
        }
    }

    var isMonitoring: Bool { isPolling }

    init() {
        let initialInterval = UserDefaults.standard.double(forKey: "updateInterval")
        let initialCapacity = UserDefaults.standard.integer(forKey: "chartCapacity")
        lastInterval = initialInterval == 0 ? 1.0 : initialInterval
        lastCapacity = initialCapacity == 0 ? 180 : initialCapacity
        
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let currentInterval = UserDefaults.standard.double(forKey: "updateInterval")
                let currentCapacity = UserDefaults.standard.integer(forKey: "chartCapacity")
                
                let actualInterval = currentInterval == 0 ? 1.0 : currentInterval
                let actualCapacity = currentCapacity == 0 ? 180 : currentCapacity
                
                if actualInterval != self.lastInterval {
                    self.lastInterval = actualInterval
                    if self.isPolling {
                        self.stopPolling()
                        self.start()
                    }
                }
                
                if actualCapacity != self.lastCapacity {
                    self.lastCapacity = actualCapacity
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        errorMessage = nil
        if !isPolling {
            isPolling = true
            
            let interval = max(0.25, min(5.0, lastInterval))
            let capacity = lastCapacity
            
            Task {
                await runner.start(interval: interval, capacity: capacity) { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self = self, self.isPolling else { return }
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            self.presentation = snapshot
                        }
                    }
                }
            }
        }
    }

    func stopPolling() {
        guard isPolling else { return }
        isPolling = false
        Task {
            await runner.stop()
        }
    }
    
    func updatePinning(window: NSWindow? = nil) {
        guard let win = window ?? NSApp.windows.first else { return }
        if isPinned {
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .managed]
        } else {
            win.level = .normal
            win.collectionBehavior = [.managed, .participatesInCycle]
        }
    }
}

// MARK: - Main UI View

struct ContentView: View {
    @StateObject private var state = MonitorState.shared
    @AppStorage("chartCapacity") private var chartCapacity: Int = 180
    @Environment(\.colorScheme) private var colorScheme

    private var appBackground: Color {
        colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.9)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let p = state.presentation, p.snap.valid {
                GeometryReader { outerGeo in
                    let spacing: CGFloat = 12
                    let padding: CGFloat = 12
                    let overhead = (padding * 2) + (spacing * 3)
                    let usableHeight = max(200, outerGeo.size.height - overhead)
                    
                    let unit = usableHeight / 3.6
                    let majorHeight = unit * 1.0
                    let minorHeight = unit * 0.8
                    
                    VStack(spacing: spacing) {
                        CorePlotView(title: "Power", unit: "WATTS", series: p.powerSeries, capacity: chartCapacity)
                            .frame(height: majorHeight)
                        CorePlotView(title: "Frequency", unit: "GHZ", series: p.freqSeries, capacity: chartCapacity, shadeRanges: [("S", "S"), ("P", "P"), ("E", "E")])
                            .frame(height: majorHeight)
                        CorePlotView(title: "Temperature", unit: "°C", series: p.tempSeries, capacity: chartCapacity, shadeRanges: [("CPU_AVG", "CPU_AVG")])
                            .frame(height: minorHeight)
                        CorePlotView(title: "Utilization", unit: "%", series: p.utilSeries, capacity: chartCapacity)
                            .frame(height: minorHeight)
                    }
                    .frame(width: max(100, outerGeo.size.width - padding * 2), height: max(100, outerGeo.size.height - padding * 2))
                    .padding(padding)
                }
                .frame(maxHeight: .infinity)
            } else if let err = state.errorMessage {
                errorView(err)
            } else {
                loadingView()
            }
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 580)
        .background(appBackground)
        .background(WindowDraggableView())
        .background(ThermalDotRepresentable(
            color: state.isMonitoring ? thermalColor : .clear,
            tooltip: thermalHelp,
            isPinned: state.isPinned
        ))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willHideNotification)) { _ in
            state.stopPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            state.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            state.stopPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            state.start()
        }
        .onAppear { state.start() }
        .onDisappear { state.stopPolling() }
    }
    
    private var thermalColor: Color {
        guard let p = state.presentation else { return .clear }
        switch p.snap.thermalPressure {
        case "Nominal": return .green
        case "Light": return .yellow
        case "Moderate": return .orange
        case "Critical": return .red
        default: return .clear
        }
    }

    private var thermalHelp: String {
        guard let p = state.presentation else { return "Thermal: no data" }
        var parts: [String] = [p.snap.thermalPressure]
        if let cpu = p.snap.thermal.cpuTemp { parts.append(String(format: "CPU %.0f\u{00B0}", cpu)) }
        if let gpu = p.snap.thermal.gpuTemp { parts.append(String(format: "GPU %.0f\u{00B0}", gpu)) }
        return "Thermal Status: \(parts.joined(separator: " \u{00B7} "))"
    }
    
    private func errorView(_ err: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.orange)
            Text(err).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func loadingView() -> some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(0.8)
            Text("Analyzing SoC Layout...").font(.title3).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AppKit Drawing View Bridging

struct CorePlotView: View {
    let title: String
    let unit: String
    let series: [UIChartSeries]
    let capacity: Int
    var shadeRanges: [(maxId: String, minId: String)] = []
    
    @Environment(\.colorScheme) private var colorScheme
    
    private var chartBackground: Color {
        colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom) {
                Text(title).font(.system(size: 14, weight: .regular)).foregroundStyle(.secondary)
                Spacer()
                Text(unit).font(.system(size: 10, weight: .regular)).foregroundStyle(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(series) { s in
                        if !s.name.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .lastTextBaseline, spacing: 0) {
                                    Text(s.name).font(.system(size: 9, weight: .regular)).foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    if let minV = s.minCur, let maxV = s.maxCur {
                                        HStack(spacing: 2) {
                                            Text(String(format: "%.1f", minV)).font(.system(size: 13, weight: .regular)).foregroundStyle(.tertiary)
                                            Text("/").font(.system(size: 13, weight: .regular)).foregroundStyle(.quaternary)
                                            Text(String(format: "%.2f", s.cur)).font(.system(size: 13, weight: .semibold)).tracking(-0.3).foregroundStyle(.primary)
                                            Text("/").font(.system(size: 13, weight: .regular)).foregroundStyle(.quaternary)
                                            Text(String(format: "%.1f", maxV)).font(.system(size: 13, weight: .regular)).foregroundStyle(.tertiary)
                                        }
                                    } else {
                                        Text(String(format: "%.2f", s.cur)).font(.system(size: 13, weight: .semibold)).tracking(-0.3).foregroundStyle(.primary)
                                    }
                                }
                                Rectangle().fill(colorForType(s.seriesType)).frame(height: 2.5)
                            }
                        }
                    }
                }
            }
            
            FastPlotView(
                series: series,
                capacity: capacity,
                shadeRanges: shadeRanges,
                title: title
            )
            .padding(.top, 10)
            .padding(.bottom, 4)
            .padding(.trailing, 2)
        }
        .padding(10)
        .background(chartBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }
    
    private func colorForType(_ type: SeriesType) -> Color {
        switch type {
        case .pkg: return Color(red: 0.0, green: 0.4, blue: 0.8)
        case .cpu: return Color(red: 0.1, green: 0.65, blue: 0.95)
        case .gpu: return Color(red: 0.63, green: 0.82, blue: 0.28)
        case .ane: return Color.orange
        case .dram: return Color(red: 0.95, green: 0.68, blue: 0.08)
        case .clusterS: return Color(red: 0.6, green: 0.3, blue: 0.9)
        case .clusterP: return Color(red: 0.1, green: 0.65, blue: 0.95)
        case .clusterE: return Color(red: 0.0, green: 0.8, blue: 0.8)
        }
    }
}

struct FastPlotView: NSViewRepresentable {
    let series: [UIChartSeries]
    let capacity: Int
    let shadeRanges: [(maxId: String, minId: String)]
    let title: String
    
    func makeNSView(context: Context) -> FastPlotNSView {
        let view = FastPlotNSView()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.series = series
        view.capacity = capacity
        view.shadeRanges = shadeRanges
        view.title = title
        return view
    }
    
    func updateNSView(_ nsView: FastPlotNSView, context: Context) {
        nsView.series = series
        nsView.capacity = capacity
        nsView.shadeRanges = shadeRanges
        nsView.title = title
    }
}

final class FastPlotNSView: NSView {
    var series: [UIChartSeries] = [] {
        didSet { needsDisplay = true }
    }
    var capacity: Int = 180 {
        didSet { needsDisplay = true }
    }
    var shadeRanges: [(maxId: String, minId: String)] = [] {
        didSet { needsDisplay = true }
    }
    var title: String = ""
    
    override var isFlipped: Bool { true }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.needsDisplay = true
    }
    
    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        self.needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        guard series.first != nil else { return }
        
        let font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gridColor = isDark ? NSColor(white: 1.0, alpha: 0.15) : NSColor(white: 0.0, alpha: 0.12)
        let subGridColor = isDark ? NSColor(white: 1.0, alpha: 0.06) : NSColor(white: 0.0, alpha: 0.04)
        let textColor = NSColor.secondaryLabelColor
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        
        // 1. Filter out off-screen values to ensure Y-scaling matches only currently visible data
        let allActiveVals = series.flatMap { s -> [Double] in
            let active = s.points.suffix(capacity)
            return active.map { $0.y } + active.compactMap { $0.yMin } + active.compactMap { $0.yMax }
        }
        
        let yDomain: ClosedRange<Double>
        if title == "Utilization" {
            yDomain = 0.0...100.0
        } else if title == "Temperature" {
            yDomain = Self.calculateYDomain(vals: allActiveVals, fixedMin: nil, fixedMax: 100)
        } else {
            yDomain = Self.calculateYDomain(vals: allActiveVals, fixedMin: 0, fixedMax: nil)
        }
        
        let topMargin: CGFloat = 4
        let bottomMargin: CGFloat = 4
        let plotHeight = size.height - topMargin - bottomMargin
        
        let ticks = Self.generateTicks(domain: yDomain, height: plotHeight)
        let yMin = yDomain.lowerBound
        let yMax = yDomain.upperBound
        let yRange = yMax - yMin > 0 ? (yMax - yMin) : 1.0
        let hasFractionalValue = ticks.main.contains { (($0 * 1000).rounded() / 1000).truncatingRemainder(dividingBy: 1) != 0 }
        
        // 2. Dynamically calculate padding width for each individual chart based on string length of visible axis labels
        var maxLabelWidth: CGFloat = 0
        for val in ticks.main {
            let labelStr = formatAxis(val, hasFractional: hasFractionalValue)
            let textSize = NSAttributedString(string: labelStr, attributes: textAttrs).size()
            maxLabelWidth = max(maxLabelWidth, textSize.width)
        }
        
        let plotLeft = max(8, maxLabelWidth + 3)
        let plotRight = size.width - 2
        _ = plotRight - plotLeft
        
        // 4pt padding gap so active line drawings don't visually merge with axis labels
        let plotDataLeft = plotLeft + 4
        let plotDataWidth = plotRight - plotDataLeft
        
        func toCoords(x: Int, y: Double) -> CGPoint {
            let pctX = CGFloat(x) / CGFloat(capacity)
            let pctY = CGFloat(y - yMin) / CGFloat(yRange)
            let drawX = plotDataLeft + (pctX * plotDataWidth)
            let drawY = topMargin + plotHeight - (pctY * plotHeight)
            return CGPoint(x: drawX, y: drawY)
        }
        
        context.setLineWidth(0.5)
        
        // 3. Draw Axis Ticks & Label Text
        for val in ticks.main {
            let p = toCoords(x: 0, y: val)
            
            context.saveGState()
            context.setStrokeColor(gridColor.cgColor)
            context.setLineDash(phase: 0, lengths: [2, 3])
            context.beginPath()
            context.move(to: CGPoint(x: plotLeft, y: p.y))
            context.addLine(to: CGPoint(x: plotRight, y: p.y))
            context.strokePath()
            context.restoreGState()
            
            let labelStr = formatAxis(val, hasFractional: hasFractionalValue)
            let attributedString = NSAttributedString(string: labelStr, attributes: textAttrs)
            let textSize = attributedString.size()
            let textRect = NSRect(
                x: plotLeft - textSize.width - 2,
                y: p.y - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            attributedString.draw(in: textRect)
        }
        
        for val in ticks.sub {
            let p = toCoords(x: 0, y: val)
            context.saveGState()
            context.setStrokeColor(subGridColor.cgColor)
            context.setLineDash(phase: 0, lengths: [2, 3])
            context.beginPath()
            context.move(to: CGPoint(x: plotLeft, y: p.y))
            context.addLine(to: CGPoint(x: plotRight, y: p.y))
            context.strokePath()
            context.restoreGState()
        }
        
        // 4. Draw Shade Areas
        for s in series {
            let hasBand = shadeRanges.contains { $0.maxId == s.id || (title == "Temperature" && s.id == "CPU_AVG") }
            let points = s.points
            let takeCount = min(capacity, points.count)
            let activePoints = Array(points.suffix(takeCount))
            
            if hasBand && activePoints.count > 1 {
                context.saveGState()
                let path = CGMutablePath()
                let offset = capacity - takeCount
                
                let first = activePoints[0]
                let p0 = toCoords(x: 0 + offset, y: first.yMax ?? first.y)
                path.move(to: p0)
                
                for i in 1..<activePoints.count {
                    let pt = activePoints[i]
                    path.addLine(to: toCoords(x: i + offset, y: pt.yMax ?? pt.y))
                }
                for i in stride(from: activePoints.count - 1, through: 0, by: -1) {
                    let pt = activePoints[i]
                    path.addLine(to: toCoords(x: i + offset, y: pt.yMin ?? pt.y))
                }
                path.closeSubpath()
                context.addPath(path)
                let color = colorForType(s.seriesType).withAlphaComponent(0.12)
                context.setFillColor(color.cgColor)
                context.fillPath()
                context.restoreGState()
            }
        }
        
        // 5. Render Trend Lines (Order: ANE -> DRAM -> GPU -> CORE -> PKG)
        let orderedSeries: [UIChartSeries]
        if title == "Power" {
            let orderMap: [String: Int] = [
                "ANE": 0,
                "DRAM": 1,
                "GPU": 2,
                "CPU": 3,
                "PKG": 4
            ]
            orderedSeries = series.sorted { s1, s2 in
                (orderMap[s1.id] ?? 99) < (orderMap[s2.id] ?? 99)
            }
        } else {
            orderedSeries = series.filter({ $0.id == "GPU" }) + series.filter({ $0.id != "GPU" })
        }
        
        for s in orderedSeries {
            let points = s.points
            let takeCount = min(capacity, points.count)
            let activePoints = Array(points.suffix(takeCount))
            guard activePoints.count > 1 else { continue }
            
            let isMaxLine = s.id.contains("MAX") || s.id == "CPU_MAX"
            let isMinLine = s.id.contains("MIN") || s.id == "CPU_MIN"
            
            let color = colorForType(s.seriesType)
            let strokeColor = isMinLine ? NSColor.clear : (isMaxLine ? color.withAlphaComponent(0.5) : color)
            let strokeWidth = isMaxLine ? CGFloat(1.2) : (isMinLine ? CGFloat(0.0) : CGFloat(1.8))
            
            if !isMinLine && strokeWidth > 0 {
                context.saveGState()
                context.setLineWidth(strokeWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setStrokeColor(strokeColor.cgColor)
                
                context.beginPath()
                let offset = capacity - takeCount
                let p0 = toCoords(x: 0 + offset, y: isMaxLine ? (activePoints[0].yMax ?? activePoints[0].y) : activePoints[0].y)
                context.move(to: p0)
                
                for i in 1..<activePoints.count {
                    let p = toCoords(x: i + offset, y: isMaxLine ? (activePoints[i].yMax ?? activePoints[i].y) : activePoints[i].y)
                    context.addLine(to: p)
                }
                context.strokePath()
                context.restoreGState()
            }
            
            let hasClusterBand = shadeRanges.contains { $0.maxId == s.id }
            if hasClusterBand {
                context.saveGState()
                context.setLineWidth(1.2)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setStrokeColor(color.withAlphaComponent(0.5).cgColor)
                
                context.beginPath()
                var hasStarted = false
                let offset = capacity - takeCount
                for i in 0..<activePoints.count {
                    let pt = activePoints[i]
                    if let yMax = pt.yMax {
                        let pDraw = toCoords(x: i + offset, y: yMax)
                        if !hasStarted {
                            context.move(to: pDraw)
                            hasStarted = true
                        } else {
                            context.addLine(to: pDraw)
                        }
                    }
                }
                if hasStarted {
                    context.strokePath()
                }
                context.restoreGState()
            }
        }
    }
    
    private func colorForType(_ type: SeriesType) -> NSColor {
        switch type {
        case .pkg: return NSColor(red: 0.0, green: 0.4, blue: 0.8, alpha: 1.0)
        case .cpu: return NSColor(red: 0.1, green: 0.65, blue: 0.95, alpha: 1.0)
        case .gpu: return NSColor(red: 0.63, green: 0.82, blue: 0.28, alpha: 1.0)
        case .ane: return NSColor.orange
        case .dram: return NSColor(red: 0.95, green: 0.68, blue: 0.08, alpha: 1.0)
        case .clusterS: return NSColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 1.0)
        case .clusterP: return NSColor(red: 0.1, green: 0.65, blue: 0.95, alpha: 1.0)
        case .clusterE: return NSColor(red: 0.0, green: 0.8, blue: 0.8, alpha: 1.0)
        }
    }
    
    private func formatAxis(_ v: Double, hasFractional: Bool) -> String {
        return hasFractional ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
    
    // Static Y-Axis Scaling & Ticking methods moved directly to drawing logic
    private static func calculateYDomain(vals: [Double], fixedMin: Double?, fixedMax: Double?) -> ClosedRange<Double> {
        let dMin = vals.min() ?? 0
        let dMax = vals.max() ?? 10
        let diff = max(dMax - dMin, 0.1)
        
        let minBound = fixedMin ?? max(0, dMin - diff * 0.01)
        let maxBound: Double
        if let fMax = fixedMax {
            maxBound = dMax > fMax ? dMax + diff * 0.01 : fMax
        } else {
            maxBound = dMax + diff * 0.03
        }
        return minBound...maxBound
    }
    
    private static func generateTicks(domain: ClosedRange<Double>, height: CGFloat) -> (main: [Double], sub: [Double]) {
        let span = domain.upperBound - domain.lowerBound
        let safeSpan = max(span, 0.001)
        let safeTargetStep = safeSpan / Double(max(1, height / 25.0))
        let mag = pow(10.0, floor(log10(safeTargetStep)))
        let base = safeTargetStep / mag
        let step = (base <= 1.5 ? 1 : base <= 3 ? 2 : base <= 7 ? 5 : 10) * mag
        
        let start = floor(domain.lowerBound / step) * step
        var main: [Double] = []
        var sub: [Double] = []
        
        var v = start
        var loopSafetyCount = 0
        while v <= domain.upperBound + (step * 0.1) && loopSafetyCount < 100 {
            if v >= domain.lowerBound && v <= domain.upperBound { main.append(v) }
            let s = v + (step / 2.0)
            if s >= domain.lowerBound && s <= domain.upperBound { sub.append(s) }
            v += step
            loopSafetyCount += 1
        }
        return (main, sub)
    }
}

// MARK: - AppKit Bridges

private struct WindowDraggableView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); DispatchQueue.main.async { view.window?.isMovableByWindowBackground = true }; return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ThermalDotRepresentable: NSViewRepresentable {
    let color: Color
    let tooltip: String
    let isPinned: Bool
    
    func makeNSView(context: Context) -> ThermalDotNSView {
        let v = ThermalDotNSView(frame: .zero)
        v.dot.toolTip = tooltip
        return v
    }
    
    func updateNSView(_ nsView: ThermalDotNSView, context: Context) {
        nsView.dot.layer?.backgroundColor = NSColor(color).cgColor
        nsView.dot.toolTip = tooltip
        nsView.dot.isHidden = (color == .clear)
        nsView.updatePinButtonImage(isPinned: isPinned)
    }
}

private final class ThermalDotNSView: NSView {
    let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    let pinButton = NSButton(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.green.cgColor
        
        pinButton.bezelStyle = .shadowlessSquare
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(pinToggled)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    @objc private func pinToggled() {
        MonitorState.shared.isPinned.toggle()
    }
    
    func updatePinButtonImage(isPinned: Bool) {
        let symbolName = isPinned ? "pin.fill" : "pin"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Pin Window") {
            img.isTemplate = true
            pinButton.image = img
        }
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        DispatchQueue.main.async { [weak self] in self?.addToTitlebar(w) }
    }
    
    private func addToTitlebar(_ window: NSWindow) {
        guard let btn = window.standardWindowButton(.closeButton), let titlebar = btn.superview else { return }
        dot.removeFromSuperview()
        pinButton.removeFromSuperview()
        
        titlebar.addSubview(dot)
        titlebar.addSubview(pinButton)
        
        positionElements(in: titlebar)
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.positionElements(in: titlebar)
        }
    }
    
    private func positionElements(in titlebar: NSView) {
        let b = titlebar.bounds
        dot.frame = NSRect(x: b.width - 24, y: (b.height - 8) / 2, width: 8, height: 8)
        pinButton.frame = NSRect(x: b.width - 48, y: (b.height - 16) / 2, width: 16, height: 16)
    }
}
