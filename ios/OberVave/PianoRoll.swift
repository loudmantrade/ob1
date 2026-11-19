// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

private let pianoRollRulerHeight: CGFloat = 78

struct PianoRollView: View {
    @ObservedObject var model: OberVaveModel
    let pattern: SequencerPattern
    let close: () -> Void
    private let sceneEpoch: UInt64
    @State private var viewport: PianoRollViewport
    @State private var editor: PianoRollEditBuffer?
    @State private var beforePublication: PianoRollEditBuffer?
    @State private var gesture: EditGesture?
    @State private var lastTap: (id: UInt64, time: TimeInterval)?
    @State private var selectionRect: CGRect?
    @State private var snap: Int64 = 240
    @State private var customGrid: Int64 = 240
    @State private var customGridInput = ""
    @State private var showCustomGrid = false
    @State private var clipboard: [SequencerNote] = []
    @State private var pasteAnchor: Int64 = 0
    @State private var scaleRoot = 0
    @State private var scale: PianoRollEditBuffer.Scale = .major
    @State private var scaleDirection: PianoRollEditBuffer.ScaleDirection = .nearest
    @State private var quantizeStrength = 100
    @State private var quantizeEnds = false
    @State private var showRegions = false
    @State private var showTranspose = false
    @State private var transposeAmount = ""
    @State private var lane: Lane = .none
    @State private var laneMode: LaneMode = .points
    @State private var controller = 1
    @State private var gridHeight: CGFloat = 0
    @State private var laneGesture: AutomationGesture?
    @State private var velocityGesture: VelocityGesture?
    @State private var markerGesture: MarkerGesture?

    private enum Lane: String, CaseIterable { case none = "Off", velocity = "Velocity", cc = "CC", bend = "Pitch Bend" }
    private enum LaneMode: String, CaseIterable { case points = "Points", draw = "Freehand" }
    private let laneHeight: CGFloat = 125

    private struct AutomationGesture {
        let baseline: PianoRollEditBuffer
        let pointID: UInt64?
        var samples: [Int64: Int] = [:]
        var last: (tick: Int64, value: Int)?
        var moved = false
        var held = false
        let start: CGPoint
    }
    private struct VelocityGesture {
        let baseline: PianoRollEditBuffer
        let note: SequencerNote
    }
    private struct MarkerGesture {
        let baseline: PianoRollEditBuffer
        let marker: PianoRollMarker
        let start: CGPoint
        var moved = false
        var candidate: PianoRollEditBuffer?
        var error: String?
    }

    private struct EditGesture {
        let start: CGPoint
        let baseline: PianoRollEditBuffer
        let hit: (id: UInt64, zone: PianoRollNoteHit.Zone)?
        let copy: Bool
        let deleteAfterHold: Bool
        var moved = false
        var held = false
    }

    private var displayedPattern: SequencerPattern { editor?.pattern ?? pattern }

    init(model: OberVaveModel, pattern: SequencerPattern, close: @escaping () -> Void) {
        self.model = model
        self.pattern = pattern
        self.close = close
        sceneEpoch = model.sequencerInteractionEpoch
        _viewport = State(initialValue: model.pianoRollViewports[pattern.id] ?? PianoRollViewport())
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Piano Roll · \(pattern.name)").font(.headline)
                Spacer()
                Button("Undo") { command { $0.undo() } }.disabled(editor?.canUndo != true || busy)
                Button("Redo") { command { $0.redo() } }.disabled(editor?.canRedo != true || busy)
                Button("Copy") {
                    do { clipboard = try editor?.copySelection() ?? [] }
                    catch { model.errorMessage = error.localizedDescription }
                }.disabled(editor?.selection.isEmpty != false || busy)
                Button("Paste") { command { try $0.paste(clipboard, at: pasteAnchor) } }
                    .disabled(clipboard.isEmpty || busy)
                Button("Delete") { command { try $0.deleteSelection() } }.disabled(editor?.selection.isEmpty != false || busy)
                Button("Regions") { showRegions = true }.disabled(busy)
                Menu("Music") {
                    Button("Transpose +1") { command { try $0.transpose(by: 1) } }
                    Button("Transpose -1") { command { try $0.transpose(by: -1) } }
                    Button("Octave up") { command { try $0.transpose(by: 12) } }
                    Button("Octave down") { command { try $0.transpose(by: -12) } }
                    Button("Transpose by semitones…") { transposeAmount = ""; showTranspose = true }
                    Menu("Playback quantize · all notes") {
                        Button("Off") { command { try $0.playbackQuantization(grid: 0) } }
                        Button("1/4") { command { try $0.playbackQuantization(grid: 960) } }
                        Button("1/8") { command { try $0.playbackQuantization(grid: 480) } }
                        Button("1/16") { command { try $0.playbackQuantization(grid: 240) } }
                        Button("1/32") { command { try $0.playbackQuantization(grid: 120) } }
                        Button("1/8 triplet") { command { try $0.playbackQuantization(grid: 320) } }
                        Button("Custom · \(customGrid) ticks") { command { try $0.playbackQuantization(grid: Int(customGrid)) } }
                    }
                    Menu("Quantize selection / all") {
                        Picker("Strength", selection: $quantizeStrength) {
                            Text("25%").tag(25); Text("50%").tag(50)
                            Text("75%").tag(75); Text("100%").tag(100)
                        }
                        Toggle("Quantize ends", isOn: $quantizeEnds)
                        Button("Off") { quantize(grid: 0) }
                        Button("1/4") { quantize(grid: 960) }
                        Button("1/8") { quantize(grid: 480) }
                        Button("1/16") { quantize(grid: 240) }
                        Button("1/32") { quantize(grid: 120) }
                        Button("1/8 triplet") { quantize(grid: 320) }
                        Button("Custom · \(customGrid) ticks") { quantize(grid: Int(customGrid)) }
                    }
                    Picker("Root", selection: $scaleRoot) {
                        ForEach(0..<12, id: \.self) { Text(["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][$0]).tag($0) }
                    }
                    Picker("Scale", selection: $scale) {
                        ForEach(PianoRollEditBuffer.Scale.allCases, id: \.self) { Text(String(describing: $0)).tag($0) }
                    }
                    Picker("Direction", selection: $scaleDirection) {
                        Text("Nearest").tag(PianoRollEditBuffer.ScaleDirection.nearest)
                        Text("Up").tag(PianoRollEditBuffer.ScaleDirection.up)
                        Text("Down").tag(PianoRollEditBuffer.ScaleDirection.down)
                    }
                    Button("Conform to scale") {
                        command { try $0.conform(root: scaleRoot, scale: scale, direction: scaleDirection) }
                    }
                }.disabled(busy)
                Menu("Snap · \(snap == 0 ? "Off" : "\(snap) ticks")") {
                    Button("Off") { snap = 0 }
                    Button("1/4") { snap = 960 }
                    Button("1/8") { snap = 480 }
                    Button("1/16") { snap = 240 }
                    Button("1/32") { snap = 120 }
                    Button("1/8 triplet") { snap = 320 }
                    Button("Custom…") { customGridInput = String(customGrid); showCustomGrid = true }
                }
                Button("Close", action: close).buttonStyle(.bordered)
            }
            Text("Two fingers: pan/zoom · Hold empty: create · Tap empty: paste anchor · Left: velocity · Right: length")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Lane", selection: $lane) {
                    ForEach(Lane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 250)
                if lane == .cc || lane == .bend {
                    Picker("Mode", selection: $laneMode) {
                        ForEach(LaneMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 200)
                    if lane == .cc {
                        Stepper("CC \(controller)", value: $controller, in: 0...127).frame(maxWidth: 150)
                    }
                    Text("Tap: point · Hold point: delete").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            GeometryReader { proxy in
                let gridSize = CGSize(width: max(0, proxy.size.width - 54),
                                      height: max(0, proxy.size.height - pianoRollRulerHeight - (lane == .none ? 0 : laneHeight)))
                Canvas { context, size in
                    draw(context: &context, size: size)
                }
                .overlay {
                    PianoRollNavigationSurface(viewport: $viewport, pattern: displayedPattern, gridSize: gridSize,
                                               onEdit: touch)
                }
                .onAppear {
                    gridHeight = gridSize.height
                    viewport.clamp(length: displayedPattern.length, intro: displayedPattern.intro, size: gridSize)
                }
                .onChange(of: proxy.size) { _ in
                    gridHeight = gridSize.height
                    viewport.clamp(length: displayedPattern.length, intro: displayedPattern.intro, size: gridSize)
                }
                .onChange(of: lane) { _ in
                    gridHeight = gridSize.height
                    viewport.clamp(length: displayedPattern.length, intro: displayedPattern.intro, size: gridSize)
                }
                .onChange(of: displayedPattern.length) { length in
                    viewport.clamp(length: length, intro: displayedPattern.intro, size: gridSize)
                }
                .onChange(of: displayedPattern.intro) { intro in
                    viewport.clamp(length: displayedPattern.length, intro: intro, size: gridSize)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showRegions) {
            PianoRollRegionsSheet(pattern: displayedPattern) { start, loopStart, loopEnd, tailEnd, loop in
                command { try $0.regions(patternStart: start, loopStart: loopStart, loopEnd: loopEnd,
                                         tailEnd: tailEnd, loop: loop) }
            }
        }
        .alert("Transpose by semitones", isPresented: $showTranspose) {
            TextField("Semitones", text: $transposeAmount).keyboardType(.numbersAndPunctuation)
            Button("Apply") {
                guard let amount = Int(transposeAmount) else {
                    model.errorMessage = "Enter an integer number of semitones."; return
                }
                command { try $0.transpose(by: amount) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Custom grid", isPresented: $showCustomGrid) {
            TextField("Ticks (1–3840)", text: $customGridInput).keyboardType(.numberPad)
            Button("Apply") {
                guard let value = Int64(customGridInput), (1...3840).contains(value) else {
                    model.errorMessage = "Enter a grid size between 1 and 3840 ticks."; return
                }
                customGrid = value
                snap = value
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            do { editor = try PianoRollEditBuffer(pattern: pattern) }
            catch { model.errorMessage = error.localizedDescription; close() }
        }
        .onChange(of: model.pendingPianoPublication?.token) { token in
            guard token == nil, let previous = beforePublication else { return }
            beforePublication = nil
            if model.pattern(slot: pattern.slot, row: pattern.row) != editor?.pattern {
                if let current = model.pattern(slot: pattern.slot, row: pattern.row) {
                    do { editor = try PianoRollEditBuffer(pattern: current) }
                    catch { model.errorMessage = error.localizedDescription; close() }
                } else {
                    editor = previous
                    model.errorMessage = "The pattern no longer exists."
                    close()
                }
            }
        }
        .onDisappear {
            if model.sequencerInteractionEpoch == sceneEpoch { model.pianoRollViewports[pattern.id] = viewport }
        }
    }

    private var busy: Bool { model.pendingPianoPublication != nil || beforePublication != nil }

    private func publish(_ candidate: PianoRollEditBuffer, replacing previous: PianoRollEditBuffer) {
        guard candidate.pattern != previous.pattern else { editor = candidate; return }
        guard !busy, model.pattern(slot: pattern.slot, row: pattern.row) == previous.pattern else {
            editor = previous
            model.errorMessage = "The pattern changed while editing. Reopen the Piano Roll."
            return
        }
        let epoch = ov_seq_scene_epoch()
        let revision = ov_seq_cell_revision(UInt32(pattern.slot), UInt32(pattern.row))
        if model.publishPianoPattern(expected: previous.pattern, replacement: candidate.pattern,
                                     epoch: epoch, revision: revision) {
            beforePublication = previous
            editor = candidate
        } else {
            editor = previous
        }
    }

    private func command(_ action: (inout PianoRollEditBuffer) throws -> Void) {
        guard !busy, let previous = editor else { return }
        var candidate = previous
        do {
            try action(&candidate)
            publish(candidate, replacing: previous)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func quantize(grid: Int) {
        command { try $0.quantizeNotes(grid: grid, strength: quantizeStrength, ends: quantizeEnds) }
    }

    private func snapped(_ tick: Double) -> Int64 {
        let value = snap == 0 ? tick.rounded() : (tick / Double(snap)).rounded() * Double(snap)
        return Int64(min(Double(SequencerPattern.maxTicks), max(-Double(SequencerPattern.maxTicks), value)))
    }

    private func touch(_ phase: PianoRollNavigationView.EditPhase, _ point: CGPoint) {
        guard !busy else { return }
        if markerGesture != nil || (phase == .begin && point.y < 0) {
            markerTouch(phase, point)
            return
        }
        if velocityGesture != nil || (phase == .begin && lane == .velocity && point.y >= gridHeight) {
            velocityTouch(phase, point)
            return
        }
        if laneGesture != nil || (phase == .begin && lane != .none && point.y >= gridHeight) {
            automationTouch(phase, point)
            return
        }
        switch phase {
        case .begin:
            guard point.x >= 0, point.y >= 0, let current = editor else { return }
            let hit = PianoRollNoteHit.hit(point: point, notes: current.pattern.notes, viewport: viewport)
            let prefix = hit.map {
                PianoRollTapSequence.isPrefix(note: $0.id, lastNote: lastTap?.id,
                    elapsed: ProcessInfo.processInfo.systemUptime - (lastTap?.time ?? 0))
            } == true
            let copy = hit?.zone == .body && hit.map { current.selection.contains($0.id) } == true && prefix
            gesture = EditGesture(start: point, baseline: current, hit: hit, copy: copy, deleteAfterHold: prefix)
        case .hold:
            guard var active = gesture, !active.moved else { return }
            active.held = true; gesture = active
        case .move:
            guard var active = gesture else { return }
            let dx = point.x - active.start.x, dy = point.y - active.start.y
            guard active.moved || hypot(dx, dy) >= 8 else { return }
            active.moved = true; gesture = active
            if let hit = active.hit {
                var preview = active.baseline
                if !preview.selection.contains(hit.id) { preview.selection = [hit.id] }
                editor = preview
                do {
                    switch hit.zone {
                    case .body:
                        guard let start = preview.pattern.notes.first(where: { $0.id == hit.id })?.start else {
                            throw SceneError.invalid("The selected note no longer exists.")
                        }
                        try preview.move(ticks: snapped(Double(start) + Double(dx) * 960 / viewport.beatWidth) - start,
                                         semitones: Int((-dy / viewport.pitchHeight).rounded()), copying: active.copy)
                    case .velocity: try preview.changeVelocity(by: Int((-dy / 2).rounded()))
                    case .duration: try preview.changeDuration(by: snapped(Double(dx) * 960 / viewport.beatWidth))
                    }
                    editor = preview
                } catch { model.errorMessage = error.localizedDescription }
            } else {
                let rect = CGRect(x: min(point.x, active.start.x), y: min(point.y, active.start.y),
                                  width: abs(dx), height: abs(dy))
                selectionRect = rect
                var preview = active.baseline
                preview.selection = Set(preview.pattern.notes.filter {
                    PianoRollNoteHit.rectangle($0, viewport: viewport).intersects(rect)
                }.map(\.id))
                editor = preview
            }
        case .end:
            guard let active = gesture else { return }
            gesture = nil; selectionRect = nil
            if active.moved {
                if active.hit != nil, let candidate = editor { publish(candidate, replacing: active.baseline) }
                return
            }
            editor = active.baseline
            if active.held {
                if let hit = active.hit, active.deleteAfterHold {
                    command { buffer in
                        if !buffer.selection.contains(hit.id) { buffer.selection = [hit.id] }
                        try buffer.deleteSelection()
                    }
                } else if active.hit == nil {
                    command { buffer in
                        let start = snapped(viewport.tick(at: Double(point.x)))
                        let pitch = PianoRollNoteHit.pitch(y: Double(point.y), viewport: viewport)
                        try buffer.create(start: start, pitch: pitch, duration: snap == 0 ? 240 : snap,
                                          velocity: 100, output: model.recordOutput)
                    }
                }
                lastTap = nil
            } else if let hit = active.hit {
                if editor?.selection.contains(hit.id) != true { editor?.selection = [hit.id] }
                if let note = editor?.pattern.notes.first(where: { $0.id == hit.id }),
                   ov_seq_audition(UInt32(pattern.slot), UInt32(note.pitch), UInt32(note.velocity),
                                   ov_seq_scene_epoch()) == 0 {
                    model.errorMessage = "Could not queue the note preview."
                }
                lastTap = (hit.id, ProcessInfo.processInfo.systemUptime)
            } else {
                editor?.selection = []; lastTap = nil
                pasteAnchor = snapped(viewport.tick(at: Double(point.x)))
            }
        case .cancel:
            if let active = gesture { editor = active.baseline }
            gesture = nil; selectionRect = nil; lastTap = nil
        }
    }

    private func markerTouch(_ phase: PianoRollNavigationView.EditPhase, _ point: CGPoint) {
        switch phase {
        case .begin:
            guard point.x >= 0, let current = editor,
                  let marker = PianoRollMarker.hit(point, pattern: current.pattern, viewport: viewport) else { return }
            guard current.pattern.hasRegions else {
                model.errorMessage = "Apply Regions before dragging markers to preserve legacy playback."
                return
            }
            markerGesture = MarkerGesture(baseline: current, marker: marker, start: point)
        case .move, .end:
            guard var active = markerGesture else { return }
            if abs(point.x - active.start.x) >= 8 { active.moved = true }
            if !active.moved {
                if phase == .end { markerGesture = nil } else { markerGesture = active }
                return
            }
            let pattern = active.baseline.pattern
            var start = pattern.patternStart, loopStart = pattern.loopStart
            var loopEnd = pattern.loopEnd, tailEnd = pattern.length
            let tick = snapped(viewport.tick(at: Double(point.x)))
            switch active.marker {
            case .patternStart: start = tick
            case .loopStart: loopStart = tick
            case .loopEnd: loopEnd = tick
            case .tailEnd: tailEnd = tick
            }
            var candidate = active.baseline
            do {
                try candidate.regions(patternStart: start, loopStart: loopStart, loopEnd: loopEnd,
                                      tailEnd: tailEnd, loop: pattern.loop)
                active.candidate = candidate; active.error = nil; editor = candidate
            } catch {
                active.candidate = nil; active.error = error.localizedDescription; editor = active.baseline
            }
            markerGesture = active
            if phase == .end {
                markerGesture = nil
                if let candidate = active.candidate { publish(candidate, replacing: active.baseline) }
                else if let error = active.error { model.errorMessage = error }
            }
        case .cancel:
            if let active = markerGesture { editor = active.baseline }
            markerGesture = nil
        case .hold: break
        }
    }

    private func velocityTouch(_ phase: PianoRollNavigationView.EditPhase, _ point: CGPoint) {
        switch phase {
        case .begin:
            guard point.x >= 0, let current = editor,
                  let note = current.pattern.notes.min(by: {
                      abs(viewport.x(forTick: Double($0.start)) - Double(point.x)) <
                      abs(viewport.x(forTick: Double($1.start)) - Double(point.x))
                  }), abs(viewport.x(forTick: Double(note.start)) - Double(point.x)) <= 12 else { return }
            velocityGesture = VelocityGesture(baseline: current, note: note)
        case .move, .end:
            guard let active = velocityGesture else { return }
            let value = PianoRollNoteHit.velocity(y: Double(point.y - gridHeight), height: Double(laneHeight))
            var candidate = active.baseline
            if !candidate.selection.contains(active.note.id) { candidate.selection = [active.note.id] }
            do {
                try candidate.changeVelocity(by: value - active.note.velocity)
                editor = candidate
                if phase == .end {
                    velocityGesture = nil
                    publish(candidate, replacing: active.baseline)
                }
            } catch {
                editor = active.baseline; velocityGesture = nil
                model.errorMessage = error.localizedDescription
            }
        case .cancel:
            if let active = velocityGesture { editor = active.baseline }
            velocityGesture = nil
        case .hold: break
        }
    }

    private func automationTouch(_ phase: PianoRollNavigationView.EditPhase, _ point: CGPoint) {
        let kind: SequencerAutomation.Kind = lane == .bend ? .pitchBend : .cc
        let cc = kind == .cc ? controller : 0
        let maxValue = kind == .cc ? 127 : 16383
        func coordinates(_ position: CGPoint, pattern: SequencerPattern) -> (tick: Int64, value: Int) {
            let tick = min(pattern.length - 1, max(-pattern.intro, snapped(viewport.tick(at: Double(position.x)))))
            let fraction = min(1, max(0, 1 - Double(position.y - gridHeight) / Double(laneHeight)))
            return (tick, Int((fraction * Double(maxValue)).rounded()))
        }
        switch phase {
        case .begin:
            guard point.x >= 0, let current = editor else { return }
            let hit = current.pattern.automation.filter { $0.kind == kind && $0.controller == cc }.min {
                abs(viewport.x(forTick: Double($0.tick)) - Double(point.x)) <
                abs(viewport.x(forTick: Double($1.tick)) - Double(point.x))
            }
            let pointID = hit.flatMap {
                abs(viewport.x(forTick: Double($0.tick)) - Double(point.x)) <= 12 ? $0.id : nil
            }
            var active = AutomationGesture(baseline: current, pointID: pointID, start: point)
            if laneMode == .draw {
                let sample = coordinates(point, pattern: current.pattern)
                active.samples[sample.tick] = sample.value
                active.last = sample
            }
            laneGesture = active
        case .hold:
            if laneGesture?.moved == false { laneGesture?.held = true }
        case .move, .end:
            guard var active = laneGesture else { return }
            if hypot(point.x - active.start.x, point.y - active.start.y) >= 8 { active.moved = true }
            if phase == .end && active.held && !active.moved, let id = active.pointID {
                laneGesture = nil
                command { buffer in try buffer.setAutomation(buffer.pattern.automation.filter { $0.id != id }) }
                return
            }
            if phase == .end && laneMode == .points && !active.moved && active.pointID != nil {
                laneGesture = nil
                return
            }
            if phase == .move && !active.moved { laneGesture = active; return }
            let sample = coordinates(point, pattern: active.baseline.pattern)
            if laneMode == .draw, let previous = active.last,
               previous.tick != sample.tick, previous.value != sample.value {
                let step = max(Int64(1), snap == 0 ? 120 : snap)
                let distance = abs(sample.tick - previous.tick)
                let count = min(Int64(257), distance / step)
                if count > 256 {
                    model.errorMessage = "The stroke exceeds the 256-point automation capacity."
                    editor = active.baseline; laneGesture = nil; return
                }
                if count > 0 {
                    for index in 1...count {
                        let fraction = Double(index * step) / Double(distance)
                        let tick = previous.tick + (sample.tick > previous.tick ? index * step : -index * step)
                        let value = Int((Double(previous.value) + fraction * Double(sample.value - previous.value)).rounded())
                        active.samples[tick] = value
                    }
                }
            }
            active.samples[sample.tick] = sample.value
            active.last = sample
            var candidate = active.baseline
            do {
                if laneMode == .points, let id = active.pointID {
                    var points = candidate.pattern.automation
                    guard let index = points.firstIndex(where: { $0.id == id }) else {
                        throw SceneError.invalid("The automation point no longer exists.")
                    }
                    points[index].tick = sample.tick; points[index].value = sample.value
                    try candidate.setAutomation(points)
                } else {
                    let samples = active.samples.map { (tick: $0.key, value: $0.value) }.sorted { $0.tick < $1.tick }
                    try candidate.automationStroke(samples, kind: kind, controller: cc)
                }
                editor = candidate; laneGesture = active
                if phase == .end {
                    laneGesture = nil
                    publish(candidate, replacing: active.baseline)
                }
            } catch {
                editor = active.baseline; laneGesture = nil
                model.errorMessage = error.localizedDescription
            }
        case .cancel:
            if let active = laneGesture { editor = active.baseline }
            laneGesture = nil
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let left: CGFloat = 54, top = pianoRollRulerHeight
        let grid = CGRect(x: left, y: top, width: max(0, size.width - left),
                          height: max(0, size.height - top - (lane == .none ? 0 : laneHeight)))
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.9)))
        for pitch in 0...127 {
            let y = top + viewport.y(forPitch: Double(pitch))
            let row = CGRect(x: 0, y: y, width: size.width, height: viewport.pitchHeight)
            guard row.maxY >= top && row.minY <= grid.maxY else { continue }
            let black = KeyboardZoneLayout.isBlack(pitch)
            context.fill(Path(row.intersection(CGRect(x: 0, y: top, width: size.width, height: grid.height))),
                         with: .color(black ? .white.opacity(0.04) : .white.opacity(0.09)))
            context.fill(Path(CGRect(x: 0, y: max(top, y), width: left - 1, height: max(0, min(grid.maxY, y + viewport.pitchHeight) - max(top, y)))),
                         with: .color(black ? .gray.opacity(0.5) : .white.opacity(0.7)))
            if pitch % 12 == 0 && y >= top {
                context.draw(Text("C\(pitch / 12 - 1)").font(.caption2).foregroundColor(.black),
                             at: CGPoint(x: 22, y: y + viewport.pitchHeight / 2))
            }
        }
        let current = displayedPattern
        if current.hasRegions {
            let tailX = max(left, left + viewport.x(forTick: Double(current.loopEnd)))
            if tailX < size.width {
                context.fill(Path(CGRect(x: tailX, y: top, width: size.width - tailX, height: grid.height)),
                             with: .color(.orange.opacity(0.10)))
            }
            for tick in PianoRollGrid.visibleTicks(from: viewport.tick(at: 0),
                                                   through: viewport.tick(at: Double(grid.width)),
                                                   snap: snap, beatWidth: viewport.beatWidth) where tick % 960 != 0 {
                let x = left + viewport.x(forTick: Double(tick))
                var line = Path(); line.move(to: CGPoint(x: x, y: top)); line.addLine(to: CGPoint(x: x, y: grid.maxY))
                context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            }
        }
        let first = Int64(floor(viewport.tick(at: 0) / 960))
        let last = Int64(ceil(viewport.tick(at: Double(grid.width)) / 960))
        if first <= last {
            for beat in first...last {
                let x = left + viewport.x(forTick: Double(beat) * 960)
                var line = Path(); line.move(to: CGPoint(x: x, y: top)); line.addLine(to: CGPoint(x: x, y: grid.maxY))
                context.stroke(line, with: .color(.white.opacity(beat % 4 == 0 ? 0.4 : 0.15)), lineWidth: 1)
                if beat % 4 == 0 {
                    context.draw(Text("\(beat / 4 + 1)").font(.caption2).foregroundColor(.white),
                                 at: CGPoint(x: x + 10, y: 13))
                }
            }
        }
        for note in displayedPattern.notes {
            let x = left + viewport.x(forTick: Double(note.start))
            let y = top + viewport.y(forPitch: Double(note.pitch))
            let rect = CGRect(x: x, y: y + 1, width: max(2, Double(note.duration) * viewport.beatWidth / 960),
                              height: max(2, viewport.pitchHeight - 2))
            guard rect.intersects(grid) else { continue }
            let selected = editor?.selection.contains(note.id) == true
            let color: Color = selected ? .orange : .cyan
            context.fill(Path(roundedRect: rect.intersection(grid), cornerRadius: 3),
                         with: .color(color.opacity(0.35 + 0.65 * Double(note.velocity) / 127)))
            if let active = gesture, active.moved, active.hit?.id == note.id {
                let label: String
                switch active.hit?.zone {
                case .velocity: label = "Velocity \(note.velocity)"
                case .duration: label = "Duration \(note.duration)"
                case .body: label = "Pitch \(note.pitch) · Tick \(note.start)"
                case nil: label = ""
                }
                context.draw(Text(label).font(.caption2).foregroundColor(.white),
                             at: CGPoint(x: min(size.width - 60, max(left + 60, rect.midX)),
                                         y: max(top + 8, rect.minY - 8)))
            }
        }
        let colors: [Color] = [.green, .cyan, .orange, .red]
        for marker in PianoRollMarker.allCases {
            let color = colors[marker.rawValue]
            let x = left + viewport.x(forTick: Double(marker.tick(in: current)))
            if x >= left && x <= size.width {
                var line = Path(); line.move(to: CGPoint(x: x, y: top)); line.addLine(to: CGPoint(x: x, y: grid.maxY))
                context.stroke(line, with: .color(color.opacity(0.8)), lineWidth: 1)
                let y = top - 60 + CGFloat(marker.rawValue) * 15 + 7.5
                context.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)),
                             with: .color(color))
                context.draw(Text(marker.title).font(.system(size: 9, weight: .bold)).foregroundColor(color),
                             at: CGPoint(x: x + 23, y: y))
            }
        }
        if let selectionRect {
            let rect = selectionRect.offsetBy(dx: left, dy: top).intersection(grid)
            context.fill(Path(rect), with: .color(.orange.opacity(0.25)))
            context.stroke(Path(rect), with: .color(.orange), lineWidth: 1)
        }
        if lane != .none {
            let rect = CGRect(x: left, y: grid.maxY, width: grid.width, height: laneHeight)
            context.fill(Path(rect), with: .color(.gray.opacity(0.18)))
            if lane == .velocity {
                for note in current.notes {
                    let x = left + viewport.x(forTick: Double(note.start))
                    guard x >= left && x <= size.width else { continue }
                    let y = grid.maxY + laneHeight * (1 - Double(note.velocity) / 127)
                    var line = Path(); line.move(to: CGPoint(x: x, y: grid.maxY + laneHeight))
                    line.addLine(to: CGPoint(x: x, y: y))
                    let color: Color = editor?.selection.contains(note.id) == true ? .orange : .cyan
                    context.stroke(line, with: .color(color), lineWidth: 3)
                    context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(color))
                }
            } else {
            let kind: SequencerAutomation.Kind = lane == .bend ? .pitchBend : .cc
            let cc = kind == .cc ? controller : 0
            let maxValue = kind == .cc ? 127.0 : 16383.0
            if lane == .bend {
                let center = grid.maxY + laneHeight * (1 - 8192 / maxValue)
                var line = Path(); line.move(to: CGPoint(x: left, y: center))
                line.addLine(to: CGPoint(x: size.width, y: center))
                context.stroke(line, with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
            let points = current.automation.filter { $0.kind == kind && $0.controller == cc }
            for point in points {
                let x = left + viewport.x(forTick: Double(point.tick))
                guard x >= left && x <= size.width else { continue }
                let y = grid.maxY + laneHeight * (1 - Double(point.value) / maxValue)
                var line = Path(); line.move(to: CGPoint(x: x, y: grid.maxY + laneHeight))
                line.addLine(to: CGPoint(x: x, y: y))
                context.stroke(line, with: .color(.cyan.opacity(0.55)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.cyan))
            }
            }
        }
        if Int(ov_seq_active(UInt32(pattern.slot))) == pattern.row {
            let tick = Double(ov_seq_position_ticks(UInt32(pattern.slot)))
            let x = left + viewport.x(forTick: tick)
            if x >= left && x <= size.width {
                var line = Path(); line.move(to: CGPoint(x: x, y: top)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.yellow), lineWidth: 2)
            }
        }
    }
}

struct PianoRollRegionsSheet: View {
    let apply: (Int64, Int64, Int64, Int64, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: String
    @State private var loopStart: String
    @State private var loopEnd: String
    @State private var tailEnd: String
    @State private var loop: Bool
    @State private var message: String?

    init(pattern: SequencerPattern, apply: @escaping (Int64, Int64, Int64, Int64, Bool) -> Void) {
        self.apply = apply
        _start = State(initialValue: PianoRollPosition.format(pattern.patternStart))
        _loopStart = State(initialValue: PianoRollPosition.format(pattern.hasRegions ? pattern.loopStart : 0))
        _loopEnd = State(initialValue: PianoRollPosition.format(pattern.hasRegions ? pattern.loopEnd : pattern.length))
        _tailEnd = State(initialValue: PianoRollPosition.format(pattern.length))
        _loop = State(initialValue: pattern.loop)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Positions: bar:beat:tick or raw ticks (960 per beat)") {
                    field("Pattern start", $start)
                    field("Loop start", $loopStart)
                    field("Loop end", $loopEnd)
                    field("Tail end", $tailEnd)
                    Toggle("Loop", isOn: $loop)
                }
                Section {
                    Text("Notes in the tail remain editable but do not start. Previously triggered notes end no later than Tail End. Applying regions changes legacy tail behavior.")
                        .font(.footnote)
                    if let message { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pattern regions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard let start = PianoRollPosition.parse(start), let loopStart = PianoRollPosition.parse(loopStart),
                              let loopEnd = PianoRollPosition.parse(loopEnd), let tailEnd = PianoRollPosition.parse(tailEnd),
                              start >= -11520, start <= loopStart, loopStart < loopEnd,
                              loopEnd <= tailEnd, tailEnd <= SequencerPattern.maxTicks else {
                            message = "Require -11520 ≤ start ≤ loop start < loop end ≤ tail end."
                            return
                        }
                        apply(start, loopStart, loopEnd, tailEnd, loop)
                        dismiss()
                    }
                }
            }
        }
    }

    private func field(_ title: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: value).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
        }
    }
}

struct PianoRollNavigationSurface: UIViewRepresentable {
    @Binding var viewport: PianoRollViewport
    let pattern: SequencerPattern
    let gridSize: CGSize
    let onEdit: (PianoRollNavigationView.EditPhase, CGPoint) -> Void

    func makeUIView(context: Context) -> PianoRollNavigationView { PianoRollNavigationView() }
    func updateUIView(_ view: PianoRollNavigationView, context: Context) {
        view.onEdit = onEdit
        view.onNavigation = { [weak view] first, second, beginning in
            guard let view else { return }
            if beginning { view.navigation = PianoRollNavigation(viewport: viewport, first: first, second: second) }
            view.navigation?.update(viewport: &viewport, first: first, second: second)
            viewport.clamp(length: pattern.length, intro: pattern.intro, size: gridSize)
        }
    }
}

final class PianoRollNavigationView: UIView {
    enum EditPhase { case begin, move, hold, end, cancel }
    var onNavigation: ((CGPoint, CGPoint, Bool) -> Void)?
    var onEdit: ((EditPhase, CGPoint) -> Void)?
    var navigation: PianoRollNavigation?
    private var fingers: [UITouch] = []
    private var arbitration = PianoRollTouchArbitration()
    private var holdTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func point(_ touch: UITouch) -> CGPoint {
        let point = touch.location(in: self)
        return CGPoint(x: point.x - 54, y: point.y - pianoRollRulerHeight)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where !fingers.contains(touch) { fingers.append(touch) }
        if fingers.count >= 2 && arbitration.mode == .idle { arbitration.begin() }
        if fingers.count == 1, let finger = fingers.first {
            arbitration.begin()
            onEdit?(.begin, point(finger))
            holdTimer?.invalidate()
            let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self, weak finger] _ in
                guard let self, let finger, self.arbitration.mode == .editing else { return }
                self.onEdit?(.hold, self.point(finger))
            }
            holdTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if fingers.count == 2 && arbitration.secondFinger() {
            holdTimer?.invalidate()
            onEdit?(.cancel, .zero)
            onNavigation?(point(fingers[0]), point(fingers[1]), true)
        } else if fingers.count > 2 {
            holdTimer?.invalidate(); onEdit?(.cancel, .zero)
            arbitration.fingerLifted(); navigation = nil
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if fingers.count == 2 && arbitration.mode == .navigating {
            onNavigation?(point(fingers[0]), point(fingers[1]), false)
        } else if fingers.count == 1 && arbitration.mode == .editing {
            onEdit?(.move, point(fingers[0]))
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if arbitration.mode == .editing, let finger = fingers.first, touches.contains(finger) {
            onEdit?(.end, point(finger))
        }
        holdTimer?.invalidate()
        fingers.removeAll { touches.contains($0) }
        if arbitration.mode == .navigating { arbitration.fingerLifted(); navigation = nil }
        if fingers.isEmpty { arbitration.allReleased() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdTimer?.invalidate(); onEdit?(.cancel, .zero)
        fingers.removeAll(); navigation = nil; arbitration.cancel()
    }
}
