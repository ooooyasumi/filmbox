# Bundled codec runtime

Filmbox carries its own `ffmpeg` and `ffprobe` in `Filmbox.app/Contents/Helpers`.
Users do not need Homebrew, a terminal command, a codec installer, or a network
connection. The helpers run locally and cannot open network protocols. Source
media remains read-only; generated posters use the app's existing cache. WebM
playback uses WebKit directly through a read-only, tokenized 127.0.0.1 Range
service; it does not transcode or copy the complete video before playback.

## Build and provenance

Run `scripts/build-codec-runtime.sh` on Apple Silicon macOS with Apple's Command
Line Tools. It downloads the **official FFmpeg 9.0.2 source release** over HTTPS,
checks the pinned SHA256 before extraction/execution, and compiles with Apple's
Clang and SDK. It does not invoke SwiftPM or install system software.
`CODEC_JOBS=4` can lower the maximum parallel compile count. An unchanged verified
runtime is reused; `--verify-only` checks the existing installation without
downloading or compiling.

- Source URL: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>
- SHA256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`
- Upstream signature: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz.asc>
- Upstream downloads and legal notes: <https://ffmpeg.org/download.html>,
  <https://ffmpeg.org/legal.html>

The hash pins the bytes retrieved from the official HTTPS release URL. It does
not claim independent PGP verification. This project does not download or trust
third-party compiled codecs. Upgrades require deliberately reviewing a new
official source release, changing both the version and pinned hash, rebuilding,
and rerunning compatibility checks.

Build output is `.build/CodecRuntime/install/bin/{ffmpeg,ffprobe}`. The complete
unchanged archive is retained at `.build/CodecRuntime/downloads/ffmpeg-9.0.2.tar.xz`
and the corresponding source at `.build/CodecRuntime/src/ffmpeg-9.0.2`.
`.build/CodecRuntime/build-arm64` retains configure/build logs and object files.
The installation's `share/filmbox-codecs` contains the source information, LGPL,
upstream license, build script, exact configuration and a JSON manifest with
binary hashes and sizes. A build fingerprint includes the source hash, script,
compiler and SDK version. Architecture and every dynamic dependency are checked
before publishing a completed runtime. A failed rebuild preserves the previous
installation.

## Included capabilities

The target is **arm64, macOS 15.0+**, matching the current Filmbox app. FFmpeg's
native decoders and demuxers cover formats beyond AVFoundation, including VP9,
HEVC, H.264, ProRes, MPEG-4 and older camera/container combinations. Unsupported,
encrypted or damaged content can still fail.

The static FFmpeg-library build disables GPL, version-3-only, nonfree, network
and automatic external-library detection. It builds no `ffplay` or capture
devices, and has no Homebrew dependency. The only enabled output encoders are
`h264_videotoolbox`, native `aac`, `png` and `mjpeg`; output containers are
MP4/MOV and image/image-pipe. `scale`, `format`, `setsar`, `aformat`, `aresample`
and their standard null/trim filters support conversion. Native `transpose`,
`hflip`, `vflip` and `rotate` preserve camera orientation, with `crop` retained
by FFmpeg's command-line program. Only `file` and `pipe` protocols are enabled.
Apple VideoToolbox/AudioToolbox and system zlib are explicit OS dependencies.
Software input decoding is available for codecs/profiles unsupported by the
machine's hardware. H.264 output uses Apple's encoder, with `-allow_sw 1` when
software encoding fallback is needed. No libx264/libx265 is included.

Production lookup uses `Bundle.main`'s Helpers directory. Development may use
the fixed `.build/CodecRuntime/install/bin` directory; do not silently search a
user's `PATH`, change system tools, or use a downloaded executable at runtime.

Posters should use an explicit video stream, one frame, bounded scale and pipe
output. A playback proxy should use the first video and optional first audio,
H.264 4:2:0/AAC, a bounded resolution, and a cache-only temporary output path.
Use `-nostdin`, bounded stdout/stderr, a cancellable process and a deadline.
`-progress pipe:1` provides machine-readable conversion progress. A conventional
MP4 must finish successfully before it is offered to AVPlayer; `+faststart`
moves the index after conversion and does not make an unfinished file playable.

## App packaging and signing

`scripts/build-app.sh` first ensures the runtime exists and passes verification,
then copies both helpers and notices into the staging app. Each helper is
signed individually before the enclosing app. The app build never requires a
user-installed FFmpeg. Code remains under `Contents/Helpers` and notices under
`Contents/Resources/Licenses/Codecs`.

The current project uses an ad hoc local signature. External distribution still
requires Developer ID signing, hardened-runtime review and notarization. A
universal app also requires a separately validated x86_64 runtime; this script
does not label an arm64-only runtime universal.

## License and corresponding source

The resulting runtime reports **LGPL version 2.1 or later**. FFmpeg's own license
and full LGPL text accompany the app, along with the Independent JPEG Group
acknowledgement in `SOURCE_INFO.txt`. No upstream files are patched. Filmbox uses
the separately executed command-line tools rather than linking FFmpeg into its
Swift executable.

When distributing outside this development machine, ship the exact retained
source archive and build script alongside the app or make the equivalent
corresponding-source download available with the app. Preserve all notices and
the user's rights to rebuild/replace and debug modifications of the LGPL tools.
The official fixed source URL is included in the app for traceability; a pointer
alone should not replace a distributor's corresponding-source obligations.
The app packaging script includes that exact complete source archive and the
build script/configuration inside `Contents/Resources/Licenses/Codecs`, together
with the license text, so the supplied app and zip accompany the tools with source.
Codec patents are separate from FFmpeg's copyright license.

## Verification record

Run the runtime build and `--verify-only`, check `otool -L` for both helpers, and
use a synthetic VP9 WebM fixture to verify software decoding, a scaled PNG
poster and H.264/AAC MP4 conversion. Validate the completed MP4 with AVFoundation's
async `isPlayable` and an actual frame decode. The fixture must contain generated
test content, never a user's media. Runtime sizes and the latest concrete check
results are recorded below after a successful build.

Verified locally on **2026-10-31**, Apple Silicon / macOS 26.6.2, using FFmpeg
9.0.2 built from the pinned archive:

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| Source archive | 12,040,788 | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |
| `ffmpeg` | 10,849,640 | `cb6a4090ae18d16cc2f6b0f9bbff09bbe92f6d169de1d73c09314dd0ec2856e0` |
| `ffprobe` | 10,672,792 | `9fc1aab11a1ea4c9bce91e5f5ce9a14408180d7d42f39168801ce4cc72dbaf96` |

The two helpers total **21,522,432 bytes (20.53 MiB)** before app packaging.
App signing may change binary hashes; the packaged manifest records those
separately as `PackagedSHA256`.

- The cached installation passes `scripts/build-codec-runtime.sh --verify-only`.
- A two-second generated VP9/Opus WebM reports `isPlayable == false` in native
  AVFoundation. The bundled tool successfully decodes it to both JPEG and PNG
  posters at 128 × 85 using `scale` and `image2pipe`.
- The bundled VideoToolbox H.264/native AAC output is `yuv420p`, has square
  pixels and reports `isPlayable == true`. AVFoundation actually decodes a
  128 × 86 frame from the completed proxy. The check uses no player UI.
- A generated 128 × 86 MP4 with a 90° display matrix produces an 86 × 128 JPEG,
  confirming the bundled autorotation filters work.
- `otool -L` on each helper contains only `/usr/lib` libraries and Apple's
  `/System/Library` frameworks, with no `@rpath`, Homebrew or other third-party
  dylib. `lipo -archs` reports only `arm64`.
- The configuration reports `LGPL version 2.1 or later`; GPL, nonfree, version3
  and network configuration flags are all disabled. Runtime protocol inspection
  reports only `file` and `pipe` for input and output.
- Re-signing a copy of the final `ffmpeg` with the app's ad hoc signing method,
  strict signature verification and execution of that signed copy all pass.
- Both build scripts pass Bash syntax validation. The enclosing Swift app build
  is validated by the main app workflow rather than this standalone codec check.

Only generated test patterns/audio were used. The test fixture was encoded
with an existing developer-side FFmpeg; that executable and its dependencies
are not copied into Filmbox, and end users do not need it. All fixture files and
the small standalone AVFoundation verification program remain in the ignored
`.build/CodecRuntime/checks` directory.
