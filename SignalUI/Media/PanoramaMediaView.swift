//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SceneKit
import SignalServiceKit

/// Renders an equirectangular 360° photo as the inside of a sphere, with a
/// pan gesture driving a virtual camera at the sphere's center so the user
/// can "look around" as if standing inside the photo.
public class PanoramaMediaView: UIView {
    private let sceneView: SCNView
    private let cameraNode = SCNNode()
    private let singleTapGestureBlock: () -> Void

    private var yaw: CGFloat = 0
    private var pitch: CGFloat = 0

    private enum Constants {
        // Keep the camera from panning past the sphere's poles, where an
        // equirectangular image is most distorted and "looking straight up/down"
        // stops being a meaningful orientation.
        static let maxPitch: CGFloat = .pi / 2 * 0.95
        static let radiansPerPoint: CGFloat = .pi / 450
        static let fieldOfViewDegrees: CGFloat = 75
        static let sphereRadius: CGFloat = 10
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
        sceneView.addGestureRecognizer(panGesture)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        sceneView.addGestureRecognizer(singleTap)

        updateCameraOrientation()
    }

    public required init?(coder: NSCoder) {
        owsFail("Not implemented!")
    }

    // MARK: -

    @objc
    private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        let translation = gestureRecognizer.translation(in: sceneView)
        gestureRecognizer.setTranslation(.zero, in: sceneView)

        yaw -= translation.x * Constants.radiansPerPoint
        pitch = (pitch - translation.y * Constants.radiansPerPoint).clamp(-Constants.maxPitch, Constants.maxPitch)

        updateCameraOrientation()
    }

    @objc
    private func handleSingleTap() {
        singleTapGestureBlock()
    }

    private func updateCameraOrientation() {
        cameraNode.eulerAngles = SCNVector3(Float(pitch), Float(yaw), 0)
    }
}
