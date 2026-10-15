# macOS port: open items

- Signing: ad hoc only. A Developer ID signature and notarisation would remove the Gatekeeper step.
- Text size: View > Bigger scales the app's text, but standard controls (pop-up menus, buttons, tab
  labels) keep the system size; SwiftUI on macOS has no Dynamic Type.
- ExifTool mapping (inherited from the Windows script, kept identical): `Keys:FilmSimulation` is not a
  writable ExifTool tag, so the film simulation is not copied (#2).
- VMAF at slowed speeds: slowed clips repeat no frames but VMAF's motion feature reads near 0, which caps
  the score at about 97.4 even for a lossless copy, so a VMAF 97 target can't be met and suggestions are
  conservative.
- Windows: the new app icon is loaded for the window, taskbar and header by a small block in the script
  (falls back to the old vector icon on any error). It parses cleanly but has not been run on Windows.
- x265 `preset slow` at 6K runs at about 0.4 fps on an M4 (2 s of footage took about 2.5 min).
- Not yet run on an Intel Mac or on macOS 14 (it builds for both).

Resolved: Make/Model now reach Apple's Keys group (#1), and speed, audio on/off, loudness normalisation and
music replacement match Windows v1.3.0 (#10), with the preview following them.

Resolved: full-range sources no longer need an FFmpeg with zscale. The app uses zscale when present and the
built-in scale filter otherwise (measured against zscale: mean difference 0.16-1.7 of 1023 code values).
