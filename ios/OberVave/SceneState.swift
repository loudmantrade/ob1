// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics

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

final class RackUIRefreshDriver {
    static let interval: TimeInterval = 0.04
    private var timer: Timer?

    func start(fast: @escaping () -> Void, slow: @escaping () -> Void) {
        guard timer == nil else { return }
        var nextSlow = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            fast()
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextSlow {
                nextSlow = now + 0.25
                slow()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { timer?.invalidate() }
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
    var recordBars: Double { Double(recordBeats) / 4 }

    mutating func setRecordBars(_ bars: Int) {
        precondition((0...64).contains(bars))
        recordBeats = bars * 4
    }

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

struct NoteQuantization: Codable, Equatable {
    var grid: Int
    var strength: Int
    var ends: Bool
}

struct SequencerNote: Codable, Equatable, Identifiable {
    var id: UInt64
    var start: Int64
    var duration: Int64
    var pitch: Int
    var velocity: Int
    var output = true
    var quantization: NoteQuantization?
}

struct SequencerAutomation: Codable, Equatable, Identifiable {
    enum Kind: Int, Codable { case cc = 0, pitchBend = 1 }
    var id: UInt64
    var tick: Int64
    var kind: Kind
    var controller: Int
    var value: Int
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
    var loopStart: Int64 = 0
    var loopEnd: Int64 = 0
    var regionStart: Int64 = 0
    var regionsEnabled = false
    var notes: [SequencerNote] = []
    var automation: [SequencerAutomation] = []

    var hasRegions: Bool { version == 3 || (version >= 4 && regionsEnabled) }
    var patternStart: Int64 { version >= 6 ? regionStart : -intro }

    func validate() throws {
        guard (2...6).contains(version), (0..<16).contains(slot), (0..<8).contains(row),
              (1...Self.maxTicks).contains(length), (0...11520).contains(intro),
              (!hasRegions || (patternStart >= -intro && patternStart <= loopStart &&
                               loopStart < loopEnd && loopEnd <= length)),
              (version != 6 || hasRegions),
              (0...3840).contains(quantize), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 96, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (version >= 4 || automation.isEmpty), automation.count <= 256,
              Set(automation.map(\.id)).count == automation.count,
              automation.allSatisfy({ $0.id > 0 && $0.id < UInt64.max && $0.tick >= -intro && $0.tick < length &&
                  (0...127).contains($0.controller) &&
                  ($0.kind == .cc ? (0...127).contains($0.value) :
                   ($0.controller == 0 && (0...16383).contains($0.value))) }),
              notes.count <= 1024, Set(notes.map(\.id)).count == notes.count,
              notes.allSatisfy({ $0.id > 0 && $0.id < UInt64.max && $0.start >= -intro && $0.start < length &&
                  (1...Self.maxTicks).contains($0.duration) && (0...127).contains($0.pitch) && (1...127).contains($0.velocity) &&
                  ($0.quantization.map { version >= 5 && (0...3840).contains($0.grid) && (0...100).contains($0.strength) } ?? true) }) else {
            throw SceneError.invalid("Invalid pattern name, timing, note ID, capacity or MIDI value.")
        }
    }

    func coreClip() -> ov_seq_clip {
        var clip = ov_seq_clip()
        clip.slot = UInt32(slot); clip.row = UInt32(row); clip.length = length; clip.intro = intro
        clip.count = UInt32(notes.count); clip.loop = loop ? 1 : 0
        clip.intro_enabled = introEnabled ? 1 : 0; clip.quantize = UInt32(quantize)
        clip.regions_enabled = hasRegions ? (version >= 6 ? 2 : 1) : 0
        if hasRegions { clip.pattern_start = patternStart; clip.loop_start = loopStart; clip.loop_end = loopEnd }
        withUnsafeMutableBytes(of: &clip.name) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: Array(name.utf8) + [0])
        }
        withUnsafeMutableBytes(of: &clip.notes) { raw in
            let buffer = raw.bindMemory(to: ov_seq_note.self)
            for (index, note) in notes.enumerated() {
                buffer[index] = ov_seq_note(id: note.id, start: note.start, duration: note.duration,
                    pitch: UInt32(note.pitch), velocity: UInt32(note.velocity), output: note.output ? 1 : 0,
                    quant_override: note.quantization == nil ? 0 : 1,
                    quant_grid: UInt32(note.quantization?.grid ?? 0),
                    quant_strength: UInt32(note.quantization?.strength ?? 0),
                    quant_ends: note.quantization?.ends == true ? 1 : 0)
            }
            clip.automation_count = UInt32(automation.count)
            withUnsafeMutableBytes(of: &clip.automation) { raw in
                let buffer = raw.bindMemory(to: ov_seq_automation.self)
                for (index, point) in automation.enumerated() {
                    buffer[index] = ov_seq_automation(id: point.id, tick: point.tick, kind: UInt32(point.kind.rawValue),
                                                       controller: UInt32(point.controller), value: UInt32(point.value))
                }
            }
        }
        return clip
    }

    init(slot: Int, row: Int, name: String) { self.slot = slot; self.row = row; self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let incomingVersion = try c.decode(Int.self, forKey: .version)
        guard (1...6).contains(incomingVersion) else {
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
        if incomingVersion >= 3 {
            version = incomingVersion
            loopStart = try c.decode(Int64.self, forKey: .loopStart)
            loopEnd = try c.decode(Int64.self, forKey: .loopEnd)
            regionsEnabled = incomingVersion == 3 ? true : try c.decode(Bool.self, forKey: .regionsEnabled)
        }
        if incomingVersion >= 4 {
            automation = try c.decode([SequencerAutomation].self, forKey: .automation)
        }
        if incomingVersion >= 6 { regionStart = try c.decode(Int64.self, forKey: .regionStart) }
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
        if clip.regions_enabled != 0 {
            version = clip.regions_enabled == 2 ? 6 : 3
            regionsEnabled = true
            if clip.regions_enabled == 2 { regionStart = clip.pattern_start }
            loopStart = clip.loop_start; loopEnd = clip.loop_end
        }
        notes = withUnsafeBytes(of: clip.notes) { raw in
            raw.bindMemory(to: ov_seq_note.self).prefix(Int(clip.count)).map {
                SequencerNote(id: $0.id, start: $0.start, duration: $0.duration,
                    pitch: Int($0.pitch), velocity: Int($0.velocity), output: $0.output != 0,
                    quantization: $0.quant_override == 0 ? nil : NoteQuantization(
                        grid: Int($0.quant_grid), strength: Int($0.quant_strength), ends: $0.quant_ends != 0))
            }
        }
        if clip.automation_count > 0 {
            version = max(version, 4)
            automation = withUnsafeBytes(of: clip.automation) { raw in
                raw.bindMemory(to: ov_seq_automation.self).prefix(Int(clip.automation_count)).map {
                    SequencerAutomation(id: $0.id, tick: $0.tick,
                        kind: SequencerAutomation.Kind(rawValue: Int($0.kind))!,
                        controller: Int($0.controller), value: Int($0.value))
                }
            }
        }
        if notes.contains(where: { $0.quantization != nil }) { version = max(version, 5) }
    }
}

struct PatternCellGesture {
    static let tapWindow = 0.24
    static let holdTime = 0.45
    static let dragDistance = 8.0
    enum Effect: Equatable {
        case tap, edit, copyReady, beginDrag(copy: Bool), drag, drop, delete, menu, scroll
    }
    private var pendingTap: Double?
    private var pressedAt: Double?
    private var prefix = false
    private var editable = false
    private var dragAllowed = false
    private var dragging = false
    private var held = false
    private var scrolling = false
    var hasInteraction: Bool { pendingTap != nil || pressedAt != nil }

    mutating func down(at time: Double, editable: Bool, dragAllowed: Bool) -> [Effect] {
        let effects = tick(at: time)
        prefix = pendingTap != nil
        pendingTap = nil
        pressedAt = time
        self.editable = editable
        self.dragAllowed = dragAllowed
        dragging = false; held = false; scrolling = false
        return effects
    }

    mutating func tick(at time: Double) -> [Effect] {
        if let pendingTap, time - pendingTap >= Self.tapWindow {
            self.pendingTap = nil
            return [.tap]
        }
        if let pressedAt, editable, !held, !dragging, !scrolling, time - pressedAt >= Self.holdTime {
            held = true
            return [.copyReady]
        }
        return []
    }

    mutating func move(distance: Double, at time: Double) -> [Effect] {
        guard pressedAt != nil, !scrolling else { return [] }
        if dragging { return [.drag] }
        guard distance >= Self.dragDistance else { return tick(at: time) }
        guard editable && dragAllowed else {
            scrolling = true; pendingTap = nil
            return [.scroll]
        }
        let copying = prefix || held || time - (pressedAt ?? time) >= Self.holdTime
        dragging = true
        return [.beginDrag(copy: copying)]
    }

    mutating func up(at time: Double) -> [Effect] {
        guard let pressedAt else { return [] }
        self.pressedAt = nil
        if scrolling { return [] }
        if dragging { return [.drop] }
        if editable && (held || time - pressedAt >= Self.holdTime) { return [prefix ? .delete : .menu] }
        if editable && prefix { return [.edit] }
        if editable { pendingTap = time; return [] }
        if time - pressedAt >= Self.holdTime { return [.menu] }
        return [.tap]
    }

    mutating func cancel() { self = Self() }
}

struct PatternCell: Hashable {
    var slot: Int
    var row: Int
    var id: Int { slot * 8 + row }
}

struct PianoRollViewport: Equatable {
    static let minimumBeatWidth = 24.0
    static let maximumBeatWidth = 480.0
    static let minimumPitchHeight = 8.0
    static let maximumPitchHeight = 64.0
    var beatWidth = 96.0
    var pitchHeight = 20.0
    var leftTick = 0.0
    var topPitch = 84.0

    func tick(at x: Double) -> Double { leftTick + x * 960 / beatWidth }
    func pitch(at y: Double) -> Double { topPitch - y / pitchHeight }
    func x(forTick tick: Double) -> Double { (tick - leftTick) * beatWidth / 960 }
    func y(forPitch pitch: Double) -> Double { (topPitch - pitch) * pitchHeight }

    mutating func clamp(length: Int64, intro: Int64, size: CoreGraphics.CGSize) {
        beatWidth = min(Self.maximumBeatWidth, max(Self.minimumBeatWidth, beatWidth))
        pitchHeight = min(Self.maximumPitchHeight, max(Self.minimumPitchHeight, pitchHeight))
        let visibleTicks = Double(max(0, size.width)) * 960 / beatWidth
        let visiblePitches = Double(max(0, size.height)) / pitchHeight
        leftTick = min(Double(length) + 960, max(-Double(intro) - visibleTicks + 960, leftTick))
        topPitch = min(127 + visiblePitches - 1, max(0, topPitch))
    }
}

struct PianoRollNavigation {
    private struct Axis {
        var separation: Double
        var scale: Double
        var sign: Double
    }
    private static let deadZone = 12.0
    private var horizontal: Axis
    private var vertical: Axis
    private let anchorTick: Double
    private let anchorPitch: Double

    init(viewport: PianoRollViewport, first: CoreGraphics.CGPoint, second: CoreGraphics.CGPoint) {
        let dx = Double(second.x - first.x), dy = Double(second.y - first.y)
        horizontal = Axis(separation: abs(dx), scale: viewport.beatWidth, sign: dx.sign == .minus ? -1 : 1)
        vertical = Axis(separation: abs(dy), scale: viewport.pitchHeight, sign: dy.sign == .minus ? -1 : 1)
        anchorTick = viewport.tick(at: Double(first.x + second.x) / 2)
        anchorPitch = viewport.pitch(at: Double(first.y + second.y) / 2)
    }

    private static func scale(_ axis: inout Axis, delta: Double, current: Double,
                              minimum: Double, maximum: Double) -> Double {
        let distance = abs(delta)
        let sign = delta.sign == .minus ? -1.0 : 1.0
        if distance < deadZone {
            axis.separation = 0
            axis.scale = current
            return current
        }
        if axis.separation < deadZone || axis.sign != sign {
            axis = Axis(separation: distance, scale: current, sign: sign)
            return current
        }
        return min(maximum, max(minimum, axis.scale * distance / axis.separation))
    }

    mutating func update(viewport: inout PianoRollViewport, first: CoreGraphics.CGPoint,
                         second: CoreGraphics.CGPoint) {
        viewport.beatWidth = Self.scale(&horizontal, delta: Double(second.x - first.x), current: viewport.beatWidth,
                                        minimum: PianoRollViewport.minimumBeatWidth, maximum: PianoRollViewport.maximumBeatWidth)
        viewport.pitchHeight = Self.scale(&vertical, delta: Double(second.y - first.y), current: viewport.pitchHeight,
                                          minimum: PianoRollViewport.minimumPitchHeight, maximum: PianoRollViewport.maximumPitchHeight)
        let midX = Double(first.x + second.x) / 2
        let midY = Double(first.y + second.y) / 2
        viewport.leftTick = anchorTick - midX * 960 / viewport.beatWidth
        viewport.topPitch = anchorPitch + midY / viewport.pitchHeight
    }
}

struct PianoRollTouchArbitration {
    enum Mode: Equatable { case idle, editing, navigating, awaitingRelease }
    private(set) var mode: Mode = .idle
    mutating func begin() { if mode == .idle { mode = .editing } }
    mutating func secondFinger() -> Bool {
        guard mode == .editing else { return false }
        mode = .navigating
        return true
    }
    mutating func fingerLifted() { if mode == .navigating { mode = .awaitingRelease } }
    mutating func allReleased() { mode = .idle }
    mutating func cancel() { mode = .idle }
}

enum PianoRollNoteHit {
    enum Zone: Equatable { case velocity, body, duration }
    static func zone(x: Double, width: Double) -> Zone {
        let edge = min(12, max(0, width) / 3)
        if x < edge { return .velocity }
        if x >= width - edge { return .duration }
        return .body
    }

    static func rectangle(_ note: SequencerNote, viewport: PianoRollViewport) -> CoreGraphics.CGRect {
        CoreGraphics.CGRect(x: viewport.x(forTick: Double(note.start)),
            y: viewport.y(forPitch: Double(note.pitch)),
            width: max(2, Double(note.duration) * viewport.beatWidth / 960),
            height: viewport.pitchHeight)
    }

    static func pitch(y: Double, viewport: PianoRollViewport) -> Int {
        Int(viewport.pitch(at: y).rounded(.up))
    }

    static func velocity(y: Double, height: Double) -> Int {
        guard height > 0 else { return 1 }
        let fraction = min(1, max(0, 1 - y / height))
        return min(127, max(1, Int((fraction * 127).rounded())))
    }

    static func hit(point: CoreGraphics.CGPoint, notes: [SequencerNote], viewport: PianoRollViewport)
        -> (id: UInt64, zone: Zone)? {
        for note in notes.reversed() {
            let rect = rectangle(note, viewport: viewport)
            let target = rect.insetBy(dx: -max(0, (18 - rect.width) / 2), dy: 0)
            if target.contains(point) {
                let relative = min(rect.width, max(0, point.x - rect.minX))
                return (note.id, zone(x: relative, width: rect.width))
            }
        }
        return nil
    }
}

enum PianoRollMarker: Int, CaseIterable {
    case patternStart, loopStart, loopEnd, tailEnd

    var title: String {
        switch self {
        case .patternStart: "START"
        case .loopStart: "LOOP"
        case .loopEnd: "END"
        case .tailEnd: "TAIL"
        }
    }

    func tick(in pattern: SequencerPattern) -> Int64 {
        switch self {
        case .patternStart: pattern.patternStart
        case .loopStart: pattern.hasRegions ? pattern.loopStart : 0
        case .loopEnd: pattern.hasRegions ? pattern.loopEnd : pattern.length
        case .tailEnd: pattern.length
        }
    }

    static func hit(_ point: CoreGraphics.CGPoint, pattern: SequencerPattern,
                    viewport: PianoRollViewport) -> PianoRollMarker? {
        let row = Int(floor((Double(point.y) + 60) / 15))
        guard let marker = Self(rawValue: row), point.y >= -60, point.y < 0 else { return nil }
        return abs(viewport.x(forTick: Double(marker.tick(in: pattern))) - Double(point.x)) <= 16 ? marker : nil
    }
}

enum PianoRollPosition {
    static func parse(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains(":") { return Int64(value) }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let bar = Int64(parts[0]), let beat = Int64(parts[1]),
              let tick = Int64(parts[2]), bar >= 1, (1...4).contains(beat), (0..<960).contains(tick),
              bar <= SequencerPattern.maxTicks / 3840 + 1 else { return nil }
        let result = (bar - 1) * 3840 + (beat - 1) * 960 + tick
        return result <= SequencerPattern.maxTicks ? result : nil
    }

    static func format(_ tick: Int64) -> String {
        guard tick >= 0 else { return String(tick) }
        return "\(tick / 3840 + 1):\(tick % 3840 / 960 + 1):\(tick % 960)"
    }
}

struct PianoRollEditBuffer {
    enum Scale: CaseIterable {
        case chromatic, major, naturalMinor, harmonicMinor, melodicMinor
        case majorPentatonic, minorPentatonic, dorian, phrygian, lydian, mixolydian, locrian

        var pitchClasses: [Int] {
            switch self {
            case .chromatic: Array(0...11)
            case .major: [0, 2, 4, 5, 7, 9, 11]
            case .naturalMinor: [0, 2, 3, 5, 7, 8, 10]
            case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
            case .melodicMinor: [0, 2, 3, 5, 7, 9, 11]
            case .majorPentatonic: [0, 2, 4, 7, 9]
            case .minorPentatonic: [0, 3, 5, 7, 10]
            case .dorian: [0, 2, 3, 5, 7, 9, 10]
            case .phrygian: [0, 1, 3, 5, 7, 8, 10]
            case .lydian: [0, 2, 4, 6, 7, 9, 11]
            case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
            case .locrian: [0, 1, 3, 5, 6, 8, 10]
            }
        }
    }
    enum ScaleDirection { case nearest, up, down }
    private(set) var pattern: SequencerPattern
    var selection: Set<UInt64> = []
    private var undoStack: [SequencerPattern] = []
    private var redoStack: [SequencerPattern] = []
    private var nextNoteID: UInt64
    private var nextAutomationID: UInt64
    private static let historyLimit = 32

    init(pattern: SequencerPattern) throws {
        try pattern.validate()
        self.pattern = pattern
        nextNoteID = (pattern.notes.map(\.id).max() ?? 0) + 1
        nextAutomationID = (pattern.automation.map(\.id).max() ?? 0) + 1
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private mutating func commit(_ candidate: SequencerPattern) throws {
        try candidate.validate()
        guard candidate != pattern else { return }
        undoStack.append(pattern)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        pattern = candidate
        selection.formIntersection(Set(pattern.notes.map(\.id)))
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(pattern)
        pattern = previous
        selection.formIntersection(Set(pattern.notes.map(\.id)))
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pattern)
        pattern = next
        selection.formIntersection(Set(pattern.notes.map(\.id)))
    }

    private func selectedIndices() throws -> [Int] {
        let indices = pattern.notes.indices.filter { selection.contains(pattern.notes[$0].id) }
        guard !indices.isEmpty else { throw SceneError.invalid("Select at least one note.") }
        return indices
    }

    private func operationIndices() -> [Int] {
        pattern.notes.indices.filter { selection.isEmpty || selection.contains(pattern.notes[$0].id) }
    }

    mutating func create(start: Int64, pitch: Int, duration: Int64, velocity: Int, output: Bool) throws {
        guard pattern.notes.count < 1024, nextNoteID < UInt64.max else {
            throw SceneError.invalid("The pattern has no remaining note capacity or IDs.")
        }
        var candidate = pattern
        candidate.notes.append(SequencerNote(id: nextNoteID, start: start, duration: duration,
                                             pitch: pitch, velocity: velocity, output: output))
        try commit(candidate)
        selection = [nextNoteID]
        nextNoteID += 1
    }

    func copySelection() throws -> [SequencerNote] {
        try selectedIndices().map { pattern.notes[$0] }
    }

    mutating func paste(_ notes: [SequencerNote], at anchor: Int64) throws {
        guard !notes.isEmpty else { throw SceneError.invalid("Copy notes before pasting.") }
        guard notes.count <= 1024 - pattern.notes.count,
              UInt64(notes.count) <= UInt64.max - nextNoteID else {
            throw SceneError.invalid("The pattern has no remaining note capacity or IDs.")
        }
        let first = notes.map(\.start).min()!
        var candidate = pattern
        var newSelection: Set<UInt64> = []
        var next = nextNoteID
        for var note in notes {
            let (offset, offsetOverflow) = note.start.subtractingReportingOverflow(first)
            let (start, startOverflow) = anchor.addingReportingOverflow(offset)
            guard !offsetOverflow, !startOverflow else { throw SceneError.invalid("Paste timing is outside the supported range.") }
            note.start = start
            note.id = next
            next += 1
            candidate.notes.append(note)
            newSelection.insert(note.id)
        }
        try commit(candidate)
        nextNoteID = next
        selection = newSelection
    }

    mutating func transpose(by semitones: Int) throws {
        let indices = operationIndices()
        guard !indices.isEmpty else { return }
        let minimum = indices.map { -pattern.notes[$0].pitch }.max()!
        let maximum = indices.map { 127 - pattern.notes[$0].pitch }.min()!
        guard (minimum...maximum).contains(semitones) else {
            throw SceneError.invalid("Transposition would move a note outside MIDI pitches 0–127.")
        }
        var candidate = pattern
        for index in indices { candidate.notes[index].pitch += semitones }
        try commit(candidate)
    }

    mutating func playbackQuantization(grid: Int) throws {
        guard (0...3840).contains(grid) else { throw SceneError.invalid("Invalid quantization grid.") }
        var candidate = pattern
        candidate.quantize = grid
        try commit(candidate)
    }

    mutating func regions(patternStart: Int64, loopStart: Int64, loopEnd: Int64,
                          tailEnd: Int64, loop: Bool) throws {
        guard patternStart >= -11520, patternStart <= loopStart,
              loopStart < loopEnd, loopEnd <= tailEnd, tailEnd <= SequencerPattern.maxTicks else {
            throw SceneError.invalid("Require -11520 ≤ pattern start ≤ loop start < loop end ≤ tail end.")
        }
        var candidate = pattern
        candidate.version = 6
        candidate.regionsEnabled = true
        candidate.regionStart = patternStart
        candidate.intro = max(candidate.intro, -min(0, patternStart))
        candidate.loopStart = loopStart
        candidate.loopEnd = loopEnd
        candidate.length = tailEnd
        candidate.loop = loop
        try commit(candidate)
    }

    mutating func setAutomation(_ points: [SequencerAutomation]) throws {
        var candidate = pattern
        candidate.regionsEnabled = pattern.hasRegions
        candidate.version = max(4, candidate.version)
        candidate.automation = points.sorted { $0.tick == $1.tick ? $0.id < $1.id : $0.tick < $1.tick }
        try commit(candidate)
        nextAutomationID = max(nextAutomationID, (points.map(\.id).max() ?? 0) + 1)
    }

    mutating func automationStroke(_ values: [(tick: Int64, value: Int)],
                                   kind: SequencerAutomation.Kind, controller: Int) throws {
        guard let first = values.map(\.tick).min(), let last = values.map(\.tick).max(),
              !values.isEmpty else { throw SceneError.invalid("An automation stroke must contain a point.") }
        var points = pattern.automation.filter {
            !($0.kind == kind && $0.controller == controller && (first...last).contains($0.tick))
        }

        guard values.count <= 256 - points.count, UInt64(values.count) <= UInt64.max - nextAutomationID else {
            throw SceneError.invalid("The pattern cannot hold more than 256 automation points.")
        }
        var next = nextAutomationID
        for value in values {
            points.append(SequencerAutomation(id: next, tick: value.tick, kind: kind,
                                               controller: controller, value: value.value))
            next += 1
        }
        try setAutomation(points)
        nextAutomationID = next
    }

    mutating func quantizeNotes(grid: Int, strength: Int, ends: Bool) throws {
        guard (0...3840).contains(grid), (0...100).contains(strength) else {
            throw SceneError.invalid("Invalid note quantization.")
        }
        let indices = operationIndices()
        guard !indices.isEmpty else { return }
        var candidate = pattern
        candidate.regionsEnabled = pattern.hasRegions
        candidate.version = max(5, candidate.version)
        for index in indices {
            candidate.notes[index].quantization = NoteQuantization(grid: grid, strength: strength, ends: ends)
        }
        try commit(candidate)
    }

    mutating func conform(root: Int, scale: Scale, direction: ScaleDirection) throws {
        guard (0...11).contains(root) else { throw SceneError.invalid("Invalid scale root.") }
        let allowed = Set(scale.pitchClasses.map { ($0 + root) % 12 })
        let indices = operationIndices()
        var candidate = pattern
        for index in indices {
            let pitch = pattern.notes[index].pitch
            let options = (0...127).filter { allowed.contains($0 % 12) }
            let mapped: Int?
            switch direction {
            case .up: mapped = options.first { $0 >= pitch }
            case .down: mapped = options.last { $0 <= pitch }
            case .nearest:
                mapped = options.min { abs($0 - pitch) == abs($1 - pitch) ? $0 < $1 : abs($0 - pitch) < abs($1 - pitch) }
            }
            guard let mapped else { throw SceneError.invalid("The scale has no valid pitch in the chosen direction.") }
            candidate.notes[index].pitch = mapped
        }
        try commit(candidate)
    }

    mutating func move(ticks: Int64, semitones: Int, copying: Bool = false) throws {
        let indices = try selectedIndices()
        let notes = indices.map { pattern.notes[$0] }
        let minTick = notes.map { -pattern.intro - $0.start }.max()!
        let maxTick = notes.map { pattern.length - 1 - $0.start }.min()!
        let minPitch = notes.map { -$0.pitch }.max()!
        let maxPitch = notes.map { 127 - $0.pitch }.min()!
        let dt = min(maxTick, max(minTick, ticks))
        let dp = min(maxPitch, max(minPitch, semitones))
        var candidate = pattern
        if copying {
            guard candidate.notes.count + notes.count <= 1024 else {
                throw SceneError.invalid("The pattern cannot hold more than 1024 notes.")
            }
            guard nextNoteID <= UInt64.max - UInt64(notes.count) else {
                throw SceneError.invalid("No note IDs remain available.")
            }
            var nextID = nextNoteID
            var newSelection: Set<UInt64> = []
            for var note in notes {
                note.id = nextID; note.start += dt; note.pitch += dp
                nextID += 1
                candidate.notes.append(note)
                newSelection.insert(note.id)
            }
            try commit(candidate)
            nextNoteID = nextID
            selection = newSelection
        } else {
            for index in indices {
                candidate.notes[index].start += dt
                candidate.notes[index].pitch += dp
            }
            try commit(candidate)
        }
    }

    mutating func changeDuration(by delta: Int64) throws {
        let indices = try selectedIndices()
        let minimum = indices.map { 1 - pattern.notes[$0].duration }.max()!
        let maximum = indices.map { SequencerPattern.maxTicks - pattern.notes[$0].duration }.min()!
        let applied = min(maximum, max(minimum, delta))
        var candidate = pattern
        for index in indices { candidate.notes[index].duration += applied }
        try commit(candidate)
    }

    mutating func changeVelocity(by delta: Int) throws {
        let indices = try selectedIndices()
        let applied = min(127, max(-127, delta))
        var candidate = pattern
        for index in indices {
            candidate.notes[index].velocity = min(127, max(1, candidate.notes[index].velocity + applied))
        }
        try commit(candidate)
    }

    mutating func deleteSelection() throws {
        _ = try selectedIndices()
        var candidate = pattern
        candidate.notes.removeAll { selection.contains($0.id) }
        try commit(candidate)
    }
}

enum SequencerRecordingSelection {
    static func keyboardMask(slots: Set<Int>, instruments: [RackInstrument]) -> UInt32 {
        instruments.filter { slots.contains($0.slot) }.reduce(UInt32(0)) {
            $0 | (1 << ($1.channel - 1))
        }
    }
}

enum PatternGridHitTesting {
    static func contains(_ point: CoreGraphics.CGPoint, cells: [PatternCell: CoreGraphics.CGRect],
                         verticalViewport: CoreGraphics.CGRect, horizontalViewport: CoreGraphics.CGRect) -> Bool {
        let content = cells.values.reduce(CoreGraphics.CGRect.null) { $0.union($1) }
        return content.intersection(verticalViewport).intersection(horizontalViewport).contains(point)
    }

    static func target(at point: CoreGraphics.CGPoint, cells: [PatternCell: CoreGraphics.CGRect],
                       verticalViewport: CoreGraphics.CGRect, horizontalViewport: CoreGraphics.CGRect,
                       recordingCells: Set<Int>) -> PatternCell? {
        guard contains(point, cells: cells, verticalViewport: verticalViewport,
                       horizontalViewport: horizontalViewport) else { return nil }
        return cells.first { $0.value.contains(point) && !recordingCells.contains($0.key.id) }?.key
    }
}

struct PatternTransfer {
    var source: SequencerPattern
    var destination: PatternCell
    var sourceRevision: UInt64
    var targetRevision: UInt64
    var epoch: UInt64
    var copying = false
    var expectedDestination: SequencerPattern?
    var replace = false
    var deleting = false

    func applying(to patterns: [SequencerPattern]) throws -> [SequencerPattern] {
        try source.validate()
        if deleting {
            guard patterns.first(where: { $0.id == source.id }) == source else {
                throw SceneError.invalid("The pattern changed before deletion. No patterns were modified.")
            }
            return patterns.filter { $0.id != source.id }
        }
        guard patterns.first(where: { $0.id == source.id }) == source,
              patterns.first(where: { $0.id == destination.id }) == expectedDestination,
              expectedDestination == nil || replace else {
            throw SceneError.invalid("The source or destination changed. No patterns were modified.")
        }
        var moved = source
        moved.slot = destination.slot; moved.row = destination.row
        try moved.validate()
        return patterns.filter { $0.id != destination.id && (copying || $0.id != source.id) } + [moved]
    }

    func acknowledged(in patterns: [SequencerPattern], sourceUnchanged: Bool, destinationUnchanged: Bool) -> [SequencerPattern] {
        var result = patterns
        if !copying && sourceUnchanged { result.removeAll { $0.id == source.id } }
        if !deleting && destinationUnchanged {
            var target = source
            target.slot = destination.slot; target.row = destination.row
            result.removeAll { $0.id == target.id }
            result.append(target)
        }
        return result
    }
}

struct PendingPatternTransfer {
    var token: UInt64
    var transfer: PatternTransfer
}

struct PendingPianoPublication {
    var token: UInt64
    var epoch: UInt64
    var replacement: SequencerPattern

    func acknowledged(in patterns: [SequencerPattern], epoch: UInt64, revisionMatches: Bool) -> [SequencerPattern] {
        guard self.epoch == epoch && revisionMatches else { return patterns }
        return patterns.filter { $0.id != replacement.id } + [replacement]
    }
}

struct CircularNoteLayout: Equatable {
    struct Arc: Equatable {
        var lane: Int
        var start: Double
        var end: Double
        var pickup: Bool
    }
    let lanes: Int
    let arcs: [Arc]

    init(_ pattern: SequencerPattern) {
        let pitches = Set(pattern.notes.filter { $0.start >= 0 }.map(\.pitch)).sorted()
        lanes = min(8, pitches.count)
        let indices = Dictionary(uniqueKeysWithValues: pitches.enumerated().map { ($0.element, $0.offset) })
        var segments: [Arc] = []
        for note in pattern.notes where note.start >= 0 || pattern.introEnabled {
            let pickup = note.start < 0
            let lane = pickup ? -1 : (indices[note.pitch] ?? 0) * max(1, lanes) / max(1, pitches.count)
            let start = Double((note.start % pattern.length + pattern.length) % pattern.length) / Double(pattern.length)
            let extent = min(1, max(1 / 360.0, Double(note.duration) / Double(pattern.length)))
            if extent >= 1 {
                segments.append(Arc(lane: lane, start: 0, end: 1, pickup: pickup))
            } else {
                segments.append(Arc(lane: lane, start: start, end: min(1, start + extent), pickup: pickup))
                if start + extent > 1 {
                    segments.append(Arc(lane: lane, start: 0, end: start + extent - 1, pickup: pickup))
                }
            }
        }
        // Merge overlaps only within a visual lane; dense pitch sets use at most eight lanes.
        segments.sort { $0.lane == $1.lane ? $0.start < $1.start : $0.lane < $1.lane }
        var merged: [Arc] = []
        for arc in segments {
            if let last = merged.last, last.lane == arc.lane && arc.start <= last.end {
                merged[merged.count - 1].end = max(last.end, arc.end)
            } else {
                merged.append(arc)
            }
        }
        arcs = merged
    }
}

struct SavedRackScene: Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
}
