# Design Doc: 360° Photo Viewing

Based on [360-PHOTOS-PRD.md](./360-PHOTOS-PRD.md).

## Key finding that shapes this design
Signal's send pipeline (`SignalUI/Attachments/NormalizedImage.swift`) strips XMP metadata from images before upload. Critically, **JPEGs (the format virtually all 360° cameras output) never go through the metadata-preserving path at all** — `removeImageMetadata(fromNonPngData:)` deliberately throws for JPEGs (a workaround for an iOS `CGImageDestinationCopyImageSource` crash bug, see line ~420) and falls back to full recompression from a raw `CGImage`, which carries no XMP forward. `preservedMetadata` (line 346) only whitelists TIFF/IPTC orientation tags today.

**Conclusion:** relying solely on the XMP `GPano` tag (as the PRD originally proposed) will not work for the common case of a 360° photo sent through Signal — it would only work for locally-viewing-your-own-unsent-photo or for images that bypass compression. Detection needs a heuristic that survives recompression.

## Detection strategy
Two-tier detection, both computed at the same point images are already inspected:

1. **Primary (survives compression): aspect-ratio heuristic.** Equirectangular 360° photos are conventionally exactly 2:1 (width:height), a property of the projection itself, not metadata — so it survives resizing/recompression. Flag images within a tight tolerance (e.g. width == 2 × height, ±1–2%) as panorama candidates.
2. **Secondary (confirmation when available): XMP `GPano` tags.** Read via `CGImageSourceCopyMetadataAtIndex`. When present (e.g. viewing a photo pre-send, or a photo received via a path that preserved metadata), use it to confirm/disambiguate — e.g. a 2:1 photo that isn't actually a panorama (rare but possible) or to distinguish equirectangular from other projections we don't yet support.

This means detection is good-enough but not perfect (false positives possible for coincidentally 2:1 flat photos, false negatives if a camera crops non-2:1). Acceptable for v1; can be tightened later with proto/attachment-level flagging if we decide to preserve GPano metadata deliberately (see Open Questions).

### Where it plugs in
- `SignalServiceKit/Util/ImageMetadata/ImageMetadata.swift`: add `isPanoramaCandidate: Bool` (or similar) to the struct.
- `SignalServiceKit/Util/ImageMetadata/OWSImageSource.swift`: compute it in `imageMetadataWithImageSource(_:imageFormat:)`, alongside the existing `pixelSize`/orientation reads — same `CGImageSource`, no extra decode cost.
- `SignalServiceKit/.../AttachmentContentValidatorImpl.swift`: `validateImageContentType(_:)` already calls `imageSource.imageMetadata()` (line ~513) — the flag flows through the same `ContentResult` used for `pixelSize` today, into the persisted `Attachment` record.

## Viewer
- New `PanoramaMediaView` (SceneKit-based — no existing SceneKit/Metal usage in the codebase, so this is net-new): `SCNSphere` with the photo as a diffuse texture on the inside surface (invert normals / negative scale), camera fixed at sphere center, camera rotation driven by a pan gesture.
- Plugs into `Signal/src/ViewControllers/MediaGallery/MediaItemViewController.swift`, `buildMediaView()` (~line 163) — branch on `attachment.isPanoramaCandidate` to build `PanoramaMediaView` instead of the standard `ZoomableMediaView`.
- **Gesture conflict (resolved)**: `ZoomableMediaView` relies on `UIScrollView` pinch-zoom (not applicable to a sphere — zoom instead means changing camera FOV), and `MediaInteractiveDismiss` (`Transitions/MediaInteractiveDismiss.swift`) claims vertical pan for swipe-to-dismiss. Since panorama look-around needs both axes, we can't reuse a plain pan gesture directly. Resolution: two dismiss affordances, not one —
  1. **Explicit close (X) button** in the chrome/toolbar overlay (same overlay `MediaItemViewController` already toggles on tap) — guaranteed, discoverable, always available regardless of pan state.
  2. **Edge-triggered swipe-down-to-dismiss**: the panorama camera's vertical pitch is clamped (can't pan infinitely past the zenith — poles of an equirectangular image are heavily distorted anyway, so clamping is needed regardless of dismiss). Once the camera hits that pitch clamp and the user keeps dragging down, feed that *residual* drag distance into the same `UIPercentDrivenInteractiveTransition` that already powers `MediaInteractiveDismiss` for the flat viewer — same rubber-band-at-boundary pattern as Photos/Apple Music/Mail. Not a new gesture system, just a different signal driving the existing interactive-dismiss code path.
- Badge UI: small "360°" indicator drawn over thumbnails/previews wherever attachment thumbnails already render, keyed off the same `isPanoramaCandidate` flag.

## Non-Functional
- No proto/wire format changes — this is entirely local computation on existing attachment bytes, so no interop impact with Android/Desktop.
- Gyroscope-driven "look around by moving phone" ships as a later, additive input mode (Chunk 3) — pan-gesture-only first, since it needs no new permissions and is simpler to ship and test as the initial vertical slice.

## Phasing
Each chunk is a complete, shippable increment of the *same* v1 feature — no chunk is a dead-end or throwaway; there is deliberately no "v2." Chunk 1 is fully usable end-to-end; later chunks refine it.

1. **Chunk 1 — Usable MVP.** Aspect-ratio detection (`ImageMetadata` flag → `Attachment` record) + "360°" badge on thumbnails/previews + `PanoramaMediaView` (SceneKit sphere, pan-gesture look-around) + X-button dismiss. A user can receive a 360° photo, see it flagged, tap it, and look around inside it. Nothing stubbed or dark-launched.
2. **Chunk 2 — Interaction refinement.** Edge-triggered swipe-down-to-dismiss (rubber-band at the pitch clamp, see Gesture conflict above), pinch-to-zoom mapped to camera FOV, pan inertia/damping.
3. **Chunk 3 — Gyroscope look-around.** Device-motion-driven look-around (`CMMotionManager`) as an added input mode alongside pan. Sequenced after Chunk 1/2 prove out the simpler pan-only interaction; carries Info.plist/permission considerations to verify.
4. **Chunk 4 — Hardening.** Max-texture-size clamp/downsampling for very high-res (8K+) panoramas on older devices; detection false-positive/negative tuning from real-world usage.

## Open Questions
1. ~~Gesture resolution for dismiss vs. look-around~~ — resolved above (X button in Chunk 1 + edge-triggered swipe-down in Chunk 2).
2. ~~Preserve GPano XMP through the send pipeline for more precise detection?~~ **Cut, not deferred.** The aspect-ratio heuristic is sufficient for a complete, correct feature on its own, and the JPEG XMP path specifically routes through a known iOS crash workaround (`NormalizedImage.swift:420`, FB13285956) — not worth the risk for a precision gain we don't need.
3. Sent-but-not-yet-sent preview (composer) detection — include in Chunk 1, or a later chunk? (No blocker either way; same detection code path applies regardless of when it's wired into the composer UI.)
