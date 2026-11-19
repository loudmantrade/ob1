// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

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

    private struct EditGesture {
        let start: CGPoint
        let baseline: PianoRollEditBuffer
        let hit: (id: UInt64, zone: PianoRollNoteHit.Zone)?
        let copy: Bool
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
                Button("Delete") { command { try $0.deleteSelection() } }.disabled(editor?.selection.isEmpty != false || busy)
                Picker("Snap", selection: $snap) {
                    Text("Off").tag(Int64(0)); Text("1/4").tag(Int64(960))
                    Text("1/8").tag(Int64(480)); Text("1/16").tag(Int64(240))
                    Text("1/32").tag(Int64(120)); Text("1/8T").tag(Int64(320))
                }.pickerStyle(.menu)
                Button("Close", action: close).buttonStyle(.bordered)
            }
            Text("Two fingers: pan/zoom · Hold empty: create · Body: move · Left: velocity · Right: length")
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let gridSize = CGSize(width: max(0, proxy.size.width - 54), height: max(0, proxy.size.height - 26))
                Canvas { context, size in
                    draw(context: &context, size: size)
                }
                .overlay {
                    PianoRollNavigationSurface(viewport: $viewport, pattern: displayedPattern, gridSize: gridSize,
                                               onEdit: touch)
                }
                .onAppear { viewport.clamp(length: pattern.length, intro: pattern.intro, size: gridSize) }
                .onChange(of: proxy.size) { _ in
                    viewport.clamp(length: pattern.length, intro: pattern.intro, size: gridSize)
                }
            }
        }
        .padding()
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
            model.errorMessage = "The pattern changed while editing. Reopen the Piano Roll."
            return
        }
        let epoch = ov_seq_scene_epoch()
        let revision = ov_seq_cell_revision(UInt32(pattern.slot), UInt32(pattern.row))
        if model.publishPianoPattern(expected: previous.pattern, replacement: candidate.pattern,
                                     epoch: epoch, revision: revision) {
            beforePublication = previous
            editor = candidate
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

    private func snapped(_ tick: Double) -> Int64 {
        let value = snap == 0 ? tick.rounded() : (tick / Double(snap)).rounded() * Double(snap)
        return Int64(min(Double(SequencerPattern.maxTicks), max(-Double(SequencerPattern.maxTicks), value)))
    }

    private func touch(_ phase: PianoRollNavigationView.EditPhase, _ point: CGPoint) {
        guard !busy else { return }
        switch phase {
        case .begin:
            guard point.x >= 0, point.y >= 0, let current = editor else { return }
            let hit = PianoRollNoteHit.hit(point: point, notes: current.pattern.notes, viewport: viewport)
            let copy = hit?.zone == .body && hit.map { current.selection.contains($0.id) &&
                lastTap?.id == $0.id && ProcessInfo.processInfo.systemUptime - (lastTap?.time ?? 0) < 0.4 } == true
            gesture = EditGesture(start: point, baseline: current, hit: hit, copy: copy)
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
                        try preview.move(ticks: snapped(viewport.tick(at: Double(point.x))) -
                                         snapped(viewport.tick(at: Double(active.start.x))),
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
                if let hit = active.hit, lastTap?.id == hit.id,
                   ProcessInfo.processInfo.systemUptime - (lastTap?.time ?? 0) < 1.0 {
                    command { buffer in
                        if !buffer.selection.contains(hit.id) { buffer.selection = [hit.id] }
                        try buffer.deleteSelection()
                    }
                } else if active.hit == nil {
                    command { buffer in
                        let start = snapped(viewport.tick(at: Double(point.x)))
                        let pitch = Int(viewport.pitch(at: Double(point.y)).rounded(.down))
                        try buffer.create(start: start, pitch: pitch, duration: snap == 0 ? 240 : snap,
                                          velocity: 100, output: true)
                    }
                }
                lastTap = nil
            } else if let hit = active.hit {
                if editor?.selection.contains(hit.id) != true { editor?.selection = [hit.id] }
                lastTap = (hit.id, ProcessInfo.processInfo.systemUptime)
            } else {
                editor?.selection = []; lastTap = nil
            }
        case .cancel:
            if let active = gesture { editor = active.baseline }
            gesture = nil; selectionRect = nil; lastTap = nil
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let left: CGFloat = 54, top: CGFloat = 26
        let grid = CGRect(x: left, y: top, width: max(0, size.width - left), height: max(0, size.height - top))
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.9)))
        for pitch in 0...127 {
            let y = top + viewport.y(forPitch: Double(pitch))
            let row = CGRect(x: 0, y: y, width: size.width, height: viewport.pitchHeight)
            guard row.maxY >= top && row.minY <= size.height else { continue }
            let black = KeyboardZoneLayout.isBlack(pitch)
            context.fill(Path(row.intersection(CGRect(x: 0, y: top, width: size.width, height: grid.height))),
                         with: .color(black ? .white.opacity(0.04) : .white.opacity(0.09)))
            context.fill(Path(CGRect(x: 0, y: max(top, y), width: left - 1, height: max(0, min(size.height, y + viewport.pitchHeight) - max(top, y)))),
                         with: .color(black ? .gray.opacity(0.5) : .white.opacity(0.7)))
            if pitch % 12 == 0 && y >= top {
                context.draw(Text("C\(pitch / 12 - 1)").font(.caption2).foregroundColor(.black),
                             at: CGPoint(x: 22, y: y + viewport.pitchHeight / 2))
            }
        }
        let first = Int64(floor(viewport.tick(at: 0) / 960))
        let last = Int64(ceil(viewport.tick(at: Double(grid.width)) / 960))
        if first <= last {
            for beat in first...last {
                let x = left + viewport.x(forTick: Double(beat) * 960)
                var line = Path(); line.move(to: CGPoint(x: x, y: top)); line.addLine(to: CGPoint(x: x, y: size.height))
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
            context.fill(Path(roundedRect: rect.intersection(grid), cornerRadius: 3),
                         with: .color(editor?.selection.contains(note.id) == true ? .orange : .cyan))
        }
        if let selectionRect {
            let rect = selectionRect.offsetBy(dx: left, dy: top).intersection(grid)
            context.fill(Path(rect), with: .color(.orange.opacity(0.25)))
            context.stroke(Path(rect), with: .color(.orange), lineWidth: 1)
        }
        if Int(ov_seq_active(UInt32(pattern.slot))) == pattern.row {
            let tick = Double(ov_seq_position(UInt32(pattern.slot))) * Double(pattern.length) / 65535
            let x = left + viewport.x(forTick: tick)
            if x >= left && x <= size.width {
                var line = Path(); line.move(to: CGPoint(x: x, y: top)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.yellow), lineWidth: 2)
            }
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
        return CGPoint(x: point.x - 54, y: point.y - 26)
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
