# Project Brief: Personal Video Archive Editor for macOS

> App name: **basit-cut**

## 1. Context & Goal

I want to build a **native macOS desktop app** for editing my **personal video archive** (family videos, trips, phone and camera recordings). It is **not** a social-media editor: no TikTok/YouTube formats, no titles, no music, no effects, no AI.

The app should do a small number of things **very well**: cut and arrange clips on a single track, add simple transitions, preview smoothly, and export either at original quality or as a space-saving HEVC file. The original files must **never** be modified.

It will be published as an **open-source** project on GitHub, so code quality, a clean architecture, and a good README matter.

## 2. Platform & Tech Stack

- **Target:** macOS only, Apple Silicon (developed on an M5 Mac). Minimum deployment target: macOS 15.
- **Language/UI:** Swift 6 + SwiftUI (AppKit only where SwiftUI falls short, e.g. key handling or the timeline view if needed).
- **Media:** AVFoundation (`AVMutableComposition`, `AVMutableVideoComposition`, `AVAudioMix`, `AVPlayer`, `AVAssetWriter` / `AVAssetExportSession`) with VideoToolbox hardware encoding.
- **Key principle:** preview and export must use the **same composition**, so the export looks exactly like the preview.
- **App model:** document-based app (`DocumentGroup`). Each project is its own document/window; users can have any number of projects open. **No tabs, no project limit.**
- **Dependencies:** avoid third-party dependencies unless clearly justified. Ask me before adding any.
- **Supported input:** whatever AVFoundation can open (MOV, MP4, M4V; H.264/HEVC). Unsupported files are rejected with a clear error message. (FFmpeg-based conversion is a possible future feature, not v1.)

## 3. Features (v1 Scope)

### 3.1 Projects
- Create, open, save, and autosave projects. The project file stores only references to the source videos plus the edit decisions (e.g. a JSON-based document package). It is **non-destructive**: source files are never touched.
- Use security-scoped bookmarks so file access survives app restarts (sandbox-friendly).
- If a source file is missing or moved, show a **relink** dialog.
- **Undo/redo** for every edit operation (via `UndoManager`).

### 3.2 Import
- **Video files only** (no images, no audio files).
- Import via file picker and drag & drop into the project window.
- All clips in a project are assumed to share the same format/resolution/frame rate. If an imported clip differs, show a warning.
- Correctly handle the **rotation metadata** of phone videos (`preferredTransform`), so portrait videos are never shown sideways.

### 3.3 Timeline (single track)
- **One video track only.** No layers, no separate audio track in the UI.
- Operations: reorder clips (drag & drop), **split** at the playhead, **trim** by dragging clip edges, delete a clip.
- Timeline zoom and a visible playhead. Thumbnails on clips are nice-to-have.

### 3.4 Transitions
Only two types, set per cut between two adjacent clips:
- **Cross fade:** the two clips dissolve into each other (they overlap, so the total duration gets shorter).
- **Black fade:** clip A fades to black, then clip B fades in from black.
- **Duration is adjustable** per transition (e.g. 0.2 s – 5 s, default 1 s).
- Default between clips: hard cut (no transition).
- Transitions must be visible in the live preview.

### 3.5 Preview & Keyboard Navigation
- Smooth playback of the full timeline, including transitions.
- `Space` → play/pause.
- **2x speed:** while a dedicated key is **held down**, playback runs at 2x. On release it returns to 1x. The key is configurable in Settings (choose a sensible default that doesn't conflict with other shortcuts). This is **preview only** and has no effect on export.
- **Arrow keys:** `←` / `→` jump 5 s, `Shift + ←` / `Shift + →` jump 30 s. **Holding the key keeps jumping continuously.** Make the seeking fast and responsive (tolerant seeking while held, exact seek on release). No frame-by-frame stepping is needed.

### 3.6 Audio (no UI at all)
- There are **no audio features** in the UI: no volume, no music, no audio editing.
- But the clips' **original audio is kept** in the export and follows the video edits.
- To avoid clicks, apply short automatic audio fades at hard cuts, an audio crossfade during cross fades, and fade the audio along with the video during black fades. All of this happens automatically, with no user setting.

### 3.7 Aspect Ratio & Crop (project-wide)
- Applies to the **whole project**, not to individual clips.
- It can only be set in two places: in the **project creation / import** step, and in the **export dialog**.
- Options: **Original** (no crop), **16:9**, **9:16**, **1:1**, and **Free crop**.
- For the fixed ratios and free crop, show a crop rectangle over a preview frame that the user can position and resize.

### 3.8 Cover Image
- The user picks a **frame from the video** in the preview ("Set current frame as cover").
- The frame is stored in the project and embedded as cover artwork in the exported file.
- Note in the README: Finder may not display embedded cover art as the file thumbnail.

### 3.9 Export
Two modes, no other presets:

**A) Original quality**
- Same codec, same resolution, same frame rate, and same (average) bitrate as the source.
- If the project has **no transitions and no crop**, use **passthrough** (no re-encoding, lossless, fast).
- Otherwise, re-encode with the source codec and bitrate.

**B) Space saving**
- **HEVC (H.265)**, `hvc1` tag for Apple compatibility, hardware encoding via VideoToolbox.
- **Average bitrate 4000 kbps**. If the source bitrate is already lower, keep the lower value.
- **Frame rate:** same as source.
- **Resolution:** downscale anything above 1080p to fit within 1920×1080, keeping the orientation (a portrait 4K video becomes 1080×1920). Sources at 1080p or lower keep their resolution.
- Audio: AAC, 128 kbps.

**For both modes:**
- **Preserve metadata,** above all the original **creation date** and the location. Take them from the first clip. This is essential for an archive: exported files must not appear as "recorded today".
- Embed the cover image if one is set.
- Export dialog: mode, aspect ratio/crop, output location, progress bar, cancel button.

## 4. Explicitly Out of Scope

No titles/text, no music, no audio editing, no effects or filters, no color correction, no keyframe animation, no speed changes in the export, no multi-track or layers, no social-media presets, no templates, no AI features, no cloud/sync, no collaboration, no tabs.

## 5. Future Version (do not build now, but don't block it architecturally)

- **Smart rendering:** re-encode only the segments around transitions and cut points, and stream-copy everything else.
- Optional FFmpeg-based import conversion for formats AVFoundation can't open (AVI, MKV, MTS, etc.).

## 6. Implementation Phases

Work phase by phase. **After each phase, stop:** summarize what was done and tell me how to test it, then wait for my OK before continuing.

0. **Plan & setup:** Propose the architecture (modules, data model of the project/timeline, how the composition is built from the model) in a short `ARCHITECTURE.md`. Wait for my feedback, then create the Xcode project.
1. **Core editing:** document-based project, import, single-track timeline (reorder, split, trim, delete), preview with all keyboard controls, undo/redo, save/load/autosave.
2. **Export:** both modes, metadata preservation, rotation handling, progress and cancel.
3. **Transitions:** cross fade and black fade with adjustable duration, in preview and export, with automatic audio fades.
4. **Aspect ratio/crop and cover image.**
5. **Polish:** relink dialog, error handling, README (features, build instructions, screenshots placeholder), open-source license (suggest one).

## 7. Working Rules

- Start in **plan mode**. Ask me if anything in this brief is unclear or conflicts before writing code.
- Keep the timeline/project model **independent from AVFoundation** so it can be unit-tested.
- Write **unit tests** for the timeline model (time calculations, splits, trims, transition overlaps, undo/redo).
- For media tests, **generate small test videos programmatically**. Don't rely on my personal files.
- Code, comments, commits, and docs are in **English**.
- **Git:** make commits under my identity as author and committer (**Atilla Özdemir**, `164641796+atillaoezdemir@users.noreply.github.com`), not as Claude. Add Claude only as a co-author with a `Co-Authored-By:` trailer. Use small, meaningful commits.
