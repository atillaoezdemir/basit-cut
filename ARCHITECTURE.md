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
| **BasitCutMedia** | `AssetInspector` (source → `MediaSource` info: duration, oriented size, fps, codec, bitrate, creation date, location), `CompositionBuilder` (Project → `AVMutableComposition` + `AVMutableVideoComposition` + `AVAudioMix`), `Exporter` (passthrough and re-encode paths, progress, cancel), `MetadataWriter`, `ThumbnailProvider`, `BookmarkResolver`, `TestVideoGenerator` (test support) | Core, AVFoundation, VideoToolbox |
| **App** | `DocumentGroup`, `ProjectDocument`, timeline / preview / export views, `PlaybackController`, `KeyboardController`, Settings | Core, Media |

## Data model (BasitCutCore)

All types are `Codable & Sendable & Hashable` value types.

```swift
struct Project {
    var formatVersion: Int
    var sources: [MediaSource]                     // referenced files, never modified
    var clips: [Clip]                              // timeline order = array order
    var crop: CropSetting                          // project-wide
    var cover: CoverFrame?                         // source + time; image stored in the package
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
  cover.jpg         optional cover frame
```

`ProjectDocument` is a SwiftUI `ReferenceFileDocument` inside a `DocumentGroup`. Each project gets its own window, with no tabs and no limit on open projects. Autosave and versions come from macOS, because every edit is registered with the UndoManager.

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
- **Video instructions,** one per segment:
  - *single clip:* the one layer at full opacity;
  - *cross fade:* opacity ramp of A from 1 to 0 over B;
  - *black fade:* opacity ramp to 0 (A) and from 0 (B) over the black background.
- **Geometry:** each layer instruction applies the source's `preferredTransform` (rotation) followed by the project crop transform. `renderSize` is the cropped, oriented size, so portrait phone videos are never shown sideways.
- **Audio mix,** automatic with no UI: a ~15 ms fade out/in at hard cuts to avoid clicks, an equal-length audio crossfade during cross fades, and fades that follow the video during black fades.

## Preview & keyboard

- `PlaybackController` (`@MainActor`, `@Observable`) owns an `AVPlayer`. After an edit, it rebuilds the player item from a fresh composition (debounced) and keeps the playhead position.
- `KeyboardController` uses an `NSEvent` local monitor for `keyDown` and `keyUp`. It is active only while the project window is key and no text field has focus.
  - `Space`: play/pause.
  - **Hold `L`** (configurable in Settings): playback runs at 2.0× while the key is held. On release it returns to 1.0×, or pauses again if playback was paused before. This affects the preview only.
  - `←` / `→` jump 5 s, and `⇧←` / `⇧→` jump 30 s. A held key drives its own timer (~8 jumps/s, independent of the system key-repeat setting) and uses **tolerant** seeks, with only one seek in flight at a time. On key up there is one **exact** seek.
- **Timeline view:** SwiftUI (`Canvas` + gestures) with zoom, playhead, drag-to-reorder, edge-trim handles, and a transition badge at each cut. Clip thumbnails come from `AVAssetImageGenerator` and are cached (nice-to-have).

## Export

### `ExportPlan` (Core, pure, unit-tested)

It turns `(project, source infos, mode)` into concrete output settings.

- **Original quality:** source codec, resolution, frame rate, and the duration-weighted average source bitrate. If the project has **no transitions, no crop, and all clips share the same orientation**, the result is `.passthrough`. Otherwise it is a re-encode with these settings.
- **Space saving:** HEVC with the `hvc1` tag via VideoToolbox hardware encoding, bitrate `min(4000 kbps, source bitrate)`, source frame rate, and resolution fitted within 1920×1080 with orientation kept (4K portrait → 1080×1920, ≤1080p unchanged). Audio is AAC at 128 kbps.

### `Exporter` (Media, actor)

- **Passthrough:** `AVAssetExportSession` with `AVAssetExportPresetPassthrough` on the composition. Edit lists keep the cuts frame-exact without re-encoding.
- **Re-encode:** `AVAssetReader` (composition + video composition + audio mix) → `AVAssetWriter` with explicit codec and bitrate settings, because export-session presets can't set a bitrate.
- **Progress** is an `AsyncStream<Double>`. **Cancel** works through task cancellation, and the partial output file is deleted.
- **Metadata:** creation date, location (ISO 6709), and make/model come from the **first clip**. The cover image is embedded as `commonIdentifierArtwork`. Everything is written through the session's or writer's `metadata`.

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
