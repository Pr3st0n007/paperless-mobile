# Android document scanner

The scanner uses the existing Flutter `camera` and `image` dependencies. It adds
no scanner SDK, model download, or external image service. Camera frames,
boundary analysis, quality heuristics, capture rendering, and PDF generation
remain on device. The boundary detector is a lightweight connected-component
heuristic: it thresholds a 320-pixel preview, favors large low-chroma regions,
checks convex four-corner geometry, rejects regions touching most of the frame,
and requires a filled candidate. Removing the old minimum ratio and A4-shaped
score allows narrow receipts and other nonstandard rectangles. This is not a
learned detector and is less reliable for dark/colorful paper, patterned
backgrounds, low contrast, occlusion, or severe perspective.

The implementation reuses the repository's already-pinned `camera`, `image`,
and `pdf` packages rather than adding a vendor scanner or model with an opaque
runtime, network requirement, or additional license surface. No detector asset
is downloaded at install or first use.

The preview outline, auto capture and guidance are driven by a single
time-based state machine (`AutoCaptureController`, see
[Auto capture](#auto-capture-and-stability) below). Green denotes a document
that has stayed still for the confirmation window; it does not certify crop
correctness, sharpness, exposure, or glare.

Auto capture is off by default and the user's choice is persisted. The quality
gate checks the detected page interior: mean neighboring-luma difference of at
least 5, no more than 55% of samples below luma 35, and no more than 90% above
luma 250. These are conservative prototype heuristics, not release thresholds.
The separate glare-like measure cannot reliably distinguish glare from white
paper, so it is not used as a gate; only the 90% clipped-highlight limit blocks
capture (shown as "too bright"). After a capture, auto capture waits until the page is absent for
600 ms, a corner moves more than 18% of the frame, or a 16x16 page fingerprint
differs at 22% of its samples. Manual capture remains available while waiting.
The fingerprint is intended to suppress duplicates, not identify document
content.

The live frame is downsampled to at most 320 pixels on its longest side. Only
one analysis runs at once; intervening frames are dropped and the analysis
rate adapts to the measured analysis time. Android YUV 4:2:0 and BGRA frames
are converted locally. Sensor/device rotation is applied before mapping the
quadrilateral through the preview's cover crop. Unsupported frame formats
disable live feedback without disabling manual capture.

Each captured page defaults to **Auto (preserve proportions)**. Auto rendering
uses the rectified crop's ratio without added margins. Auto PDF pages use a
deterministic 297 mm long side; this is a sizing convention, not a physical-size
measurement. A4, Letter, and custom formats orient to the page and fit the crop
proportionally on a white page; they do not stretch or crop content. The
scan-wide format is persisted and re-renders non-overridden pages from their
originals. A page explicitly changed in the editor keeps its override when the
scan-wide format changes. Retakes replace both the page image and its stored
original; normal edits always render from the retained original.

## Capture architecture

`ScanCapturePage` only orchestrates. Each concern has one owner that can be
tested and replaced on its own:

| Component | Location | Responsibility |
|---|---|---|
| `ScanCameraSession` | `capture/camera/` | Permission check, controller lifecycle, torch, focus, still capture, stream start/stop. All platform calls are serialized. |
| `CameraPermissionGateway` | `capture/camera/` | Injectable permission source (permission_handler on Android, plugin-driven elsewhere). |
| `CameraFrameConverter` | `capture/analysis/` | Downsamples YUV/BGRA frames to packed RGB. |
| `FrameAnalysisWorker` | `capture/analysis/` | Long-lived background isolate running `DocumentProcessor.analyzeRgbFrame`. |
| `LiveScanAnalyzer` | `capture/analysis/` | Frame dropping, adaptive pacing, rotation, publishes `CaptureReadiness` through a `ValueNotifier`. |
| `AutoCaptureController` | `capture/` | Pure, clock-free state machine: guidance, stability, countdown, trigger, duplicate suppression. |
| `ScanCaptureTuning`, `AutoCaptureSpeed` | `capture/` | Every threshold and timing in one place. |
| `ScanCapturePreferencesStore` | `capture/` | Persists auto capture, speed, haptics and "tips seen". |
| `CaptureDraft` | `capture/` | Unsaved pages in a private temp directory; add/replace/edit/undoable delete/commit. |
| Widgets | `view/capture/` | `CameraViewport`, `DocumentOverlay`, `GuidanceChip`, `ShutterButton`, `AutoCaptureToggle`, `CapturedPagesTray`, `CameraStatusView`, sheets. |

Reasoning: the former page mixed camera lifecycle, frame conversion, detection,
gating, file handling and UI in one ~960-line `State`. Splitting it lets the
timing logic be unit-tested without a camera (`auto_capture_controller_test`),
lets the camera lifecycle be tested with a fake platform, and keeps new
features (e.g. a learned detector, batch modes, ID-card presets) local to one
component.

### Camera preview fix

The CameraX plugin keeps a single native session and shared `Preview` and
`ImageAnalysis` objects for all `CameraController`s. Its `dispose()` calls
`preview.releaseSurfaceProvider()` and `unbindAll()` on those shared objects.
The old page released the camera on every non-resumed lifecycle state
(including `inactive`, which fires for the permission dialog, the notification
shade and the recents screen) without awaiting `dispose()`, then immediately
created a new controller on resume. The late dispose released the *new*
preview surface, while the image stream was re-bound afterwards: a black
preview with a working boundary overlay.

`ScanCameraSession` now runs every platform call (create, dispose, stream
start/stop, capture, torch, focus) through one process-wide queue and cancels
stale opens with a token, so a dispose can never overlap a newer camera. The
camera is released only on `hidden`/`paused`, not on `inactive`. A widget test
asserts that no two cameras are open at once.

The preview is also rendered full-bleed (`BoxFit.cover`) instead of
letterboxed, and overlay coordinates and tap-to-focus points use the same
cover transform (`ScanPreviewTransform.mapToViewport` / `viewportToSource`).
The capture screen is pushed on the root navigator so it is not squeezed by
the bottom navigation bar.

If a specific device still shows a black preview, check it once with
`flutter run --no-enable-impeller` to isolate the engine's camera texture path
from the app code.

## Auto capture and stability

`AutoCaptureController` consumes one `FrameObservation` (timestamp, corners,
quality, fingerprint) per analyzed frame and returns a `CaptureReadiness`
(phase, guidance, countdown progress).

* **Presets** (`AutoCaptureSpeed`): Relaxed 2.0 s, Balanced 1.3 s (default),
  Fast 0.8 s. Selectable in the scanner settings sheet and persisted.
* **Full-duration rule**: the countdown starts on the first valid frame and
  only fires on a later valid frame at least the hold duration after it. Every
  frame in between must show a valid, large enough (≥ 12% of the frame), sharp
  and exposed document.
* **Movement**: corners are compared with where the hold *started*, not with
  the previous frame, so slow drift cannot accumulate. Any corner moving more
  than 3% of the frame restarts the countdown ("Hold steady").
* **Confidence drop**: blur, under/over-exposure, a too-small page or losing
  the page restarts the countdown with specific guidance. One isolated missed
  detection is tolerated (detector flicker) but never advances or completes
  the countdown; two in a row restart it.
* **Timestamps** come from frame arrival, so the logic is independent of the
  analysis rate and deterministic in tests.
* **Manual mode** uses the same machine: the outline turns green once the page
  has been still for 400 ms.
* Auto capture is suspended while retaking a page, while tips are shown and
  while an operation is in progress; changing speed or mode resets the hold.

All values live in `ScanCaptureTuning` and should be revisited with the device
acceptance matrix below.

## UX decisions

| Area | Change | Reasoning |
|---|---|---|
| Layout | Full-bleed dark camera, root route, short title, compact app bar (torch, settings, `Done (n)`). Two always-visible paragraphs of hint text removed. | Maximizes the viewfinder like Lens/Adobe Scan; the old text consumed a third of the screen and truncated the title. |
| Permission | Android checks first and asks in context; denial shows an explanation with "Allow camera access"; permanent denial shows "Settings". Returning from settings re-checks. Import is always offered. | The user is never stuck on a black screen or a transient snackbar. |
| Loading / errors | Dedicated states for starting, no camera and failure (with retry). | Explicit, recoverable states build trust. |
| First run | Dismissible tips card (surface, corners, steadiness, light), re-openable from settings. Auto capture is paused while it is visible. | Teaches the model once without permanent clutter. |
| Edge feedback | Corners animate between results, the outside is dimmed, colors: white = found, amber = problem, green = stable. | Smooth, legible feedback at 4–15 Hz analysis rates. |
| Guidance | Single status pill: point at document, move closer, too dark/bright, blurry, hold steady, capturing, next page. Messages stay ≥ 700 ms. | Actionable instructions instead of a binary stable/uncertain line; no flicker. |
| Auto-capture feedback | Countdown drawn around the page outline and as a ring on the shutter; Auto/Manual toggle shows the active speed. | The user can see *when* capture will happen and cancel by moving. |
| Manual fallback | Large camera-style shutter always available; works when live analysis is unavailable. | Auto capture assists, never blocks. |
| Capture feedback | Shutter flash, haptic, spoken "Page n captured", tray scrolls to the new page. | Confirms success without looking away. |
| Review | Tapping a thumbnail opens a sheet with a large preview and Edit / Retake / Delete; delete is undoable; retake shows a cancellable banner. | Replaces an 18 px overflow menu with large targets and makes mistakes reversible. |
| Leaving | Back with unsaved pages asks: Discard / Keep scanning / Save pages. Saving shows "Saving page x of y". | Previously back silently deleted captured pages. |
| Haptics | Light tick when a page becomes ready, medium impact on capture; toggle in settings. | Few, meaningful vibrations instead of one per stability flip. |
| Accessibility | Semantic labels for shutter, toggle and thumbnails; guidance announced only after it persists 1.2 s; capture announced; reduced-motion respected; 48 dp+ targets. | Usable with TalkBack without announcement floods. |
| Low-end devices | Persistent analysis isolate, adaptive analysis interval (70–300 ms), frames dropped while busy, only overlay/status rebuild per frame, thumbnails decoded at 160 px. | Keeps the preview fluid when the CPU is the bottleneck. |

## Device acceptance matrix (pending)

No representative Android hardware was available in this implementation
session. The following acceptance work is required before release:

| Page | Lighting/background/angle coverage | Measurements and checks |
|---|---|---|
| Receipt | Narrow and long; dark, patterned, and light surfaces; indoor and low light; shallow and steep angles | Four-corner error against manually annotated corners; false-positive rate; time from stable presentation to overlay |
| Loose newspaper clipping | Whole source sheet visible; article is cropped manually; uneven lighting and textured surroundings | Confirm detection selects the sheet, not article layout; manual crop and full-image fallback |
| Flat magazine page | Colorful print, gloss, glare, edge shadows, varied backgrounds | Boundary error, false positives, quality-gate behavior, and glare limitations |
| A4 and Letter | Portrait and landscape; varied camera distance, orientation, and lighting | Overlay registration, stable transition/loss, manual/auto capture, output media-box dimensions |
| Offline first use | Fresh install, no network | Capture, edit, and export without downloading detector assets |
| Duplicate suppression | Hold a page still, remove it, replace it, and present a changed page in the same position | No repeat capture while the same page remains; rearm on absence or clear page change |
| Responsiveness | Representative supported Android devices | Record frame-to-overlay latency and capture latency with device model and OS |

Use an annotated sample set containing at least 30 images per page category,
including hard negatives with no page. Record per-corner normalized error,
successful four-corner detection rate, false-positive rate, median/p95 detection
latency, and capture latency, broken down by device and lighting. Maintainers
must approve numerical release targets after these prototype measurements;
targets are intentionally not fabricated in the absence of measurements.
Real-device acceptance, sample-set measurements, and tuning-threshold approval
remain pending. Cloud tests cannot establish camera accuracy or device
performance.

## Verification status

`flutter analyze` and the `test/features/document_scan` suite run with the
pinned Flutter 3.35.4 SDK. The pre-existing "narrow receipt" detector test
fails independently of the capture refactoring (the detector is unchanged).
The capture flow has not yet been verified on physical Android hardware; the
black-preview fix in particular must be confirmed on the affected device.
