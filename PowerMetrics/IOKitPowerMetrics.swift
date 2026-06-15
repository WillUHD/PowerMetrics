import Foundation
import IOKit
import Darwin

// MARK: - IOReport C API

@_silgen_name("IOReportCopyChannelsInGroup")
private func _IOC(_ g: CFString?, _ s: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportMergeChannels")
private func _IOM(_ a: CFMutableDictionary, _ b: CFDictionary, _ n: CFTypeRef?)
@_silgen_name("IOReportCreateSubscription")
private func _IOS(_ a: UnsafeMutableRawPointer?, _ ch: CFMutableDictionary, _ sub: UnsafeMutablePointer<CFMutableDictionary?>, _ id: UInt64, _ n: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamples")
private func _IORD(_ s: Unmanaged<CFDictionary>, _ ch: CFMutableDictionary?, _ n: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func _IOD(_ p: CFDictionary, _ c: CFDictionary, _ n: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportSimpleGetIntegerValue")
private func _IOSG(_ ch: CFDictionary, _ d: Int32) -> Int64
@_silgen_name("IOReportStateGetCount")
private func _IOSC(_ ch: CFDictionary) -> Int32
@_silgen_name("IOReportStateGetResidency")
private func _IOSR(_ ch: CFDictionary, _ i: Int32) -> Int64
@_silgen_name("IOReportStateGetNameForIndex")
private func _IOSN(_ ch: CFDictionary, _ i: Int32) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetChannelName")
private func _IOCN(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetGroup")
private func _IOCG(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetSubGroup")
private func _IOCS(_ ch: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func _IOCL(_ ch: CFDictionary) -> Unmanaged<CFString>?

// MARK: - IOHIDEventSystemClient C API

private typealias HIDClientRef = AnyObject
private typealias HIDServiceRef = AnyObject
private typealias HIDEventRef = AnyObject

@_silgen_name("IOHIDEventSystemClientCreate")
private func _hidCreateClient(_ alloc: CFAllocator?) -> Unmanaged<HIDClientRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func _hidSetMatching(_ client: HIDClientRef, _ match: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func _hidCopyServices(_ client: HIDClientRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func _hidCopyProperty(_ service: HIDServiceRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func _hidCopyEvent(_ service: HIDServiceRef, _ type: Int, _ options: Int, _ timeout: Int64) -> Unmanaged<HIDEventRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func _hidGetFloat(_ event: HIDEventRef, _ field: Int64) -> Double

// MARK: - Core Telemetry Structs

struct ThermalSample: Sendable {
    var cpuTemp: Double?
    var gpuTemp: Double?
    var aneTemp: Double?
    var systemTemp: Double?
    var allSensors: [(key: String, label: String, temp: Double)]
}

struct ClusterInfo: Sendable {
    var name: String
    var freqMHz: Int = 0
    var activeRatio: Double = 0
    var minFreqMHz: Int = 0
    var maxFreqMHz: Int = 0
}

struct PowerSample: Sendable {
    var cpuPower: Double = 0
    var gpuPower: Double = 0
    var anePower: Double = 0
    var dramPower: Double = 0
}

struct FreqSample: Sendable {
    var clusters: [ClusterInfo] = []
    var gpuFreqMHz: Int = 0
}

struct UtilSample: Sendable {
    var clusters: [ClusterInfo] = []
    var gpuActive: Double = 0
}

struct HardwareSnapshot: Sendable {
    var power = PowerSample()
    var freq = FreqSample()
    var util = UtilSample()
    var thermal = ThermalSample(cpuTemp: nil, gpuTemp: nil, aneTemp: nil, systemTemp: nil, allSensors: [])
    var thermalPressure: String = "Nominal"
    var packagePower: Double = 0
    var valid = false
}

// MARK: - Metadata Cache

private final class LockedCache: @unchecked Sendable {
    private var cache: [UInt64: ChannelMetadata] = [:]
    private var lock = os_unfair_lock_s()
    
    func get(_ id: UInt64) -> ChannelMetadata? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return cache[id]
    }
    
    func set(_ id: UInt64, _ meta: ChannelMetadata) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        cache[id] = meta
    }
}

enum ChannelType: Sendable {
    case cpuEnergy
    case gpuEnergy
    case aneEnergy
    case dramEnergy
    case cpuStat
    case gpuStat
    case unknown
}

struct ChannelMetadata: Sendable {
    let id: UInt64
    let name: String
    let group: String
    let type: ChannelType
    let canonicalCluster: String
    let scale: Double
}

enum SensorType: Sendable {
    case cpu
    case gpu
    case ane
    case unknown
}

struct CachedThermalSensor: Sendable {
    let service: AnyObject
    let type: SensorType
    let key: String
    let label: String
}

// MARK: - Telemetry Engine

final class IOKitPowerMetrics: @unchecked Sendable {
    static let shared = IOKitPowerMetrics()
    private init() {}

    private var sub: Unmanaged<CFDictionary>?
    private var channels: CFMutableDictionary?
    private var ready = false
    var isRunning: Bool { return ready }

    private var eFreqs: [Int] = []
    private var pFreqs: [Int] = []
    private var sFreqs: [Int] = []
    private var gFreqs: [Int] = []

    private var isSuperActive = false
    
    private var level1CoreRange: ClosedRange<Int>? = nil
    private var level0CoreRange: ClosedRange<Int>? = nil

    private var lastIOReportSample: CFDictionary?
    private var lastSampleTime: Double = 0
    
    private var hidClient: HIDClientRef?
    
    private var cachedSensors: [CachedThermalSensor] = []
    private var isThermalServiceCached = false
    private let metadataCache = LockedCache()

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func start() -> Bool {
        guard !ready else { return true }
        
        if let level0Name = getSysctlString(name: "hw.perflevel0.name") {
            isSuperActive = level0Name.lowercased().contains("super")
        }
        
        var level0Count = getSysctlInt(name: "hw.perflevel0.physicalcpu")
        var level1Count = getSysctlInt(name: "hw.perflevel1.physicalcpu")
        
        if level0Count == 0 { level0Count = isSuperActive ? 6 : 8 }
        if level1Count == 0 { level1Count = isSuperActive ? 12 : 2 }
        
        level1CoreRange = 0...(level1Count - 1)
        level0CoreRange = level1Count...(level1Count + level0Count - 1)
        
        loadFreqTables()
        discoverThermalServices()
        guard initIOReport() else { return false }
        ready = true
        return true
    }

    func sample() -> HardwareSnapshot {
        guard ready else { return HardwareSnapshot() }
        var snap = HardwareSnapshot()
        
        let machNow = mach_absolute_time()
        let numer = UInt64(Self.timebase.numer)
        let denom = UInt64(Self.timebase.denom)
        let nowSec = Double(machNow * numer / denom) / 1e9
        
        guard let currentSample = takeIOReport() else { return snap }
        
        defer {
            lastIOReportSample = currentSample
            lastSampleTime = nowSec
        }
        
        guard let previousSample = lastIOReportSample, lastSampleTime > 0 else { return snap }
        
        let durNs = (nowSec - lastSampleTime) * 1e9
        guard durNs > 100_000_000, durNs < 10_000_000_000 else { return snap }
        
        guard let delta = _IOD(previousSample, currentSample, nil)?.takeRetainedValue() else { return snap }
        parseDelta(delta, &snap, durNs)
        
        snap.thermal = readTemps()
        snap.thermalPressure = thermalLabel()
        snap.packagePower = snap.power.cpuPower + snap.power.gpuPower + snap.power.anePower + snap.power.dramPower
        snap.valid = true
        return snap
    }

    func stop() {
        sub?.release()
        sub = nil
        channels = nil
        ready = false
        lastIOReportSample = nil
        lastSampleTime = 0
        cachedSensors.removeAll()
        isThermalServiceCached = false
    }

    private func initIOReport() -> Bool {
        guard let eCh = _IOC("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return false }
        let merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(eCh), eCh)!
        if let cpuCh = _IOC("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() { _IOM(merged, cpuCh, nil) }
        if let gpuCh = _IOC("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() { _IOM(merged, gpuCh, nil) }
        var subbed: CFMutableDictionary?
        guard let s = _IOS(nil, merged, &subbed, 0, nil) else { return false }
        sub = s
        channels = subbed
        return true
    }

    private func takeIOReport() -> CFDictionary? {
        guard let s = sub, let ch = channels else { return nil }
        return _IORD(s, ch, nil)?.takeRetainedValue()
    }

    private func getChannelID(_ ch: CFDictionary) -> UInt64 {
        let key = unsafeBitCast("ChannelID" as CFString, to: UnsafeRawPointer.self)
        if let val = CFDictionaryGetValue(ch, key) {
            var id: UInt64 = 0
            CFNumberGetValue(unsafeBitCast(val, to: CFNumber.self), .sInt64Type, &id)
            if id != 0 { return id }
        }
        let name = str(_IOCN(ch))
        let group = str(_IOCG(ch))
        return UInt64(truncatingIfNeeded: (name + group).hashValue)
    }

    private func getChannelMetadata(_ ch: CFDictionary) -> ChannelMetadata {
        let id = getChannelID(ch)
        if let cached = metadataCache.get(id) {
            return cached
        }
        
        let name = str(_IOCN(ch))
        let group = str(_IOCG(ch))
        let unit = str(_IOCL(ch))
        
        var type: ChannelType = .unknown
        var canonicalCluster = ""

        if group == "Energy Model" {
            let lowerName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            if lowerName.hasPrefix("cpu") {
                // CPU needs prefix because it has multiple complexes/clusters
                type = .cpuEnergy
            } else if lowerName == "gpu" {
                // GPU uses exact match to avoid doubling with "GPU Energy"
                type = .gpuEnergy
            } else if lowerName.hasPrefix("ane") {
                type = .aneEnergy
            } else if lowerName.hasPrefix("dram") {
                type = .dramEnergy
            }
        } else if group == "CPU Stats" {
            type = .cpuStat
            canonicalCluster = getCanonicalCluster(name: name, hasSuper: isSuperActive)
        } else if group == "GPU Stats" {
            type = .gpuStat
        }
        
        let scale: Double
        if unit == "mJ" { scale = 1e-3 }
        else if unit == "uJ" { scale = 1e-6 }
        else if unit == "nJ" { scale = 1e-9 }
        else { scale = 1e-3 }
        
        let meta = ChannelMetadata(
            id: id,
            name: name,
            group: group,
            type: type,
            canonicalCluster: canonicalCluster,
            scale: scale
        )
        metadataCache.set(id, meta)
        return meta
    }

    private func parseDelta(_ delta: CFDictionary, _ snap: inout HardwareSnapshot, _ dur: Double) {
        guard dur > 0,
              let raw = CFDictionaryGetValue(delta, Unmanaged.passUnretained("IOReportChannels" as CFTypeRef).toOpaque()) else { return }
        let arr = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        let count = CFArrayGetCount(arr)

        var sFreqsCount = 0, sFreqsSum = 0, sFreqsMin = Int.max, sFreqsMax = Int.min, sUtilsSum = 0.0, sUtilsCount = 0
        var pFreqsCount = 0, pFreqsSum = 0, pFreqsMin = Int.max, pFreqsMax = Int.min, pUtilsSum = 0.0, pUtilsCount = 0
        var eFreqsCount = 0, eFreqsSum = 0, eFreqsMin = Int.max, eFreqsMax = Int.min, eUtilsSum = 0.0, eUtilsCount = 0
        
        var gpuActive: Double = 0
        var gpuFreq: Int = 0
        
        var cpuPowerSum = 0.0
        var gpuPowerSum = 0.0
        var anePowerSum = 0.0
        var dramPowerSum = 0.0
        
        let durSecs = dur / 1e9

        for i in 0..<count {
            guard let elem = CFArrayGetValueAtIndex(arr, i) else { continue }
            let ch = Unmanaged<CFDictionary>.fromOpaque(elem).takeUnretainedValue()
            let meta = getChannelMetadata(ch)
            
            switch meta.type {
            case .cpuEnergy:
                cpuPowerSum += (Double(_IOSG(ch, 0)) * meta.scale) / durSecs
            case .gpuEnergy:
                gpuPowerSum += (Double(_IOSG(ch, 0)) * meta.scale) / durSecs
            case .aneEnergy:
                anePowerSum += (Double(_IOSG(ch, 0)) * meta.scale) / durSecs
            case .dramEnergy:
                dramPowerSum += (Double(_IOSG(ch, 0)) * meta.scale) / durSecs
            case .cpuStat:
                let n = Int(_IOSC(ch))
                let table: [Int]
                if meta.canonicalCluster == "S" { table = sFreqs }
                else if meta.canonicalCluster == "P" { table = pFreqs }
                else { table = eFreqs }
                
                let freq = cpuFreqFromState(ch, n, table)
                let util = cpuUtilization(ch, n)
                
                if meta.canonicalCluster == "S" {
                    if freq > 0 {
                        sFreqsCount += 1
                        sFreqsSum += freq
                        sFreqsMin = min(sFreqsMin, freq)
                        sFreqsMax = max(sFreqsMax, freq)
                    }
                    sUtilsCount += 1
                    sUtilsSum += util
                } else if meta.canonicalCluster == "P" {
                    if freq > 0 {
                        pFreqsCount += 1
                        pFreqsSum += freq
                        pFreqsMin = min(pFreqsMin, freq)
                        pFreqsMax = max(pFreqsMax, freq)
                    }
                    pUtilsCount += 1
                    pUtilsSum += util
                } else if meta.canonicalCluster == "E" {
                    if freq > 0 {
                        eFreqsCount += 1
                        eFreqsSum += freq
                        eFreqsMin = min(eFreqsMin, freq)
                        eFreqsMax = max(eFreqsMax, freq)
                    }
                    eUtilsCount += 1
                    eUtilsSum += util
                }
            case .gpuStat:
                let n = Int(_IOSC(ch))
                if n > 0 {
                    gpuActive = cpuUtilization(ch, n)
                    gpuFreq = gpuFreqFromState(ch, n)
                }
            case .unknown:
                break
            }
        }

        snap.power.cpuPower = cpuPowerSum
        snap.power.gpuPower = gpuPowerSum
        snap.power.anePower = anePowerSum
        snap.power.dramPower = dramPowerSum
        
        snap.util.gpuActive = gpuActive
        snap.freq.gpuFreqMHz = gpuFreq

        if sUtilsCount > 0 {
            let avgF = sFreqsCount > 0 ? sFreqsSum / sFreqsCount : 0
            let avgU = sUtilsSum / Double(sUtilsCount)
            snap.freq.clusters.append(ClusterInfo(name: "S", freqMHz: avgF, activeRatio: avgU, minFreqMHz: sFreqsMin != Int.max ? sFreqsMin : 0, maxFreqMHz: sFreqsMax != Int.min ? sFreqsMax : 0))
            snap.util.clusters.append(ClusterInfo(name: "S", activeRatio: avgU))
        }
        if pUtilsCount > 0 {
            let avgF = pFreqsCount > 0 ? pFreqsSum / pFreqsCount : 0
            let avgU = pUtilsSum / Double(pUtilsCount)
            snap.freq.clusters.append(ClusterInfo(name: "P", freqMHz: avgF, activeRatio: avgU, minFreqMHz: pFreqsMin != Int.max ? pFreqsMin : 0, maxFreqMHz: pFreqsMax != Int.min ? pFreqsMax : 0))
            snap.util.clusters.append(ClusterInfo(name: "P", activeRatio: avgU))
        }
        if eUtilsCount > 0 {
            let avgF = eFreqsCount > 0 ? eFreqsSum / eFreqsCount : 0
            let avgU = eUtilsSum / Double(eUtilsCount)
            snap.freq.clusters.append(ClusterInfo(name: "E", freqMHz: avgF, activeRatio: avgU, minFreqMHz: eFreqsMin != Int.max ? eFreqsMin : 0, maxFreqMHz: eFreqsMax != Int.min ? eFreqsMax : 0))
            snap.util.clusters.append(ClusterInfo(name: "E", activeRatio: avgU))
        }
    }

    private func cpuFreqFromState(_ ch: CFDictionary, _ stateCount: Int, _ table: [Int]) -> Int {
        guard !table.isEmpty, stateCount > 2 else { return 0 }
        var totalActiveRes: Int64 = 0
        var weightedSum: Double = 0
        var activeStateIndex = 0
        
        for i in 0..<stateCount {
            var isIdleOrDown = false
            if let nameRef = _IOSN(ch, Int32(i)) {
                let name = (nameRef.takeUnretainedValue() as String).lowercased()
                if name.contains("idle") || name.contains("down") || name.contains("off") || name.contains("sleep") {
                    isIdleOrDown = true
                }
            } else if i == 0 {
                isIdleOrDown = true
            }
            
            if isIdleOrDown { continue }
            
            let res = _IOSR(ch, Int32(i))
            guard res > 0 else {
                activeStateIndex += 1
                continue
            }
            
            let freq = activeStateIndex < table.count ? table[activeStateIndex] : (table.last ?? 0)
            totalActiveRes += res
            weightedSum += Double(res) * Double(freq)
            activeStateIndex += 1
        }
        return totalActiveRes > 0 ? Int(round(weightedSum / Double(totalActiveRes))) : 0
    }

    private func gpuFreqFromState(_ ch: CFDictionary, _ stateCount: Int) -> Int {
        guard !gFreqs.isEmpty, stateCount > 1 else { return 0 }
        var totalActiveRes: Int64 = 0
        var weightedSum: Double = 0
        var activeStateIndex = 0
        
        for i in 1..<stateCount {
            var isIdleOrDown = false
            if let nameRef = _IOSN(ch, Int32(i)) {
                let name = (nameRef.takeUnretainedValue() as String).lowercased()
                if name.contains("idle") || name.contains("down") || name.contains("off") || name.contains("sleep") {
                    isIdleOrDown = true
                }
            } else if i == 0 {
                isIdleOrDown = true
            }
            
            if isIdleOrDown { continue }
            
            let res = _IOSR(ch, Int32(i))
            guard res > 0 else {
                activeStateIndex += 1
                continue
            }
            
            let freq = activeStateIndex < gFreqs.count ? gFreqs[activeStateIndex] : (gFreqs.last ?? 0)
            totalActiveRes += res
            weightedSum += Double(res) * Double(freq)
            activeStateIndex += 1
        }
        return totalActiveRes > 0 ? Int(round(weightedSum / Double(totalActiveRes))) : 0
    }

    private func cpuUtilization(_ ch: CFDictionary, _ stateCount: Int) -> Double {
        guard stateCount > 0 else { return 0 }
        var idle: Int64 = 0; var total: Int64 = 0
        for i in 0..<stateCount {
            let r = _IOSR(ch, Int32(i))
            total += r
            
            var isIdle = false
            if let nameRef = _IOSN(ch, Int32(i)) {
                let name = (nameRef.takeUnretainedValue() as String).lowercased()
                if name.contains("idle") || name.contains("off") || name.contains("down") || name.contains("sleep") {
                    isIdle = true
                }
            } else if i == 0 {
                isIdle = true
            }
            
            if isIdle { idle += r }
        }
        return total > 0 ? (1.0 - Double(idle) / Double(total)) * 100.0 : 0
    }

    private func getCanonicalCluster(name: String, hasSuper: Bool) -> String {
        let u = name.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if u.contains("CPM") || u.contains("DCS") { return "" }
        
        if u.hasPrefix("CPU ") {
            let parts = u.components(separatedBy: " ")
            if parts.count >= 2, let id = Int(parts[1]) {
                if hasSuper {
                    if let range0 = level0CoreRange, range0.contains(id) { return "S" }
                    if let range1 = level1CoreRange, range1.contains(id) { return "P" }
                } else {
                    if let range0 = level0CoreRange, range0.contains(id) { return "P" }
                    if let range1 = level1CoreRange, range1.contains(id) { return "E" }
                }
            }
        }
        
        if hasSuper {
            if u.contains("PACC") || u.contains("PCPU") || u.contains("SUPER") || u.contains("S-") || u.contains("SCPU") { return "S" }
            if u.contains("MCPU") || u.contains("MCPM") || u.contains("M0") || u.contains("M1") || u.contains("ECPU") || u.contains("EACC") || u.contains("P0") || u.contains("P1") || u.contains("P-") { return "P" }
        } else {
            if u.contains("PACC") || u.contains("PCPU") || u.contains("P-") || u.contains("P0") || u.contains("P1") { return "P" }
            if u.contains("ECPU") || u.contains("EACC") || u.contains("E-") || u.contains("E0") || u.contains("E1") { return "E" }
        }
        return ""
    }

    private func str(_ u: Unmanaged<CFString>?) -> String { u?.takeUnretainedValue() as String? ?? "" }

    private func getSysctlString(name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname(name, &buffer, &size, nil, 0)
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }
    
    private func getSysctlInt(name: String) -> Int {
        var val = 0
        var size = MemoryLayout<Int>.size
        let result = sysctlbyname(name, &val, &size, nil, 0)
        return result == 0 ? val : 0
    }

    private func loadFreqTables() {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard entry != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(entry) }
        
        var dict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = dict?.takeRetainedValue() as? [String: Any] else { return }
        
        let hasSuper = isSuperActive
        
        if hasSuper {
            if let data = props["voltage-states22-sram"] as? Data { pFreqs = parseHz(data) }
            else if let data = props["voltage-states22"] as? Data { pFreqs = parseHz(data) }
            
            if let data = props["voltage-states5-sram"] as? Data { sFreqs = parseHz(data) }
            else if let data = props["voltage-states5"] as? Data { sFreqs = parseHz(data) }
            eFreqs = []
        } else {
            if let data = props["voltage-states1-sram"] as? Data { eFreqs = parseHz(data) }
            else if let data = props["voltage-states1"] as? Data { eFreqs = parseHz(data) }
            
            if let data = props["voltage-states5-sram"] as? Data { pFreqs = parseHz(data) }
            else if let data = props["voltage-states5"] as? Data { pFreqs = parseHz(data) }
            sFreqs = pFreqs
        }
        
        if let data = props["voltage-states14-sram"] as? Data { gFreqs = parseHz(data) }
        else if let data = props["voltage-states14"] as? Data { gFreqs = parseHz(data) }
        else if let data = props["voltage-states9-sram"] as? Data { gFreqs = parseHz(data) }
        else if let data = props["voltage-states9"] as? Data { gFreqs = parseHz(data) }
        
        if eFreqs.isEmpty { eFreqs = [2064, 2424, 2748, 2892, 3048] }
        if pFreqs.isEmpty { pFreqs = [3228, 3696, 4056, 4512, 4380] }
        if sFreqs.isEmpty { sFreqs = pFreqs }
        if gFreqs.isEmpty { gFreqs = [338, 450, 600, 800, 1000, 1200, 1398] }
    }

    private func initHID() {
        guard hidClient == nil else { return }
        if let client = _hidCreateClient(kCFAllocatorDefault)?.takeRetainedValue() {
            self.hidClient = client
            let match: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
            _hidSetMatching(client, match as CFDictionary)
        }
    }

    private func discoverThermalServices() {
        guard !isThermalServiceCached else { return }
        initHID()
        guard let client = hidClient,
              let services = _hidCopyServices(client)?.takeRetainedValue() else { return }
        
        let count = CFArrayGetCount(services)
        var discovered: [CachedThermalSensor] = []
        
        for i in 0..<count {
            let svc = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: AnyObject.self)
            guard let product = _hidCopyProperty(svc, "Product" as CFString)?.takeRetainedValue() else { continue }
            
            if CFGetTypeID(product) == CFStringGetTypeID() {
                var buf = [UInt8](repeating: 0, count: 128)
                CFStringGetCString(unsafeBitCast(product, to: CFString.self), &buf, 128, CFStringBuiltInEncodings.ASCII.rawValue)
                let name = String(cString: buf)
                let lk = name.lowercased()
                
                if lk.contains("tdev") || lk.contains("tcal") { continue }
                if lk.contains("tdie") {
                    let type: SensorType
                    let key: String
                    let label: String
                    
                    if lk.contains("tdie9") || lk.contains("gpu") || lk.contains("tg0") {
                        type = .gpu
                        key = "GPU"
                        label = "GPU Die"
                    } else if lk.contains("tdie11") || lk.contains("ane") || lk.contains("ta0") {
                        type = .ane
                        key = "ANE"
                        label = "Neural Engine"
                    } else {
                        type = .cpu
                        key = name
                        label = name
                    }
                    discovered.append(CachedThermalSensor(service: svc, type: type, key: key, label: label))
                }
            }
        }
        cachedSensors = discovered
        isThermalServiceCached = true
    }

    private func parseHz(_ d: Data) -> [Int] {
        let parsed: [Int] = (0..<(d.count / 8)).compactMap { (i: Int) -> Int? in
            var f: UInt32 = 0
            (d as NSData).getBytes(&f, range: NSRange(location: i * 8, length: 4))
            guard f > 0 else { return nil }
            return f > 100_000_000 ? Int(f) / 1_000_000 : (f > 100_000 ? Int(f) / 1_000 : Int(f))
        }
        return parsed.filter { $0 > 0 }
    }

    private func readTemps() -> ThermalSample {
        discoverThermalServices()
        guard isThermalServiceCached else { return ThermalSample(cpuTemp: nil, gpuTemp: nil, aneTemp: nil, systemTemp: nil, allSensors: []) }
        
        let fieldPath: Int64 = Int64(15) << 16
        var sensors: [(key: String, label: String, temp: Double)] = []
        var cpuT: [Double] = []
        var gpuT: [Double] = []
        var aneT: [Double] = []

        for sensor in cachedSensors {
            guard let event = _hidCopyEvent(sensor.service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let temp = _hidGetFloat(event, fieldPath)
            guard temp > 15, temp < 130 else { continue }

            switch sensor.type {
            case .cpu: cpuT.append(temp)
            case .gpu: gpuT.append(temp)
            case .ane: aneT.append(temp)
            case .unknown: break
            }
        }

        let maxCPU = cpuT.max()
        let maxGPU = gpuT.max() ?? maxCPU
        let maxANE = aneT.max() ?? (maxCPU != nil ? maxCPU! - 2.0 : nil)
        
        if !cpuT.isEmpty {
            sensors.append(("CPU_MAX", "CPU Core (Max)", cpuT.max() ?? 0))
            sensors.append(("CPU_AVG", "CPU Core (Avg)", cpuT.reduce(0, +) / Double(cpuT.count)))
            sensors.append(("CPU_MIN", "CPU Core (Min)", cpuT.min() ?? 0))
        }
        if let gpu = maxGPU { sensors.append(("GPU", "GPU Die", gpu)) }
        if let ane = maxANE { sensors.append(("ANE", "Neural Engine", ane)) }

        return ThermalSample(cpuTemp: maxCPU, gpuTemp: maxGPU, aneTemp: maxANE, systemTemp: nil, allSensors: sensors)
    }

    private func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Light"
        case .serious: return "Moderate"
        case .critical: return "Critical"
        @unknown default: return "Nominal"
        }
    }
}

// MARK: - Circular Ring Buffer

struct RingBuffer: Sendable {
    private(set) var array: [Double]
    private(set) var head: Int = 0
    private(set) var count: Int = 0
    let capacity: Int
    
    init(capacity: Int) {
        let maxCapacity = max(2, capacity)
        self.capacity = maxCapacity
        self.array = Array(repeating: 0.0, count: maxCapacity)
    }
    
    // Explicitly mark as nonisolated to prevent MainActor inference
    mutating nonisolated func append(_ value: Double) {
        // Because this is mutating, we need to ensure the caller has
        // exclusive access. Since it's a value type inside an actor,
        // the actor provides this safety.
        
        // Note: 'mutating' and 'nonisolated' on a struct is standard
        // for value types used across actors.
        if count < capacity {
            array[count] = value
            count += 1
        } else {
            array[head] = value
            head = (head + 1) % capacity
        }
    }
    
    // Explicitly mark as nonisolated
    nonisolated var values: [Double] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(array[0..<count])
        }
        return Array(array[head..<capacity] + array[0..<head])
    }
    
    // Explicitly mark as nonisolated
    nonisolated func lastValues(_ n: Int) -> [Double] {
        let all = self.values
        let takeCount = min(n, all.count)
        return Array(all.suffix(takeCount))
    }
}

// MARK: - Safe Background Monitor Actor

actor BackgroundMonitorRunner {
    private var isPolling = false
    private var pollTask: Task<Void, Never>?
    private var activeCapacity: Int = 180
    
    private var powerHistory: [String: RingBuffer] = [:]
    private var freqHistory: [String: RingBuffer] = [:]
    private var utilHistory: [String: RingBuffer] = [:]
    private var tempHistory: [String: RingBuffer] = [:]
    
    // Returns a stream that the UI can "listen" to
    func snapshots(interval: Double, capacity: Int) -> AsyncStream<PresentationSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                
                let initialized = await IOKitPowerMetrics.shared.start()
                guard initialized else {
                    continuation.finish()
                    return
                }
                
                while !Task.isCancelled {
                    let sample = await IOKitPowerMetrics.shared.sample()
                    if sample.valid {
                        // Process the sample on the actor
                        let presentation = await self.processSample(sample, capacity: capacity)
                        // Send it to the listener
                        continuation.yield(presentation)
                    }
                    
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
    
    func stop() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
    }
    
    func updateCapacity(_ capacity: Int) {
        self.activeCapacity = capacity
    }
    
    private func getActiveCapacity() -> Int {
        return activeCapacity
    }
    
    private func getIsPolling() -> Bool {
        return isPolling
    }
    
    private func processSample(_ s: HardwareSnapshot, capacity: Int) -> PresentationSnapshot {
        appendHistory(s)
        
        // Always build full 360-point internal vectors so rendering can dynamically scale on slice
        let maxCapacity = 360
        let power = buildPowerSeries(s, capacity: maxCapacity)
        let freq = buildFreqSeries(s, capacity: maxCapacity)
        let temp = buildTempSeries(s, capacity: maxCapacity)
        let util = buildUtilSeries(s, capacity: maxCapacity)
        
        return PresentationSnapshot(
            snap: s,
            powerSeries: power,
            freqSeries: freq,
            tempSeries: temp,
            utilSeries: util
        )
    }
    
    private func appendHistory(_ s: HardwareSnapshot) {
        func add(_ dict: inout [String: RingBuffer], key: String, val: Double) {
            if dict[key] == nil {
                dict[key] = RingBuffer(capacity: 360)
            }
            dict[key]!.append(val)
        }
        
        add(&powerHistory, key: "PKG", val: s.packagePower)
        add(&powerHistory, key: "CPU", val: s.power.cpuPower)
        add(&powerHistory, key: "GPU", val: s.power.gpuPower)
        add(&powerHistory, key: "ANE", val: s.power.anePower)
        if s.power.dramPower > 0 { add(&powerHistory, key: "DRAM", val: s.power.dramPower) }
        
        for c in s.freq.clusters {
            add(&freqHistory, key: c.name, val: Double(c.freqMHz) / 1000.0)
            add(&freqHistory, key: "\(c.name)_MIN", val: Double(c.minFreqMHz) / 1000.0)
            add(&freqHistory, key: "\(c.name)_MAX", val: Double(c.maxFreqMHz) / 1000.0)
        }
        add(&freqHistory, key: "GPU", val: Double(s.freq.gpuFreqMHz) / 1000.0)
        
        for c in s.util.clusters { add(&utilHistory, key: c.name, val: c.activeRatio) }
        add(&utilHistory, key: "GPU", val: s.util.gpuActive)
        
        for sensor in s.thermal.allSensors { add(&tempHistory, key: sensor.key, val: sensor.temp) }
    }
    
    // MARK: - Generation of Intermediate Render Models
    
    private func buildPowerSeries(_ s: HardwareSnapshot, capacity: Int) -> [UIChartSeries] {
        var series: [UIChartSeries] = []
        
        func addSeries(id: String, name: String, type: SeriesType, vals: [Double], cur: Double) {
            let points = Self.buildPoints(vals: vals, minVals: nil, maxVals: nil, capacity: capacity)
            series.append(UIChartSeries(
                id: id, name: name, seriesType: type, points: points, cur: cur, minCur: nil, maxCur: nil,
                yDomain: 0...1, mainTicks: [], subTicks: [], hasFractionalValue: false
            ))
        }
        
        addSeries(id: "PKG", name: "PKG", type: .pkg, vals: powerHistory["PKG"]?.lastValues(capacity) ?? [], cur: s.packagePower)
        addSeries(id: "CPU", name: "CORE", type: .cpu, vals: powerHistory["CPU"]?.lastValues(capacity) ?? [], cur: s.power.cpuPower)
        addSeries(id: "GPU", name: "GPU", type: .gpu, vals: powerHistory["GPU"]?.lastValues(capacity) ?? [], cur: s.power.gpuPower)
        addSeries(id: "ANE", name: "ANE", type: .ane, vals: powerHistory["ANE"]?.lastValues(capacity) ?? [], cur: s.power.anePower)
        if s.power.dramPower > 0 {
            addSeries(id: "DRAM", name: "DRAM", type: .dram, vals: powerHistory["DRAM"]?.lastValues(capacity) ?? [], cur: s.power.dramPower)
        }
        
        let allVals = series.flatMap { s in s.points.map { $0.y } }
        let sharedDomain = Self.calculateYDomain(vals: allVals, fixedMin: 0, fixedMax: nil)
        let sharedTicks = Self.generateTicks(domain: sharedDomain)
        let hasFrac = sharedTicks.main.contains { (($0 * 1000).rounded() / 1000).truncatingRemainder(dividingBy: 1) != 0 }
        
        return series.map { s in
            UIChartSeries(
                id: s.id, name: s.name, seriesType: s.seriesType, points: s.points, cur: s.cur,
                minCur: s.minCur, maxCur: s.maxCur, yDomain: sharedDomain, mainTicks: sharedTicks.main,
                subTicks: sharedTicks.sub, hasFractionalValue: hasFrac
            )
        }
    }
    
    private func buildFreqSeries(_ s: HardwareSnapshot, capacity: Int) -> [UIChartSeries] {
        var series: [UIChartSeries] = []
        for c in s.freq.clusters {
            let label = "\(c.name)-CORES"
            let type: SeriesType = c.name == "S" ? .clusterS : (c.name == "P" ? .clusterP : .clusterE)
            
            let vals = freqHistory[c.name]?.lastValues(capacity) ?? []
            let minVals = freqHistory["\(c.name)_MIN"]?.lastValues(capacity) ?? []
            let maxVals = freqHistory["\(c.name)_MAX"]?.lastValues(capacity) ?? []
            let points = Self.buildPoints(vals: vals, minVals: minVals, maxVals: maxVals, capacity: capacity)
            
            series.append(UIChartSeries(
                id: c.name, name: label, seriesType: type, points: points,
                cur: Double(c.freqMHz) / 1000.0,
                minCur: Double(c.minFreqMHz) / 1000.0,
                maxCur: Double(c.maxFreqMHz) / 1000.0,
                yDomain: 0...1, mainTicks: [], subTicks: [], hasFractionalValue: false
            ))
        }
        
        let gpuVals = freqHistory["GPU"]?.lastValues(capacity) ?? []
        let gpuPoints = Self.buildPoints(vals: gpuVals, minVals: nil, maxVals: nil, capacity: capacity)
        series.append(UIChartSeries(
            id: "GPU", name: "GPU", seriesType: .gpu, points: gpuPoints,
            cur: Double(s.freq.gpuFreqMHz) / 1000.0, minCur: nil, maxCur: nil,
            yDomain: 0...1, mainTicks: [], subTicks: [], hasFractionalValue: false
        ))
        
        let allVals = series.flatMap { s in s.points.map { $0.y } + s.points.compactMap { $0.yMin } + s.points.compactMap { $0.yMax } }
        let sharedDomain = Self.calculateYDomain(vals: allVals, fixedMin: 0, fixedMax: nil)
        let sharedTicks = Self.generateTicks(domain: sharedDomain)
        let hasFrac = sharedTicks.main.contains { (($0 * 1000).rounded() / 1000).truncatingRemainder(dividingBy: 1) != 0 }
        
        return series.map { s in
            UIChartSeries(
                id: s.id, name: s.name, seriesType: s.seriesType, points: s.points, cur: s.cur,
                minCur: s.minCur, maxCur: s.maxCur, yDomain: sharedDomain, mainTicks: sharedTicks.main,
                subTicks: sharedTicks.sub, hasFractionalValue: hasFrac
            )
        }
    }
    
    private func buildTempSeries(_ s: HardwareSnapshot, capacity: Int) -> [UIChartSeries] {
        var series: [UIChartSeries] = []
        let get: (String) -> Double = { k in s.thermal.allSensors.first(where: { $0.key == k })?.temp ?? 0 }
        let avg = get("CPU_AVG")
        let max = get("CPU_MAX")
        let min = get("CPU_MIN")
        let g = get("GPU")
        
        if avg > 0 {
            let vals = tempHistory["CPU_AVG"]?.lastValues(capacity) ?? []
            let minVals = tempHistory["CPU_MIN"]?.lastValues(capacity) ?? []
            let maxVals = tempHistory["CPU_MAX"]?.lastValues(capacity) ?? []
            let points = Self.buildPoints(vals: vals, minVals: minVals, maxVals: maxVals, capacity: capacity)
            
            series.append(UIChartSeries(
                id: "CPU_AVG", name: "CORE", seriesType: .cpu, points: points,
                cur: avg,
                minCur: min > 0 ? min : nil,
                maxCur: max > 0 ? max : nil,
                yDomain: 0...1, mainTicks: [], subTicks: [], hasFractionalValue: false
            ))
        }
        
        if g > 0 {
            let vals = tempHistory["GPU"]?.lastValues(capacity) ?? []
            let points = Self.buildPoints(vals: vals, minVals: nil, maxVals: nil, capacity: capacity)
            
            series.append(UIChartSeries(
                id: "GPU", name: "GPU", seriesType: .gpu, points: points,
                cur: g, minCur: nil, maxCur: nil,
                yDomain: 0...1, mainTicks: [], subTicks: [], hasFractionalValue: false
            ))
        }
        
        let allVals = series.flatMap { s in s.points.map { $0.y } + s.points.compactMap { $0.yMin } + s.points.compactMap { $0.yMax } }
        let sharedDomain = Self.calculateYDomain(vals: allVals, fixedMin: nil, fixedMax: 100)
        let sharedTicks = Self.generateTicks(domain: sharedDomain)
        let hasFrac = sharedTicks.main.contains { (($0 * 1000).rounded() / 1000).truncatingRemainder(dividingBy: 1) != 0 }
        
        return series.map { s in
            UIChartSeries(
                id: s.id, name: s.name, seriesType: s.seriesType, points: s.points, cur: s.cur,
                minCur: s.minCur, maxCur: s.maxCur, yDomain: sharedDomain, mainTicks: sharedTicks.main,
                subTicks: sharedTicks.sub, hasFractionalValue: hasFrac
            )
        }
    }
    
    private func buildUtilSeries(_ s: HardwareSnapshot, capacity: Int) -> [UIChartSeries] {
        var series: [UIChartSeries] = []
        for c in s.util.clusters {
            let label = "\(c.name)-CORE"
            let type: SeriesType = c.name == "S" ? .clusterS : (c.name == "P" ? .clusterP : .clusterE)
            
            let vals = utilHistory[c.name]?.lastValues(capacity) ?? []
            let points = Self.buildPoints(vals: vals, minVals: nil, maxVals: nil, capacity: capacity)
            
            series.append(UIChartSeries(
                id: c.name, name: label, seriesType: type, points: points,
                cur: c.activeRatio, minCur: nil, maxCur: nil,
                yDomain: 0...100, mainTicks: [], subTicks: [], hasFractionalValue: false
            ))
        }
        
        let gpuVals = utilHistory["GPU"]?.lastValues(capacity) ?? []
        let gpuPoints = Self.buildPoints(vals: gpuVals, minVals: nil, maxVals: nil, capacity: capacity)
        series.append(UIChartSeries(
            id: "GPU", name: "GPU", seriesType: .gpu, points: gpuPoints,
            cur: s.util.gpuActive, minCur: nil, maxCur: nil,
            yDomain: 0...100, mainTicks: [], subTicks: [], hasFractionalValue: false
        ))
        
        let sharedDomain = 0.0...100.0
        let sharedTicks = Self.generateTicks(domain: sharedDomain)
        let hasFrac = sharedTicks.main.contains { (($0 * 1000).rounded() / 1000).truncatingRemainder(dividingBy: 1) != 0 }
        
        return series.map { s in
            UIChartSeries(
                id: s.id, name: s.name, seriesType: s.seriesType, points: s.points, cur: s.cur,
                minCur: s.minCur, maxCur: s.maxCur, yDomain: sharedDomain, mainTicks: sharedTicks.main,
                subTicks: sharedTicks.sub, hasFractionalValue: hasFrac
            )
        }
    }
    
    // MARK: - Mathematical Pre-calculations
    
    private static func buildPoints(vals: [Double], minVals: [Double]?, maxVals: [Double]?, capacity: Int) -> [ChartPoint] {
        let count = vals.count
        guard count > 0 else { return [] }
        let offset = capacity - count
        
        var points: [ChartPoint] = []
        points.reserveCapacity(count)
        
        for i in 0..<count {
            let x = i + offset
            let y = vals[i]
            let yMin = (minVals != nil && i < minVals!.count) ? minVals![i] : nil
            let yMax = (maxVals != nil && i < maxVals!.count) ? maxVals![i] : nil
            
            points.append(ChartPoint(id: x, x: x, y: y, yMin: yMin, yMax: yMax))
        }
        return points
    }
    
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
    
    private static func generateTicks(domain: ClosedRange<Double>, height: CGFloat = 80.0) -> (main: [Double], sub: [Double]) {
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
