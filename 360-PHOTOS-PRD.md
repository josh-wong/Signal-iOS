# PRD: 360° Photo Viewing

## Problem
Users increasingly capture photos with 360° cameras (Ricoh Theta, Insta360, Samsung Gear 360, etc.) and share them via Signal. Today Signal displays these as flat, visibly distorted equirectangular images. Other messaging/photo apps (Facebook, Google Photos, WhatsApp) render these as immersive, drag-to-look-around panoramas. Signal has no equivalent, so 360° content sent through Signal looks broken compared to sending it anywhere else.

## Goals
- Detect when a received (or sent) photo is a 360° equirectangular panorama.
- Let the user view it immersively: drag/pan to look around as if standing inside the photo.
- Make it obvious *before* opening that a photo is a 360° photo (so users aren't confused by a "stretched" thumbnail).

## Non-Goals (v1)
- 360° **video** — photos only.
- VR/AR headset viewing modes.
- Cropping, editing, or re-projecting 360° photos within Signal.
- Capturing 360° photos with Signal's own in-app camera.
- Cross-platform parity — this PRD scopes iOS only. Android/Desktop are unaffected since this is purely client-side rendering of an existing attachment; no wire-format or protocol changes.

## User Stories
1. As a recipient, when someone sends me a 360° photo, I want to immediately recognize it as such (not just a weirdly-shaped flat image).
2. As a recipient, I want to drag/swipe around the photo to look in different directions, the way I can in Google Photos or Facebook.
3. As a sender, if I send a 360° photo I captured, I want it to arrive at the recipient's device still recognizable and viewable as 360°.

## Functional Requirements
- **Detection**: Identify 360° photos via embedded XMP `GPano` metadata (`ProjectionType=equirectangular`, the de facto standard written by all major 360° cameras), not just aspect ratio heuristics.
- **Indicator**: Show a "360°" badge on thumbnails/previews so users know before opening.
- **Immersive viewer**: A distinct viewing mode where the photo is mapped onto a sphere and the user pans to look around, entered from the badge/tap.
- **Graceful fallback**: If metadata is stripped or ambiguous, the photo simply displays as a normal flat image (no broken states).

## Non-Functional Requirements
- Viewer must feel smooth (native frame rates) on supported devices.
- No impact to existing photo-viewing performance/behavior for non-360 photos.
- No new permission prompts unless a specific capability (e.g., gyroscope-driven look-around) requires one — to be confirmed in design.

## Open Questions / Risks
1. **Metadata survival**: Does Signal's existing privacy-motivated metadata stripping (on send) remove the XMP `GPano` block? If so, detection may only work in one direction (e.g., locally-viewing your own unsent photo) unless we preserve this specific tag deliberately. **Needs verification before design.**
2. Do we want gyroscope-based ("move your phone to look around") control in v1, or pan-gesture-only? Affects Info.plist / permission scope.
3. Should sent photos (in the composer/preview, before sending) also get 360° detection and viewing, or is this receive-side only for v1?
4. Any file-size/resolution ceiling for the immersive viewer (very high-res panoramas from some cameras can be 8K+)?

## Success Criteria
- 360° photos sent through Signal are visually recognizable as such and can be panned/explored, matching the baseline UX of comparable messaging apps.
