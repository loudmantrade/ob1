// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum KeyboardZoneLayout {
    static func isBlack(_ note: Int) -> Bool { [1, 3, 6, 8, 10].contains(note % 12) }

    static func whiteIndex(_ note: Int) -> Int {
        note / 12 * 7 + [0, 1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6][note % 12]
    }

    static func position(_ note: Int) -> Double {
        (Double(whiteIndex(note)) + (isBlack(note) ? 0 : 0.5)) / 75
    }

    static func note(at position: Double) -> Int {
        var nearest = 0
        for note in 1...127 where abs(Self.position(note) - position) < abs(Self.position(nearest) - position) {
            nearest = note
        }
        return nearest
    }
}

final class SceneSaveMonitor {
    private var timer: Timer?

    func start(timeout: TimeInterval = 5, interval: TimeInterval = 0.05,
               poll: @escaping () -> Bool, onTimeout: @escaping () -> Void) {
        timer?.invalidate()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if poll() {
                timer.invalidate()
                self.timer = nil
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                timer.invalidate()
                self.timer = nil
                onTimeout()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { timer?.invalidate() }
}

struct RackInstrument: Codable, Equatable, Identifiable {
    var id: Int { slot }
    var slot: Int
    var name: String
    var engine = Int(OV_ENGINE_OBERVAVE)
    var channel: Int
    var lowNote = 0
    var highNote = 127
    var levelDB = 0.0
    var pan = 0.0
    var muted = false
    var programIndex = 17
    var parameters: [Int]
    var cc: [Int]
    var sync = false
    var grid = 2
    var arpMode = 1
    var latchMode = 2
    var recordBeats = 4

    static func oberVave(slot: Int, channel: Int) -> RackInstrument {
        RackInstrument(slot: slot, name: "OberVave \(slot + 1)", channel: channel,
            parameters: (0..<Int(ov_parameter_count())).map { Int(ov_rack_factory_parameter(17, UInt32($0))) },
            cc: (0..<Int(ov_parameter_count())).map { Int(ov_rack_default_cc(UInt32($0))) })
    }

    func validate() throws {
        guard (0..<16).contains(slot), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 64, engine > 0, engine <= Int(UInt32.max),
              !String(cString: ov_engine_name(UInt32(engine))).isEmpty,
              (1...16).contains(channel), (0...127).contains(lowNote),
              (lowNote...127).contains(highNote), levelDB.isFinite, (-48...0).contains(levelDB),
              pan.isFinite, (-1...1).contains(pan), (0..<768).contains(programIndex),
              (0...5).contains(grid), (1...8).contains(arpMode), (1...2).contains(latchMode),
              (0...256).contains(recordBeats),
              parameters.count == Int(ov_parameter_count()), cc.count == parameters.count else {
            throw SceneError.invalid("Invalid instrument configuration or unsupported engine.")
        }
        for (index, value) in parameters.enumerated() {
            guard (0...Int(ov_parameter_max(UInt32(index)))).contains(value),
                  (0...127).contains(cc[index]) || cc[index] == 255 else {
                throw SceneError.invalid("Invalid sound parameters or MIDI assignments.")
            }
        }
    }

    func coreConfig() -> ov_instrument_config {
        var c = ov_instrument_config()
        c.engine = UInt32(engine); c.channel = UInt32(channel)
        c.low_note = UInt32(lowNote); c.high_note = UInt32(highNote)
        c.program = UInt32(programIndex); c.sync = sync ? 1 : 0; c.grid = UInt32(grid)
        c.level_db = Float(levelDB); c.pan = Float(pan); c.muted = muted ? 1 : 0
        withUnsafeMutableBytes(of: &c.parameters) { $0.copyBytes(from: parameters.map(UInt8.init)) }
        withUnsafeMutableBytes(of: &c.cc) { $0.copyBytes(from: cc.map(UInt8.init)) }
        return c
    }

    mutating func updateSound(_ c: ov_instrument_config) {
        parameters = withUnsafeBytes(of: c.parameters) { $0.map(Int.init) }
        cc = withUnsafeBytes(of: c.cc) { $0.map(Int.init) }
        programIndex = Int(c.program)
        sync = c.sync != 0; grid = Int(c.grid)
        if parameters[SynthParameter.arpMode.rawValue] > 0 { arpMode = parameters[SynthParameter.arpMode.rawValue] }
        if parameters[SynthParameter.arpLatch.rawValue] > 0 { latchMode = parameters[SynthParameter.arpLatch.rawValue] }
    }
}

enum SceneError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

extension RackInstrument {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(Int.self, forKey: .slot)
        name = try c.decode(String.self, forKey: .name)
        engine = try c.decode(Int.self, forKey: .engine)
        channel = try c.decode(Int.self, forKey: .channel)
        lowNote = try c.decode(Int.self, forKey: .lowNote)
        highNote = try c.decode(Int.self, forKey: .highNote)
        levelDB = try c.decode(Double.self, forKey: .levelDB)
        pan = try c.decode(Double.self, forKey: .pan)
        muted = try c.decode(Bool.self, forKey: .muted)
        programIndex = try c.decode(Int.self, forKey: .programIndex)
        parameters = try c.decode([Int].self, forKey: .parameters)
        cc = try c.decode([Int].self, forKey: .cc)
        sync = try c.decode(Bool.self, forKey: .sync)
        grid = try c.decode(Int.self, forKey: .grid)
        arpMode = try c.decode(Int.self, forKey: .arpMode)
        latchMode = try c.decode(Int.self, forKey: .latchMode)
        recordBeats = try c.decodeIfPresent(Int.self, forKey: .recordBeats) ?? 4
        if [65, 90].contains(parameters.count) && cc.count == parameters.count {
            for p in parameters.count..<Int(ov_parameter_count()) {
                parameters.append(Int(ov_rack_factory_parameter(17, UInt32(p))))
                cc.append(Int(ov_rack_default_cc(UInt32(p))))
            }
        }
    }
}

struct RackSceneDocument: Codable {
    var version = 1
    var name: String
    var instruments: [RackInstrument]
    var tempo: Int
    var masterDB: Double
    var masterPan: Double
    var keyboardMask: UInt32
    var selectedSlot: Int?
    var patterns: [SequencerPattern]?

    static func read(from url: URL) throws -> RackSceneDocument {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 33_554_432 else {
            throw SceneError.invalid("The scene must be a regular file no larger than 32 MB.")
        }
        let document = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try document.validate()
        return document
    }

    func validate() throws {
        guard version == 1 else { throw SceneError.invalid("This scene version is not supported.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
              instruments.count <= 16, Set(instruments.map(\.slot)).count == instruments.count,
              (40...240).contains(tempo), masterDB.isFinite, (-48...0).contains(masterDB),
              masterPan.isFinite, (-1...1).contains(masterPan), keyboardMask <= 0xFFFF,
              selectedSlot == nil || instruments.contains(where: { $0.slot == selectedSlot }) else {
            throw SceneError.invalid("Invalid scene, channel selection or master settings.")
        }
        try instruments.forEach { try $0.validate() }
        let clips = patterns ?? []
        try clips.forEach { try $0.validate() }
        guard clips.count <= 128, Set(clips.map(\.id)).count == clips.count,
              clips.allSatisfy({ clip in instruments.contains { $0.slot == clip.slot } }) else {
            throw SceneError.invalid("Invalid sequencer cell or missing instrument.")
        }
    }
}

enum SequencerRecordMode: Int, CaseIterable {
    case waitForNote, countIn, immediate
    var title: String {
        switch self {
        case .waitForNote: "Wait for note"
        case .countIn: "Count-in"
        case .immediate: "Immediate"
        }
    }
}

struct SequencerNote: Codable, Equatable, Identifiable {
    var id: UInt64
    var start: Int64
    var duration: Int64
    var pitch: Int
    var velocity: Int
    var output = true
}

struct SequencerPattern: Codable, Equatable, Identifiable {
    static let maxTicks: Int64 = 1 << 38
    var id: Int { slot * 8 + row }
    var version = 2
    var slot: Int
    var row: Int
    var name: String
    var length: Int64 = 3840
    var intro: Int64 = 0
    var introEnabled = true
    var loop = true
    var quantize = 0
    var notes: [SequencerNote] = []

    func validate() throws {
        guard version == 2, (0..<16).contains(slot), (0..<8).contains(row),
              (1...Self.maxTicks).contains(length), (0...11520).contains(intro),
              (0...3840).contains(quantize), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 96, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              notes.count <= 1024, Set(notes.map(\.id)).count == notes.count,
              notes.allSatisfy({ $0.id > 0 && $0.id < UInt64.max && $0.start >= -intro && $0.start < length &&
                  (1...Self.maxTicks).contains($0.duration) && (0...127).contains($0.pitch) && (1...127).contains($0.velocity) }) else {
            throw SceneError.invalid("Invalid pattern name, timing, note ID, capacity or MIDI value.")
        }
    }

    func coreClip() -> ov_seq_clip {
        var clip = ov_seq_clip()
        clip.slot = UInt32(slot); clip.row = UInt32(row); clip.length = length; clip.intro = intro
        clip.count = UInt32(notes.count); clip.loop = loop ? 1 : 0
        clip.intro_enabled = introEnabled ? 1 : 0; clip.quantize = UInt32(quantize)
        withUnsafeMutableBytes(of: &clip.name) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: Array(name.utf8) + [0])
        }
        withUnsafeMutableBytes(of: &clip.notes) { raw in
            let buffer = raw.bindMemory(to: ov_seq_note.self)
            for (index, note) in notes.enumerated() {
                buffer[index] = ov_seq_note(id: note.id, start: note.start, duration: note.duration,
                    pitch: UInt32(note.pitch), velocity: UInt32(note.velocity), output: note.output ? 1 : 0)
            }
        }
        return clip
    }

    init(slot: Int, row: Int, name: String) { self.slot = slot; self.row = row; self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let incomingVersion = try c.decode(Int.self, forKey: .version)
        guard incomingVersion == 1 || incomingVersion == 2 else {
            throw SceneError.invalid("This pattern version is not supported.")
        }
        slot = try c.decode(Int.self, forKey: .slot)
        row = try c.decode(Int.self, forKey: .row)
        name = try c.decode(String.self, forKey: .name)
        length = try c.decode(Int64.self, forKey: .length)
        intro = try c.decode(Int64.self, forKey: .intro)
        introEnabled = try c.decode(Bool.self, forKey: .introEnabled)
        loop = try c.decode(Bool.self, forKey: .loop)
        quantize = try c.decode(Int.self, forKey: .quantize)
        notes = try c.decode([SequencerNote].self, forKey: .notes)
        if incomingVersion == 1 && (length > 245760 || notes.contains { $0.duration > 245760 } || intro > 3840) {
            throw SceneError.invalid("Invalid version 1 pattern timing.")
        }
        try validate()
    }
    init(core clip: ov_seq_clip) {
        slot = Int(clip.slot); row = Int(clip.row)
        name = withUnsafeBytes(of: clip.name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        length = clip.length; intro = clip.intro; introEnabled = clip.intro_enabled != 0
        loop = clip.loop != 0; quantize = Int(clip.quantize)
        notes = withUnsafeBytes(of: clip.notes) { raw in
            raw.bindMemory(to: ov_seq_note.self).prefix(Int(clip.count)).map {
                SequencerNote(id: $0.id, start: $0.start, duration: $0.duration,
                    pitch: Int($0.pitch), velocity: Int($0.velocity), output: $0.output != 0)
            }
        }
    }
}

struct SavedRackScene: Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
}
