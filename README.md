# Smart Comics Scroll

**v0.1.0-beta** · Community plugin for [KOReader](https://github.com/koreader/koreader)

Read image-based comics in **landscape orientation** with full-width rendering and screen-by-screen navigation that looks for horizontal white/black separators. Unlike panel-by-panel readers, Smart Comics Scroll does not attempt to detect individual panels.

## Features

- Full-width rendering with conservative removal of white side margins.
- Separator-aware page turns, including thin gutters.
- FIT SCAN: may reduce the visible slice to finish at a verified separator, or fit the end of a physical image within the configured reduction limit (default **33%**).
- Optional **Auto Trim Top**, enabled by default.
- Persistent **ON/OFF** switch, also available as a KOReader gesture action.
- Two-column settings dialog; optional visual diagnostic overlay (off by default for new installations).
- Small cached separator analysis and optional render preloading.

## Installation

1. Download the release ZIP and extract it.
2. Copy the **`smartcomicsscroll.koplugin`** directory to your KOReader **`plugins/`** directory. On many Android installs this is `koreader/plugins/` in shared storage.
3. Restart KOReader.
4. Open a supported image-based comic in **landscape** and enable **Smart Comics Scroll** in the reader menu.

The plugin **does not rotate the screen automatically**. If you already used an experimental build, saved preferences (including visual debug) may carry over.

## Gestures

In KOReader's gesture settings, look for **Smart Comics: ON/OFF**. The plugin also registers **Smart Comics: next screen** and **Smart Comics: previous screen**.

## Settings

- Search range (%): how far to inspect around the target.
- Max Page-End reduction (%): maximum permitted shrinking for fit-to-height.
- Auto Trim Top: remove verified blank space at the beginning of a view.
- Preload pages: adjust rendering work versus responsiveness.
- Visual debug: draw diagnostic lines and counters over artwork.

## Compatibility and limitations

- Intended for **KOReader in landscape** with non-reflowable, image-based comics, especially CBZ. CBR/JPG behavior may depend on the document backend and is not yet broadly verified.
- First beta tested manually on sample CBZ pages. Device/format coverage is limited; this is **not** a KOReader core feature.
- No panel recognition, no automatic rotation, no guarantee that every visual separator will be detected.
- Some pages may show blank space at their end rather than combining physical images.
- Processing high-resolution images can use noticeable memory; disable preloading if needed.

## Bug reports

Please include: KOReader version, device/OS, file type, whether landscape mode was enabled, the plugin settings, and screenshots with **Visual debug** enabled. If possible provide a copyright-safe sample image.

## Status

**Beta** — please test before relying on it for everyday reading. License: GPL-3.0 (see LICENSE).