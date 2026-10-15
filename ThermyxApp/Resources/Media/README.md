# Onboarding slide videos

- `slide-construction.mp4` — "Built for construction workers."
- `slide-athletes.mp4` — "Built for athletes."
- `slide-soldiers.mp4` — "Built for soldiers."

Each plays silently on a loop while its slide is showing. They're 600 × 1080
(portrait), HEVC at about 1.8 Mbps, with no audio track, cropped from the
1920 × 1080 originals that had the clip centred on white.

To replace one, keep the name and the portrait shape (the frame on screen
takes the 600 × 1080 shape; see `SlideVideo.aspect` in
`OnboardingSlides.swift`), then run `xcodegen generate`.
