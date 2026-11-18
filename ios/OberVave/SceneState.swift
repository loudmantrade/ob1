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

enum PatternGridHitTesting {
    static func contains(_ point: CoreGraphics.CGPoint, cells: [PatternCell: CoreGraphics.CGRect],
                         verticalViewport: CoreGraphics.CGRect, horizontalViewport: CoreGraphics.CGRect) -> Bool {
        let content = cells.values.reduce(CoreGraphics.CGRect.null) { $0.union($1) }
        return content.intersection(verticalViewport).intersection(horizontalViewport).contains(point)
    }

    static func target(at point: CoreGraphics.CGPoint, cells: [PatternCell: CoreGraphics.CGRect],
                       verticalViewport: CoreGraphics.CGRect, horizontalViewport: CoreGraphics.CGRect,
                       recordingCell: Int?) -> PatternCell? {
        guard contains(point, cells: cells, verticalViewport: verticalViewport,
                       horizontalViewport: horizontalViewport) else { return nil }
        return cells.first { $0.value.contains(point) && $0.key.id != recordingCell }?.key
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
