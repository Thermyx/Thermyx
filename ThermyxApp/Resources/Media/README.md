# Onboarding walkthrough

`onboarding-walkthrough.mp4` plays as the hero on the first onboarding screen:
muted, looping, no controls, no audio session.

## The file here is a placeholder

It is a **simulator screen recording of this app running on preview data**,
captured from a scripted tab tour. It is real footage of the real interface, so
the onboarding screen works and looks right today — but it is not what should
ship.

## What should replace it

A recording of **a real phone in someone's hands**, using Thermyx during an
actual session: a thumb reaching the thermal control bar, the soles updating as
they walk, a caution appearing and being acknowledged. The point of this hero is
to answer "what is it like to use this", and a hand on a device answers that in
a way a simulator capture cannot.

When recording:

- **Portrait, roughly 2:1.** The player uses `resizeAspectFill` in a rounded
  frame at `aspectRatio(0.49)`, so anything near portrait crops cleanly.
- **10–20 seconds, loopable.** Start and end on a similar frame so the loop does
  not jump.
- **Silent.** Any audio track is ignored, but strip it to keep the file small.
- **Keep it under a few megabytes.** It ships in the bundle.
- **No fabricated readings on screen.** If the recording is made with preview
  data rather than a live insole, that is fine for a walkthrough — but do not
  present it anywhere as a real session, and do not put numbers in marketing
  copy that came from it.

Drop the new file in at the same path and name. Nothing in code needs to change.
If the file is missing entirely, the onboarding screen falls back to the
animated sole rather than showing a black rectangle.
