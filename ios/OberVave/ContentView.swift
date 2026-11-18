import Combine
import SwiftUI
#if !OBERVAVE_AU
import AVFoundation
import CoreBluetooth
import CoreMIDI
import Darwin
import UIKit

fileprivate struct BluetoothMIDIDevice: Identifiable {
    let id: UUID
    let name: String
    var isConnecting: Bool
    var isConnected: Bool
}

private struct BLEMIDIMidiMessage {
    let status: UInt8
    let data1: UInt8
    let data2: UInt8
    let hostTime: TimeInterval
}

private struct BLEMIDINoteParser {
    private var runningStatus: UInt8?
    private var lastRawTimestamp: UInt16?
    private var extendedTimestamp: UInt64 = 0
    private var lastPacketArrival: TimeInterval?
    private var hostTimeOffset: TimeInterval?

    mutating func consume(_ packet: Data, receivedAt: TimeInterval) -> [BLEMIDIMidiMessage] {
        let bytes = [UInt8](packet)
        guard bytes.count >= 3, bytes[0] & 0xC0 == 0x80 else { return [] }

        var parsed: [(status: UInt8, data1: UInt8, data2: UInt8, timestamp: UInt64)] = []
        var index = 1
        let timestampHigh = UInt16(bytes[0] & 0x3F) << 7
        var packetTimestamp: UInt16?
        while index < bytes.count {
            guard bytes[index] & 0x80 != 0 else { break }
            let timestampLow = UInt16(bytes[index] & 0x7F)
            index += 1
            if let previous = packetTimestamp {
                var high = previous & 0x1F80
                let previousLow = previous & 0x7F
                if timestampLow < previousLow && previousLow - timestampLow > 64 {
                    high = (high + 128) & 0x1F80
                }
                packetTimestamp = high | timestampLow
            } else {
                packetTimestamp = timestampHigh | timestampLow
            }
            guard index < bytes.count else { break }

            let first = bytes[index]
            let status: UInt8
            var dataBytes: [UInt8] = []
            if first & 0x80 != 0 {
                status = first
                index += 1
                if status < 0xF0 {
                    runningStatus = status
                } else if status < 0xF8 {
                    runningStatus = nil
                }
                if status >= 0xF0 && status < 0xF8 {
                    continue
                }
            } else {
                guard let runningStatus else { break }
                status = runningStatus
                dataBytes.append(first)
                index += 1
            }

            if status >= 0xF8 {
                if status == 0xF8 || status == 0xFA || status == 0xFB || status == 0xFC {
                    parsed.append((
                        status, 0, 0,
                        extendTimestamp(packetTimestamp!, receivedAt: receivedAt, considerArrival: parsed.isEmpty)
                    ))
                }
                continue
            }

            let command = status & 0xF0
            let dataCount = command == 0xC0 || command == 0xD0 ? 1 : 2
            while dataBytes.count < dataCount, index < bytes.count, bytes[index] & 0x80 == 0 {
                dataBytes.append(bytes[index])
                index += 1
            }
            guard dataBytes.count == dataCount else { break }

            parsed.append((
                status,
                dataBytes[0],
                dataCount > 1 ? dataBytes[1] : 0,
                extendTimestamp(packetTimestamp!, receivedAt: receivedAt, considerArrival: parsed.isEmpty)
            ))
        }
        guard let latestTimestamp = parsed.last?.timestamp else { return [] }
        let arrivalOffset = receivedAt - Double(latestTimestamp) / 1000
        if let hostTimeOffset {
            self.hostTimeOffset = min(hostTimeOffset, arrivalOffset)
        } else {
            hostTimeOffset = arrivalOffset
        }
        lastPacketArrival = receivedAt
        return parsed.map {
            BLEMIDIMidiMessage(
                status: $0.status,
                data1: $0.data1,
                data2: $0.data2,
                hostTime: Double($0.timestamp) / 1000 + (hostTimeOffset ?? arrivalOffset)
            )
        }
    }

    private mutating func extendTimestamp(
        _ rawTimestamp: UInt16,
        receivedAt: TimeInterval,
        considerArrival: Bool
    ) -> UInt64 {
        guard let lastRawTimestamp else {
            self.lastRawTimestamp = rawTimestamp
            extendedTimestamp = UInt64(rawTimestamp)
            return extendedTimestamp
        }
        let modularDelta = Int((rawTimestamp + 8192 - lastRawTimestamp) % 8192)
        var delta = modularDelta
        if considerArrival, let lastPacketArrival, receivedAt > lastPacketArrival {
            let expectedDelta = Int(((receivedAt - lastPacketArrival) * 1000).rounded())
            if expectedDelta > modularDelta {
                delta += ((expectedDelta - modularDelta + 4096) / 8192) * 8192
            }
        }
        extendedTimestamp += UInt64(max(0, delta))
        self.lastRawTimestamp = rawTimestamp
        return extendedTimestamp
    }
}

#endif

#if !OBERVAVE_AU
private struct StoredPreset: Codable {
    let name: String
    let parameters: [Int]
    let ccAssignments: [Int]
    var arpSelectedMode: Int?
    var latchSelectedMode: Int?
}

private struct PresetLibrary: Codable {
    var presets: [String: StoredPreset] = [:]
    var ccMappings: [String: [Int]] = [:]
}

#endif

struct SynthControl: Identifiable {
    let parameter: SynthParameter
    let label: String
    var options: [String] = []
    var optionValueOffset: Int = 0

    var id: SynthParameter { parameter }
}

struct SynthControlSection: Identifiable {
    let title: String
    let controls: [SynthControl]

    var id: String { title }
}

enum ControlPanelItem: Identifiable {
    case amp
    case section(SynthControlSection)

    var id: String {
        switch self {
        case .amp: "amp"
        case .section(let section): section.id
        }
    }
}

enum SynthControlLayouts {
    static let ob1: [SynthControlSection] = [
        .init(title: "OSCILLATOR 1", controls: [
            .init(parameter: .osc1Wave, label: "WAVE", options: ["OFF", "SAW", "PULSE", "BOTH"]),
            .init(parameter: .osc1PulseWidth, label: "PULSE WIDTH"),
            .init(parameter: .osc1Level, label: "LEVEL"),
            .init(parameter: .noise, label: "NOISE")
        ]),
        .init(title: "OSCILLATOR 2", controls: [
            .init(parameter: .osc2Wave, label: "WAVE", options: ["OFF", "SAW", "PULSE", "BOTH"]),
            .init(parameter: .osc2PulseWidth, label: "PULSE WIDTH"),
            .init(parameter: .osc2Level, label: "LEVEL"),
            .init(parameter: .osc2Semitone, label: "SEMITONE"),
            .init(parameter: .osc2Fine, label: "FINE")
        ]),
        .init(title: "OSC MODULATION", controls: [
            .init(parameter: .oscillatorSync, label: "SYNC", options: ["OFF", "ON"]),
            .init(parameter: .crossMod, label: "CROSS MOD"),
            .init(parameter: .envelopeToOsc2, label: "ENV → OSC 2")
        ]),
        .init(title: "FILTER", controls: [
            .init(parameter: .cutoff, label: "CUTOFF"),
            .init(parameter: .resonance, label: "RESONANCE"),
            .init(parameter: .filterEnvelopeAmount, label: "ENV AMOUNT"),
            .init(parameter: .keyTracking, label: "KEY TRACK"),
            .init(parameter: .filterType, label: "TYPE", options: ["LP 12", "HP 12", "BP 12", "NOTCH", "LP 24", "SEM"])
        ]),
        .init(title: "FILTER ENVELOPE", controls: [
            .init(parameter: .filterAttack, label: "ATTACK"),
            .init(parameter: .filterDecay, label: "DECAY"),
            .init(parameter: .filterSustain, label: "SUSTAIN"),
            .init(parameter: .filterRelease, label: "RELEASE")
        ]),
        .init(title: "AMPLIFIER ENVELOPE", controls: [
            .init(parameter: .ampAttack, label: "ATTACK"),
            .init(parameter: .ampDecay, label: "DECAY"),
            .init(parameter: .ampSustain, label: "SUSTAIN"),
            .init(parameter: .ampRelease, label: "RELEASE")
        ]),
        .init(title: "PERFORMANCE", controls: [
            .init(parameter: .glide, label: "GLIDE"),
            .init(parameter: .bendRange, label: "BEND RANGE"),
            .init(parameter: .volume, label: "VOLUME")
        ])
    ]

    static let extensions: [SynthControlSection] = [
        .init(title: "VOICE", controls: [
            .init(parameter: .voiceMode, label: "MODE", options: ["POLY", "DUAL", "UNISON", "MONO"]),
            .init(parameter: .unisonVoices, label: "UNISON VOICES"),
            .init(parameter: .detune, label: "DETUNE"),
            .init(parameter: .vintage, label: "VINTAGE"),
            .init(parameter: .stereoSpread, label: "STEREO SPREAD")
        ]),
        .init(title: "OSCILLATOR / FILTER", controls: [
            .init(parameter: .drive, label: "DRIVE"),
            .init(parameter: .velocityToFilter, label: "VELOCITY → FILTER"),
            .init(parameter: .velocityToAmp, label: "VELOCITY → AMP"),
            .init(parameter: .fmMorph, label: "FM MORPH")
        ]),
        .init(title: "ARPEGGIATOR", controls: [
            .init(parameter: .arpMode, label: "MODE", options: ["UP", "DOWN", "UP/DN", "RANDOM", "PLAYED", "CHORD", "HOLD RETRIGGER", "HOLD LEGATO"], optionValueOffset: 1),
            .init(parameter: .arpLatch, label: "LATCH MODE", options: ["ADD", "REPLACE"], optionValueOffset: 1),
            .init(parameter: .arpDivision, label: "DIVISION", options: ["1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T"]),
            .init(parameter: .arpOctaves, label: "OCTAVES", options: ["1", "2", "3", "4"], optionValueOffset: 1),
            .init(parameter: .arpVelocity, label: "VELOCITY"),
            .init(parameter: .arpGate, label: "GATE")
        ]),
    ]

    static let modulation: [SynthControlSection] = [
        .init(title: "LFO", controls: [
            .init(parameter: .lfoShape, label: "WAVE", options: ["TRI", "SAW", "RAMP", "SQUARE", "S&H", "RND"]),
            .init(parameter: .lfoRate, label: "RATE"),
            .init(parameter: .lfoDelay, label: "DELAY"),
            .init(parameter: .lfoPhase, label: "PHASE", options: ["SYNC", "FREE", "SPREAD"])
        ]),
        .init(title: "LFO OSCILLATORS", controls: [
            .init(parameter: .lfoPitch, label: "PITCH DEPTH"),
            .init(parameter: .lfoPitchTarget, label: "PITCH →", options: ["OSC 1", "OSC 2", "BOTH"]),
            .init(parameter: .lfoPulseWidth, label: "PWM DEPTH"),
            .init(parameter: .lfoPulseTarget, label: "PWM →", options: ["OSC 1", "OSC 2", "BOTH"])
        ]),
        .init(title: "LFO FILTER / AMP", controls: [
            .init(parameter: .lfoFilter, label: "CUTOFF DEPTH"),
            .init(parameter: .lfoAmp, label: "VOLUME DEPTH"),
            .init(parameter: .modWheelDepth, label: "LEGACY WHEEL DEPTH")
        ])
    ]

    static let effects: [SynthControlSection] = [
        .init(title: "CHORUS", controls: [
            .init(parameter: .chorusRate, label: "RATE"),
            .init(parameter: .chorusDepth, label: "DEPTH"),
            .init(parameter: .chorusMix, label: "MIX")
        ]),
        .init(title: "DELAY", controls: [
            .init(parameter: .delayTime, label: "TIME", options: ["1/16", "1/8T", "1/8", "1/8.", "1/4", "1/4.", "1/2"]),
            .init(parameter: .delayFeedback, label: "FEEDBACK"),
            .init(parameter: .delayTone, label: "TONE"),
            .init(parameter: .delayMix, label: "MIX")
        ]),
        .init(title: "REVERB", controls: [
            .init(parameter: .reverbSize, label: "SIZE"),
            .init(parameter: .reverbDamping, label: "DAMPING"),
            .init(parameter: .reverbPreDelay, label: "PRE-DELAY"),
            .init(parameter: .reverbMix, label: "MIX")
        ])
    ]
}

enum OberVaveScreen: Int, CaseIterable {
    case main
    case more
    case effects
    case modulation
    case controllers
#if !OBERVAVE_AU
    case sequencer
#endif

    var title: String {
        switch self {
        case .main: "OB-1"
        case .more: "MORE"
        case .effects: "EFFECTS"
        case .modulation: "LFO / MOD"
        case .controllers: "CONTROLLERS"
#if !OBERVAVE_AU
        case .sequencer: "SEQ"
#endif
        }
    }

    var icon: String {
        switch self {
        case .main: "slider.horizontal.3"
        case .more: "ellipsis.circle"
        case .effects: "waveform"
        case .modulation: "point.3.connected.trianglepath.dotted"
        case .controllers: "dial.medium"
#if !OBERVAVE_AU
        case .sequencer: "square.grid.3x3"
#endif
        }
    }
}

#if !OBERVAVE_AU
@MainActor
final class OberVaveModel: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var bank = 0
    @Published var program = 17
    @Published var parameterValues: [Int] = []
    @Published var arpSelectedMode = 1
    @Published var latchSelectedMode = 2
    @Published var ccAssignments: [Int] = []
    @Published var midiMappingMode = false
    @Published private(set) var learningParameter: SynthParameter?
    @Published private(set) var mappingStatus: String?
    @Published var presetRevision = 0
    @Published var instruments: [RackInstrument] = []
    @Published var selectedSlot = 0
    @Published var sceneName = "Untitled Scene"
    @Published var savedScenes: [SavedRackScene] = []
    @Published var sceneStatus: String?
    @Published var pendingSceneName: String?
    @Published var keyboardChannelMask: UInt32 = 1
    @Published var keyboardLock = KeyboardLockState()
    @Published var patterns: [SequencerPattern] = [] {
        didSet {
            let previous = Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id, $0) })
            noteLayouts = Dictionary(uniqueKeysWithValues: patterns.map { pattern in
                (pattern.id, previous[pattern.id] == pattern
                    ? noteLayouts[pattern.id] ?? CircularNoteLayout(pattern) : CircularNoteLayout(pattern))
            })
        }
    }
    private(set) var noteLayouts: [Int: CircularNoteLayout] = [:]
    @Published var pendingPatternTransfer: PendingPatternTransfer?
    var patternTransferToken: UInt64 = 0
    @Published var sequencerInteractionEpoch: UInt64 = 0
    @Published var soloSlots: Set<Int> = []
    @Published var sequencerRevision = 0
    @Published var launchGrid = 2
    @Published var recordingPattern: Int?
    @Published var recordMode = SequencerRecordMode.waitForNote
    @Published var recordCountBars = 1
    @Published var recordOutput = true
    var keyboardStopGeneration: UInt32 = 0
    var sceneFileURL: URL?
    var pendingSceneURL: URL?
    let sceneSaveMonitor = SceneSaveMonitor()
    @Published var midiSourceCount = 0
    @Published var midiSourceNames: [String] = []
    @Published fileprivate var bluetoothDevices: [BluetoothMIDIDevice] = []
    @Published var bluetoothState = CBManagerState.unknown
    @Published var isScanningBluetoothMIDI = false
    @Published var errorMessage: String?
    @Published var tempo = 120
    @Published private(set) var isMIDIClockActive = false
    @Published var isArpSyncEnabled = false
    @Published var arpSyncGrid = 2
    @Published private(set) var bleMidiBufferMilliseconds = 20
    @Published private(set) var masterLevelDB = 0.0
    @Published private(set) var masterPan = 0.0
    @Published private(set) var audioOutputName = "Not connected"
    @Published private(set) var audioOutputFormat = ""
    @Published private(set) var arpLatencyAuto = true
    @Published private(set) var arpLatencyManualMS = 0.0
    @Published private(set) var audioLatencyEstimateMS = 0.0
    @Published private(set) var isAudioRunning = false
    @Published private(set) var sustainInverted = false
    @Published private(set) var sustainStopGesture = false
    @Published private(set) var sustainInput: UInt32 = 0
    @Published private(set) var sustainDownChannels: UInt32 = 0

    var sustainInputDescription: String {
        guard sustainInput & 0x10000 != 0 else { return "No CC64 received" }
        let value = Int(sustainInput & 127)
        let channel = Int((sustainInput >> 8) & 15) + 1
        let down = sustainDownChannels & (1 << (channel - 1)) != 0
        return "CH \(channel) · CC64 \(value) · \(down ? "DOWN" : "UP")"
    }

    func setSustainInverted(_ inverted: Bool) {
        sustainInverted = inverted
        ov_set_sustain_inverted(inverted ? 1 : 0)
        UserDefaults.standard.set(inverted, forKey: "sustain-inverted")
    }

    func refreshSustainInput() {
        let latest = ov_sustain_input()
        if latest != sustainInput { sustainInput = latest }
        let channels = ov_sustain_down_channels()
        if channels != sustainDownChannels { sustainDownChannels = channels }
    }

    func setSustainStopGesture(_ enabled: Bool) {
        sustainStopGesture = enabled
        ov_set_sustain_stop_gesture(enabled ? 1 : 0)
        UserDefaults.standard.set(enabled, forKey: "sustain-stop-gesture")
    }

    let programNames: [String]
    private let defaultCCAssignments: [Int]
    private var audioEngine = AVAudioEngine()
    private var audioNotifications = Set<AnyCancellable>()
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var audioInterrupted = false
    private let presetLibraryKey = "io.github.joakimeriksson.obervave.preset-library"
    private let arpSyncKey = "io.github.joakimeriksson.obervave.arp-master-sync"
    private let arpSyncGridKey = "io.github.joakimeriksson.obervave.arp-master-sync-grid"
    private let bleMidiBufferKey = "io.github.joakimeriksson.obervave.ble-midi-buffer-ms"
    private var presetLibrary = PresetLibrary()
    private let screenWakeTimeout: TimeInterval = 120
    private var lastTempoTap: TimeInterval?
    private var tapTempoIntervalSum: TimeInterval = 0
    private var tapTempoIntervalCount = 0
    private var screenWakeWorkItem: DispatchWorkItem?
    private var centralManager: CBCentralManager!
    private var midiClient = MIDIClientRef()
    private var midiInput = MIDIPortRef()
    private var connectedSources: [MIDIEndpointRef: UInt32] = [:]
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheralNames: [UUID: String] = [:]
    private var connectingPeripherals = Set<UUID>()
    private var connectedBluetoothPeripherals = Set<UUID>()
    private var bluetoothMIDICharacteristics: [UUID: CBCharacteristic] = [:]
    private var bleMIDIParsers: [UUID: BLEMIDINoteParser] = [:]
    private var bluetoothSourceIDs: [UUID: UInt32] = [:]
    private var midiConnectionErrors: [String] = []
    private let bluetoothMIDIService = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    private let bluetoothMIDICharacteristic = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

    override init() {
        ov_init()
        let arpSyncEnabled = UserDefaults.standard.bool(forKey: arpSyncKey)
        ov_set_arp_sync(arpSyncEnabled ? 1 : 0)
        isArpSyncEnabled = arpSyncEnabled
        let savedGrid = UserDefaults.standard.object(forKey: arpSyncGridKey) as? Int ?? 2
        let configuredGrid = min(5, max(0, savedGrid))
        arpSyncGrid = configuredGrid
        ov_set_arp_sync_grid(UInt32(configuredGrid))
        let savedBuffer = UserDefaults.standard.object(forKey: bleMidiBufferKey) as? Int ?? 20
        let configuredBuffer = min(50, max(0, savedBuffer))
        bleMidiBufferMilliseconds = configuredBuffer
        ov_set_ble_midi_buffer_ms(UInt32(configuredBuffer))
        parameterValues = (0..<Int(ov_parameter_count())).map {
            Int(ov_parameter_value(UInt32($0)))
        }
        programNames = (0..<Int(ov_program_count())).map {
            String(cString: ov_program_name(UInt32($0)))
        }
        defaultCCAssignments = (0..<Int(ov_parameter_count())).map {
            let cc = Int(ov_parameter_cc(UInt32($0)))
            return cc == 255 ? -1 : cc
        }
        super.init()
        sustainInverted = UserDefaults.standard.bool(forKey: "sustain-inverted")
        ov_set_sustain_inverted(sustainInverted ? 1 : 0)
        sustainStopGesture = UserDefaults.standard.bool(forKey: "sustain-stop-gesture")
        ov_set_sustain_stop_gesture(sustainStopGesture ? 1 : 0)
        arpLatencyAuto = UserDefaults.standard.object(forKey: "arp-latency-auto") as? Bool ?? true
        let manual = UserDefaults.standard.double(forKey: "arp-latency-manual-ms")
        arpLatencyManualMS = manual.isFinite ? min(500, max(-500, manual)) : 0
        loadPresetLibrary()
        ccAssignments = defaultCCAssignments
        applyPresetData(for: selectedPresetIndex)
        instruments = [.oberVave(slot: 0, channel: 1)]
        rememberSelectedInstrument()
        startAudio()
        observeAudioChanges()
        startMIDI()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func selectPreviousProgram() {
        selectProgram((program + 127) % 128)
    }

    func selectNextProgram() {
        selectProgram((program + 1) % 128)
    }

    private var selectedPresetIndex: Int { bank * 128 + program }

    func selectProgram(_ number: Int) {
        selectPreset(bank: bank, program: number)
    }

    func selectBank(_ number: Int) {
        selectPreset(bank: number, program: program)
    }

    private func selectPreset(bank newBank: Int, program newProgram: Int, notifyCore: Bool = true) {
        guard (0..<6).contains(newBank), (0..<128).contains(newProgram) else { return }
        let changed = bank != newBank || program != newProgram
        guard changed || notifyCore else { return }
        bank = newBank
        program = newProgram
        let index = selectedPresetIndex
        if notifyCore {
            ov_select_program(UInt32(index))
        }
        applyPresetData(for: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshParameterValues()
        }
    }

    func presetName(bank: Int, program: Int) -> String {
        guard (0..<6).contains(bank), (0..<128).contains(program) else { return "INIT" }
        let key = presetKey(bank: bank, program: program)
        return presetLibrary.presets[key]?.name ?? programNames[bank * 128 + program]
    }

    @discardableResult
    func savePreset(bank: Int, program: Int, name: String) -> Bool {
        guard (0..<6).contains(bank), (0..<128).contains(program) else { return false }
        let values = (0..<Int(ov_parameter_count())).map {
            Int(ov_parameter_value(UInt32($0)))
        }
        guard values.count == Int(ov_parameter_count()) else {
            errorMessage = "Preset parameters are not ready to save."
            return false
        }
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
        guard !cleanName.isEmpty else {
            errorMessage = "Enter a preset name."
            return false
        }
        let key = presetKey(bank: bank, program: program)
        var updatedLibrary = presetLibrary
        updatedLibrary.presets[key] = StoredPreset(name: cleanName, parameters: values,
            ccAssignments: ccAssignments, arpSelectedMode: performanceMode(.arpMode),
            latchSelectedMode: performanceMode(.arpLatch))
        updatedLibrary.ccMappings[key] = ccAssignments
        guard persistPresetLibrary(updatedLibrary) else { return false }
        presetRevision &+= 1
        selectPreset(bank: bank, program: program)
        return true
    }

    func slotHasPreset(bank: Int, program: Int) -> Bool {
        guard (0..<6).contains(bank), (0..<128).contains(program) else { return false }
        return presetLibrary.presets[presetKey(bank: bank, program: program)] != nil ||
            (bank == 0 && program < 70)
    }

    func restoreCurrentPresetDefaults() {
        let key = presetKey(bank: bank, program: program)
        var updatedLibrary = presetLibrary
        updatedLibrary.presets.removeValue(forKey: key)
        updatedLibrary.ccMappings.removeValue(forKey: key)
        guard persistPresetLibrary(updatedLibrary) else { return }
        selectPreset(bank: bank, program: program)
        presetRevision &+= 1
    }

    func handleMappingTap(_ parameter: SynthParameter, count: Int) {
        guard midiMappingMode else { return }
        switch count {
        case 1:
            if learningParameter == parameter {
                learningParameter = nil
                ov_set_midi_learn(-1)
                mappingStatus = "CC learn cancelled"
            } else {
                learningParameter = parameter
                ov_set_midi_learn(Int32(parameter.rawValue))
                mappingStatus = "Waiting for CC for parameter \(parameter.rawValue + 1)"
            }
        case 2:
            learningParameter = nil
            ov_set_midi_learn(-1)
            if setCC(parameter, value: defaultCCAssignments[parameter.rawValue]) {
                mappingStatus = "Restored default CC"
            }
        case 3:
            learningParameter = nil
            ov_set_midi_learn(-1)
            if setCC(parameter, value: -1) {
                mappingStatus = "CC assignment removed"
            }
        default:
            break
        }
    }

    func cancelMidiLearn() {
        learningParameter = nil
        ov_set_midi_learn(-1)
        mappingStatus = nil
    }

    @discardableResult
    func setCC(_ parameter: SynthParameter, value: Int) -> Bool {
        guard ccAssignments.indices.contains(parameter.rawValue), (-1...127).contains(value) else { return false }
        let parameterIndex = parameter.rawValue
        var updatedAssignments = ccAssignments
        updatedAssignments[parameterIndex] = value
        var updatedLibrary = presetLibrary
        updatedLibrary.ccMappings[presetKey(bank: bank, program: program)] = updatedAssignments
        guard persistPresetLibrary(updatedLibrary) else { return false }
        learningParameter = nil
        ov_set_midi_learn(-1)
        ov_set_parameter_cc(UInt32(parameterIndex), UInt32(value < 0 ? 255 : value))
        ccAssignments = updatedAssignments
        return true
    }

    func noteOn(_ note: UInt32) {
        recordMIDIActivity()
        ov_note_on(note, 100)
    }

    func noteOff(_ note: UInt32) {
        recordMIDIActivity()
        ov_note_off(note)
    }

    var lockedKeyboardNotes: Set<UInt32> { keyboardLock.notes(on: keyboardChannelMask) }

    func releaseLockedKey(_ note: UInt32, channels: UInt32? = nil) {
        let released = keyboardLock.release(note, channels: channels ?? keyboardChannelMask)
        if released != 0 { ov_keyboard_note_off(note, released); recordMIDIActivity() }
    }

    func releaseLockedKeys(channels: UInt32) {
        for note in keyboardLock.notes(on: channels) {
            releaseLockedKey(note, channels: channels)
        }
    }

    func toggleKeyLock() {
        if keyboardLock.enabled {
            releaseLockedKeys(channels: 0xFFFF)
        }
        keyboardLock.enabled.toggle()
    }

    func setPitchBend(_ value: Int) {
        let bend = min(8191, max(-8192, value)) + 8192
        ov_keyboard_control(0xE0, UInt32(bend & 0x7F), UInt32((bend >> 7) & 0x7F))
        recordMIDIActivity()
    }

    func setModWheel(_ value: Int) {
        ov_keyboard_control(0xB0, 1, UInt32(min(127, max(0, value))))
        recordMIDIActivity()
    }

    func allNotesOff() {
        keyboardLock.clear()
        ov_all_notes_off()
    }

    func stopAllPlayback() {
        keyboardLock.clear()
        if ov_rack_stop_all() == 0 {
            errorMessage = "The transport stop queue overflowed. Notes will be stopped to prevent stuck notes."
        }
    }

    func parameterValue(_ parameter: SynthParameter) -> Int {
        guard parameter.rawValue < parameterValues.count else { return 0 }
        return parameterValues[parameter.rawValue]
    }

    func parameterMax(_ parameter: SynthParameter) -> Int {
        Int(ov_parameter_max(UInt32(parameter.rawValue)))
    }

    func setParameter(_ parameter: SynthParameter, value: Int) {
        recordMIDIActivity()
        let value = min(parameterMax(parameter), max(0, value))
        ov_set_parameter(UInt32(parameter.rawValue), UInt32(value))
        guard parameter.rawValue < parameterValues.count else { return }
        parameterValues[parameter.rawValue] = value
        rememberPerformanceMode(parameter, value: value)
        rememberSelectedInstrument()
    }

    var controllerContext: Int { selectedSlot }
    func armControllerLearn(_ armed: Bool) { ov_controller_learn(armed ? 1 : 0) }
    func takeControllerLearn() -> Int { Int(ov_controller_learned()) }

    func performanceMode(_ parameter: SynthParameter) -> Int {
        let current = parameterValue(parameter)
        return current > 0 ? current : parameter == .arpMode ? arpSelectedMode : latchSelectedMode
    }

    private func rememberPerformanceMode(_ parameter: SynthParameter, value: Int) {
        guard value > 0 else { return }
        if parameter == .arpMode { arpSelectedMode = value }
        if parameter == .arpLatch { latchSelectedMode = value }
    }

    func selectPerformanceMode(_ parameter: SynthParameter, value: Int) {
        let selected = min(parameterMax(parameter), max(1, value))
        rememberPerformanceMode(parameter, value: selected)
        if parameterValue(parameter) != 0 { setParameter(parameter, value: selected) }
        rememberSelectedInstrument()
    }

    func togglePerformance(_ parameter: SynthParameter) {
        setParameter(parameter, value: parameterValue(parameter) == 0 ? performanceMode(parameter) : 0)
    }

    func setTempo(_ bpm: Int) {
        guard !isMIDIClockActive else { return }
        let tempo = min(240, max(40, bpm))
        ov_set_tempo(UInt32(tempo))
        self.tempo = tempo
        recordMIDIActivity()
    }

    func setArpSyncEnabled(_ enabled: Bool) {
        ov_set_arp_sync(enabled ? 1 : 0)
        if selectedSlot == 0 { UserDefaults.standard.set(enabled, forKey: arpSyncKey) }
        isArpSyncEnabled = enabled
        rememberSelectedInstrument()
        recordMIDIActivity()
    }

    func setArpSyncGrid(_ grid: Int) {
        guard (0...5).contains(grid) else { return }
        ov_set_arp_sync_grid(UInt32(grid))
        if selectedSlot == 0 { UserDefaults.standard.set(grid, forKey: arpSyncGridKey) }
        arpSyncGrid = grid
        rememberSelectedInstrument()
        recordMIDIActivity()
    }

    func setBLEMIDIBufferMilliseconds(_ milliseconds: Int) {
        let value = min(50, max(0, milliseconds))
        ov_set_ble_midi_buffer_ms(UInt32(value))
        UserDefaults.standard.set(value, forKey: bleMidiBufferKey)
        bleMidiBufferMilliseconds = value
        recordMIDIActivity()
    }

    func setMasterLevelDB(_ decibels: Double) {
        let level = min(0, max(-48, decibels))
        audioEngine.mainMixerNode.outputVolume = level <= -48 ? 0 : Float(pow(10, level / 20))
        masterLevelDB = level
        recordMIDIActivity()
    }

    func setMasterPan(_ pan: Double) {
        let value = min(1, max(-1, pan))
        ov_set_master_pan(Float(value))
        masterPan = value
        recordMIDIActivity()
    }

    func tapTempo() {
        guard !isMIDIClockActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTempoTap {
            let interval = now - lastTempoTap
            if interval > 2.0 {
                tapTempoIntervalSum = 0
                tapTempoIntervalCount = 0
            } else if (60.0 / 240.0)...(60.0 / 40.0) ~= interval {
                tapTempoIntervalSum += interval
                tapTempoIntervalCount += 1
                setTempo(Int((60.0 * Double(tapTempoIntervalCount) / tapTempoIntervalSum).rounded()))
            } else {
                tapTempoIntervalSum = 0
                tapTempoIntervalCount = 0
            }
        }
        lastTempoTap = now
        recordMIDIActivity()
    }

    func recordMIDIActivity() {
        UIApplication.shared.isIdleTimerDisabled = true
        screenWakeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            UIApplication.shared.isIdleTimerDisabled = false
            self?.screenWakeWorkItem = nil
        }
        screenWakeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + screenWakeTimeout, execute: workItem)
    }

    func stopPreventingScreenSleep() {
        screenWakeWorkItem?.cancel()
        screenWakeWorkItem = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func refreshParameterValues() {
        syncRackState()
        let currentTempo = Int(ov_tempo())
        if currentTempo != tempo { tempo = currentTempo }
        let clockActive = ov_midi_clock_active() != 0
        if clockActive != isMIDIClockActive { isMIDIClockActive = clockActive }
        guard !instruments.isEmpty else { return }
        let currentPresetIndex = Int(ov_current_program())
        if (0..<768).contains(currentPresetIndex), currentPresetIndex != selectedPresetIndex {
            selectPreset(
                bank: currentPresetIndex / 128,
                program: currentPresetIndex % 128,
                notifyCore: false
            )
        }
        let current = (0..<Int(ov_parameter_count())).map {
            Int(ov_parameter_value(UInt32($0)))
        }
        if current != parameterValues {
            parameterValues = current
        }
        rememberPerformanceMode(.arpMode, value: parameterValue(.arpMode))
        rememberPerformanceMode(.arpLatch, value: parameterValue(.arpLatch))
        let currentCCs = (0..<Int(ov_parameter_count())).map {
            let cc = Int(ov_parameter_cc(UInt32($0)))
            return cc == 255 ? -1 : cc
        }
        if currentCCs != ccAssignments {
            ccAssignments = currentCCs
        }
        let learned = ov_take_midi_learn_result()
        if learned != 0 {
            let parameterIndex = Int((learned >> 8) - 1)
            let cc = Int((learned & 0xFF) - 1)
            if let parameter = SynthParameter(rawValue: parameterIndex) {
                if setCC(parameter, value: cc) {
                    mappingStatus = "Learned CC \(cc) for parameter \(parameter.rawValue + 1)"
                }
            }
        }
    }

    private func presetKey(bank: Int, program: Int) -> String {
        "\(bank).\(program)"
    }

    private func loadPresetLibrary() {
        guard let data = UserDefaults.standard.data(forKey: presetLibraryKey) else { return }
        do {
            presetLibrary = try JSONDecoder().decode(PresetLibrary.self, from: data)
        } catch {
            errorMessage = "Could not load saved presets: \(error.localizedDescription)"
        }
    }

    private func persistPresetLibrary(_ updatedLibrary: PresetLibrary) -> Bool {
        do {
            let data = try JSONEncoder().encode(updatedLibrary)
            UserDefaults.standard.set(data, forKey: presetLibraryKey)
            presetLibrary = updatedLibrary
            return true
        } catch {
            errorMessage = "Could not save presets: \(error.localizedDescription)"
            return false
        }
    }

    func applyPresetData(for index: Int) {
        let bank = index / 128
        let program = index % 128
        let key = presetKey(bank: bank, program: program)
        ov_reset_parameter_ccs()
        arpSelectedMode = min(8, max(1, presetLibrary.presets[key]?.arpSelectedMode ?? 1))
        latchSelectedMode = min(2, max(1, presetLibrary.presets[key]?.latchSelectedMode ?? 2))
        if let preset = presetLibrary.presets[key] {
            for (parameter, value) in preset.parameters.enumerated()
                where parameter < Int(ov_parameter_count()) {
                ov_set_parameter(UInt32(parameter), UInt32(value))
            }
        }
        let savedMappings = presetLibrary.ccMappings[key] ??
            presetLibrary.presets[key]?.ccAssignments ??
            defaultCCAssignments
        let mappings = ModulationMatrix.migrateLegacy(savedMappings, defaults: defaultCCAssignments)
        ccAssignments = mappings
        for (parameter, cc) in mappings.enumerated() where parameter < defaultCCAssignments.count {
            if cc != defaultCCAssignments[parameter] {
                ov_set_parameter_cc(UInt32(parameter), UInt32(cc < 0 ? 255 : cc))
            }
        }
    }

    func refreshMIDISources() {
        let count = MIDIGetNumberOfSources()
        var currentSources = Set<MIDIEndpointRef>()
        var sourceNames: [String] = []
        midiConnectionErrors.removeAll(keepingCapacity: true)
        for index in 0..<count {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            currentSources.insert(source)
            sourceNames.append(midiDeviceName(for: source) ?? "MIDI input \(index + 1)")
            guard connectedSources[source] == nil else { continue }
            let sourceID = ov_midi_source_open()
            guard sourceID != 0 else {
                midiConnectionErrors.append("\(sourceNames.last ?? "MIDI input"): input capacity exhausted")
                errorMessage = "Could not allocate MIDI input state."
                continue
            }
            let status = MIDIPortConnectSource(midiInput, source, UnsafeMutableRawPointer(bitPattern: UInt(sourceID)))
            if status != noErr {
                _ = ov_midi_source_close(sourceID)
                midiConnectionErrors.append("\(sourceNames.last ?? "MIDI input"): \(status)")
                errorMessage = "Could not connect MIDI source (\(status))."
            } else {
                connectedSources[source] = sourceID
            }
        }
        for source in Set(connectedSources.keys).subtracting(currentSources) {
            let status = MIDIPortDisconnectSource(midiInput, source)
            if status == noErr {
                if let sourceID = connectedSources.removeValue(forKey: source) {
                    _ = ov_midi_source_close(sourceID)
                }
            } else {
                errorMessage = "Could not disconnect MIDI source (\(status))."
            }
        }
        midiSourceCount = connectedSources.count + connectedBluetoothPeripherals.count
        let bluetoothNames = connectedBluetoothPeripherals.compactMap { peripheralNames[$0] }
            .map { "\($0) (Bluetooth MIDI)" }
        midiSourceNames = (sourceNames + bluetoothNames)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func toggleBluetoothMIDIScan() {
        guard bluetoothState == .poweredOn else {
            errorMessage = "Turn on Bluetooth in Settings to find MIDI devices."
            return
        }
        if isScanningBluetoothMIDI {
            centralManager.stopScan()
            isScanningBluetoothMIDI = false
        } else {
            centralManager.scanForPeripherals(
                withServices: [bluetoothMIDIService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            isScanningBluetoothMIDI = true
        }
    }

    func connectBluetoothMIDI(_ id: UUID) {
        guard let peripheral = discoveredPeripherals[id] else { return }
        guard !connectedBluetoothPeripherals.contains(id), !connectingPeripherals.contains(id) else { return }
        connectingPeripherals.insert(id)
        updateBluetoothDevice(peripheral)
        centralManager.connect(peripheral)
    }

    func disconnectBluetoothMIDI(_ id: UUID) {
        guard let peripheral = discoveredPeripherals[id] else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state != .poweredOn {
            isScanningBluetoothMIDI = false
            for sourceID in bluetoothSourceIDs.values {
                _ = ov_midi_source_close(sourceID)
            }
            bluetoothSourceIDs.removeAll()
            bleMIDIParsers.removeAll()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        if let name {
            peripheralNames[peripheral.identifier] = name
        }
        updateBluetoothDevice(peripheral, advertisedName: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([bluetoothMIDIService])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failBluetoothMIDISetup(for: peripheral, message: "Could not discover Bluetooth MIDI service: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == bluetoothMIDIService }) else {
            failBluetoothMIDISetup(for: peripheral, message: "The device does not expose the Bluetooth MIDI service.")
            return
        }
        peripheral.discoverCharacteristics([bluetoothMIDICharacteristic], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            failBluetoothMIDISetup(for: peripheral, message: "Could not discover Bluetooth MIDI I/O: \(error.localizedDescription)")
            return
        }
        guard service.uuid == bluetoothMIDIService,
              let characteristic = service.characteristics?.first(where: { $0.uuid == bluetoothMIDICharacteristic }),
              characteristic.properties.contains(.notify) else {
            failBluetoothMIDISetup(for: peripheral, message: "The device is missing the Bluetooth MIDI I/O characteristic required for MIDI input.")
            return
        }
        bluetoothMIDICharacteristics[peripheral.identifier] = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == bluetoothMIDICharacteristic else { return }
        if let error {
            failBluetoothMIDISetup(for: peripheral, message: "Could not enable MIDI notifications: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            failBluetoothMIDISetup(for: peripheral, message: "The device refused MIDI input notifications.")
            return
        }
        if bluetoothSourceIDs[peripheral.identifier] == nil {
            let sourceID = ov_midi_source_open()
            guard sourceID != 0 else {
                failBluetoothMIDISetup(for: peripheral, message: "Could not allocate MIDI input state.")
                return
            }
            bluetoothSourceIDs[peripheral.identifier] = sourceID
        }
        connectingPeripherals.remove(peripheral.identifier)
        connectedBluetoothPeripherals.insert(peripheral.identifier)
        bleMIDIParsers[peripheral.identifier] = BLEMIDINoteParser()
        updateBluetoothDevice(peripheral)
        refreshMIDISources()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == bluetoothMIDICharacteristic else { return }
        if let error {
            errorMessage = "Could not receive Bluetooth MIDI data: \(error.localizedDescription)"
            return
        }
        guard let packet = characteristic.value,
              let sourceID = bluetoothSourceIDs[peripheral.identifier] else { return }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        var parser = bleMIDIParsers[peripheral.identifier] ?? BLEMIDINoteParser()
        let messages = parser.consume(packet, receivedAt: receivedAt)
        bleMIDIParsers[peripheral.identifier] = parser
        if !messages.isEmpty {
            recordMIDIActivity()
        }
        let baseFrame = ov_audio_frame()
        let buffer = Double(ov_ble_midi_buffer_ms()) / 1000
        for message in messages {
            let delay = max(0, message.hostTime + buffer - receivedAt)
            let frame = baseFrame &+ UInt32((delay * 44_100).rounded())
            _ = ov_midi_source_message_at(
                sourceID,
                UInt32(message.status),
                UInt32(message.data1),
                UInt32(message.data2),
                frame
            )
        }
    }

    private func failBluetoothMIDISetup(for peripheral: CBPeripheral, message: String) {
        connectingPeripherals.remove(peripheral.identifier)
        bluetoothMIDICharacteristics.removeValue(forKey: peripheral.identifier)
        bleMIDIParsers.removeValue(forKey: peripheral.identifier)
        if let sourceID = bluetoothSourceIDs.removeValue(forKey: peripheral.identifier) {
            _ = ov_midi_source_close(sourceID)
        }
        updateBluetoothDevice(peripheral)
        errorMessage = "\(peripheralNames[peripheral.identifier] ?? "Bluetooth device"): \(message)"
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectingPeripherals.remove(peripheral.identifier)
        updateBluetoothDevice(peripheral)
        errorMessage = "Could not connect to \(peripheral.name ?? "Bluetooth MIDI device"): \(error?.localizedDescription ?? "unknown error")."
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectingPeripherals.remove(peripheral.identifier)
        connectedBluetoothPeripherals.remove(peripheral.identifier)
        bluetoothMIDICharacteristics.removeValue(forKey: peripheral.identifier)
        bleMIDIParsers.removeValue(forKey: peripheral.identifier)
        if let sourceID = bluetoothSourceIDs.removeValue(forKey: peripheral.identifier) {
            _ = ov_midi_source_close(sourceID)
        }
        updateBluetoothDevice(peripheral)
        refreshMIDISources()
    }

    private func midiDeviceName(for source: MIDIEndpointRef) -> String? {
        var entity = MIDIEntityRef()
        guard MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0 else {
            return midiObjectName(source)
        }
        var device = MIDIDeviceRef()
        guard MIDIEntityGetDevice(entity, &device) == noErr, device != 0 else {
            return midiObjectName(source)
        }
        return midiObjectName(device) ?? midiObjectName(source)
    }

    private func midiObjectName(_ object: MIDIObjectRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyName, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private func updateBluetoothDevice(_ peripheral: CBPeripheral, advertisedName: String? = nil) {
        let id = peripheral.identifier
        let name = advertisedName ?? peripheralNames[id] ?? peripheral.name ?? "Bluetooth MIDI device"
        let device = BluetoothMIDIDevice(
            id: id,
            name: name,
            isConnecting: connectingPeripherals.contains(id),
            isConnected: connectedBluetoothPeripherals.contains(id)
        )
        if let index = bluetoothDevices.firstIndex(where: { $0.id == id }) {
            bluetoothDevices[index] = device
        } else {
            bluetoothDevices.append(device)
            bluetoothDevices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(44_100)
            try session.setActive(true)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 2,
                interleaved: false
            )!
            let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count >= 2,
                      let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                    return kAudio_ParamError
                }
                ov_render(left, right, frameCount)
                return noErr
            }
            audioEngine.attach(source)
            audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
            audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
                guard let channels = buffer.floatChannelData, buffer.format.channelCount >= 2 else { return }
                var leftPeak: Float = 0
                var rightPeak: Float = 0
                for frame in 0..<Int(buffer.frameLength) {
                    leftPeak = max(leftPeak, abs(channels[0][frame]))
                    rightPeak = max(rightPeak, abs(channels[1][frame]))
                }
                ov_set_output_meter(leftPeak, rightPeak)
            }
            audioEngine.mainMixerNode.outputVolume = masterLevelDB <= -48
                ? 0 : Float(pow(10, masterLevelDB / 20))
            try audioEngine.start()
        } catch {
            errorMessage = "Could not start audio: \(error.localizedDescription)"
        }
        refreshAudioStatus()
    }

    func refreshAudioStatus() {
        let session = AVAudioSession.sharedInstance()
        audioOutputName = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        if audioOutputName.isEmpty { audioOutputName = "Not connected" }
        audioOutputFormat = "\(Int(session.sampleRate)) Hz · \(session.outputNumberOfChannels) ch"
        isAudioRunning = audioEngine.isRunning
        let estimate = (session.outputLatency + session.ioBufferDuration) * 1000
        guard estimate.isFinite, estimate >= 0, estimate <= 1500 else {
            errorMessage = "The audio output reported an invalid latency estimate."
            return
        }
        audioLatencyEstimateMS = estimate
        updateArpLatency()
    }

    var arpLatencyTotalMS: Double {
        (arpLatencyAuto ? audioLatencyEstimateMS : 0) + arpLatencyManualMS
    }

    func setArpLatencyAuto(_ enabled: Bool) {
        arpLatencyAuto = enabled
        UserDefaults.standard.set(enabled, forKey: "arp-latency-auto")
        updateArpLatency()
    }

    func setArpLatencyManualMS(_ value: Double) {
        guard value.isFinite else { errorMessage = "Enter a finite latency in milliseconds."; return }
        arpLatencyManualMS = min(500, max(-500, value))
        UserDefaults.standard.set(arpLatencyManualMS, forKey: "arp-latency-manual-ms")
        updateArpLatency()
    }

    private func updateArpLatency() {
        ov_set_arp_audio_latency_ms(Float(arpLatencyTotalMS))
    }

    private func observeAudioChanges() {
        let notifications = NotificationCenter.default
        notifications.publisher(for: AVAudioSession.routeChangeNotification)
            .merge(with: notifications.publisher(for: .AVAudioEngineConfigurationChange))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleAudioRecovery()
                }
            }
            .store(in: &audioNotifications)
        notifications.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor [weak self] in
                    guard let self, let type,
                          let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
                    if interruption == .began {
                        self.audioInterrupted = true
                        self.audioRecoveryWorkItem?.cancel()
                        self.audioEngine.pause()
                        self.allNotesOff()
                        self.refreshAudioStatus()
                    } else {
                        self.audioInterrupted = false
                        if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                            self.scheduleAudioRecovery()
                        }
                    }
                }
            }
            .store(in: &audioNotifications)
        notifications.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.audioRecoveryWorkItem?.cancel()
                    self.audioInterrupted = false
                    self.audioEngine = AVAudioEngine()
                    self.startAudio()
                }
            }
            .store(in: &audioNotifications)
    }

    private func scheduleAudioRecovery() {
        audioRecoveryWorkItem?.cancel()
        refreshAudioStatus()
        guard !audioInterrupted else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.resumeAudio()
        }
        audioRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    func resumeAudio() {
        guard !audioInterrupted else { return }
        do {
            if !audioEngine.isRunning {
                try AVAudioSession.sharedInstance().setActive(true)
                audioEngine.prepare()
                try audioEngine.start()
            }
        } catch {
            errorMessage = "Could not resume audio after a device change: \(error.localizedDescription)"
        }
        refreshAudioStatus()
    }

    private func startMIDI() {
        let clientStatus = MIDIClientCreateWithBlock("OberVave" as CFString, &midiClient) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshMIDISources()
            }
        }
        guard clientStatus == noErr else {
            errorMessage = "Could not create MIDI client (\(clientStatus))."
            return
        }
        let portStatus = MIDIInputPortCreateWithBlock(
            midiClient,
            "OberVave MIDI In" as CFString,
            &midiInput,
            { [weak self] packetList, connectionContext in
                guard let connectionContext else { return }
                let sourceID = UInt32(UInt(bitPattern: connectionContext))
                if packetList.pointee.numPackets > 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.recordMIDIActivity()
                    }
                }
                consumeMIDIPacketList(packetList, sourceID: sourceID)
            }
        )
        guard portStatus == noErr else {
            errorMessage = "Could not create MIDI input (\(portStatus))."
            return
        }
        refreshMIDISources()
    }
}

@MainActor
final class OutputMeterModel: ObservableObject {
    @Published private(set) var left = 0.0
    @Published private(set) var right = 0.0
    @Published private(set) var voiceLevels = Array(repeating: 0.0, count: 8)

    func refresh() {
        let packed = ov_take_output_meter()
        let nextLeft = Double(packed & 0xFFFF) / 65535
        let nextRight = Double((packed >> 16) & 0xFFFF) / 65535
        left = max(nextLeft, left * 0.78)
        right = max(nextRight, right * 0.78)

        let levels = (0..<voiceLevels.count).map {
            Double(ov_voice_level(UInt32($0))) / 32767
        }
        if levels != voiceLevels {
            voiceLevels = levels
        }
    }
}

private func consumeMIDIPacketList(_ packetList: UnsafePointer<MIDIPacketList>, sourceID: UInt32) {
    let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
    let listAddress = UnsafeRawPointer(packetList)
    let currentHostTime = mach_absolute_time()
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let baseFrame = ov_audio_frame()
    let bufferFrames = ov_ble_midi_buffer_ms() * 44_100 / 1000
    var packet = UnsafeMutablePointer<MIDIPacket>(
        mutating: listAddress.advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
    )
    for _ in 0..<packetList.pointee.numPackets {
        let length = Int(packet.pointee.length)
        let packetHostTime = packet.pointee.timeStamp
        let timestampDeltaNanos: Int64
        if packetHostTime == 0 {
            timestampDeltaNanos = 0
        } else {
            let hostTicks = Int64(packetHostTime) - Int64(currentHostTime)
            timestampDeltaNanos = Int64(
                Double(hostTicks) * Double(timebase.numer) / Double(timebase.denom)
            )
        }
        let timestampDeltaFrames = Int64(Double(timestampDeltaNanos) * 44_100 / 1_000_000_000)
        let delayFrames = min(22_050, max(0, Int64(bufferFrames) + timestampDeltaFrames))
        let targetFrame = baseFrame &+ UInt32(delayFrames)
        withUnsafeBytes(of: packet.pointee.data) { bytes in
            for byte in bytes.prefix(length) {
                _ = ov_midi_source_byte_at(sourceID, UInt32(byte), targetFrame)
            }
        }
        packet = UnsafeMutablePointer(mutating: MIDIPacketNext(packet))
    }
}

private struct ProgramMenuButton: UIViewRepresentable {
    let bank: Int
    let program: Int
    let presetRevision: Int
    let names: [String]
    let onSelect: (Int) -> Void

    fileprivate struct Snapshot: Equatable {
        let bank: Int
        let program: Int
        let presetRevision: Int
        let names: [String]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.imagePadding = 8
        configuration.imagePlacement = .trailing
        configuration.baseForegroundColor = .secondaryLabel
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            return updated
        }
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        let snapshot = Snapshot(bank: bank, program: program, presetRevision: presetRevision, names: names)
        guard coordinator.snapshot != snapshot else { return }
        coordinator.snapshot = snapshot

        guard names.indices.contains(program) else { return }
        var configuration = button.configuration ?? UIButton.Configuration.plain()
        configuration.title = String(format: "%03d  %@", program + 1, names[program])
        button.configuration = configuration
        let actions = names.enumerated().map { index, name in
            UIAction(
                title: String(format: "%03d  %@", index + 1, name),
                state: index == program ? .on : .off
            ) { [weak coordinator] _ in
                coordinator?.onSelect(index)
            }
        }
        button.menu = UIMenu(title: "BANK \(String(UnicodeScalar(65 + bank)!))", children: actions)
    }

    final class Coordinator {
        var onSelect: (Int) -> Void
        fileprivate var snapshot: Snapshot?

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
        }
    }
}

struct ContentView: View {
    @StateObject private var model = OberVaveModel()
    @StateObject private var outputMeters = OutputMeterModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedScreen = OberVaveScreen.main
    @State private var showsBluetoothMIDI = false
    @State private var showsKeyboard = false
    @State private var keyboardFirstNote = 48
    @State private var keyboardOctaveCount = 2
    @State private var showsPresetEditor = false
    @State private var createsPreset = false
    @State private var showsDefaultResetConfirmation = false
    @State private var showsRack = false

    var body: some View {
        HStack(spacing: 0) {
            RackInstanceSidebar(model: model)
        VStack(spacing: 8) {
            rackHeader
            instrumentHeader
                .disabled(model.instruments.isEmpty)

            if model.instruments.isEmpty {
                Spacer()
                Button("Add an Instrument") { showsRack = true }
                    .buttonStyle(.borderedProminent)
                Text("Create a scene with up to 16 instruments.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
              TabView(selection: $selectedScreen) {
                ForEach(OberVaveScreen.allCases, id: \.self) { screen in
                    screenContent(for: screen)
                        .tag(screen)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Synthesizer pages")
            }

            HStack(spacing: 8) {
                ForEach(OberVaveScreen.allCases, id: \.self) { screen in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedScreen = screen
                        }
                    } label: {
                        Label(screen.title, systemImage: screen.icon)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .foregroundStyle(selectedScreen == screen ? Color.black : Color.white.opacity(0.75))
                            .background(
                                selectedScreen == screen ? Color.cyan : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedScreen == screen ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        }
        .padding(.top, 10)
        .background(Color(red: 0.055, green: 0.075, blue: 0.11).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsBluetoothMIDI) {
            BluetoothMIDIView(model: model)
        }
        .sheet(isPresented: $showsRack) {
            RackSceneView(model: model)
        }
        .overlay(alignment: .bottom) {
            if showsKeyboard {
                GeometryReader { geometry in
                    TouchKeyboardView(model: model, onClose: { showsKeyboard = false },
                                      octaveCount: $keyboardOctaveCount, firstNote: $keyboardFirstNote)
                        .frame(height: min(320, max(240, geometry.size.height * 0.36)) + 40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom))
                }
                .ignoresSafeArea(edges: .bottom)
                .zIndex(1)
            }
        }
        .sheet(isPresented: $showsPresetEditor) {
            PresetSaveView(
                model: model,
                allowsSlotSelection: createsPreset,
                initialBank: model.bank,
                initialProgram: model.program,
                initialName: createsPreset ? "" : model.presetName(bank: model.bank, program: model.program)
            )
            .preferredColorScheme(.dark)
        }
        .confirmationDialog("Restore this preset's default sound and CC assignments?", isPresented: $showsDefaultResetConfirmation) {
            Button("Restore Defaults", role: .destructive) {
                model.restoreCurrentPresetDefaults()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            model.refreshParameterValues()
        }
        .onReceive(Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()) { _ in
            outputMeters.refresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.resumeAudio()
            } else {
                model.stopPreventingScreenSleep()
            }
        }
        .alert("OberVave", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var rackHeader: some View {
        HStack(spacing: 12) {
            Button { showsRack = true } label: {
                Label(model.sceneName, systemImage: "square.stack.3d.up")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            Menu {
                ForEach(model.instruments) { instrument in
                    Button("\(instrument.name) · CH \(instrument.channel)") {
                        model.selectInstrument(instrument.slot)
                    }
                }
            } label: {
                Text(model.selectedInstrument.map { "\($0.name) · CH \($0.channel)" } ?? "No Instrument")
                    .lineLimit(1)
            }
            .disabled(model.instruments.isEmpty || model.pendingSceneName != nil)
            Spacer()
            Text("\(model.instruments.count)/16")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            transportControls
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            Button(action: model.stopAllPlayback) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop all playback")
            .accessibilityHint("Releases all notes and stops all arpeggiators, preserving effect tails.")
            SynthTempoControl(model: model)
            SequencerRecordModeControl(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport")
    }

    private var instrumentHeader: some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("OB-1")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .tracking(2)
                    Text("OBERVAVE · NATIVE")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.cyan)
                }

                Menu {
                    ForEach(0..<6, id: \.self) { bank in
                        Button {
                            model.selectBank(bank)
                        } label: {
                            if bank == model.bank {
                                Label("BANK \(String(UnicodeScalar(65 + bank)!))", systemImage: "checkmark")
                            } else {
                                Text("BANK \(String(UnicodeScalar(65 + bank)!))")
                            }
                        }
                    }
                } label: {
                    Text("BANK \(String(UnicodeScalar(65 + model.bank)!))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .buttonStyle(.bordered)

                Button(action: model.selectPreviousProgram) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)

                ProgramMenuButton(
                    bank: model.bank,
                    program: model.program,
                    presetRevision: model.presetRevision,
                    names: (0..<128).map { model.presetName(bank: model.bank, program: $0) },
                    onSelect: model.selectProgram
                )
                .frame(width: 185, height: 36)

                Button(action: model.selectNextProgram) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button {
                    showsKeyboard = true
                } label: {
                    Image(systemName: "pianokeys")
                        .frame(width: 28, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("On-screen keyboard")

                Button {
                    model.refreshMIDISources()
                    showsBluetoothMIDI = true
                } label: {
                    Label("\(model.midiSourceCount)", systemImage: "dot.radiowaves.left.and.right")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("MIDI devices")
            }
            .frame(height: 40)
            .layoutPriority(1)

            HStack(spacing: 8) {
                Button {
                    createsPreset = false
                    showsPresetEditor = true
                } label: {
                    Label("SAVE", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    createsPreset = true
                    showsPresetEditor = true
                } label: {
                    Label("NEW", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    showsDefaultResetConfirmation = true
                } label: {
                    Label("DEFAULT", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    model.midiMappingMode.toggle()
                    if !model.midiMappingMode {
                        model.cancelMidiLearn()
                    }
                } label: {
                    Label("MIDI MAP", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .tint(model.midiMappingMode ? Color.cyan : Color.primary)

                Spacer(minLength: 0)
                if model.midiMappingMode {
                    Text(model.mappingStatus ?? "Tap control to learn · CC badge to assign")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.learningParameter == nil ? Color.secondary : Color.yellow)
                        .lineLimit(1)
                }
            }
            .frame(height: 36)
            .layoutPriority(1)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .frame(height: 81, alignment: .top)
    }

    @ViewBuilder
    private func screenContent(for screen: OberVaveScreen) -> some View {
        switch screen {
        case .main:
            controlScreen(
                title: "ANALOG POLYSYNTH",
                sections: SynthControlLayouts.ob1,
                minimumPanelWidth: 165,
                showsPatch: true,
                showsAMP: true
            )
        case .more:
            controlScreen(
                title: "OBERVAVE EXTENSIONS",
                sections: SynthControlLayouts.extensions,
                minimumPanelWidth: 205
            )
        case .effects:
            controlScreen(
                title: "EFFECTS",
                sections: SynthControlLayouts.effects,
                minimumPanelWidth: 205
            )
        case .modulation:
            SynthControlPanel.ModulationMatrixView(model: model)
        case .controllers:
            ControllersView(model: model)
        case .sequencer:
            SequencerView(model: model)
        }
    }

    private func controlScreen(
        title: String,
        sections: [SynthControlSection],
        minimumPanelWidth: CGFloat,
        showsPatch: Bool = false,
        showsAMP: Bool = false
    ) -> some View {
        GeometryReader { geometry in
            let horizontalInset: CGFloat = 12
            let spacing: CGFloat = 12
            let contentWidth = geometry.size.width - horizontalInset * 2
            let columnCount = max(1, Int((contentWidth + spacing) / (minimumPanelWidth + spacing)))
            let cellWidth = (contentWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let items = (showsAMP ? [ControlPanelItem.amp] : []) + sections.map(ControlPanelItem.section)
            let rows = stride(from: 0, to: items.count, by: columnCount).map { start in
                Array(items[start..<min(start + columnCount, items.count)])
            }

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.cyan).frame(width: 4)
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2)
                    Spacer()
                    if showsPatch {
                        Text("PATCH \(String(format: "%02d", model.program + 1))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 18)
                .padding(.horizontal, horizontalInset)

                ScrollView {
                    Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(row) { item in
                                    controlPanel(item)
                                        .frame(width: cellWidth)
                                        .frame(maxHeight: .infinity, alignment: .top)
                                }
                            }
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, 8)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func controlPanel(_ item: ControlPanelItem) -> some View {
        switch item {
        case .amp:
            SynthMasterOutputPanel(model: model, meters: outputMeters)
                .frame(maxHeight: .infinity, alignment: .top)
        case .section(let section):
            SynthControlPanel(section: section, model: model)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct SynthTempoControl: View {
    @ObservedObject var model: OberVaveModel
    @State private var showsTempoEditor = false
    @State private var tempoInput = "120"

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.tapTempo()
            } label: {
                Label("TAP", systemImage: "hand.tap")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(minHeight: 30)
            }
            .buttonStyle(.bordered)
            .disabled(model.isMIDIClockActive)
            .accessibilityLabel("Tap to set tempo")
            .accessibilityHint("Tap steadily at the desired tempo")

            Button {
                tempoInput = "\(model.tempo)"
                showsTempoEditor = true
            } label: {
                VStack(spacing: 1) {
                    Text("\(model.tempo)")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                    Text(model.isMIDIClockActive ? "MIDI" : "BPM")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.isMIDIClockActive ? Color.green : Color.secondary)
                }
                .foregroundStyle(.cyan)
                .frame(minWidth: 46, minHeight: 30)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsTempoEditor, arrowEdge: .bottom) {
                tempoEditor
                    .frame(width: 280, height: 190)
                    .fixedSize()
                    .padding(16)
                    .preferredColorScheme(.dark)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .frame(height: 34)
        .onChange(of: model.tempo) { tempoInput = "\($0)" }
        .zIndex(showsTempoEditor ? 2 : 0)
    }

    private var tempoEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GLOBAL TEMPO")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { Double(min(240, max(40, model.tempo))) },
                    set: { model.setTempo(Int($0.rounded())) }
                ),
                in: 40...240,
                step: 1
            )
            .tint(.cyan)
            .disabled(model.isMIDIClockActive)
            .accessibilityLabel("Global tempo")

            HStack {
                TextField("40–240", text: $tempoInput)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .disabled(model.isMIDIClockActive)
                    .onSubmit(applyTempoInput)
                Text("BPM")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set", action: applyTempoInput)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(model.isMIDIClockActive || parsedTempo == nil)
            }

            Text(model.isMIDIClockActive ? "Tempo follows incoming MIDI Clock." : "Range: 40–240 BPM")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var parsedTempo: Int? {
        guard let value = Int(tempoInput), (40...240).contains(value) else { return nil }
        return value
    }

    private func applyTempoInput() {
        guard let parsedTempo else { return }
        model.setTempo(parsedTempo)
        showsTempoEditor = false
    }
}

#endif

struct SynthMasterOutputPanel: View {
@ObservedObject var model: OberVaveModel
@ObservedObject var meters: OutputMeterModel

var body: some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.cyan)
                .frame(width: 3, height: 13)
            Text("AMP")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1)
            Spacer()
            Text(model.masterLevelDB <= -48 ? "MUTE" : "\(Int(model.masterLevelDB)) dB")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
        }

        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                MasterOutputKnob(
                    title: "VOLUME",
                    valueText: model.masterLevelDB <= -48 ? "MUTE" : "\(Int(model.masterLevelDB)) dB",
                    value: model.masterLevelDB,
                    range: -48...0,
                    color: .cyan,
                    onChange: model.setMasterLevelDB,
                    onEditingChanged: { editing in
#if OBERVAVE_AU
                        model.editOutput(pan: false, editing: editing)
#endif
                    }
                )
                MasterOutputKnob(
                    title: "PAN",
                    valueText: panText(model.masterPan),
                    value: model.masterPan,
                    range: -1...1,
                    color: .orange,
                    onChange: model.setMasterPan,
                    onEditingChanged: { editing in
#if OBERVAVE_AU
                        model.editOutput(pan: true, editing: editing)
#endif
                    }
                )

                Text("VOICES")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Grid(horizontalSpacing: 8, verticalSpacing: 5) {
                    ForEach(0..<4, id: \.self) { row in
                        GridRow {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                HStack(spacing: 4) {
                                    VoiceLevelDot(index: index, level: meters.voiceLevels[index])
                                    Text("\(index + 1)")
                                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 112, alignment: .topLeading)

            VStack(spacing: 4) {
                Text("STEREO")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 8) {
                        StereoMeterBar(label: "L", level: meters.left, height: geometry.size.height)
                        StereoMeterBar(label: "R", level: meters.right, height: geometry.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 180)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
        LinearGradient(
            colors: [Color(red: 0.13, green: 0.17, blue: 0.23), Color(red: 0.085, green: 0.11, blue: 0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(0.09), lineWidth: 1)
    }
}

private func panText(_ value: Double) -> String {
    if abs(value) < 0.05 { return "C" }
    return value < 0 ? "L \(Int(abs(value) * 100))" : "R \(Int(value * 100))"
}
}

private struct MasterOutputKnob: View {
let title: String
let valueText: String
let value: Double
let range: ClosedRange<Double>
let color: Color
let onChange: (Double) -> Void
var onEditingChanged: (Bool) -> Void = { _ in }
@State private var dragOrigin: Double?

private var progress: Double {
    (value - range.lowerBound) / (range.upperBound - range.lowerBound)
}

var body: some View {
    VStack(spacing: 4) {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 42, height: 42)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 42, height: 42)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.39, green: 0.45, blue: 0.53), Color(red: 0.12, green: 0.16, blue: 0.21)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)
                .overlay { Circle().stroke(Color.white.opacity(0.23), lineWidth: 1) }
            Capsule()
                .fill(Color.white)
                .frame(width: 2, height: 8)
                .offset(y: -11)
                .rotationEffect(.degrees(-135 + progress * 270))
        }
        .contentShape(Circle().size(width: 50, height: 50))
#if OBERVAVE_AU
        .overlay {
            AUDragSurface(
                onStart: { dragOrigin = value; onEditingChanged(true) },
                onChange: { _, translation in
                    guard let dragOrigin else { return }
                    let delta = -Double(translation.height) / 100 * (range.upperBound - range.lowerBound)
                    onChange(min(range.upperBound, max(range.lowerBound, dragOrigin + delta)))
                },
                onEnd: { dragOrigin = nil; onEditingChanged(false) }
            )
        }
#else
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragOrigin == nil { dragOrigin = value; onEditingChanged(true) }
                    guard let dragOrigin else { return }
                    let delta = -Double(gesture.translation.height) / 100 * (range.upperBound - range.lowerBound)
                    onChange(min(range.upperBound, max(range.lowerBound, dragOrigin + delta)))
                }
                .onEnded { _ in dragOrigin = nil; onEditingChanged(false) }
        )
#endif
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(valueText)

        Text(title)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
        Text(valueText)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
    .frame(width: 52)
    .onDisappear {
        if dragOrigin != nil { dragOrigin = nil; onEditingChanged(false) }
    }
}
}

private struct StereoMeterBar: View {
let label: String
let level: Double
let height: CGFloat

var body: some View {
    VStack(spacing: 3) {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.4))
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .green, location: 0),
                                .init(color: .green, location: 0.58),
                                .init(color: .yellow, location: 0.78),
                                .init(color: .red, location: 1)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: max(2, geometry.size.height * min(1, max(0, level))))
            }
        }
        .frame(width: 11, height: height)
        Text(label)
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
    }
    .accessibilityElement()
    .accessibilityLabel("Stereo output \(label)")
    .accessibilityValue("\(Int(level * 100)) percent")
}
}

private struct VoiceLevelDot: View {
let index: Int
let level: Double

private var color: Color {
    let value = min(1, max(0, level))
    if value < 0.5 {
        return Color(red: value * 2, green: 1, blue: 0)
    }
    return Color(red: 1, green: (1 - value) * 2, blue: 0)
}

var body: some View {
    Circle()
        .fill(level > 0.01 ? color : Color.white.opacity(0.2))
        .opacity(level > 0.01 ? 0.3 + min(1, level) * 0.7 : 0.35)
        .frame(width: 8, height: 8)
        .accessibilityLabel("Voice \(index + 1)")
        .accessibilityValue("\(Int(level * 100)) percent")
}
}

struct SynthControlPanel: View {
    let section: SynthControlSection
    @ObservedObject var model: OberVaveModel

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.cyan)
                    .frame(width: 3, height: 13)
                Text(section.title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Circle().fill(Color.cyan.opacity(0.75)).frame(width: 5, height: 5)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(section.controls) { control in
                    parameterControl(for: control)
                }
            }
            if section.title == "ARPEGGIATOR" {
                Toggle(
                    "MASTER SYNC",
                    isOn: Binding(
                        get: { model.isArpSyncEnabled },
                        set: { model.setArpSyncEnabled($0) }
                    )
                )
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tint(.cyan)
                Menu {
                    ForEach(Array(["1/1", "1/2", "1/4", "1/8", "1/16", "1/32"].enumerated()), id: \.offset) { index, label in
                        Button(index == model.arpSyncGrid ? "✓ \(label)" : label) {
                            model.setArpSyncGrid(index)
                        }
                    }
                } label: {
#if OBERVAVE_AU
                    Text("START GRID  \(["1/1", "1/2", "1/4", "1/8", "1/16", "1/32"][model.arpSyncGrid])")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
#else
                    HStack {
                        Text("START GRID")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.72))
                        Spacer()
                        Text(["1/1", "1/2", "1/4", "1/8", "1/16", "1/32"][model.arpSyncGrid])
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6))
#endif
                }
                .disabled(!model.isArpSyncEnabled)
                .accessibilityLabel("Arpeggiator start grid")
                .accessibilityValue(["1/1", "1/2", "1/4", "1/8", "1/16", "1/32"][model.arpSyncGrid])
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.17, blue: 0.23), Color(red: 0.085, green: 0.11, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
    }

    struct ModulationMatrixView: View {
        @ObservedObject var model: OberVaveModel
        @State private var confirmsClear = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        ForEach(SynthControlLayouts.modulation) { section in
                            SynthControlPanel(section: section, model: model)
                        }
                    }
                    ForEach(LFOModulationRoute.routes(value: model.parameterValue)) { route in
                        if let warning = route.warning {
                            Text(warning).foregroundStyle(.orange)
                                .font(.system(size: 11))
                        }
                    }
                    HStack {
                        Label("MODULATION MATRIX", systemImage: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan)
                        Spacer()
                        Button("CLEAR MATRIX") { confirmsClear = true }
                            .buttonStyle(.bordered)
                    }
                    Text("8 independent routes, added to existing patch modulation. LFO is bipolar; wheel, velocity, aftertouch and envelopes are unipolar. Negative depth reverses the effect.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Toggle("LEGACY WHEEL → PITCH + CUTOFF", isOn: Binding(
                        get: { model.parameterValue(.legacyWheel) != 0 },
                        set: { model.setParameter(.legacyWheel, value: $0 ? 1 : 0) }
                    ))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tint(.cyan)
                    Text("Turn this off for freely assigned CC1 with no built-in vibrato/filter sweep. LFO × WHEEL lets the wheel control LFO depth.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(0..<8, id: \.self) { slot in
                        route(slot)
                    }
                    Text("Ranges are per route at ±100%. Routes sum before destination limits. Volume scales the amp envelope (cannot bypass it); PWM needs a PULSE wave. Aftertouch accepts channel pressure and per-note poly pressure.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .confirmationDialog("Clear all eight modulation routes? Existing patch modulation is unchanged.",
                                isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("Clear Matrix", role: .destructive) {
                    for slot in 0..<8 { reset(slot) }
                }
            }
        }

        private func selection(_ parameter: SynthParameter) -> Binding<Int> {
            Binding(get: { model.parameterValue(parameter) },
                    set: { model.setParameter(parameter, value: $0) })
        }

        private func reset(_ slot: Int) {
            let p = ModulationMatrix.parameters(slot: slot)
            model.setParameter(p.source, value: 0)
            model.setParameter(p.destination, value: 0)
            model.setParameter(p.amount, value: 64)
        }

        private func route(_ slot: Int) -> some View {
            let p = ModulationMatrix.parameters(slot: slot)
            let source = model.parameterValue(p.source)
            let destination = model.parameterValue(p.destination)
            let amount = model.parameterValue(p.amount)
            let active = source != 0 && amount != 64
            let pulseParameter: SynthParameter = destination == 2 ? .osc1Wave : .osc2Wave
            let pwmWarning = active && (destination == 2 || destination == 3) &&
                model.parameterValue(pulseParameter) & 2 == 0
            return VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(String(format: "%02d", slot + 1)).foregroundStyle(active ? Color.cyan : .secondary)
                    Picker("SOURCE", selection: selection(p.source)) {
                        ForEach(ModulationMatrix.sources.indices, id: \.self) { index in
                            Text(ModulationMatrix.sources[index]).tag(index)
                        }
                    }
                    .accessibilityLabel("Mod \(slot + 1) source")
                    Image(systemName: "arrow.right").foregroundStyle(.cyan)
                    Picker("DESTINATION", selection: selection(p.destination)) {
                        ForEach(ModulationMatrix.destinations.indices, id: \.self) { index in
                            Text(ModulationMatrix.destinations[index]).tag(index)
                        }
                    }
                    .accessibilityLabel("Mod \(slot + 1) destination")
                    Button("RESET") { reset(slot) }.buttonStyle(.bordered)
                        .accessibilityLabel("Reset mod \(slot + 1)")
                }
                HStack(spacing: 10) {
                    Text("DEPTH").frame(width: 48, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.parameterValue(p.amount)) },
                                          set: { model.setParameter(p.amount, value: Int($0.rounded())) }),
                           in: 0...128, step: 1, onEditingChanged: { editing in
    #if OBERVAVE_AU
                        model.editParameter(p.amount, editing: editing)
    #endif
                    })
                    .tint(.cyan)
                    .accessibilityLabel("Mod \(slot + 1) depth")
                    .accessibilityValue(ModulationMatrix.amountText(amount))
#if OBERVAVE_AU
                    .overlay {
                        GeometryReader { geometry in
                            AUDragSurface(
                                onStart: { model.editParameter(p.amount, editing: true) },
                                onChange: { point, _ in
                                    let position = (point.x - 8) / max(1, geometry.size.width - 16)
                                    model.setParameter(p.amount, value: Int((min(1, max(0, position)) * 128).rounded()))
                                },
                                onEnd: { model.editParameter(p.amount, editing: false) }
                            )
                        }
                    }
#endif
                    Text(ModulationMatrix.amountText(amount)).frame(width: 70, alignment: .trailing)
                        .foregroundStyle(active ? Color.cyan : .secondary)
                    Button("ZERO") { model.setParameter(p.amount, value: 64) }
                        .buttonStyle(.bordered).accessibilityLabel("Zero mod \(slot + 1) depth")
                    Text(ModulationMatrix.ranges[max(0, min(7, destination))])
                        .frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
                }
                if pwmWarning {
                    Text("Enable PULSE for \(destination == 2 ? "OSC 1" : "OSC 2") to hear PWM.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(10)
            .background(Color.white.opacity(active ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func parameterControl(for control: SynthControl) -> some View {
        let parameter = control.parameter
        let performance = parameter == .arpMode || parameter == .arpLatch
        let displayedValue = performance ? model.performanceMode(parameter) : model.parameterValue(parameter)
        let onValueChange: (Int) -> Void = { value in
            if performance { model.selectPerformanceMode(parameter, value: value) }
            else { model.setParameter(parameter, value: value) }
        }
#if OBERVAVE_AU
        return SynthParameterControl(
            definition: control,
            value: displayedValue,
            maximum: model.parameterMax(parameter),
            mappingMode: false,
            ccAssignment: -1,
            isLearning: false,
            onChange: onValueChange,
            onMappingTap: { _ in },
            onCCChange: { _ in },
            onEditingChanged: { model.editParameter(parameter, editing: $0) },
            isEnabled: performance ? model.parameterValue(parameter) != 0 : nil,
            onToggle: { model.togglePerformance(parameter) }
        )
#else
        let parameterIndex = parameter.rawValue
        let ccAssignment = model.ccAssignments.indices.contains(parameterIndex)
            ? model.ccAssignments[parameterIndex]
            : -1
        let value = displayedValue
        let maximum = model.parameterMax(parameter)
        let isLearning = model.learningParameter == parameter
        let onChange = onValueChange
        let onMappingTap: (Int) -> Void = { count in model.handleMappingTap(parameter, count: count) }
        let onCCChange: (Int) -> Void = { cc in model.setCC(parameter, value: cc) }

        return SynthParameterControl(
            definition: control,
            value: value,
            maximum: maximum,
            mappingMode: model.midiMappingMode,
            ccAssignment: ccAssignment,
            isLearning: isLearning,
            onChange: onChange,
            onMappingTap: onMappingTap,
            onCCChange: onCCChange,
            isEnabled: performance ? model.parameterValue(parameter) != 0 : nil,
            onToggle: { model.togglePerformance(parameter) }
        )
#endif
    }
}

struct ControllersView: View {
    @ObservedObject var model: OberVaveModel
    @State private var learningSlot: Int?
    @State private var learnDeadline = Date.distantPast
    @State private var status = ""
    @State private var confirmsReset = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("CONTROLLERS", systemImage: "dial.medium")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                    Spacer()
                    Button("RESET ROUTES") { confirmsReset = true }.buttonStyle(.bordered)
                }
                Text("16 routes per instrument. VALUE writes the parameter through Min/Max; MOD adds a signed offset to its current setting without overwriting it. Depth is a percentage of the target's full parameter range.")
                Text("CC and pressure are unipolar. Pitch Bend is centered for MOD and spans Min/Max for VALUE. Poly Aftertouch is per-note for voice modulation; effects, LFO and arpeggiator settings use the last received pressure. Discrete targets are rounded.")
                    .foregroundStyle(.secondary)
                Text("OVERRIDE disables this input's original action and old CC assignments while the route is enabled. Use it to redirect Mod Wheel, Sustain, bank CC, CC7, Pitch Bend or panic CC. Input still reaches other custom routes and matrix sources. Program Change, notes and MIDI transport are not remapped.")
                    .foregroundStyle(.secondary)
                if !status.isEmpty { Text(status).foregroundStyle(learningSlot == nil ? Color.secondary : .cyan) }
                ForEach(0..<16, id: \.self) { slot in route(slot) }
#if !OBERVAVE_AU
                DisclosureGroup("EXISTING CC ASSIGNMENTS") {
                    Text("These are the same per-preset assignments shown by MIDI Mapping. Custom routes with OVERRIDE bypass them for that input.")
                        .foregroundStyle(.secondary)
                    ForEach(0..<ControllerRouting.targetNames.count, id: \.self) { index in
                        let parameter = SynthParameter.allCases[index]
                        Picker(ControllerRouting.targetNames[index], selection: Binding(
                            get: { model.ccAssignments.indices.contains(index) ? model.ccAssignments[index] : -1 },
                            set: { _ = model.setCC(parameter, value: $0) }
                        )) {
                            Text("UNASSIGNED").tag(-1)
                            ForEach(0..<128, id: \.self) { cc in Text("CC \(cc)").tag(cc) }
                        }
                    }
                }
#endif
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(12)
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            guard let slot = learningSlot else { return }
            let source = model.takeControllerLearn()
            if source > 0 && source < ControllerRouting.sources.count {
                model.setParameter(ControllerRouting.parameter(slot, 0), value: source)
                status = "Route \(slot + 1): learned \(ControllerRouting.sources[source])."
                cancelLearn()
            } else if Date() >= learnDeadline {
                status = "MIDI Learn timed out. Move a controller on this instrument's MIDI channel and try again."
                cancelLearn()
            }
        }
        .onDisappear { cancelLearn() }
        .onChange(of: model.controllerContext) { _ in
            cancelLearn()
            status = ""
        }
        .confirmationDialog("Reset all controller routes? Sound parameters and existing CC assignments are unchanged.",
                            isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset Routes", role: .destructive) {
                cancelLearn()
                for slot in 0..<16 { reset(slot) }
            }
        }
    }

    private func cancelLearn() {
        model.armControllerLearn(false)
        learningSlot = nil
    }

    private func reset(_ slot: Int) {
        for (field, value) in [0, 12, 0, 0, 128, 64, 0].enumerated() {
            model.setParameter(ControllerRouting.parameter(slot, field), value: value)
        }
    }

    private func binding(_ slot: Int, _ field: Int) -> Binding<Int> {
        let parameter = ControllerRouting.parameter(slot, field)
        return Binding(get: { model.parameterValue(parameter) },
                       set: { model.setParameter(parameter, value: $0) })
    }

    private func amount(_ slot: Int, _ field: Int, _ label: String, signed: Bool = false) -> some View {
        let parameter = ControllerRouting.parameter(slot, field)
        let value = model.parameterValue(parameter)
        return HStack {
            Text(label).frame(width: 45, alignment: .leading)
            Slider(value: Binding(get: { Double(model.parameterValue(parameter)) },
                                  set: { model.setParameter(parameter, value: Int($0.rounded())) }),
                   in: 0...128, step: 1, onEditingChanged: { editing in
#if OBERVAVE_AU
                model.editParameter(parameter, editing: editing)
#endif
            })
            .tint(.cyan)
#if OBERVAVE_AU
            .overlay {
                GeometryReader { geometry in
                    AUDragSurface(onStart: { model.editParameter(parameter, editing: true) },
                                  onChange: { point, _ in
                        let x = min(1, max(0, (point.x - 8) / max(1, geometry.size.width - 16)))
                        model.setParameter(parameter, value: Int((x * 128).rounded()))
                    }, onEnd: { model.editParameter(parameter, editing: false) })
                }
            }
#endif
            .accessibilityLabel("Controller \(slot + 1) \(label)")
            Text(signed ? ModulationMatrix.amountText(value) : String(format: "%.1f%%", Double(value) * 100 / 128))
                .frame(width: 75, alignment: .trailing).foregroundStyle(.cyan)
            if signed {
                Button("ZERO") { model.setParameter(parameter, value: 64) }.buttonStyle(.bordered)
            }
        }
    }

    private func route(_ slot: Int) -> some View {
        let source = model.parameterValue(ControllerRouting.parameter(slot, 0))
        let mode = model.parameterValue(ControllerRouting.parameter(slot, 2))
        let target = model.parameterValue(ControllerRouting.parameter(slot, 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(format: "%02d", slot + 1)).foregroundStyle(source > 0 ? Color.cyan : .secondary)
                Picker("INPUT", selection: binding(slot, 0)) {
                    ForEach(ControllerRouting.sources.indices, id: \.self) { index in
                        Text(ControllerRouting.sources[index]).tag(index)
                    }
                }
                Button(learningSlot == slot ? "CANCEL" : "LEARN") {
                    let wasLearning = learningSlot == slot
                    cancelLearn()
                    if !wasLearning {
                        learningSlot = slot
                        learnDeadline = Date().addingTimeInterval(15)
                        status = "Move a CC, Pitch Bend or Aftertouch control for route \(slot + 1)…"
                        model.armControllerLearn(true)
                    }
                }.buttonStyle(.bordered).tint(learningSlot == slot ? .cyan : nil)
                Button("RESET") { reset(slot) }.buttonStyle(.bordered)
            }
            HStack {
                Picker("TARGET", selection: binding(slot, 1)) {
                    ForEach(ControllerRouting.targetNames.indices, id: \.self) { index in
                        Text(ControllerRouting.targetNames[index]).tag(index)
                    }
                }
                Picker("TYPE", selection: binding(slot, 2)) {
                    Text("VALUE").tag(0)
                    Text("MOD").tag(1)
                }.frame(maxWidth: 200)
                Toggle("OVERRIDE", isOn: Binding(get: { binding(slot, 6).wrappedValue != 0 },
                                                set: { binding(slot, 6).wrappedValue = $0 ? 1 : 0 }))
                    .toggleStyle(.switch).tint(.orange)
            }
            if mode == 0 {
                amount(slot, 3, "MIN")
                amount(slot, 4, "MAX")
                let maximum = model.parameterMax(SynthParameter.allCases[target])
                Text("Output \(Int((Double(binding(slot, 3).wrappedValue) * Double(maximum) / 128).rounded())) → \(Int((Double(binding(slot, 4).wrappedValue) * Double(maximum) / 128).rounded())) / \(maximum). Min > Max inverts the controller.")
                    .foregroundStyle(.secondary)
            } else {
                amount(slot, 5, "DEPTH", signed: true)
            }
        }
        .padding(10)
        .background(Color.white.opacity(source > 0 ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SynthParameterControl: View {
    let definition: SynthControl
    let value: Int
    let maximum: Int
    let mappingMode: Bool
    let ccAssignment: Int
    let isLearning: Bool
    let onChange: (Int) -> Void
    let onMappingTap: (Int) -> Void
    let onCCChange: (Int) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    var isEnabled: Bool?
    var onToggle: () -> Void = {}
    @State private var dragOrigin: Int?
    @State private var tapCount = 0
    @State private var tapDispatch: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                Text(definition.label)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if mappingMode {
                    Menu {
                        Button("Unassigned") { onCCChange(-1) }
                        ForEach(0..<128, id: \.self) { cc in
                            Button(ccAssignment == cc ? "✓ CC \(cc)" : "CC \(cc)") {
                                onCCChange(cc)
                            }
                        }
                    } label: {
                        Text(ccAssignment < 0 ? "—" : "CC \(ccAssignment)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(ccAssignment < 0 ? Color.secondary : Color.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.3), in: Capsule())
                    }
                    .accessibilityLabel("MIDI CC assignment for \(definition.label)")
                }
            }

            Group {
                VStack(spacing: 8) {
                    if let isEnabled {
                        Button(action: onToggle) {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(isEnabled ? Color.black.opacity(0.7) : Color.white.opacity(0.25))
                                    .frame(width: 8, height: 8)
                                Text(definition.parameter == .arpMode ? "ARP" : "LATCH")
                                    .font(.system(size: 12, weight: .black, design: .monospaced))
                                Spacer(minLength: 0)
                                Text(isEnabled ? "ON" : "OFF")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(isEnabled ? Color.black : Color.white.opacity(0.6))
                            .background(isEnabled ? Color.cyan : Color.black.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isEnabled ? Color.cyan : Color.white.opacity(0.14), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(definition.parameter == .arpMode ? "Arpeggiator enabled" : "Latch enabled")
                        .accessibilityValue(isEnabled ? "On" : "Off")
                    }
                    if definition.options.isEmpty {
                        rotaryControl
                    } else {
                        choiceButton
                    }
                }
            }
            .allowsHitTesting(!mappingMode)
            .overlay {
                if mappingMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: registerMappingTap)
                        .overlay {
                            if isLearning {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.yellow, lineWidth: 2)
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onDisappear {
            tapDispatch?.cancel()
            if dragOrigin != nil { dragOrigin = nil; onEditingChanged(false) }
        }
    }

    private func registerMappingTap() {
        tapCount += 1
        let count = tapCount
        tapDispatch?.cancel()
        let dispatch = DispatchWorkItem {
            onMappingTap(count)
            tapCount = 0
            tapDispatch = nil
        }
        tapDispatch = dispatch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: dispatch)
    }

    private var rotaryControl: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 54, height: 54)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: 54, height: 54)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.39, green: 0.45, blue: 0.53), Color(red: 0.12, green: 0.16, blue: 0.21)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.23), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2, height: 10)
                    .offset(y: -15)
                    .rotationEffect(.degrees(-135 + progress * 270))
            }
            .contentShape(Circle().size(width: 64, height: 64))
#if OBERVAVE_AU
            .overlay {
                AUDragSurface(
                    onStart: { dragOrigin = value; onEditingChanged(true) },
                    onChange: { _, translation in
                        guard let dragOrigin else { return }
                        let delta = Int((-translation.height / 2.2).rounded(.towardZero))
                        onChange(min(maximum, max(0, dragOrigin + delta)))
                    },
                    onEnd: { dragOrigin = nil; onEditingChanged(false) }
                )
            }
#else
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragOrigin == nil { dragOrigin = value; onEditingChanged(true) }
                        guard let dragOrigin else { return }
                        let delta = Int((-gesture.translation.height / 2.2).rounded(.towardZero))
                        onChange(min(maximum, max(0, dragOrigin + delta)))
                    }
                    .onEnded { _ in dragOrigin = nil; onEditingChanged(false) }
            )
#endif
            .accessibilityElement()
            .accessibilityLabel(definition.label)
            .accessibilityValue(displayValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(min(maximum, value + 1))
                case .decrement: onChange(max(0, value - 1))
                @unknown default: break
                }
            }

            Text(displayValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var choiceButton: some View {
        Group {
            if definition.options.count == 2 && definition.optionValueOffset == 0 {
                Button {
                    onChange(value == 0 ? 1 : 0)
                } label: {
                    choiceLabel(systemImage: "switch.2")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to switch")
            } else {
                Menu {
                    ForEach(Array(definition.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            onChange(index + definition.optionValueOffset)
                        } label: {
                            if index + definition.optionValueOffset == value {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(option)
                            }
                        }
                    }
                } label: {
                    choiceLabel(systemImage: "chevron.down")
                }
                .accessibilityHint("Tap to choose an option")
            }
        }
        .accessibilityLabel(definition.label)
        .accessibilityValue(selectedOption)
    }

    private func choiceLabel(systemImage: String) -> some View {
        HStack(spacing: 5) {
            Text(selectedOption)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(selectedOption == "OFF" ? Color.white.opacity(0.78) : .cyan)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    private var progress: CGFloat {
        maximum > 0 ? CGFloat(value) / CGFloat(maximum) : 0
    }

    private var selectedOption: String {
        let optionIndex = value - definition.optionValueOffset
        guard definition.options.indices.contains(optionIndex) else { return "—" }
        return definition.options[optionIndex]
    }

    private var displayValue: String {
        switch definition.parameter {
        case .osc2Semitone:
            let semitones = value - 24
            return semitones > 0 ? "+\(semitones)" : "\(semitones)"
        case .osc2Fine, .envelopeToOsc2:
            let amount = value - 64
            return amount > 0 ? "+\(amount)" : "\(amount)"
        case .lfoRate:
            return lfoRateText(value)
        case .arpVelocity:
            return value == 0 ? "KEY" : "\(value)"
        default:
            return "\(value)"
        }
    }
}

#if !OBERVAVE_AU
private struct PresetSaveView: View {
    @ObservedObject var model: OberVaveModel
    @Environment(\.dismiss) private var dismiss
    let allowsSlotSelection: Bool
    @State private var bank: Int
    @State private var program: Int
    @State private var name: String
    @State private var showsOverwriteConfirmation = false

    init(
        model: OberVaveModel,
        allowsSlotSelection: Bool,
        initialBank: Int,
        initialProgram: Int,
        initialName: String
    ) {
        self.model = model
        self.allowsSlotSelection = allowsSlotSelection
        _bank = State(initialValue: initialBank)
        _program = State(initialValue: initialProgram)
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                if allowsSlotSelection {
                    Picker("Bank", selection: $bank) {
                        ForEach(0..<6, id: \.self) { bank in
                            Text("BANK \(String(UnicodeScalar(65 + bank)!))").tag(bank)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Program", selection: $program) {
                        ForEach(0..<128, id: \.self) { slot in
                            Text(String(format: "%03d  %@", slot + 1, model.presetName(bank: bank, program: slot)))
                                .tag(slot)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Preset name (max 10 characters)", text: $name)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: name) { value in
                            if value.count > 10 { name = String(value.prefix(10)) }
                        }
                } else {
                    LabeledContent("Bank", value: "BANK \(String(UnicodeScalar(65 + bank)!))")
                    LabeledContent("Program", value: String(format: "%03d", program + 1))
                    TextField("Preset name (max 10 characters)", text: $name)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: name) { value in
                            if value.count > 10 { name = String(value.prefix(10)) }
                        }
                }

                Text("Sound parameters and this preset's MIDI CC assignments will be saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(allowsSlotSelection ? "Save New Preset" : "Save Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: requestSave)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Do you want to replace existing preset?", isPresented: $showsOverwriteConfirmation) {
                Button("Yes", role: .destructive) { saveAndClose() }
                Button("No") {}
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .onChange(of: bank) { value in
                name = model.presetName(bank: value, program: program)
            }
            .onChange(of: program) { value in
                name = model.presetName(bank: bank, program: value)
            }
        }
    }

    private func requestSave() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.slotHasPreset(bank: bank, program: program) {
            showsOverwriteConfirmation = true
        } else {
            saveAndClose()
        }
    }

    private func saveAndClose() {
        if model.savePreset(bank: bank, program: program, name: name) {
            dismiss()
        }
    }
}

private struct BluetoothMIDIView: View {
    @ObservedObject var model: OberVaveModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Bluetooth", systemImage: "waveform")
                        Spacer()
                        Text(bluetoothStatusText)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.toggleBluetoothMIDIScan()
                    } label: {
                        Label(
                            model.isScanningBluetoothMIDI ? "Stop Scanning" : "Find Bluetooth MIDI",
                            systemImage: model.isScanningBluetoothMIDI ? "stop.circle" : "magnifyingglass"
                        )
                    }
                    .disabled(model.bluetoothState != .poweredOn)
                } header: {
                    Text("Bluetooth MIDI")
                } footer: {
                    Text("Turn on your MIDI device and put it in pairing mode. Keep this screen open while OberVave searches.")
                }

                Section("Nearby Devices") {
                    if model.bluetoothDevices.isEmpty {
                        Text(model.isScanningBluetoothMIDI ? "Searching for MIDI devices…" : "No Bluetooth MIDI devices found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.bluetoothDevices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                    Text(device.isConnected ? "Connected · BLE MIDI input" : device.isConnecting ? "Connecting…" : "Bluetooth MIDI")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.isConnecting {
                                    ProgressView()
                                } else if device.isConnected {
                                    Button("Disconnect", role: .destructive) {
                                        model.disconnectBluetoothMIDI(device.id)
                                    }
                                    .font(.subheadline)
                                } else {
                                    Button("Connect") {
                                        model.connectBluetoothMIDI(device.id)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                    }
                }

                Section("MIDI Inputs") {
                    HStack {
                        Label("Active inputs", systemImage: "pianokeys")
                        Spacer()
                        Text("\(model.midiSourceCount)")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.midiSourceNames, id: \.self) { name in
                        Label(name, systemImage: "pianoinstrument")
                            .font(.subheadline)
                    }
                    Button("Refresh MIDI Inputs", systemImage: "arrow.clockwise") {
                        model.refreshMIDISources()
                    }
                }

                Section("Sustain Pedal") {
                    Toggle("Triple-tap Sustain to Stop All", isOn: Binding(
                        get: { model.sustainStopGesture },
                        set: { model.setSustainStopGesture($0) }))
                    Text("Three presses of 300 ms or less, with gaps no longer than one quarter note at the current tempo. Stops all playback on the third release, preserving effect tails. Each MIDI source/channel is recognized separately; normal Sustain still works. This device setting is off by default and is not saved in scenes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Invert Sustain polarity", isOn: Binding(
                        get: { model.sustainInverted },
                        set: { model.setSustainInverted($0) }))
                    Text(model.sustainInputDescription)
                        .font(.subheadline.monospaced())
                    Text("After polarity correction: CC64 96-127 arms DOWN; 0-31 releases UP only after DOWN. Values 32-95 preserve the previous state to reject pedal chatter. Enable inversion if your pedal sends low values on press. Change polarity with notes released, then cycle the pedal once. This device setting applies to all MIDI channels, not AU or scene files.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Audio output", value: model.audioOutputName)
                    LabeledContent("Hardware format", value: model.audioOutputFormat)
                    LabeledContent("Engine", value: model.isAudioRunning ? "Running" : "Stopped")
                    Button("Refresh Audio / Resume", systemImage: "arrow.clockwise") {
                        model.resumeAudio()
                        model.refreshMIDISources()
                    }
                    Text("Connect iPad to Mac by USB, then enable iPad in Audio MIDI Setup on the Mac. Select iPad as the DAW MIDI output and stereo audio input. Audio routing is managed by iPadOS, not this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("USB DAW / Audio (IDAM)")
                }

                Section("Arpeggiator Audio Compensation") {
                    Toggle("Automatic output compensation", isOn: Binding(
                        get: { model.arpLatencyAuto }, set: { model.setArpLatencyAuto($0) }))
                    LabeledContent("iOS output + buffer estimate",
                        value: String(format: "%.1f ms", model.audioLatencyEstimateMS))
                    HStack {
                        Text("Manual correction")
                        Spacer()
                        TextField("ms", value: Binding(
                            get: { model.arpLatencyManualMS },
                            set: { model.setArpLatencyManualMS($0) }),
                            format: .number.precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("ms")
                    }
                    Slider(value: Binding(get: { model.arpLatencyManualMS },
                        set: { model.setArpLatencyManualMS(($0 * 10).rounded() / 10) }),
                        in: -500...500, step: 0.1)
                        .tint(.cyan)
                    LabeledContent("Total audio advance",
                        value: String(format: "%+.1f ms", model.arpLatencyTotalMS))
                    Button("Reset manual correction") { model.setArpLatencyManualMS(0) }
                    Text("Requires MASTER SYNC. Positive values advance the rhythm; negative values delay it. Changes shift playing arpeggios immediately, without restarting the phrase, so you can adjust by ear. Large advances may skip timing boundaries without a burst of notes. Timestamped MIDI Clock also includes compensation for MIDI INPUT BUFFER. Auto estimates this iPad's output, not the complete USB/DAW path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("MIDI INPUT BUFFER")
                            Spacer()
                            Text("\(model.bleMidiBufferMilliseconds) ms")
                                .monospacedDigit()
                                .foregroundStyle(.cyan)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(model.bleMidiBufferMilliseconds) },
                                set: { model.setBLEMIDIBufferMilliseconds(Int($0.rounded())) }
                            ),
                            in: 0...50,
                            step: 1
                        )
                        .tint(.cyan)
                        Text("Schedules timestamped Bluetooth and CoreMIDI events ahead. Higher values smooth delayed packets but add note latency.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("MIDI Timing")
                }
            }
            .navigationTitle("MIDI Connections")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
                model.refreshSustainInput()
            }
            .onAppear {
                model.refreshMIDISources()
                model.refreshAudioStatus()
                model.refreshSustainInput()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var bluetoothStatusText: String {
        switch model.bluetoothState {
        case .poweredOn: "On"
        case .poweredOff: "Off"
        case .unauthorized: "Not authorized"
        case .unsupported: "Unavailable"
        case .resetting: "Starting…"
        case .unknown: "Checking…"
        @unknown default: "Unavailable"
        }
    }
}

#endif

struct TouchKeyboardView: View {
#if OBERVAVE_AU
    let model: OberVaveModel
#else
    @ObservedObject var model: OberVaveModel
#endif
    let onClose: () -> Void
#if OBERVAVE_AU
    @State private var octaveCount = 2
    @State private var firstNote = 48
#else
    @Binding var octaveCount: Int
    @Binding var firstNote: Int
    @State private var visibleNotes: Set<UInt32> = []
#endif
    @State private var pitchBend = 0
    @State private var modulation = 0

    private let maximumOctaves = 8

    var body: some View {
        GeometryReader { container in
#if OBERVAVE_AU
            let keyboardHeight = max(120, container.size.height - 64)
            let wheelHeight = (keyboardHeight - 12) / 2
            let wheelTrackHeight = max(36, wheelHeight - 40)
#else
            let lockRowHeight: CGFloat = 46
            let keyboardHeight = max(90, container.size.height - 98 - lockRowHeight)
            let wheelHeight = (keyboardHeight - 12) / 2
            let wheelTrackHeight = max(12, wheelHeight - 40)
#endif

            VStack(spacing: keyboardSpacing) {
                HStack(spacing: 8) {
                    Label("ON-SCREEN KEYBOARD", systemImage: "pianokeys")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Spacer()
                    Menu {
                        ForEach(1...availableOctaves, id: \.self) { count in
                            Button("\(count) \(count == 1 ? "OCTAVE" : "OCTAVES")") {
                                octaveCount = count
                            }
                        }
                    } label: {
                        Label("\(octaveCount) OCT", systemImage: "rectangle.expand.vertical")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        transpose(by: -12)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(firstNote < 12)
                    .accessibilityLabel("Transpose keyboard down one octave")

                    Text(noteName(firstNote % 12) + "\(firstNote / 12 - 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(minWidth: 30)

                    Button {
                        transpose(by: 12)
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(firstNote + (octaveCount + 1) * 12 > 127)
                    .accessibilityLabel("Transpose keyboard up one octave")

                    Button("Done", action: onClose)
                        .buttonStyle(.bordered)
                }
#if !OBERVAVE_AU
                .frame(height: 44)
#endif

#if !OBERVAVE_AU
                HStack(spacing: 3) {
                    Button("KEY-LOCK") { model.toggleKeyLock() }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .frame(height: 34)
                        .foregroundStyle(model.keyboardLock.enabled ? Color.black : Color.secondary)
                        .background(model.keyboardLock.enabled ? Color.cyan : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.keyboardLock.enabled ? .isSelected : [])
                    ForEach(1...16, id: \.self) { channel in
                        let active = model.keyboardChannelMask & (1 << (channel - 1)) != 0
                        let color = MIDIChannelColors.color(channel)
                        Button("\(channel)") { model.toggleKeyboardChannel(channel) }
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(active ? Color.black : color)
                            .background(color.opacity(active ? 1 : 0.12),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(color.opacity(active ? 1 : 0.45), lineWidth: 1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Keyboard MIDI channel \(channel)")
                            .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
#endif

                HStack(spacing: 8) {
                    VStack(spacing: 12) {
                        TouchMIDIWheel(
                            title: "PITCH",
                            value: $pitchBend,
                            range: -8192...8191,
                            centerValue: 0,
                            color: .cyan,
                            trackHeight: wheelTrackHeight,
                            onChange: model.setPitchBend,
                            onRelease: { model.setPitchBend(0) }
                        )
                        .frame(width: 48, height: wheelHeight)

                        TouchMIDIWheel(
                            title: "MOD",
                            value: $modulation,
                            range: 0...127,
                            centerValue: 0,
                            color: .orange,
                            trackHeight: wheelTrackHeight,
                            onChange: model.setModWheel
                        )
                        .frame(width: 48, height: wheelHeight)
                    }
                    .padding(.leading, 8)

                    GeometryReader { geometry in
                        let visibleOctaves = min(octaveCount, 2)
                        let whiteKeyWidth = max(220.0 / 7,
                            (geometry.size.width - CGFloat(visibleOctaves - 1) * 4) /
                            CGFloat(visibleOctaves * 7 + 1))
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(0..<octaveCount, id: \.self) { octave in
                                    KeyboardOctave(
                                        firstNote: firstNote + octave * 12,
                                        includesTopC: octave == octaveCount - 1,
                                        model: model
                                    )
                                    .id(firstNote + octave * 12)
                                    .frame(width: whiteKeyWidth * CGFloat(octave == octaveCount - 1 ? 8 : 7))
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
#if !OBERVAVE_AU
                        .coordinateSpace(name: "keyboardViewport")
                        .onPreferenceChange(KeyboardKeyFrames.self) { frames in
                            let viewport = CGRect(origin: .zero, size: geometry.size)
                            visibleNotes = Set(frames.compactMap { note, frame in
                                let intersection = viewport.intersection(frame)
                                return !intersection.isNull && intersection.width >= frame.width * 0.5
                                    && intersection.height > 0 ? note : nil
                            })
                        }
#endif
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: keyboardHeight)
#if !OBERVAVE_AU
                HStack(spacing: 8) {
                    if model.keyboardLock.enabled {
                        Button("RELEASE CHANNEL") {
                            model.releaseLockedKeys(channels: model.keyboardChannelMask)
                        }
                        .disabled(model.lockedKeyboardNotes.isEmpty)
                        .accessibilityLabel("Release keyboard locks on selected MIDI channels")
                        Button("RELEASE ALL") {
                            model.releaseLockedKeys(channels: 0xFFFF)
                        }
                        .disabled(model.keyboardLock.notes.isEmpty)
                        .accessibilityLabel("Release keyboard locks on all MIDI channels")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            if model.keyboardLock.enabled && model.lockedKeyboardNotes.subtracting(visibleNotes).isEmpty {
                                Label("Swipe down past a key to lock", systemImage: "arrow.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.lockedKeyboardNotes.subtracting(visibleNotes).sorted(), id: \.self) { note in
                                ForEach(MIDIChannelColors.channels(in: model.keyboardLock.channels(for: note)
                                    & model.keyboardChannelMask), id: \.self) { channel in
                                    Button {
                                        model.releaseLockedKey(note, channels: 1 << (channel - 1))
                                    } label: {
                                        Text(rackNoteName(Int(note)))
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .frame(width: 28, height: 24)
                                            .foregroundStyle(.black)
                                            .background(MIDIChannelColors.color(channel),
                                                        in: RoundedRectangle(cornerRadius: 3))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Release locked \(rackNoteName(Int(note))), MIDI channel \(channel)")
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .buttonStyle(.bordered)
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(Color.black.opacity(0.18))
#endif
            }
            .padding(.vertical, keyboardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.11))
        .onDisappear {
            model.setPitchBend(0)
            model.setModWheel(0)
        }
    }

    private var keyboardSpacing: CGFloat {
#if OBERVAVE_AU
        10
#else
        6
#endif
    }

    private var keyboardPadding: CGFloat {
#if OBERVAVE_AU
        12
#else
        4
#endif
    }

    private var availableOctaves: Int {
        max(1, min(maximumOctaves, (127 - firstNote) / 12))
    }

    private func transpose(by semitones: Int) {
        let next = firstNote + semitones
        guard next >= 0, next + octaveCount * 12 <= 127 else { return }
        firstNote = next
    }

    private func noteName(_ semitone: Int) -> String {
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][semitone]
    }
}

private struct KeyboardOctave: View {
    let firstNote: Int
    let includesTopC: Bool
    let model: OberVaveModel

    private var whiteNotes: [Int] { [0, 2, 4, 5, 7, 9, 11] + (includesTopC ? [12] : []) }
    private let blackNotes = [1, 3, 6, 8, 10]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                HStack(spacing: 3) {
                    ForEach(whiteNotes, id: \.self) { semitone in
                        TouchKey(
                            note: UInt32(firstNote + semitone),
                            label: semitone % 12 == 0 ? noteName(0) : "",
                            isBlack: false,
                            model: model
                        )
                    }
                }
                ForEach(blackNotes, id: \.self) { semitone in
                    TouchKey(
                        note: UInt32(firstNote + semitone),
                        label: "",
                        isBlack: true,
                        model: model
                    )
                    .frame(width: geometry.size.width / CGFloat(whiteNotes.count) * 0.62, height: geometry.size.height * 0.62)
                    .position(
                        x: geometry.size.width * CGFloat(blackKeyBoundary(semitone)) / CGFloat(whiteNotes.count),
                        y: geometry.size.height * 0.31
                    )
                }
            }
        }
    }

    private func noteName(_ semitone: Int) -> String {
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][semitone]
    }

    private func blackKeyBoundary(_ semitone: Int) -> Int {
        switch semitone {
        case 1: 1
        case 3: 2
        case 6: 4
        case 8: 5
        default: 6
        }
    }
}

private struct TouchMIDIWheel: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let centerValue: Int
    let color: Color
    let trackHeight: CGFloat
    let onChange: (Int) -> Void
    var onRelease: (() -> Void)?

    private var progress: Double {
        Double(value - range.lowerBound) / Double(range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            GeometryReader { geometry in
                let thumbHeight: CGFloat = 24
                let travel = max(0, geometry.size.height - thumbHeight)
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 12)
                        .frame(maxWidth: .infinity)
                    if title == "PITCH" {
                        Rectangle()
                            .fill(Color.white.opacity(0.24))
                            .frame(width: 24, height: 1)
                            .position(x: geometry.size.width / 2, y: travel * (1 - 0.5) + thumbHeight / 2)
                    }
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.8), color.opacity(0.35)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 38, height: thumbHeight)
                        .overlay {
                            Capsule()
                                .fill(Color.white.opacity(0.75))
                                .frame(width: 18, height: 2)
                        }
                        .offset(y: travel * (1 - progress))
                }
                .contentShape(Rectangle())
#if OBERVAVE_AU
                .overlay {
                    AUDragSurface(
                        onStart: {},
                        onChange: { location, _ in
                            let position = min(travel, max(0, location.y - thumbHeight / 2))
                            let normalized = 1 - position / max(1, travel)
                            let next = range.lowerBound + Int((normalized * Double(range.upperBound - range.lowerBound)).rounded())
                            value = min(range.upperBound, max(range.lowerBound, next))
                            onChange(value)
                        },
                        onEnd: {
                            if title == "PITCH" { value = centerValue }
                            onRelease?()
                        }
                    )
                }
#else
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let position = min(travel, max(0, gesture.location.y - thumbHeight / 2))
                            let normalized = 1 - position / max(1, travel)
                            let next = range.lowerBound + Int((normalized * Double(range.upperBound - range.lowerBound)).rounded())
                            value = min(range.upperBound, max(range.lowerBound, next))
                            onChange(value)
                        }
                        .onEnded { _ in
                            if title == "PITCH" {
                                value = centerValue
                            }
                            onRelease?()
                        }
                )
#endif
            }
            .frame(height: trackHeight)
            Text(title == "PITCH" ? "\(Int(progress * 100))%" : "\(value)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

#if !OBERVAVE_AU
private struct KeyboardKeyFrames: PreferenceKey {
    static var defaultValue: [UInt32: CGRect] = [:]
    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
#endif

private struct TouchKey: View {
    let note: UInt32
    let label: String
    let isBlack: Bool
#if OBERVAVE_AU
    let model: OberVaveModel
#else
    @ObservedObject var model: OberVaveModel
    @State private var touchStarted: Date?
    @State private var touchChannels: UInt32 = 0
    @State private var releaseChannels: UInt32 = 0
#endif
    @State private var isDown = false

    var body: some View {
        GeometryReader { geometry in
        RoundedRectangle(cornerRadius: 9)
            .fill(isHighlighted ? Color.cyan : isBlack ? Color(red: 0.16, green: 0.2, blue: 0.28) : Color(red: 0.82, green: 0.86, blue: 0.92))
#if !OBERVAVE_AU
            .overlay {
                HStack(spacing: 0) {
                    ForEach(MIDIChannelColors.channels(in: highlightedChannels), id: \.self) { channel in
                        MIDIChannelColors.color(channel)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .allowsHitTesting(false)
            }
#endif
            .overlay(alignment: .bottom) {
                Text(label)
                    .font(.caption.weight(.medium))
#if OBERVAVE_AU
                    .foregroundStyle(isBlack || isHighlighted ? .white : .black)
#else
                    .foregroundStyle(isBlack && !isHighlighted ? .white : .black)
#endif
                    .padding(.bottom, 12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isDown ? Color.white.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1)
            }
#if !OBERVAVE_AU
            .overlay(alignment: .bottom) {
                if lockedChannels != 0 {
                    HStack(spacing: 2) {
                        ForEach(MIDIChannelColors.channels(in: lockedChannels), id: \.self) { channel in
                            MIDIChannelColors.color(channel)
                        }
                    }
                    .frame(height: 5)
                    .clipShape(Capsule())
                    .padding(3)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
                }
            }
#endif
            .contentShape(Rectangle())
#if OBERVAVE_AU
            .overlay {
                AUDragSurface(
                    onStart: { isDown = true; model.noteOn(note) },
                    onChange: { _, _ in },
                    onEnd: { isDown = false; model.noteOff(note) }
                )
            }
#else
            .background {
                Color.clear.preference(key: KeyboardKeyFrames.self,
                    value: [note: geometry.frame(in: .named("keyboardViewport"))])
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if touchStarted == nil {
                            touchStarted = value.time
                            touchChannels = model.keyboardChannelMask
                            releaseChannels = model.keyboardLock.channels(for: note) & touchChannels
                            let newChannels = touchChannels & ~releaseChannels
                            if newChannels != 0 {
                                isDown = true
                                ov_keyboard_note_on(note, 100, newChannels)
                                model.recordMIDIActivity()
                            }
                        }
                        guard model.keyboardLock.enabled,
                              let start = touchStarted else { return }
                        if KeyboardLockState.isLockSwipe(startY: value.startLocation.y,
                            endY: value.location.y, keyHeight: geometry.size.height,
                            duration: value.time.timeIntervalSince(start)) {
                            model.keyboardLock.lock(note, channels: touchChannels & ~releaseChannels)
                        }
                    }
                    .onEnded { _ in
                        isDown = false
                        model.releaseLockedKey(note, channels: releaseChannels)
                        let unlatched = touchChannels & ~releaseChannels & ~model.keyboardLock.channels(for: note)
                        ov_keyboard_note_off(note, unlatched)
                        touchStarted = nil
                        touchChannels = 0
                        releaseChannels = 0
                    }
            )
#endif
            .onDisappear {
                if isDown {
                    isDown = false
#if OBERVAVE_AU
                    model.noteOff(note)
#else
                    ov_keyboard_note_off(note, touchChannels & ~model.keyboardLock.channels(for: note))
#endif
                }
            }
        }
    }

    private var isHighlighted: Bool {
#if OBERVAVE_AU
        isDown
#else
        highlightedChannels != 0
#endif
    }

#if !OBERVAVE_AU
    private var lockedChannels: UInt32 {
        model.keyboardLock.channels(for: note)
    }

    private var highlightedChannels: UInt32 {
        (lockedChannels & model.keyboardChannelMask) | (isDown ? touchChannels : 0)
    }
#endif
}
