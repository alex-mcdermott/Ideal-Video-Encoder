# macOS port: open items

## Install an ffmpeg with zscale (deferred)

Homebrew's standard `ffmpeg` (8.1.x and 9.0.x) is built without zimg, so it has no `zscale` filter.
The encode uses `zscale=rangein=full:range=limited:matrix=709` for full-range (`pc`) sources, as the
Windows version does, so **full-range clips fail to encode** until this is fixed. Limited-range clips are
unaffected. The app's tool check reports it with the fix below.

Fix (replaces the system ffmpeg; builds from source):

```
brew uninstall ffmpeg
brew tap homebrew-ffmpeg/ffmpeg
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-zimg --with-libvmaf
```

Once it's installed, re-run the checks that were skipped because of it: full-range encodes in the
integration tests, the range/levels comparison for full-range sources, full-range preview fidelity
against the encode, and analysis of full-range clips.
