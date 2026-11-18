// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

struct SequencerTouchSurface: UIViewRepresentable {
    var editable: Bool
    var epoch: UInt64
    var revision: UInt64
    var onDown: () -> Void
    var onEffect: (PatternCellGesture.Effect, CGPoint) -> Void
    var onCancel: () -> Void

    func makeUIView(context: Context) -> SequencerTouchView {
        let view = SequencerTouchView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: SequencerTouchView, context: Context) {
        if view.epoch != epoch || view.revision != revision {
            let interrupted = view.touch.hasInteraction
            view.touch.cancelInteraction(notify: false)
            view.epoch = epoch
            view.revision = revision
            if interrupted { DispatchQueue.main.async(execute: onCancel) }
        }
        view.touch.editable = editable
        view.touch.onDown = onDown
        view.touch.onEffect = onEffect
        view.touch.onCancel = onCancel
    }

    static func dismantleUIView(_ view: SequencerTouchView, coordinator: ()) {
        view.touch.cancelInteraction(notify: false)
    }
}

final class SequencerTouchView: UIView {
    let touch = SequencerTouchRecognizer()
    var epoch: UInt64 = 0
    var revision: UInt64 = 0

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
        addGestureRecognizer(touch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                // Central note-diagram drags edit; edge/empty-cell drags fail promptly and scroll.
                scroll.panGestureRecognizer.require(toFail: touch)
            }
            ancestor = view.superview
        }
        if window == nil { touch.cancelInteraction(notify: false) }
    }
}

final class SequencerTouchRecognizer: UIGestureRecognizer {
    var editable = false
    var onDown: (() -> Void)?
    var onEffect: ((PatternCellGesture.Effect, CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private var machine = PatternCellGesture()
    private var timer: Timer?
    private var start = CGPoint.zero
    private var point = CGPoint.zero
    private var maximumDistance = 0.0
    private var touching = false
    var hasInteraction: Bool { machine.hasInteraction }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true
    }

    private func emit(_ effects: [PatternCellGesture.Effect]) {
        for effect in effects {
            switch effect {
            case .beginDrag: state = .began
            case .drag: state = .changed
            case .scroll: state = .failed
            default: break
            }
            onEffect?(effect, point)
        }
    }

    private func schedule(after delay: Double) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.emit(self.machine.tick(at: ProcessInfo.processInfo.systemUptime))
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !touching, touches.count == 1, let touch = touches.first, let view else {
            cancelInteraction(); state = .failed; return
        }
        touching = true
        point = touch.location(in: view.window)
        start = point; maximumDistance = 0
        let local = touch.location(in: view)
        let central = hypot(local.x - view.bounds.midX, local.y - view.bounds.midY) <= 23
        emit(machine.down(at: ProcessInfo.processInfo.systemUptime, editable: editable, dragAllowed: central))
        onDown?()
        schedule(after: PatternCellGesture.holdTime + 0.005)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        point = touch.location(in: view?.window)
        maximumDistance = max(maximumDistance, hypot(point.x - start.x, point.y - start.y))
        emit(machine.move(distance: maximumDistance, at: ProcessInfo.processInfo.systemUptime))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { point = touch.location(in: view?.window) }
        timer?.invalidate()
        touching = false
        emit(machine.up(at: ProcessInfo.processInfo.systemUptime))
        if state != .failed { state = .ended }
        schedule(after: PatternCellGesture.tapWindow + 0.005)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancelInteraction()
        state = .cancelled
    }

    func cancelInteraction(notify: Bool = true) {
        timer?.invalidate(); timer = nil
        machine.cancel(); touching = false
        if notify { onCancel?() }
    }
}
