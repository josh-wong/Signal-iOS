//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol InteractivelyDismissableViewController: UIViewController {
    func performInteractiveDismissal(animated: Bool)
}

protocol InteractiveDismissDelegate: AnyObject {
    func interactiveDismissDidBegin(_ interactiveDismiss: UIPercentDrivenInteractiveTransition)
    func interactiveDismiss(
        _ interactiveDismiss: UIPercentDrivenInteractiveTransition,
        didChangeProgress: CGFloat,
        touchOffset: CGPoint,
    )
    func interactiveDismissDidFinish(_ interactiveDismiss: UIPercentDrivenInteractiveTransition)
    func interactiveDismissDidCancel(_ interactiveDismiss: UIPercentDrivenInteractiveTransition)
}

class MediaInteractiveDismiss: UIPercentDrivenInteractiveTransition, UIGestureRecognizerDelegate {
    var interactionInProgress = false

    weak var interactiveDismissDelegate: InteractiveDismissDelegate?
    private weak var targetViewController: InteractivelyDismissableViewController?

    /// Consulted before the swipe-to-dismiss gesture is allowed to begin.
    /// Panorama content owns full 2-axis pan for look-around, so it returns
    /// false while a panorama is on screen; edge-triggered dismiss (feeding
    /// residual drag past the camera's pitch clamp into this same
    /// interactive transition) is a separate follow-on refinement.
    var shouldBeginDismissGesture: (() -> Bool)?

    init(targetViewController: InteractivelyDismissableViewController) {
        super.init()
        self.targetViewController = targetViewController
    }

    func addGestureRecognizer(to view: UIView) {
        let gesture = DirectionalPanGestureRecognizer(
            direction: .vertical,
            target: self,
            action: #selector(handleGesture(_:)),
        )
        // Allow panning with trackpad
        gesture.allowedScrollTypesMask = .continuous
        gesture.delegate = self
        view.addGestureRecognizer(gesture)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return shouldBeginDismissGesture?() ?? true
    }

    /// Drives this interactive transition from an externally-owned gesture —
    /// used by panorama content, whose own pan gesture (which needs full
    /// 2-axis control for look-around) feeds in the residual drag past its
    /// pitch clamp, rather than the `UIPanGestureRecognizer` added by
    /// `addGestureRecognizer(to:)` driving this directly.
    func beginExternalDismiss() {
        beginDismiss()
    }

    func updateExternalDismiss(progress: CGFloat, touchOffset: CGPoint) {
        changeDismiss(progress: progress, touchOffset: touchOffset)
    }

    func endExternalDismiss(finished: Bool) {
        endDismiss(finished: finished)
    }

    // MARK: - Private

    private static let distanceToCompletion: CGFloat = 88

    private func beginDismiss() {
        interactionInProgress = true
        targetViewController?.performInteractiveDismissal(animated: true)
    }

    private func changeDismiss(progress: CGFloat, touchOffset: CGPoint) {
        let clampedProgress = CGFloat.clamp01(progress)
        update(clampedProgress)
        interactiveDismissDelegate?.interactiveDismiss(self, didChangeProgress: clampedProgress, touchOffset: touchOffset)
    }

    private func endDismiss(finished: Bool) {
        if finished {
            finish()
        } else {
            cancel()
        }

        interactiveDismissDelegate?.interactiveDismissDidFinish(self)
        targetViewController?.setNeedsStatusBarAppearanceUpdate()

        interactionInProgress = false
    }

    @objc
    private func handleGesture(_ gestureRecognizer: UIScreenEdgePanGestureRecognizer) {
        guard let coordinateSpace = gestureRecognizer.view?.superview else {
            owsFailDebug("coordinateSpace was unexpectedly nil")
            return
        }

        if case .began = gestureRecognizer.state {
            gestureRecognizer.setTranslation(.zero, in: coordinateSpace)
        }

        switch gestureRecognizer.state {
        case .began:
            beginDismiss()

        case .changed:
            let offset = gestureRecognizer.translation(in: coordinateSpace)
            changeDismiss(progress: offset.length / Self.distanceToCompletion, touchOffset: offset)

        case .cancelled:
            cancel()
            interactiveDismissDelegate?.interactiveDismissDidCancel(self)

            interactionInProgress = false

            targetViewController?.setNeedsStatusBarAppearanceUpdate()

        case .ended:
            endDismiss(finished: percentComplete > 0)

        default:
            break
        }
    }
}
