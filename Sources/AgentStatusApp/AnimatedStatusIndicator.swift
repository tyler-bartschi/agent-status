import AppKit
import AgentStatusCore
import QuartzCore
import SwiftUI

struct AnimatedStatusIndicator: NSViewRepresentable {
    let status: SessionStatus

    func makeNSView(context: Context) -> StatusIndicatorView {
        let view = StatusIndicatorView()
        view.configure(status: status)
        return view
    }

    func updateNSView(_ view: StatusIndicatorView, context: Context) {
        view.configure(status: status)
    }
}

final class StatusIndicatorView: NSView {
    private let pulseLayer = CAShapeLayer()
    private let baseLayer = CAShapeLayer()
    private let activityLayer = CAShapeLayer()
    private let glyphLayer = CAShapeLayer()

    private var status: SessionStatus?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpLayers()
        observeAccessibilitySettings()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpLayers()
        observeAccessibilitySettings()
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let status else { return }
        if !reduceMotion && animationsAreMissing(for: status) {
            render(status: status, animated: true)
        }
    }

    func configure(status: SessionStatus) {
        guard self.status != status else { return }
        self.status = status
        render(status: status, animated: !reduceMotion)
    }

    private func setUpLayers() {
        wantsLayer = true
        layer?.masksToBounds = false

        [pulseLayer, baseLayer, activityLayer, glyphLayer].forEach { shapeLayer in
            shapeLayer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "path": NSNull(),
                "transform": NSNull(),
                "opacity": NSNull(),
                "strokeEnd": NSNull(),
            ]
            layer?.addSublayer(shapeLayer)
        }

        activityLayer.fillColor = NSColor.clear.cgColor
        activityLayer.lineCap = .round
        glyphLayer.fillColor = NSColor.clear.cgColor
        glyphLayer.lineCap = .round
        glyphLayer.lineJoin = .round
    }

    private func observeAccessibilitySettings() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let newValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard newValue != self.reduceMotion else { return }
            self.reduceMotion = newValue
            if let status = self.status {
                self.render(status: status, animated: !newValue)
            }
        }
    }

    private func updateLayerGeometry() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }

        let frame = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        let lineWidth = max(1.25, side * 0.15)
        let circleRect = frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let circlePath = CGPath(
            ellipseIn: circleRect,
            transform: nil
        )
        let waitingDotPath = CGPath(
            ellipseIn: circleRect.insetBy(dx: side * 0.19, dy: side * 0.19),
            transform: nil
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        [pulseLayer, baseLayer, activityLayer, glyphLayer].forEach {
            $0.frame = bounds
            $0.contentsScale = window?.backingScaleFactor ?? 2
        }
        pulseLayer.path = circlePath
        baseLayer.path = status == .waiting ? waitingDotPath : circlePath
        activityLayer.path = circlePath
        pulseLayer.lineWidth = lineWidth
        baseLayer.lineWidth = lineWidth
        activityLayer.lineWidth = lineWidth
        glyphLayer.lineWidth = max(1.2, side * 0.14)
        glyphLayer.path = checkmarkPath(in: frame)
        CATransaction.commit()
    }

    private func checkmarkPath(in frame: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frame.minX + frame.width * 0.24, y: frame.midY))
        path.addLine(to: CGPoint(x: frame.minX + frame.width * 0.43, y: frame.minY + frame.height * 0.31))
        path.addLine(to: CGPoint(x: frame.minX + frame.width * 0.77, y: frame.minY + frame.height * 0.70))
        return path
    }

    private func render(status: SessionStatus, animated: Bool) {
        updateLayerGeometry()
        removeAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.opacity = 0
        pulseLayer.fillColor = NSColor.clear.cgColor
        pulseLayer.strokeColor = NSColor.clear.cgColor
        baseLayer.fillColor = NSColor.clear.cgColor
        baseLayer.strokeColor = NSColor.clear.cgColor
        activityLayer.strokeColor = NSColor.clear.cgColor
        activityLayer.strokeStart = 0
        activityLayer.strokeEnd = 1
        glyphLayer.strokeColor = NSColor.clear.cgColor
        glyphLayer.strokeEnd = 1
        CATransaction.commit()

        switch status {
        case .working:
            renderWorking(animated: animated)
        case .waiting:
            renderWaiting(animated: animated)
        case .finished:
            renderFinished(animated: animated)
        }
    }

    private func renderWorking(animated: Bool) {
        let yellow = NSColor.systemYellow
        baseLayer.strokeColor = yellow.withAlphaComponent(0.28).cgColor
        activityLayer.strokeColor = yellow.cgColor
        activityLayer.strokeEnd = 0.68

        guard animated else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 0.9
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        activityLayer.add(rotation, forKey: "working.rotation")
    }

    private func renderWaiting(animated: Bool) {
        let red = NSColor.systemRed
        baseLayer.fillColor = red.cgColor
        pulseLayer.strokeColor = red.cgColor

        guard animated else { return }
        pulseLayer.opacity = 1

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.42
        scale.toValue = 1

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0.08

        let pulse = CAAnimationGroup()
        pulse.animations = [scale, opacity]
        pulse.duration = 1.05
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.add(pulse, forKey: "waiting.pulse")

        let heartbeat = CABasicAnimation(keyPath: "transform.scale")
        heartbeat.fromValue = 0.78
        heartbeat.toValue = 1
        heartbeat.duration = 0.52
        heartbeat.autoreverses = true
        heartbeat.repeatCount = .infinity
        heartbeat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        baseLayer.add(heartbeat, forKey: "waiting.heartbeat")
    }

    private func renderFinished(animated: Bool) {
        baseLayer.fillColor = NSColor.systemGreen.cgColor
        glyphLayer.strokeColor = NSColor.white.cgColor

        guard animated else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.45
        pop.toValue = 1
        pop.mass = 0.7
        pop.stiffness = 260
        pop.damping = 15
        pop.initialVelocity = 0
        pop.duration = pop.settlingDuration
        layer?.add(pop, forKey: "finished.pop")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.32
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glyphLayer.add(draw, forKey: "finished.checkmark")
    }

    private func removeAnimations() {
        layer?.removeAllAnimations()
        pulseLayer.removeAllAnimations()
        baseLayer.removeAllAnimations()
        activityLayer.removeAllAnimations()
        glyphLayer.removeAllAnimations()
    }

    private func animationsAreMissing(for status: SessionStatus) -> Bool {
        switch status {
        case .working:
            activityLayer.animation(forKey: "working.rotation") == nil
        case .waiting:
            pulseLayer.animation(forKey: "waiting.pulse") == nil
        case .finished:
            false
        }
    }
}
