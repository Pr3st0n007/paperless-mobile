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

The preview outline is neutral until four valid results arrive consecutively
with every corner moving no more than 3.5% of the frame between frames. A missed
or unstable result clears stable state immediately. Green denotes stable
boundaries only; it does not certify crop correctness, sharpness, exposure, or
glare. Stable transitions are announced accessibly and optionally use one
haptic event.

Auto capture is off by default. It requires stable corners and local checks on
the detected page interior: mean neighboring-luma difference of at least 5,
no more than 55% of samples below luma 35, and no more than 90% above luma 250.
These are conservative prototype heuristics, not release thresholds. The
clipped-highlight measure can flag glare-like areas but cannot reliably
distinguish glare from white paper, so the proxy is not used as a hard gate or
presented as a reliable glare detector. After capture, auto capture is disarmed
until five consecutive missing detections, a corner movement above 18% of the
frame, or a 16x16 page fingerprint differs at 22% of its samples. Manual capture
remains available while disarmed. The fingerprint is intended to suppress
duplicates, not identify document content.

The live frame is downsampled to at most 320 pixels on its longest side. Only
one asynchronous analysis runs at once; intervening frames are dropped. Android
YUV 4:2:0 and BGRA frames are converted locally. Sensor/device rotation is
applied before mapping the quadrilateral through the preview's cover crop.
Unsupported frame formats disable live feedback without disabling manual
capture.

Each captured page defaults to **Auto (preserve proportions)**. Auto rendering
uses the rectified crop's ratio without added margins. Auto PDF pages use a
deterministic 297 mm long side; this is a sizing convention, not a physical-size
measurement. A4, Letter, and custom formats orient to the page and fit the crop
proportionally on a white page; they do not stretch or crop content. The
scan-wide format is persisted and re-renders non-overridden pages from their
originals. A page explicitly changed in the editor keeps its override when the
scan-wide format changes. Retakes replace both the page image and its stored
original; normal edits always render from the retained original.

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

The repository-pinned Flutter submodule is `d693b4b9dbac2acd4477aea4555ca6dcbea44ba2`.
Its Dart SDK bootstrap returned HTTP 403 from the configured Google storage
host in this session. As a result, localization generation, `flutter analyze`,
`flutter test`, and `flutter build apk --debug` could not be run here. The
required commands should be run with the pinned SDK before merge.
