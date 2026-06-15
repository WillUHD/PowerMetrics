import SwiftUI
import AppKit
import Combine

// MARK: - Safe Sendable UI Models

enum SeriesType: Sendable {
    case pkg, cpu, gpu, ane, dram, clusterS, clusterP, clusterE
}

struct ChartPoint: Identifiable, Sendable {
    let id: Int // Using Int indices avoids expensive UUID allocations
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
    
    @AppStorage("updateInterval") private var updateInterval: Double = 1.0
    @AppStorage("chartCapacity") private var chartCapacity: Int = 180
    @AppStorage("isPinned") var isPinned: Bool = false {
        didSet {
            updatePinning()
        }
    }

    var isMonitoring: Bool { isPolling }

    func start() {
        errorMessage = nil
        if !isPolling {
            isPolling = true
            
            let interval = max(0.1, min(3.0, updateInterval))
            let capacity = chartCapacity
            
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
                HStack(spacing: 12) {
                    ForEach(series) { s in
                        if !s.name.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .lastTextBaseline, spacing: 0) {
                                    Text(s.name).font(.system(size: 9, weight: .regular)).foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    if let minV = s.minCur, let maxV = s.maxCur {
                                        HStack(spacing: 2) {
                                            Text(String(format: "%.2f", minV)).font(.system(size: 13, weight: .regular)).foregroundStyle(.tertiary)
                                            Text("/").font(.system(size: 13, weight: .regular)).foregroundStyle(.quaternary)
                                            Text(String(format: "%.2f", s.cur)).font(.system(size: 13, weight: .semibold)).tracking(-0.3).foregroundStyle(.primary)
                                            Text("/").font(.system(size: 13, weight: .regular)).foregroundStyle(.quaternary)
                                            Text(String(format: "%.2f", maxV)).font(.system(size: 13, weight: .regular)).foregroundStyle(.tertiary)
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
            
            FastPlotView(series: series, capacity: capacity, shadeRanges: shadeRanges, title: title)
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
        case .dram: return Color.yellow
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
    
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let size = bounds.size
        let labelPadding: CGFloat = 34
        let plotLeft = labelPadding
        let plotWidth = size.width - plotLeft
        let topMargin: CGFloat = 8
        let plotHeight = size.height - topMargin - 8
        
        guard let firstSeries = series.first else { return }
        let yDomain = firstSeries.yDomain
        let yMin = yDomain.lowerBound
        let yMax = yDomain.upperBound
        let yRange = yMax - yMin > 0 ? (yMax - yMin) : 1.0
        
        func toCoords(x: Int, y: Double) -> CGPoint {
            let pctX = CGFloat(x) / CGFloat(capacity)
            let pctY = CGFloat(y - yMin) / CGFloat(yRange)
            let drawX = plotLeft + (pctX * plotWidth)
            let drawY = topMargin + plotHeight - (pctY * plotHeight)
            return CGPoint(x: drawX, y: drawY)
        }
        
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gridColor = isDark ? NSColor(white: 1.0, alpha: 0.15) : NSColor(white: 0.0, alpha: 0.12)
        let subGridColor = isDark ? NSColor(white: 1.0, alpha: 0.06) : NSColor(white: 0.0, alpha: 0.04)
        let textColor = NSColor.secondaryLabelColor
        
        let font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        
        context.setLineWidth(0.5)
        
        // 1. Draw Axis Ticks & Label Text
        for val in firstSeries.mainTicks {
            let p = toCoords(x: 0, y: val)
            
            context.saveGState()
            context.setStrokeColor(gridColor.cgColor)
            context.setLineDash(phase: 0, lengths: [2, 3])
            context.beginPath()
            context.move(to: CGPoint(x: plotLeft, y: p.y))
            context.addLine(to: CGPoint(x: size.width, y: p.y))
            context.strokePath()
            context.restoreGState()
            
            let labelStr = formatAxis(val, hasFractional: firstSeries.hasFractionalValue)
            let attributedString = NSAttributedString(string: labelStr, attributes: textAttrs)
            let textSize = attributedString.size()
            let textRect = NSRect(
                x: plotLeft - textSize.width - 4,
                y: p.y - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            attributedString.draw(in: textRect)
        }
        
        for val in firstSeries.subTicks {
            let p = toCoords(x: 0, y: val)
            context.saveGState()
            context.setStrokeColor(subGridColor.cgColor)
            context.setLineDash(phase: 0, lengths: [2, 3])
            context.beginPath()
            context.move(to: CGPoint(x: plotLeft, y: p.y))
            context.addLine(to: CGPoint(x: size.width, y: p.y))
            context.strokePath()
            context.restoreGState()
        }
        
        // 2. Draw Shade Areas
        for s in series {
            let hasBand = shadeRanges.contains { $0.maxId == s.id || (title == "Temperature" && s.id == "CPU_AVG") }
            if hasBand && s.points.count > 1 {
                context.saveGState()
                let path = CGMutablePath()
                let first = s.points[0]
                let p0 = toCoords(x: first.x, y: first.yMax ?? first.y)
                path.move(to: p0)
                
                for i in 1..<s.points.count {
                    let pt = s.points[i]
                    path.addLine(to: toCoords(x: pt.x, y: pt.yMax ?? pt.y))
                }
                for i in stride(from: s.points.count - 1, through: 0, by: -1) {
                    let pt = s.points[i]
                    path.addLine(to: toCoords(x: pt.x, y: pt.yMin ?? pt.y))
                }
                path.closeSubpath()
                context.addPath(path)
                let color = colorForType(s.seriesType).withAlphaComponent(0.12)
                context.setFillColor(color.cgColor)
                context.fillPath()
                context.restoreGState()
            }
        }
        
        // 3. Render Trend Lines
        let orderedSeries = series.filter({ $0.id == "GPU" }) + series.filter({ $0.id != "GPU" })
        for s in orderedSeries {
            let points = s.points
            guard points.count > 1 else { continue }
            
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
                let p0 = toCoords(x: points[0].x, y: isMaxLine ? (points[0].yMax ?? points[0].y) : points[0].y)
                context.move(to: p0)
                
                for i in 1..<points.count {
                    let p = toCoords(x: points[i].x, y: isMaxLine ? (points[i].yMax ?? points[i].y) : points[i].y)
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
                for pt in points {
                    if let yMax = pt.yMax {
                        let pDraw = toCoords(x: pt.x, y: yMax)
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
        case .dram: return NSColor.yellow
        case .clusterS: return NSColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 1.0)
        case .clusterP: return NSColor(red: 0.1, green: 0.65, blue: 0.95, alpha: 1.0)
        case .clusterE: return NSColor(red: 0.0, green: 0.8, blue: 0.8, alpha: 1.0)
        }
    }
    
    private func formatAxis(_ v: Double, hasFractional: Bool) -> String {
        return hasFractional ? String(format: "%.1f", v) : String(format: "%.0f", v)
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
