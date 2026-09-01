# Changelog

## [Unreleased]

### Added

- Added an `Open in YouTube` fallback from the tvOS playback error screen and player menu.
- Added tvOS YouTube handoff URL coverage for valid and empty video identifiers.

### Fixed

- Error-state playback actions now receive an explicit default focus, so Siri Remote can select
  `Retry` and move to `Open in YouTube`.
- Cleared saved playback progress when a video naturally finishes, so replaying it starts from
  the beginning while queue auto-advance remains intact.

### Notes

- The YouTube handoff uses an undocumented tvOS URL scheme when available and falls back to HTTPS.
  It cannot provide FreeTube with official-app playback progress, completion, queue, or resolution
  state.
