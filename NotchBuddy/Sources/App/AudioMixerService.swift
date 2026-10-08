import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - Core Audio Helpers

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(object, &addr)
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        fallback: T
    ) -> T {
        var addr = address
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) { buffer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? result : fallback
    }

    @discardableResult
    static func setValue<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ value: T
    ) -> OSStatus {
        var addr = address
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeBytes(of: value) { buffer in
            AudioObjectSetPropertyData(object, &addr, 0, nil, size, buffer.baseAddress!)
        }
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: T.Type = T.self
    ) -> [T] {
        var addr = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var dataSize = size
            let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &dataSize, buffer.baseAddress!)
            initialized = (status == noErr) ? Int(dataSize) / MemoryLayout<T>.stride : 0
        }
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var addr = address
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    final class ListenerToken: @unchecked Sendable {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        private let queue: DispatchQueue
        private var active = true

        init(object: AudioObjectID,
             address: AudioObjectPropertyAddress,
             queue: DispatchQueue,
             block: @escaping AudioObjectPropertyListenerBlock) {
            self.object = object
            self.address = address
            self.queue = queue
            self.block = block
            AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
        }

        func cancel() {
            guard active else { return }
            active = false
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }

        deinit { cancel() }
    }

    static func listen(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) -> ListenerToken {
        ListenerToken(object: object, address: address, queue: queue) { _, _ in handler() }
    }
}

// MARK: - Audio App Model

struct AudioApp: Identifiable, Equatable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    var volume: Float      // 0.0 ... 1.0 (or up to 1.5)
    var isMuted: Bool

    var displayVolumePercent: Int {
        Int((volume * 100).rounded())
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted && lhs.name == rhs.name
    }
}

// MARK: - Process Tap

final class ProcessTap: @unchecked Sendable {
    let processObjectID: AudioObjectID
    let outputDeviceUID: String
    private let queue: DispatchQueue
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let gainPtr: UnsafeMutablePointer<Float32>
    private(set) var isRunning: Bool = false

    init(processObjectID: AudioObjectID, outputDeviceUID: String, initialGain: Float32, queue: DispatchQueue) {
        self.processObjectID = processObjectID
        self.outputDeviceUID = outputDeviceUID
        self.queue = queue
        self.gainPtr = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        self.gainPtr.initialize(to: initialGain)
    }

    func setGain(_ gain: Float32) {
        gainPtr.pointee = gain
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.name = "CoucouTap-\(processObjectID)"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapErr == noErr, newTapID != kAudioObjectUnknown else {
            return false
        }
        tapID = newTapID

        let aggregateUID = "fr.louisraille.NotchBuddy.agg.\(UUID().uuidString)"
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CoucouTapAgg-\(processObjectID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(config as CFDictionary, &newAggregate)
        guard aggErr == noErr, newAggregate != kAudioObjectUnknown else {
            cleanup()
            return false
        }
        aggregateID = newAggregate

        let gainPtr = self.gainPtr
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            let gain = gainPtr.pointee
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            ProcessTap.mix(from: input, to: output, gain: gain)
        }

        var newProcID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue, ioBlock)
        guard procErr == noErr, let newProcID else {
            cleanup()
            return false
        }
        ioProcID = newProcID

        let startErr = AudioDeviceStart(aggregateID, newProcID)
        guard startErr == noErr else {
            cleanup()
            return false
        }

        isRunning = true
        return true
    }

    func stop() {
        cleanup()
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
    }

    deinit {
        cleanup()
        gainPtr.deinitialize(count: 1)
        gainPtr.deallocate()
    }

    static func mix(
        from input: UnsafeMutableAudioBufferListPointer,
        to output: UnsafeMutableAudioBufferListPointer,
        gain: Float32
    ) {
        guard output.count > 0 else { return }

        let outInterleaved = output.count == 1 && output[0].mNumberChannels > 1
        let outChannels = outInterleaved ? Int(output[0].mNumberChannels) : output.count
        let outFrames = outInterleaved
            ? Int(output[0].mDataByteSize) / (Int(output[0].mNumberChannels) * MemoryLayout<Float32>.size)
            : Int(output[0].mDataByteSize) / MemoryLayout<Float32>.size

        guard input.count > 0, input[0].mData != nil else {
            for buffer in output {
                if let dst = buffer.mData { memset(dst, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        let inInterleaved = input.count == 1 && input[0].mNumberChannels > 1
        let inChannels = inInterleaved ? Int(input[0].mNumberChannels) : input.count
        let inFrames = inInterleaved
            ? Int(input[0].mDataByteSize) / (Int(input[0].mNumberChannels) * MemoryLayout<Float32>.size)
            : Int(input[0].mDataByteSize) / MemoryLayout<Float32>.size

        let frames = min(inFrames, outFrames)

        func inChannel(_ ch: Int) -> (UnsafeMutablePointer<Float32>, Int)? {
            if inInterleaved {
                guard let base = input[0].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base + ch, inChannels)
            } else {
                guard ch < input.count, let base = input[ch].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base, 1)
            }
        }

        func outChannel(_ ch: Int) -> (UnsafeMutablePointer<Float32>, Int)? {
            if outInterleaved {
                guard let base = output[0].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base + ch, outChannels)
            } else {
                guard ch < output.count, let base = output[ch].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base, 1)
            }
        }

        for co in 0..<outChannels {
            guard let (dst, dStride) = outChannel(co) else { continue }
            let ci = co < inChannels ? co : inChannels - 1
            if let (src, sStride) = inChannel(ci) {
                var f = 0
                while f < frames {
                    dst[f * dStride] = src[f * sStride] * gain
                    f += 1
                }
                var t = frames
                while t < outFrames { dst[t * dStride] = 0; t += 1 }
            } else {
                var t = 0
                while t < outFrames { dst[t * dStride] = 0; t += 1 }
            }
        }
    }
}

// MARK: - Audio Mixer Service

@MainActor
final class AudioMixerService: ObservableObject {
    static let shared = AudioMixerService()

    @Published var apps: [AudioApp] = []
    @Published var masterVolume: Float = 1.0
    @Published var outputDeviceName: String = "Sortie principale"
    @Published var hasPermission: Bool = true

    private var taps: [AudioObjectID: ProcessTap] = [:]
    private var processListListener: CA.ListenerToken?
    private var outputDeviceListener: CA.ListenerToken?
    private var pollTimer: Timer?
    private let ioQueue = DispatchQueue(label: "fr.louisraille.coucou.audio-io", qos: .userInteractive)

    private init() {
        refreshMasterVolume()
        setupListeners()
    }

    private func setupListeners() {
        processListListener = CA.listen(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            Task { @MainActor in
                self?.refreshApps()
            }
        }

        outputDeviceListener = CA.listen(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            Task { @MainActor in
                self?.handleOutputDeviceChanged()
            }
        }
    }

    // MARK: - Monitoring Lifecycle (0% CPU when idle)

    func startMonitoring() {
        refreshMasterVolume()
        refreshApps()

        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshApps()
                    self?.refreshMasterVolume()
                }
            }
        }
    }

    func stopMonitoring() {
        // If no custom taps are currently modified, pause polling to conserve CPU
        if taps.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Volume & Mute Controls

    func setVolume(for app: AudioApp, volume: Float) {
        let clamped = max(0.0, min(1.5, volume))
        saveVolume(clamped, for: app)
        applyTap(for: app, volume: clamped, isMuted: app.isMuted)
    }

    func toggleMute(for app: AudioApp) {
        let newMuted = !app.isMuted
        saveMuted(newMuted, for: app)
        applyTap(for: app, volume: app.volume, isMuted: newMuted)
    }

    func resetVolume(for app: AudioApp) {
        saveVolume(1.0, for: app)
        saveMuted(false, for: app)
        dropTap(for: app.id)
        refreshApps()
    }

    private func applyTap(for app: AudioApp, volume: Float, isMuted: Bool) {
        // Normal unity gain and not muted → no interception needed!
        if abs(volume - 1.0) < 0.01 && !isMuted {
            dropTap(for: app.id)
            refreshApps()
            return
        }

        guard let output = currentOutput() else { return }
        let gain = isMuted ? Float32(0.0) : Float32(volume)

        if let existing = taps[app.id] {
            existing.setGain(gain)
        } else {
            let tap = ProcessTap(
                processObjectID: app.id,
                outputDeviceUID: output.uid,
                initialGain: gain,
                queue: ioQueue
            )
            if tap.start() {
                taps[app.id] = tap
                hasPermission = true
            } else {
                hasPermission = false
            }
        }
        refreshApps()
    }

    private func dropTap(for processObjectID: AudioObjectID) {
        taps[processObjectID]?.stop()
        taps.removeValue(forKey: processObjectID)
    }

    // MARK: - Master Volume

    func refreshMasterVolume() {
        let device = CA.value(
            CA.system,
            CA.address(kAudioHardwarePropertyDefaultOutputDevice),
            fallback: AudioObjectID(kAudioObjectUnknown)
        )
        guard device != kAudioObjectUnknown else { return }

        if let name = CA.string(device, CA.address(kAudioObjectPropertyName)) {
            self.outputDeviceName = name
        }

        var addr = CA.address(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
        if CA.hasProperty(device, addr) {
            var vol: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
                self.masterVolume = vol
            }
        }
    }

    func setMasterVolume(_ vol: Float) {
        let clamped = max(0.0, min(1.0, vol))
        self.masterVolume = clamped

        let device = CA.value(
            CA.system,
            CA.address(kAudioHardwarePropertyDefaultOutputDevice),
            fallback: AudioObjectID(kAudioObjectUnknown)
        )
        guard device != kAudioObjectUnknown else { return }

        var addr = CA.address(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
        if CA.hasProperty(device, addr) {
            var val = Float32(clamped)
            let size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, &val)
        }
    }

    private func handleOutputDeviceChanged() {
        guard let output = currentOutput() else { return }
        let currentTaps = taps
        taps.removeAll()

        for (id, oldTap) in currentTaps {
            oldTap.stop()
            if let app = apps.first(where: { $0.id == id }) {
                let gain = app.isMuted ? Float32(0.0) : Float32(app.volume)
                let newTap = ProcessTap(
                    processObjectID: id,
                    outputDeviceUID: output.uid,
                    initialGain: gain,
                    queue: ioQueue
                )
                if newTap.start() {
                    taps[id] = newTap
                }
            }
        }
        refreshMasterVolume()
    }

    // MARK: - App Discovery

    func refreshApps() {
        let ids = CA.array(
            CA.system,
            CA.address(kAudioHardwarePropertyProcessObjectList),
            of: AudioObjectID.self
        )
        let ownPID = getpid()

        var discovered: [AudioApp] = []

        for id in ids {
            let isRunning = CA.value(
                id,
                CA.address(kAudioProcessPropertyIsRunningOutput),
                fallback: UInt32(0)
            ) != 0

            let pid = CA.value(
                id,
                CA.address(kAudioProcessPropertyPID),
                fallback: pid_t(-1)
            )
            guard pid != ownPID && pid > 0 else { continue }

            let bundleID = CA.string(id, CA.address(kAudioProcessPropertyBundleID))
            let owner = Self.owningApp(pid: pid)

            guard owner != nil || !(bundleID?.isEmpty ?? true) else { continue }

            let effectiveBundle = owner?.bundleIdentifier ?? bundleID
            let name = owner?.localizedName ?? Self.fallbackName(bundleID: bundleID, pid: pid)
            let icon = owner?.icon

            let key = effectiveBundle ?? name
            let savedVol = loadSavedVolume(key: key)
            let savedMute = loadSavedMuted(key: key)

            // Only display apps currently outputting audio or actively tapped
            if isRunning || taps[id] != nil {
                // If this app is running and has saved custom volume/mute, ensure tap is running
                if isRunning && (abs(savedVol - 1.0) > 0.01 || savedMute) && taps[id] == nil {
                    if let output = currentOutput() {
                        let gain = savedMute ? Float32(0.0) : Float32(savedVol)
                        let tap = ProcessTap(
                            processObjectID: id,
                            outputDeviceUID: output.uid,
                            initialGain: gain,
                            queue: ioQueue
                        )
                        if tap.start() {
                            taps[id] = tap
                        }
                    }
                }

                discovered.append(AudioApp(
                    id: id,
                    pid: pid,
                    bundleID: effectiveBundle,
                    name: name,
                    icon: icon,
                    volume: savedVol,
                    isMuted: savedMute
                ))
            }
        }

        // Clean up taps for apps that no longer exist
        let liveIDs = Set(discovered.map(\.id))
        for (id, tap) in taps where !liveIDs.contains(id) {
            tap.stop()
            taps.removeValue(forKey: id)
        }

        self.apps = discovered.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Process Hierarchy & Helpers

    private static func owningApp(pid: pid_t) -> NSRunningApplication? {
        var current = pid
        var depth = 0
        while current > 1, depth < 8 {
            if let app = NSRunningApplication(processIdentifier: current) { return app }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
            depth += 1
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    private static func fallbackName(bundleID: String?, pid: pid_t) -> String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
        return "App (\(pid))"
    }

    private func currentOutput() -> (id: AudioObjectID, uid: String)? {
        let device = CA.value(
            CA.system,
            CA.address(kAudioHardwarePropertyDefaultOutputDevice),
            fallback: AudioObjectID(kAudioObjectUnknown)
        )
        guard device != kAudioObjectUnknown,
              let uid = CA.string(device, CA.address(kAudioDevicePropertyDeviceUID))
        else { return nil }
        return (device, uid)
    }

    // MARK: - Persistence

    private func saveVolume(_ volume: Float, for app: AudioApp) {
        let key = app.bundleID ?? app.name
        UserDefaults.standard.set(volume, forKey: "appAudioVolume_\(key)")
    }

    private func saveMuted(_ isMuted: Bool, for app: AudioApp) {
        let key = app.bundleID ?? app.name
        UserDefaults.standard.set(isMuted, forKey: "appAudioMuted_\(key)")
    }

    private func loadSavedVolume(key: String) -> Float {
        if let val = UserDefaults.standard.object(forKey: "appAudioVolume_\(key)") as? Float {
            return val
        }
        if let val = UserDefaults.standard.object(forKey: "appAudioVolume_\(key)") as? Double {
            return Float(val)
        }
        return 1.0
    }

    private func loadSavedMuted(key: String) -> Bool {
        UserDefaults.standard.bool(forKey: "appAudioMuted_\(key)")
    }

    // MARK: - Permission Request

    func requestPermission() {
        let service = "kTCCServiceAudioCapture" as CFString
        if let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) {
            defer { dlclose(handle) }
            typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
            if let sym = dlsym(handle, "TCCAccessRequest") {
                let req = unsafeBitCast(sym, to: RequestFn.self)
                req(service, nil) { [weak self] granted in
                    Task { @MainActor in
                        self?.hasPermission = granted
                        self?.refreshApps()
                    }
                }
                return
            }
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
