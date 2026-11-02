# Light

Private strength training for iPhone and Apple Watch, built with SwiftUI, Core Data,
HealthKit, WatchConnectivity, ActivityKit, and WidgetKit.

Light is an independent continuation of **[Iron](https://github.com/karimknaebel/Iron)**,
created by **Karim Abou Zeid**. Iron provided the foundation; this fork adds a new visual
system, inline workout logging, expanded import tools, and deeper training insights.
Original copyright notices and the [GPL v3 license](LICENSE) are retained.

## Workout logging

- One focused editor guides the next set across the entire workout: large weight/reps fields,
  steppers, previous results, plate calculations, and RPE.
- Completed rows fill with color. Warm-up, drop, and failure sets have distinct treatments;
  value fields remain visible over every row color.
- Supersets alternate by round, with optional decelerating scrolling. A visual Superset sheet
  previews the order before saving.
- Hold an exercise header, or choose Reorder, for Arrange Exercises. Native drag handles stage
  the order until Done; Cancel keeps the original arrangement.
- Rest timers beside their sets, with pause, skip, −15/+15 controls, an inline duration ruler,
  and per-exercise defaults.
- A segmented session bar and a manually chosen expanded or floating glass summary.
- A completion recap with metrics, records, effort, set/rest history, and a saved-workout option.

## Plan and review

- Saved workouts, one-tap Repeat from Recent Workouts, and saving a recent session as a workout.
- Recency-first exercise discovery, equipment/muscle filters, custom exercises, instructions,
  diagrams, and cached demonstration thumbnails where available.
- Exercise charts for estimated 1RM, weight, and volume; session history; muscle targeting
  with hold-and-drag inspection.
- Home's weekly training overview, day bars, streaks, recent progress, and calendar daily recaps.
- History grouped by week, with totals, record/RPE badges, and session strips.
- Private body measurements and training summaries.

## Apple Watch and live surfaces

**Watch status:** the current implementation is a saved work in progress and needs another
design and on-device validation pass. The owner has paused Watch development; the features
below describe the code currently preserved, not a finished or accepted Watch experience.

- An exercise-first Watch workout flow: open the workout's exercise list, an exercise's sets,
  then an individual set to edit it. Heart rate and active calories stay pinned above scrolling
  content, including Always On. Crown weight editors and steppers use 0.5-unit increments.
  Start an empty workout, log any set, add/remove/reorder/replace exercises, link supersets,
  and edit RPE, notes and effort directly on the Watch.
- Create, edit, delete and start saved workouts; browse synced history and repeat a session.
  The bundled exercise text catalog and cached workouts work without a connected phone.
- An active workout automatically starts or recovers its Watch HealthKit recording for heart
  rate and estimated active energy. Durable edits queue
  separately and sync in order when iPhone reconnects; competing current workouts are preserved.
- Live Watch heart rate and estimated active calories appear in the phone workout header.
  Readings come from the Watch's HealthKit workout; missing or stale data is shown clearly.
- Live Activities identify the exercise with cached artwork and a blue set-progress tile.
  Compact views keep workout progress in focus; expanded views expose rest controls and
  supported quick actions. Apple Watch Smart Stack activities use a black surface, exercise
  name/next-set position, and a secondary rest countdown.
- A Last Workout widget for recent training.
- Adaptive colors, SF Pro typography, metric roles, haptics, original workout sounds,
  Dynamic Type, VoiceOver actions, and Reduce Motion support.

## Import, export, and Health

- Background Hevy workout/measurement CSV import with progress feedback. Name aliases reconnect
  imported history to catalogue exercises without rewriting historical names or relationships.
- Re-import deduplication, imported-workout counts/date ranges, removal, and replacement from a
  fresh export. Replacement rolls back on failure; workouts logged in Light are kept.
- Hevy-compatible CSV export, complete backups, existing Iron backup restoration, and the
  available local/iCloud backup tools.
- Only eligible workouts completed in Light are exported to Apple Health. **Imported workouts
  are never exported.** Durable export state/retries avoid accidental duplicates; Watch-owned
  Health workouts retain their own recording path.
- No public profile or social feed. Hevy compatibility does not imply affiliation.

## Building

The current working tree is verified with **Xcode 27 beta 6**. The iPhone app/widget targets
require iOS 17 or later; the Watch app targets watchOS 10 or later. Some features require newer
systems.

1. Open `Light.xcodeproj` and select the `Iron` scheme.
2. Select your Apple development team for the app, Watch app, and extensions.
3. For your own distribution, configure consistent bundle/companion IDs, entitlements, app
   groups, and containers before building.
4. Build on a simulator or connected device. See the
   [workspace build guide](docs/DESIGN_BACKLOG.md#03-build-and-install) for local commands.

```sh
xcodebuild -project Light.xcodeproj -scheme Iron \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/light-dd build CODE_SIGNING_ALLOWED=NO
```

The displayed name is **Light**. Internal project/scheme names and compatibility identifiers
still use Iron. The existing development installation keeps its bundle ID so updates preserve
its data container, Watch relationship, backups, and preferences. `com.sopat712.light` is the
proposed identity for a separately configured Light distribution; changing an installed app's
bundle ID requires a deliberate data migration.

## Project notes and credits

- [Design system](docs/DESIGN_SYSTEM.md), [backlog](docs/DESIGN_BACKLOG.md), and [handoff](docs/HANDOFF.md).
- [Iron by Karim Abou Zeid](https://github.com/karimknaebel/Iron): original app and foundation.
- [Third-party notices](THIRD_PARTY_NOTICES.md): exercise text/media provenance, MuscleMap,
  and their individual license requirements. Catalogue text and artwork do not all share the
  app's license; retain the accompanying notices.

Older repository screenshots and the upstream App Store listing describe the original Iron,
not a published Light release. This fork does not currently claim an App Store listing.
