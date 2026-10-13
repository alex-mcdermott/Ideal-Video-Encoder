# macOS port: open items

## Install an ffmpeg with zscale (deferred)

Homebrew's standard `ffmpeg` (8.1.x and 9.0.x) is built without zimg, so it has no `zscale` filter.
The encode uses `zscale=rangein=full:range=limited:matrix=709` for full-range (`pc`) sources, as the
Windows version does, so **full-range clips fail to encode** (with a clear message) until this is fixed.
Limited-range clips are unaffected. The app's Tools Setup window reports it with the fix below.

Fix (replaces the system ffmpeg; builds from source):

```
brew uninstall ffmpeg
brew tap homebrew-ffmpeg/ffmpeg
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-zimg --with-libvmaf
```

Once it's installed, re-run the checks that were skipped because of it: full-range encodes in the
integration tests (`fullRangeSource` then checks `color_range=tv` instead of the failure message), the
range/levels comparison for a full-range source (encode vs source through the same filters), and the
analysis of a full-range clip.

## Known issues and ideas

- Signing: ad hoc only. A Developer ID signature and notarisation would remove the Gatekeeper step.
- Text size: View > Bigger scales the app's text, but standard controls (pop-up menus, buttons, tab
  labels) keep the system size; SwiftUI on macOS has no Dynamic Type.
- ExifTool mapping (inherited from the Windows script, kept identical): `-QuickTime:Make<Make` overrides
  the earlier `-Keys:Make<Make`, so Make/Model end up in UserData/XMP rather than Apple's Keys group, and
  `Keys:FilmSimulation` is not a writable ExifTool tag, so the film simulation is not copied.
- x265 `preset slow` at 6K runs at about 0.4 fps on an M4 (2 s of footage took about 2.5 min).
