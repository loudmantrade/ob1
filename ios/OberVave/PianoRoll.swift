// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

struct PianoRollView: View {
    @ObservedObject var model: OberVaveModel
    let pattern: SequencerPattern
    let close: () -> Void
    private let sceneEpoch: UInt64
    @State private var viewport: PianoRollViewport

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
                Text("Two fingers: pan and zoom").font(.caption).foregroundStyle(.secondary)
                Button("Close", action: close).buttonStyle(.bordered)
            }
            GeometryReader { proxy in
                let gridSize = CGSize(width: max(0, proxy.size.width - 54), height: max(0, proxy.size.height - 26))
                Canvas { context, size in
                    draw(context: &context, size: size)
                }
                .overlay {
                    PianoRollNavigationSurface(viewport: $viewport, pattern: pattern, gridSize: gridSize)
                }
                .onAppear { viewport.clamp(length: pattern.length, intro: pattern.intro, size: gridSize) }
                .onChange(of: proxy.size) { _ in
                    viewport.clamp(length: pattern.length, intro: pattern.intro, size: gridSize)
                }
            }
        }
        .padding()
        .onDisappear {
            if model.sequencerInteractionEpoch == sceneEpoch { model.pianoRollViewports[pattern.id] = viewport }
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
        for note in pattern.notes {
            let x = left + viewport.x(forTick: Double(note.start))
            let y = top + viewport.y(forPitch: Double(note.pitch))
            let rect = CGRect(x: x, y: y + 1, width: max(2, Double(note.duration) * viewport.beatWidth / 960),
                              height: max(2, viewport.pitchHeight - 2))
            guard rect.intersects(grid) else { continue }
            context.fill(Path(roundedRect: rect.intersection(grid), cornerRadius: 3), with: .color(.cyan))
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

    func makeUIView(context: Context) -> PianoRollNavigationView { PianoRollNavigationView() }
    func updateUIView(_ view: PianoRollNavigationView, context: Context) {
        view.onNavigation = { first, second, beginning in
            if beginning { view.navigation = PianoRollNavigation(viewport: viewport, first: first, second: second) }
            view.navigation?.update(viewport: &viewport, first: first, second: second)
            viewport.clamp(length: pattern.length, intro: pattern.intro, size: gridSize)
        }
    }
}

final class PianoRollNavigationView: UIView {
    var onNavigation: ((CGPoint, CGPoint, Bool) -> Void)?
    var navigation: PianoRollNavigation?
    private var fingers: [UITouch] = []
    private var arbitration = PianoRollTouchArbitration()

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
        if fingers.count == 1 { arbitration.begin() }
        if fingers.count == 2 && arbitration.secondFinger() {
            onNavigation?(point(fingers[0]), point(fingers[1]), true)
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if fingers.count == 2 && arbitration.mode == .navigating {
            onNavigation?(point(fingers[0]), point(fingers[1]), false)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingers.removeAll { touches.contains($0) }
        if arbitration.mode == .navigating { arbitration.fingerLifted(); navigation = nil }
        if fingers.isEmpty { arbitration.allReleased() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingers.removeAll(); navigation = nil; arbitration.cancel()
    }
}
