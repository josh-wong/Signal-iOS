//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SceneKit
import SignalServiceKit

/// Closures driving an interactive dismiss transition from
/// `PanoramaMediaView`'s edge-triggered swipe-down gesture, so the app target
/// can wire it to its own `MediaInteractiveDismiss` (which SignalUI cannot
/// depend on directly).
public struct PanoramaEdgeDismissHandler {
    public var didBegin: () -> Void
    public var didChangeProgress: (_ progress: CGFloat, _ touchOffset: CGPoint) -> Void
    public var didEnd: (_ finished: Bool) -> Void

    public init(
        didBegin: @escaping () -> Void,
        didChangeProgress: @escaping (_ progress: CGFloat, _ touchOffset: CGPoint) -> Void,
        didEnd: @escaping (_ finished: Bool) -> Void,
    ) {
        self.didBegin = didBegin
        self.didChangeProgress = didChangeProgress
        self.didEnd = didEnd
    }
}

/// Renders an equirectangular 360° photo as the inside of a sphere, with a
/// pan gesture driving a virtual camera at the sphere's center so the user
/// can "look around" as if standing inside the photo.
public class PanoramaMediaView: UIView {
    private let sceneView: SCNView
    private let cameraNode = SCNNode()
    private let singleTapGestureBlock: () -> Void

    private var yaw: CGFloat = 0
    private var pitch: CGFloat = 0

    /// Points of drag past the pitch clamp, accumulated while the user
    /// continues dragging in the clamped direction. Drives the edge-triggered
    /// swipe-down-to-dismiss handoff to `edgeDismissHandler`.
    private var edgeDragDistance: CGFloat = 0
    private var isDrivingEdgeDismiss = false

    /// Set by the owner (e.g. `MediaItemViewController`/`MediaPageViewController`)
    /// to drive its own interactive dismiss transition once look-around
    /// panning hits its pitch clamp and the user keeps dragging down.
    public var edgeDismissHandler: PanoramaEdgeDismissHandler?

    private var pinchStartFieldOfView: CGFloat = Constants.fieldOfViewDegrees

    private var inertiaDisplayLink: CADisplayLink?
    private var lastInertiaTimestamp: CFTimeInterval = 0
    private var yawVelocity: CGFloat = 0 // radians/second
    private var pitchVelocity: CGFloat = 0 // radians/second

    private enum Constants {
        // Keep the camera from panning past the sphere's poles, where an
        // equirectangular image is most distorted and "looking straight up/down"
        // stops being a meaningful orientation.
        static let maxPitch: CGFloat = .pi / 2 * 0.95
        static let radiansPerPoint: CGFloat = .pi / 450
        static let fieldOfViewDegrees: CGFloat = 75
        static let minFieldOfView: CGFloat = 30
        static let maxFieldOfView: CGFloat = 100
        static let sphereRadius: CGFloat = 10
        /// Points of drag past the pitch clamp before edge-triggered dismiss
        /// completes. Mirrors `MediaInteractiveDismiss.distanceToCompletion`.
        static let edgeDismissDistance: CGFloat = 88
        /// Fraction of angular velocity retained after one second of pan
        /// inertia; applied continuously via `pow(_:dt)` so it's frame-rate
        /// independent.
        static let inertiaDecayPerSecond: CGFloat = 0.05
        static let minInertiaAngularVelocity: CGFloat = 0.02
    }

    public init(image: UIImage, onSingleTap: @escaping () -> Void = {}) {
        self.sceneView = SCNView()
        self.singleTapGestureBlock = onSingleTap
        super.init(frame: .zero)

        let scene = SCNScene()

        let camera = SCNCamera()
        camera.fieldOfView = Constants.fieldOfViewDegrees
        camera.zNear = 0.05
        camera.zFar = Double(Constants.sphereRadius) * 2
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let sphere = SCNSphere(radius: Constants.sphereRadius)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.diffuse.contents = image
        // SCNSphere's faces point outward; flip which face renders so the
        // texture is visible from a camera placed inside the sphere.
        material.cullMode = .front
        material.diffuse.mipFilter = .linear
        sphere.firstMaterial = material

        let sphereNode = SCNNode(geometry: sphere)
        // Mirror horizontally: equirectangular longitude increases left-to-right
        // when viewed from outside-in, but SceneKit's UVs run the other way
        // for inside-facing geometry.
        sphereNode.scale = SCNVector3(-1, 1, 1)
        scene.rootNode.addChildNode(sphereNode)

        sceneView.scene = scene
        sceneView.backgroundColor = .black
        sceneView.isUserInteractionEnabled = true
        addSubview(sceneView)
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        sceneView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        sceneView.addGestureRecognizer(pinchGesture)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        sceneView.addGestureRecognizer(singleTap)

        updateCameraOrientation()
    }

    public required init?(coder: NSCoder) {
        owsFail("Not implemented!")
    }

    deinit {
        inertiaDisplayLink?.invalidate()
    }

    // MARK: - Pan (look-around + edge-triggered dismiss)

    @objc
    private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        let translation = gestureRecognizer.translation(in: sceneView)
        gestureRecognizer.setTranslation(.zero, in: sceneView)
        let state = gestureRecognizer.state

        if state == .began {
            cancelInertia()
            edgeDragDistance = 0
        }

        yaw -= translation.x * Constants.radiansPerPoint

        if edgeDragDistance > 0 {
            // Already past the clamp: further downward drag grows the
            // residual, upward drag rubber-bands it back toward 0.
            edgeDragDistance = max(0, edgeDragDistance + translation.y)
        } else {
            let desiredPitch = pitch - translation.y * Constants.radiansPerPoint
            if desiredPitch < -Constants.maxPitch {
                pitch = -Constants.maxPitch
                edgeDragDistance = (-Constants.maxPitch - desiredPitch) / Constants.radiansPerPoint
            } else {
                pitch = desiredPitch.clamp(-Constants.maxPitch, Constants.maxPitch)
            }
        }
        updateCameraOrientation()

        let wasDrivingEdgeDismiss = isDrivingEdgeDismiss
        updateEdgeDismiss(for: state)

        if state == .ended || state == .cancelled {
            if !wasDrivingEdgeDismiss {
                startInertia(velocity: gestureRecognizer.velocity(in: sceneView))
            }
            edgeDragDistance = 0
        }
    }

    private func updateEdgeDismiss(for state: UIGestureRecognizer.State) {
        guard let edgeDismissHandler else { return }

        if edgeDragDistance > 0 {
            if !isDrivingEdgeDismiss {
                isDrivingEdgeDismiss = true
                edgeDismissHandler.didBegin()
            }
            let progress = CGFloat.clamp01(edgeDragDistance / Constants.edgeDismissDistance)
            edgeDismissHandler.didChangeProgress(progress, CGPoint(x: 0, y: edgeDragDistance))
        }

        switch state {
        case .ended, .cancelled:
            if isDrivingEdgeDismiss {
                isDrivingEdgeDismiss = false
                edgeDismissHandler.didEnd(edgeDragDistance >= Constants.edgeDismissDistance)
            }
        default:
            if isDrivingEdgeDismiss, edgeDragDistance == 0 {
                isDrivingEdgeDismiss = false
                edgeDismissHandler.didEnd(false)
            }
        }
    }

    // MARK: - Pinch-to-zoom (camera field of view)

    @objc
    private func handlePinch(_ gestureRecognizer: UIPinchGestureRecognizer) {
        switch gestureRecognizer.state {
        case .began:
            pinchStartFieldOfView = cameraNode.camera?.fieldOfView ?? Constants.fieldOfViewDegrees
        case .changed:
            guard gestureRecognizer.scale > 0 else { return }
            cameraNode.camera?.fieldOfView = (pinchStartFieldOfView / gestureRecognizer.scale)
                .clamp(Constants.minFieldOfView, Constants.maxFieldOfView)
        default:
            break
        }
    }

    // MARK: - Pan inertia

    private func startInertia(velocity: CGPoint) {
        yawVelocity = -velocity.x * Constants.radiansPerPoint
        pitchVelocity = -velocity.y * Constants.radiansPerPoint
        guard
            abs(yawVelocity) > Constants.minInertiaAngularVelocity ||
            abs(pitchVelocity) > Constants.minInertiaAngularVelocity
        else {
            return
        }

        cancelInertia()
        lastInertiaTimestamp = CACurrentMediaTime()
        let displayLink = CADisplayLink(target: self, selector: #selector(stepInertia(_:)))
        displayLink.add(to: .main, forMode: .common)
        inertiaDisplayLink = displayLink
    }

    private func cancelInertia() {
        inertiaDisplayLink?.invalidate()
        inertiaDisplayLink = nil
    }

    @objc
    private func stepInertia(_ displayLink: CADisplayLink) {
        let dt = CGFloat(displayLink.timestamp - lastInertiaTimestamp)
        lastInertiaTimestamp = displayLink.timestamp

        yaw -= yawVelocity * dt
        pitch = (pitch - pitchVelocity * dt).clamp(-Constants.maxPitch, Constants.maxPitch)
        updateCameraOrientation()

        let decay = pow(Constants.inertiaDecayPerSecond, dt)
        yawVelocity *= decay
        pitchVelocity *= decay

        if
            abs(yawVelocity) < Constants.minInertiaAngularVelocity,
            abs(pitchVelocity) < Constants.minInertiaAngularVelocity
        {
            cancelInertia()
        }
    }

    // MARK: - Tap

    @objc
    private func handleSingleTap() {
        singleTapGestureBlock()
    }

    // MARK: -

    private func updateCameraOrientation() {
        cameraNode.eulerAngles = SCNVector3(Float(pitch), Float(yaw), 0)
    }
}

extension PanoramaMediaView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer,
    ) -> Bool {
        // Allow simultaneous pan (look-around) and pinch (zoom).
        true
    }
}
