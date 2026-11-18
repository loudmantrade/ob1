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

    static func read(from url: URL) throws -> RackSceneDocument {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576 else {
            throw SceneError.invalid("The scene must be a regular file no larger than 1 MB.")
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
    }
}

struct SavedRackScene: Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
}
