# Agent guide for Iron

Iron is a SwiftUI strength-training app for iPhone and Apple Watch (Core Data model in `WorkoutDataKit`).

## Read before any UI work

1. [`docs/DESIGN_SYSTEM.md`](docs/DESIGN_SYSTEM.md): colors, type, spacing, components, motion, haptics, sounds and copy. To restyle a screen from a screenshot, follow §16.
2. [`docs/DESIGN_BACKLOG.md`](docs/DESIGN_BACKLOG.md): approved build specs (B1–B10), lane and file ownership, and build and install commands.
3. [`docs/HANDOFF.md`](docs/HANDOFF.md): mission, current state, owner preferences, the prioritized task list, and the UI ideas log.

## Hard rules

- Never commit, push, stash, reset or checkout unless the person running you explicitly says to. Never touch `reference-material/`.
- Apple Health: only workouts completed in Iron are exported. Imported workouts (`Workout.importSource != nil`) are never exported.
- No new package dependencies. Register new Swift files in `Light.xcodeproj/project.pbxproj`.
- Use `IronTheme` roles, `Font.ironMetric` and `IronMotion` tokens. No hard-coded colors and no rounded font design.
- Preserve existing persistence, Watch sync, Live Activity, and accessibility behavior when changing visuals.

## Build

See `docs/DESIGN_BACKLOG.md` §0.3. Packages are pre-cloned in `/tmp/iron-spm`. Pass `-disableAutomaticPackageResolution`.

## Share Apple build and simulator resources with Overland

- Use `~/.local/share/agent-coord/coord.py`; read `inbox Iron` before every claim.
- All builds use `run compiler Light`, with `nice -n 10 xcodebuild` and at most `-jobs 2` (currently jobs1 for headroom). All simulator operations and tests use `run check Light`, which claims both slots.
- **Latest shared-phone rule (owner via Overland, 2026-10-31):** use only Overland Regression `42FA2C2F-F66C-41DB-A33C-A018165BB0D7` for both apps, with serial access under the mutex. It replaced the unhealthy Light phone. Keep the shared phone booted between checks; this supersedes the earlier shutdown-after-each-check rule. Never boot a second phone. Adapt old helpers that hard-code the previous phone or always shut it down before reuse.
- Use one Watch only when essential, and shut down the Watch after its check. Do not quit Simulator.app while the shared phone is in use. Never stop Overland's devices or processes.
- Idle-runtime exception: if the shared phone consumes excessive CPU with app processes closed, coordinate its shutdown to protect the desktop instead of keeping it booted. Do not boot another phone to work around that load; wait for a safe baseline.
- Heavy builds/checks require the agreed `Overland-iOS/ci_scripts/resource_guard.py` inside the coordinator, with specific DerivedData roots; simulator app monitoring also needs exact installed executable `--process-path`. Current conservative thresholds are pause50/resume35 with jobs1. This samples aggregate CPU and throttles owned work, not a hard instantaneous system-wide cap; report actual peaks honestly. `nice`/jobs alone are not a cap. No broad screenshot/test sweeps when a focused check covers the change.
- Coordinate timing directly using `message Overland`. Treat `BUSY` (exit 73) as a wait/retry, never as success. Notify Overland after releasing resources and before physical-device installs.
- Persistent caches/scripts live in `~/.local/share/light/`, outside cleaner-managed `~/Library/Caches`.
