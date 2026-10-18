# Media formats

| Input | Accepted | Delivered |
| --- | --- | --- |
| MP3, AAC/M4A | ✅ | Original reused when within the profile bitrate; otherwise AAC transcodes at or below the source bitrate |
| FLAC, WAV/W64, AIFF, ALAC, WavPack, APE | ✅ | AAC profiles + **ALAC lossless** (bit depth preserved: 16 → 16, 24 → 24-in-32). Original kept |
| Ogg Vorbis/Opus | ✅ | AAC profiles (no lossless; source is lossy) |
| MP4/MOV/M4V, MKV, WebM, AVI, MPEG-TS video | ✅ | HLS H.264 ladder (360/540/720/1080, never above source) + AAC audio renditions per audio track, thumbnail, preview sprites, audio-only AAC |
| SRT, WebVTT | ✅ | Normalised WebVTT (sidecar + HLS subtitle group); original preserved |
| Embedded subtitles: SubRip, mov_text, ASS/SSA, WebVTT | ✅ | Extracted to WebVTT (ASS styling is dropped) |
| Embedded bitmap subtitles: PGS, VobSub, DVB | ❌ | Skipped with a job log entry (needs OCR) |
| Images (artwork): JPEG, PNG, WebP ≥ 300×300 | ✅ | JPEG 1000 px and 300 px variants |

Limits: 6 h maximum duration, `MAX_UPLOAD_BYTES` (default 20 GB), subtitle files ≤ 5 MB.

Device testing still required for: 24-bit ALAC over Bluetooth (iOS resamples to the codec in use), HLS subtitles
in PiP and AirPlay, multi-audio HLS language switching, and FFmpeg-encoded AAC gapless metadata.
