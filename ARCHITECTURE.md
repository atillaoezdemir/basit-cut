# basit-cut – Architecture

This document describes how basit-cut is structured: the modules, the project/timeline data model, and how a single AVFoundation composition is built from that model and used for both preview and export. See [SPEC.md](SPEC.md) for the product requirements.

## Guiding principles

1. **Non-destructive.** Source files are only ever read. A project stores references plus edit decisions.
2. **One composition.** Preview and export are built from the same `CompositionBuilder` output, so the export looks exactly like the preview.
3. **Testable core.** The timeline model knows nothing about AVFoundation and is fully unit-tested.
4. **No third-party dependencies.** Apple frameworks only.

## Repository layout

```
basit-cut/
  BasitCut.xcodeproj            app target + test target
  BasitCut/                     app target (SwiftUI, small AppKit bridges)
    App/                        @main, DocumentGroup, Settings scene
    Document/                   ProjectDocument, UTType, package I/O
    Views/                      preview, timeline, import, export, crop
    Playback/                   PlaybackController (AVPlayer wrapper)
    Input/                      KeyboardController (key down/up handling)
    Export/                     export dialog view model
    Resources/                  assets, Info.plist
    BasitCut.entitlements
  Packages/BasitCutKit/         local Swift package (swift-tools 6.0, macOS 15)
    Sources/BasitCutCore/       pure model – Foundation only, NO AVFoundation
    Sources/BasitCutMedia/      AVFoundation layer
    Tests/BasitCutCoreTests/    timeline math, edits, transitions, undo
    Tests/BasitCutMediaTests/   uses programmatically generated test videos
```

`swift test --package-path Packages/BasitCutKit` runs all model and media tests without launching the app.

## Modules

| Module | Contains | Depends on |
|---|---|---|
| **BasitCutCore** | `Project`, `Clip`, `MediaSource`, `Transition`, `CropSetting`, `RationalTime` / `TimeRange`, `TimelineLayout` (time calculations, segment list), `TimelineEditor` (split / trim / reorder / delete / set transition as pure, validated functions), `ProjectEditor` (undo-aware edit entry point), `ExportPlan` (decides codec, bitrate, resolution, passthrough) | Foundation |
| **BasitCutMedia** | `AssetInspector` (source → `MediaSource` info: duration, oriented size, fps, codec, bitrate, creation date, location), `CompositionBuilder` (Project → `AVMutableComposition` + `AVMutableVideoComposition` + `AVAudioMix`), `Exporter` (passthrough and re-encode paths, progress, cancel), `ArchiveMetadata`, `SecurityScopedBookmark`, `TestVideoGenerator` (test support) | Core, AVFoundation, VideoToolbox |
| **App** | `DocumentGroup`, `ProjectDocument`, timeline / preview / export views, `PlaybackController`, `KeyboardController`, Settings | Core, Media |

## Data model (BasitCutCore)

All types are `Codable & Sendable & Hashable` value types.

```swift
struct Project {
    var formatVersion: Int
    var sources: [MediaSource]                     // referenced files, never modified
    var clips: [Clip]                              // timeline order = array order
    var crop: CropSetting                          // project-wide
    var cover: CoverFrame?                         // source + time; rendered when exporting
}

struct MediaSource {
    var id: UUID
    var bookmark: Data            // security-scoped bookmark
    var lastKnownPath: String     // for display / relink
    var duration: RationalTime
    var naturalSize: Size         // encoded size
    var transform: Transform2D    // preferredTransform (rotation); orientedSize is derived
    var frameDuration: RationalTime
    var codec: VideoCodec         // .h264, .hevc, …
    var videoBitrate: Int         // average, bits per second
    var hasAudio: Bool
    var creationDate: Date?
}

struct Clip {
    var id: UUID
    var sourceID: MediaSource.ID
    var sourceRange: TimeRange    // in/out points in the source
    var outgoingTransition: Transition?   // transition at the cut to the next clip; nil = hard cut
}

struct Transition {
    enum Kind { case crossFade, blackFade }
    var kind: Kind
    var duration: RationalTime    // 0.2 s – 5 s, default 1 s
}

struct CropSetting {
    enum Mode { case original, ratio16x9, ratio9x16, ratio1x1, free }
    var mode: Mode
    var rect: NormalizedRect      // 0…1 in oriented source coordinates
}
```

### Time

Time is an exact rational value (`value` / `timescale`, `Int64`) that mirrors `CMTime` without depending on CoreMedia. The media layer converts it 1:1. Split and trim math never drifts the way floating-point math would.

### Layout rule (`TimelineLayout`)

```
start(0)   = 0
start(i+1) = start(i) + duration(i) − overlap(i)
overlap(i) = transition(i).duration   if cross fade
           = 0                         otherwise (hard cut, black fade)
```

- **Cross fade:** the clips overlap, so the total timeline length gets shorter.
- **Black fade** of duration `d`: clip A fades to black over its last `d/2`, and clip B fades in from black over its first `d/2`. The total length does not change.

`TimelineLayout.segments` produces an ordered, AVFoundation-free list of segments (`.single(clip)`, `.crossFade(a, b)`, `.fadeOut(a)`, `.fadeIn(b)`) with timeline ranges. It drives the composition builder and is the hook for future **smart rendering**, which needs to re-encode only the non-`single` segments and the cut points.

### Invariants (enforced by `TimelineEditor`)

- A transition is never longer than either neighbouring clip.
- For each clip, `incoming overlap + outgoing overlap ≤ clip duration`.
- If a trim or split would break this, the transition duration is clamped automatically. If it would fall below 0.2 s, the transition is removed.
- A transition is removed when its cut disappears (delete, reorder).

### Undo / redo

Every edit goes through `ProjectEditor` (`@MainActor`). It applies a pure `TimelineEditor` operation and registers the previous `Project` snapshot with the document's `UndoManager`. Snapshots of a value type are small, simple, and can never get out of sync with the edit logic. Undo/redo is unit-tested with a plain `UndoManager`.

## Document format

A `.basitcut` file is a **package** (a directory that Finder shows as one file) with the exported UTType `io.github.atillaoezdemir.basitcut.project`:

```
MyTrip.basitcut/
  project.json      Project: references + edit decisions only
```

`ProjectDocument` is a SwiftUI `ReferenceFileDocument` inside a `DocumentGroup`. Each project gets its own window, with no tabs and no limit on open projects. Autosave and versions come from macOS, because every edit is registered with the UndoManager.

### Projects folder

All projects live in one folder that the user chooses once (and can change in Settings). Its security-scoped bookmark is stored in the user defaults, and access stays open for the app's lifetime (`ProjectsFolder`). At launch the app shows the **Projects window** instead of an untitled document or an open panel. That window lists the `.basitcut` packages in the folder, newest first, and creates new projects there under a unique name (`ProjectListing`). A project therefore already has a file location when it opens, so saving never asks where to put it. Projects stored elsewhere can still be opened with File → Open….

### File access (App Sandbox)

- Entitlements: `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-write`, `com.apple.security.files.bookmarks.app-scope`.
- On import, each source gets an app-scoped security-scoped bookmark, which is stored in `MediaSource.bookmark`.
- When a document opens, `BookmarkResolver` resolves the bookmarks, refreshes stale ones, and reports missing files. Missing files trigger the relink dialog (Phase 5).

## Composition: preview == export

```
CompositionBuilder.build(project, resolvedAssets) -> BuiltComposition {
    composition:      AVMutableComposition
    videoComposition: AVMutableVideoComposition
    audioMix:         AVAudioMix
    renderSize:       CGSize
}
```

The same `BuiltComposition` feeds both the `AVPlayerItem` (preview) and the `Exporter`.

- **Tracks:** clips alternate between two video tracks (A/B) and two audio tracks, so a cross fade overlap is simply two tracks playing at the same time.
- **Fades are computed in Core:** `TimelineLayout.envelopes(for:)` gives each clip an opacity and a volume `Envelope` (linear `Ramp`s on the timeline), so the rules are unit-tested without AVFoundation. The builder only translates them.
- **Video instructions,** one per segment between clip boundaries. Later clips are drawn on top, and each layer gets its opacity ramps cut to the segment:
  - *single clip:* the one layer at full opacity;
  - *cross fade:* B (on top) ramps from 0 to 1 over the overlap while A stays opaque underneath;
  - *black fade:* A ramps to 0 over its last half and B from 0 over its first half, over the black background.
- **Geometry:** each layer instruction rotates the source upright (`preferredTransform`), fits it into the **canvas** (the first clip's upright frame), then shifts it by the crop origin. `renderSize` is the crop size, so the preview shows exactly what will be exported, and portrait phone videos are never shown sideways.

### Crop and cover

- **Crop** (`Crop.swift` in Core): `CropSetting.rect` is normalized (0…1, top-left origin) in the canvas. Fixed ratios (16:9, 9:16) keep their ratio in pixels whatever the canvas shape; free crop is only clamped to the frame and a minimum side of 10 %. `Project.cropRect` turns it into canvas pixels with an even width and height, and `renderSize` follows it. A ratio picked before the project has clips (in the New Project sheet) starts as `.full` and is centred once the first clip defines the canvas. (1:1 was dropped; an old project with it opens as free crop.)
- **Where it is set** (a deliberate change from the spec, which asked for creation and the export dialog only): the New Project sheet (ratio only) and the **Crop** button in the transport bar, which puts the preview into crop editing. A bar above the preview picks the ratio (Original, 16:9, 9:16, Free; Original removes the crop), the player shows the uncropped composition (`ProjectSession.previewProject`), `CropOverlay` draws the draft rectangle over it, and Done commits it as one undoable edit (Cancel discards it). The export dialog only shows the result in its summary.
- **Cover:** the project stores only the source frame (`CoverFrame`: source + source time). `CoverImage` renders it at export time with the same fitting and the current crop, so it always matches the video, and it is embedded as `quickTimeMetadataArtwork` (JPEG, at most 1920 px on the long side). If the source is missing, the export goes ahead without a cover.
- **Audio mix,** automatic with no UI: a 15 ms fade out/in at hard cuts to avoid clicks, a linear audio crossfade during cross fades, and fades that follow the video during black fades. Each audio track gets the volume ramps of its clips plus an explicit start volume: without it the mixer plays a fade-in's first buffer at full volume, because it only notices a ramp at its next buffer boundary.
- **Passthrough export** copies audio as is, so the hard-cut fades don't apply there (the accepted trade-off from the open question below).

## Preview & keyboard

- `PlaybackController` (`@MainActor`, `@Observable`) owns an `AVPlayer`. After an edit, it rebuilds the player item from a fresh composition (debounced) and keeps the playhead position.
- `KeyboardController` uses an `NSEvent` local monitor for `keyDown` and `keyUp`. It is active only while the project window is key and no text field has focus.
  - `Space`: play/pause.
  - **Hold `L`** (configurable in Settings): playback runs at 2.0× while the key is held. On release it returns to 1.0×, or pauses again if playback was paused before. This affects the preview only.
  - `←` / `→` jump 5 s, and `⇧←` / `⇧→` jump 30 s. A held key drives its own timer (~8 jumps/s, independent of the system key-repeat setting) and uses **tolerant** seeks, with only one seek in flight at a time. On key up there is one **exact** seek.
- **Timeline view:** SwiftUI (`Canvas` + gestures) with zoom, playhead, drag-to-reorder, edge-trim handles, and a transition badge at each cut. Clip thumbnails come from `AVAssetImageGenerator` and are cached (nice-to-have).

## Export

### `ExportPlan` (Core, pure, unit-tested)

It turns `(project, mode)` into `.passthrough` or `.reencode(ExportSettings)`.

- **Original quality:** source codec, resolution (the first clip's upright size), frame rate, and the duration-weighted average source bitrate. If the project has **no transitions and no crop**, and every clip shares the first clip's format (size, codec, frame rate) and rotation, the result is `.passthrough`. A single passthrough track can't mix formats or rotations cleanly, so mixed projects are re-encoded. H.264 stays H.264; other codecs (HEVC, ProRes, …) are re-encoded as HEVC. Audio is AAC at 256 kbps.
- **Space saving:** HEVC with the `hvc1` tag via VideoToolbox, bitrate `min(4000 kbps, source bitrate)`, source frame rate, and resolution fitted within 1920×1080 with orientation kept (4K portrait → 1080×1920, ≤1080p unchanged). Audio is AAC at 128 kbps.
- If no source reports a bitrate, it is estimated at 0.1 bits per pixel per frame.

### `Exporter` (Media)

The output is always a QuickTime movie (`.mov`), the container that keeps phone metadata most reliably.

- **Passthrough:** a separate single-track composition (clips back to back, the shared rotation as the track's `preferredTransform`) exported with `AVAssetExportSession` and the passthrough preset. Edit lists keep the cuts frame-exact without re-encoding.
- **Re-encode:** the preview's `BuiltComposition` is read with `AVAssetReaderVideoCompositionOutput` and `AVAssetReaderAudioMixOutput`, and encoded with `AVAssetWriter` using explicit codec and bitrate settings (export-session presets can't set a bitrate). Frames are rendered at the composition's size and scaled by the encoder for space saving. Audio is mixed to 48 kHz stereo AAC.
- **Progress** is reported through a callback. **Cancel** works through task cancellation, and the partial output file is deleted.
- **Metadata:** creation date, location (ISO 6709, plus its accuracy), and make/model/software are copied from the **first clip** (capture-specific identifiers such as the Live Photo content identifier are not). If the file has no creation date but the inspector found one, that date is written. The output file's creation and modification dates are set to the recording date, so Finder doesn't show it as "today". The cover image, if set, is embedded as `quickTimeMetadataArtwork`, in passthrough and re-encode alike.

## Concurrency

The project uses Swift 6 strict concurrency.
- Core is made of plain `Sendable` value types.
- UI and playback state is `@MainActor`.
- Media work runs in actors and async functions, using AVFoundation's async loading APIs (`load(.duration)`, …).

## Testing

- **Core:** time and layout math, split, trim, reorder, delete, transition clamping and overlaps, `ExportPlan` decisions, undo/redo round-trips, JSON round-trips.
- **Media:** `TestVideoGenerator` writes small H.264/HEVC clips (color bars, a frame counter, a sine tone, optional rotation metadata, optional differing resolution) into a temporary directory. Tests cover the inspector, composition durations and transitions, export settings, and metadata preservation. No personal files are used.

## Future work this design keeps open

- **Smart rendering:** `TimelineLayout.segments` already separates the segments that need re-encoding (transitions and cuts) from those that could be stream-copied.
- **FFmpeg import conversion:** it would plug in before `AssetInspector` as an optional "convert to a temporary MOV" step, with no changes to Core.

## Open question

**Passthrough and audio clicks.** In true passthrough the audio is copied as well, so the automatic short audio fades at hard cuts cannot be applied. The proposal is to accept this, because lossless and fast is the point of passthrough. The alternative, copying the video and re-encoding only the audio, works only when cuts land on keyframes. **Recommendation:** accept clicks as a possible passthrough limitation and document it.
