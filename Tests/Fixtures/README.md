# Synthetic compatibility fixtures

Run `python3 scripts/generate-test-media.py` from the repository root before media or Android device checks. FFmpeg with H.264, VP9 and Opus encoding is required for generation.

The script generates test patterns and synthesized sine-wave audio. It writes `h264-aac.mp4` (128 × 86, H.264/AAC, 2 s), `vp9-opus.webm` (320 × 180, VP9/Opus, approximately 1.2 s), and the Android test asset. Encoded bytes vary with the development encoder. These generated outputs are ignored by Git. Tests copy them into temporary directories.
