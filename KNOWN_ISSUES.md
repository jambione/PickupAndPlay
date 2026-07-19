# TapNote — Known Issues & Deferred Work

Parked on 2026-07-18 after the first on-device play-test cycle. Ordered roughly by
user impact. Diagnostic tooling (PressLog / FrameRecorder / LatencyHUD) stays in
place — every item below can be verified with a pull of `tapnote_presslog.txt`
and `tapnote_capture.mov` off the device.

## ✅ Verified good on device (2026-07-19)

- **Responsiveness + lift-release damper** — user play-tested: "feels a lot
  better. Responsive. No forced sustains." The core interaction is now solid.
  Adaptive 2/3-frame confirm, dropout-aware repress guard, QR stride 12, 5 ms
  buffer, and the motion damper all confirmed working in real play. Tuning
  knobs (`liftReleaseSpeed`, `fastTapSpeed`) can still be refined from log data
  if edge cases surface, but no longer blocking.

## Real bugs, not yet fixed (continued below too)

0. **Near-camera parallax drift (CONFIRMED by user, 2026-07-19)** — tracking
   accuracy degrades as the hand nears the camera. Far from the lens the dot
   sits on the fingertip and the correct key fires; up close the dot drifts off
   the finger onto a neighbouring key. **Cause is geometric, not detection:** the
   fingertip rides a few mm ABOVE the paper, but the homography maps the tracked
   2D point as if it lay ON the paper plane. An elevated point projects into the
   image displaced (along the camera's line of sight) from the paper spot
   directly beneath it, and that displacement grows with (a) fingertip height,
   (b) camera obliqueness, and (c) proximity — the same physical height subtends
   a bigger angle up close, so the key-space error balloons near the lens.
   Distinct from #8 (confidence collapse): here the point is tracked
   *confidently* but is geometrically offset. Also amplifies #5 (a resting hand
   near the lens reads even further off its true key).

   **Fix = software parallax correction (user ruled out a top-down rig as
   unrealistic, 2026-07-19).** Key math: the mapped-point error is
   `error = (h/cz)·(q − c_xy)` where q = naive homography-mapped paper point,
   c_xy = camera's ground-projection in paper coords, cz = camera height, h =
   fingertip height. So the corrected contact is
   `f = q − (h/cz)·(q − c_xy)` — i.e. shift the mapped point toward the camera's
   ground projection by a fraction of its distance. Because this is **affine in
   q**, an affine correction can cancel it exactly. Two ways to get the
   coefficients: (a) derive c_xy/cz from the 4 QR corners + the iOS camera
   intrinsic matrix (`cameraIntrinsicMatrixDeliveryEnabled`) via homography
   decomposition, with h ≈ 10–15 mm as the one tunable; (b) fit the affine
   empirically from FrameRecorder+PressLog drift samples. Plan: measure the real
   drift field first (recorder already captures it), then implement (a) and
   validate against the same data. NOTE: an earlier idea here — "bias the tip
   toward the DIP joint" — was WRONG (the DIP sits higher off the paper than the
   tip, making it worse); deleted.

## Needs on-device verification (built, not yet confirmed by play)

1. **Any other rough edges from the bass session?** — parallax drift (#0) is
   filed; ask the user whether more of the "some things still need working out"
   remain to capture.
2. **Latency HUD `total`** — the actual millisecond number still hasn't been
   read off the HUD, even though feel is now good. Nice-to-have confirmation.
3. **"My Sample" recorded voice** — record → pitched playback across keys.
   The audio-session swap during recording (`.playback` ↔ `.playAndRecord`) is
   the fragile part; verify playback still works after a recording. Also check
   the single-sample pitch mapping sounds right across the whole range.
4. **Drums / mallet / zither play-test** — still never physically played
   (piano got all the test time). Zither's thin strings are the tightest touch
   targets in the app; expect a tuning pass. Sticky sheet-swap (~1.6 s + audible
   cue) also unverified in practice.

## Real bugs, not yet fixed

5. **Phantom presses from the paper-holding hand** — video showed resting
   fingertips on printed keys registering as presses (G4–C5 cluster,
   session 5). Options: velocity-gate near-zero-approach presses (PRESS log now
   records `vel=` for tuning), or user guidance (hold the margin / clip the
   sheet). Not yet addressed in code.
6. **Manual-calibration corner prompt is piano-only** — hardcoded "C5/C6" copy
   in `PaperPianoView.swift` is wrong/confusing on drum/mallet/zither/bass
   sheets (found in the health-check audit, still open).
7. **Session-4 unexplained variant flip** — a re-lock chose `threeOctave` via
   modern `3:` tokens while the 2-octave sheet was believed in the stand.
   Probably a real paper swap by the user; unconfirmed. If it recurs, the
   frame recorder will catch which sheet was actually in view.

## Physical/UX limits & product gaps

8. **Near-edge fingertip confidence collapse** — at shallow stand angles the
   fingertips hide behind the knuckles (all-zero confidences at the near edge).
   Mitigated by framing/thresholds; the real fix is a steeper, more top-down
   camera. Future code idea: fall back to the DIP joint (usually higher
   confidence) with forward extrapolation.
9. **Print-scale enforcement not built** — the product vision requires
   true-100% printed key spacing (muscle-memory transfer); QR geometry can
   measure actual print scale and warn. Roadmapped, unimplemented.
10. **Audible "tracking lost" cue not built** — eyes-on-paper play means
    tracking failures must be heard, not seen. Only sheet-swap has a cue today.
11. **Mallet/drum sheet art polish** — cymbal labels sit low over the grooves;
    mallet frame-rail stubs poke past the end bars. Cosmetic.

## Code health (from the health-check audit, all still open)

12. **Uncommitted work** — the entire device-test cycle (probe, recorder,
    press log, sample voice, sheet art, all fixes) sits uncommitted in the
    working tree. Commit before the next feature push.
13. **Structural debt** — `CameraSessionManager.swift` (>1100 lines) and
    `PaperPianoView.swift` (~1000 lines, ~20 types) keep absorbing features;
    `InstrumentPreset` needs 6 switch edits per new instrument (data-table
    refactor would collapse to one).
14. **Dead code** — `PaperPianoEntryCard.swift` only referenced from the
    unreachable `HomeView`.
15. **Zero tests** — nothing in the project is covered; the press-detection
    state machine (`evaluatePress`) is now complex enough to deserve them.
