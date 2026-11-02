# Iron Design Backlog: build specs

**Latest owner decision (2026-10-31):** correct the Watch retheme to match the phone, keep
Previous visible/read-only, and give reps more width. Finish simulator verification while
sharing resources with Overland, then install on the owner's phone and Watch for direct testing.
The earlier October 26 stop is superseded by the owner's later requests. Read HANDOFF.md's
active correction and DESIGN_SYSTEM.md §22 before using the historical specifications below.

Approved design work that is not built yet, written so a coding agent can build each item
**without asking questions**. Read [`DESIGN_SYSTEM.md`](DESIGN_SYSTEM.md) first. Every token,
pattern and rule referenced here (§n) is defined there.

Owner decisions are final and recorded here. When a canvas board and this file disagree,
this file wins.

---

## 0. How to run this backlog

### 0.1 Lanes (parallel-safe file ownership)

Items in the same lane touch the same files and **must run sequentially in one agent**. Different
lanes can run at the same time. A lane must **not** edit files owned by another lane.

| Lane | Items, in order | Owns these files (exclusive) |
| --- | --- | --- |
| **A: Live workout** | B1 → B4 → B5 → B3 → B2 | `Iron/UI/Workout/CurrentWorkoutView.swift`, `Iron/UI/Workout/RestTimerView.swift`, `Iron/UI/Workout/WorkoutSetEditor.swift`, `Iron/UI/SwiftUISupport.swift`, `Shared/UI/SwiftUI/IronStyle.swift`, new `Iron/UI/Components/RestLengthRuler.swift`, `Light.xcodeproj/project.pbxproj` |
| **B: Exercise detail** | B6 | `Iron/UI/Exercises/ExerciseDetailView.swift`, `Iron/UI/Exercises/ExerciseStatisticsView.swift`, `Iron/UI/Exercises/ExerciseHistoryView.swift` |
| **C: Workout tab and Home** | B8 → B9 | `Iron/UI/Workout/StartWorkoutView.swift`, `Iron/UI/History/WorkoutDetailView.swift`, `Iron/UI/Feed/FeedView.swift` |
| **D: Polish** (after A–C merge) | B7, B10 | Whatever those items name |

Lanes B and C may **read** but not edit `SwiftUISupport.swift` and `IronStyle.swift`. If a lane
needs a new token, it uses existing ones and leaves a `// TODO(design-token)` comment. Only lane A
adds files to the Xcode project.

### 0.2 Rules for every agent

- **Do not** commit, push, stash, reset or checkout without an explicit owner request.
- **Do not** touch `reference-material/`.
- **Apple Health:** never export imported workouts (`Workout.importSource != nil`). Only workouts
  completed in Iron are exported. Do not change `HealthManager` behavior.
- No new package dependencies. A new Swift file must be registered in
  `Light.xcodeproj/project.pbxproj` for the correct target(s).
- Preserve every existing action, persistence path, accessibility label and the Watch and Live
  Activity sync calls. Visual changes must not change data behavior.
- Follow `DESIGN_SYSTEM.md` §16 and §18 for anything this file does not spell out.

### 0.3 Build and install

Offline simulator build (package checkouts are already cloned):

```bash
xcodebuild -project Light.xcodeproj -scheme Iron -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/iron-<lane>-dd -clonedSourcePackagesDirPath /tmp/iron-spm \
  -disableAutomaticPackageResolution build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

If `/tmp/iron-spm` is missing, copy it from an earlier derived-data `SourcePackages` folder or
resolve once with network access. Codex's `workspace-write` sandbox cannot run `xcodebuild`
(`sandbox_apply: Operation not permitted`). Run Codex with `-s danger-full-access` when builds
are needed, or let the orchestrator build.

Install on the owner's iPhone (the orchestrator does this; the phone must be unlocked):

```bash
xcodebuild -project Light.xcodeproj -scheme Iron -configuration Debug \
  -destination 'id=00008150-001914903E69401C' -derivedDataPath /tmp/iron-device-dd \
  -clonedSourcePackagesDirPath /tmp/iron-spm -disableAutomaticPackageResolution \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008150-001914903E69401C \
  /tmp/iron-device-dd/Build/Products/Debug-iphoneos/Iron.app
xcrun devicectl device process launch --device 00008150-001914903E69401C \
  com.joshpatra.IronDev
```

Ask the owner before booting a simulator, because other apps on the Mac may be using the CPU.

### 0.4 Status of earlier work

| Item | State |
| --- | --- |
| Recency ordering of exercises (lists, search, pickers, Watch) | **Built**: `ExerciseStore.lastPerformedDates`, `orderedByRecency`, `ExerciseRecency` |
| Exercise detail first pass (inline progress plus target map, tap-only tooltip) | **Built as a first pass**; B6 revises it to match the boards |
| Logger B focused current-set editor | **Built** (`showsFocusedEditor` in `InlineWorkoutSetRow`) |
| 2026-10-25 follow-up working tree | T1 intrinsic empty-state actions; T3 local MuscleMap hit tester + hold/scrub; T4b imported-data tools; B7 captions; B10 native zoom; audio-session setup off main. Final verification is tracked in `HANDOFF.md`. |

---

## B1. Swipe-to-delete must never overlap the complete button (bug)

**Owner report:** dragging left on a set overlaps the button that marks it complete with the
delete region.

**Cause:** in `InlineWorkoutSetRow` (`CurrentWorkoutView.swift`), `swipeDeleteAction` is
`deleteRevealWidth + deleteRevealOverlap` (18 pt) wide and sits *under* the row. The row also
extends its chrome by `InlineWorkoutSetLayout.completedChromeExpansion` (6 pt) on each side.
The red therefore starts underneath the trailing check button, which slides over it and
remains tappable.

**Spec (§9.9):**
1. Remove the overlap. The red action occupies only the space the row has vacated, minus an
   **8 pt gap**:
   `actionWidth = max(0, deleteRevealWidth − 8 − completedChromeExpansion)`.
   Position it at the trailing edge, so it never extends under the row.
2. Action visual: `danger` fill, a continuous rounded rectangle with `compactCornerRadius`, the
   **same height as the row** (52 pt compact; the focused editor's full card height), with
   `trash.fill` (14 pt bold) and "Delete" (12 pt bold) in `onMedia` white. Show the label only
   when the action is at least 52 pt wide; below that, fade and scale it (0.82 → 1), as today.
3. While the row is open (`swipeOffset < 0`):
   - every control in the row (check, fields, steppers, set-type menu, RPE pill) is
     non-interactive (`allowsHitTesting(false)` on the row content);
   - a transparent tap catcher over the row closes it (`swipeOffset = 0`, `IronMotion.snappy`);
   - the open position is `−(deleteActionWidth + 8 + completedChromeExpansion)`, so the full
     action is visible beside the row.
4. Keep everything else unchanged: the full-swipe delete threshold, the horizontal-only
   recognizer (`HorizontalSwipeRecognizer`), haptics, and the collapse transition after delete.
5. Opening one row's swipe closes any other open row. Use a shared `@State openSwipeSetID` on the
   exercise section, or a notification, whichever is simpler.

**Acceptance:**
- At every offset, the check button's frame and the red action's frame do not intersect. Check
  this with a debug overlay or by reasoning about the layout math in a code comment.
- Tapping the check button while the row is open closes the row and does **not** complete the set.
- Vertical scrolling that starts on a row still scrolls.
- This works the same for compact rows, focused editors and duration sets.

---

## B2. Session bar below the top bar, persistent

**Owner:** "I like the session bar! But I want to keep the current duration, volume, sets and
muscle group thing we have. Put the session bar right below the header of the workout, so it
remains even above the liquid glass time duration thingy when I collapse."

**Spec:**
1. Add `WorkoutSessionProgressBar`, a private view in `CurrentWorkoutView.swift`. Place it
   **directly below `workoutTopBar`** and **outside** the collapsible `sessionHeader`, so it is
   visible in both the expanded and collapsed states. In the collapsed state the glass summary
   pill sits *below* the bar.
2. Geometry: horizontal padding `IronTheme.horizontalPadding`, 2 pt top and 8 pt bottom
   padding, a **6 pt tall** capsule track in `tertiaryFill`.
3. Segments: one per exercise in workout order, width proportional to that exercise's total set
   count (completed plus planned), with **2 pt gaps** that show the background. Each segment is
   its own small capsule.
4. Fill: within each segment, completed sets fill left to right in **accent**. Completed warm-up
   sets fill in `metricSets` at 0.7 opacity; drop and failure sets use their B4 badge colors at
   0.7. Animate widths with `IronMotion.snappy`.
5. Segments use fill only, with no inner stroke. The active exercise is communicated by the
   focused editor and accessibility summary. The strip shares the unified toolbar surface.
6. Tapping a segment scrolls to that exercise, through the existing `scrollTarget` and
   `scrollTo(anchor: .top)`, with a selection haptic.
7. Accessibility: one element, label "Workout progress", value "6 of 14 sets complete, current
   exercise Bench Press", with an adjustable action that moves between exercises (scroll).
8. Do **not** change the session header contents (watch-sync banner, Duration / Volume / Sets,
   live muscle map) or the collapsed pill content. Collapse/expand is manual only; scroll
   position must never select a mode. Recheck that
   `collapsedSummaryClearance` still clears the pill. At default size it is 66 pt; at
   accessibility sizes use the measured pill height plus its 8 pt top inset and 12 pt gap.
   The pill floats inside the viewport, over content that can scroll behind its glass.
9. Hide the bar when the workout has no exercises.

**Acceptance:** the bar is visible at the scroll top and when collapsed; the collapsed pill
never covers the first exercise; completing a set animates the bar; tapping a segment scrolls.

---

## B3. Rest timer: keep the ±15 strip, top-right exercise timer, inline ruler instead of the modal

**Owner:** "I kind of like the current timer style with the −15 and +15!", "I like putting the
timer up top right of the exercise", "I'm ok with the rest length ruler! That will help us fix
the rest timer modal."

### B3.1 The rest strip stays as it is
Keep `activeRestTimerStrip` exactly as it is: `metricTimeContainer` background, `IronRestRing`,
countdown and "Rest of 2:30", and the four 44 pt neutral controls **−15 · pause/play · +15 ·
skip**. The only behavior change: tapping the readout (ring plus countdown) **toggles the inline
ruler (B3.3)** instead of setting `activeSheet = .restTimer`. Update its accessibility hint to
"Shows rest length".

### B3.2 Rest chip at the top right of each exercise card
In the exercise card header, between the title block and the ⋯ menu:
- **Idle** (this exercise has no running rest): a 32 pt capsule on `metricTimeContainer` holding
  the `timer` symbol (13 pt semibold) and the exercise's rest length in `ironMetric(.footnote,
  weight: .bold)`, all in `metricTime`. The length is `workoutExercise.restTimerDurationValue`,
  or the app's default rest when that is nil. Tap it to open the inline ruler (B3.3) under the
  exercise header, editing **this exercise's default rest**
  (`workoutExercise.restTimerDurationValue`; persist with the existing save path).
- **Running** (this exercise's rest is active): the same capsule shows a 16 pt mini
  `IronRestRing` and the live countdown (`numericText(countsDown: true)`). When paused, the tint
  is `warning`, matching `restTimerTint`. Tap it to scroll the strip into view and briefly pulse
  it (scale 1.03, `snappy`).
- Hide the chip for exercises whose sets are all duration sets with no rest configured.

### B3.3 `RestLengthRuler`: the new reusable component
Create `Iron/UI/Components/RestLengthRuler.swift` and register it in the Iron target.

```
┌──────────────────────────────────────────┐
│ Rest length                        2:30   │  footnote semibold secondary / ironMetric(.title3) metricTime
│ ▮ | | | ▮ | | | ▮ ┃ | | ▮ | | | ▮ | | | ▮ │  ticks + indicator
│ 0:30 1:00     2:00    3:00   4:00   5:00  │  caption2 secondary
│ ( 1:00 )( 1:30 )( 2:00 )( 2:30 )( 3:00 )  │  presets
└──────────────────────────────────────────┘
```

- Container: `IronTheme.raisedSurface`, `RoundedRectangle(cornerRadius: 18, style: .continuous)`,
  padding 12 vertical and 14 horizontal, 10 pt vertical spacing.
- Range **0:30–5:00 in 15 s steps** (19 ticks), evenly spaced. Each tick is 2 pt wide with a
  1 pt radius. Full-minute ticks are 26 pt tall, the others 14 pt, bottom-aligned in a 26 pt
  band. Ticks at or below the value are `metricTime`; ticks above it are `tertiaryFill`.
- Indicator: a 4 × 32 pt `metricTime` capsule. During a drag it tracks the touch continuously
  without a chasing spring; the duration and notch feedback still snap to 15 s. On release
  it settles to the chosen tick with `IronMotion.snappy` (respect Reduce Motion).
- Labels 0:30, 1:00, 2:00, 3:00, 4:00 and 5:00, positioned under their ticks.
- Interaction: a horizontal drag anywhere on the ruler sets the value to the nearest step, and a
  tap jumps to it. Each step change plays a `.selection` haptic and `IronSoundPlayer.tick`. Only
  **horizontal intent** starts a drag (reuse the `HorizontalSwipeRecognizer` approach on iOS 18
  or later; on iOS 17, `DragGesture(minimumDistance: 8)` with an `abs(dx) > abs(dy)` check), so
  vertical drags scroll the logger.
- Presets: five equal capsules, 34 pt tall: 1:00, 1:30, 2:00, 2:30, 3:00. The selected one is
  filled `metricTime` with **black** text in dark mode and **white** in light mode
  (`Color(.systemBackground)` inverted). The others are `tertiaryFill` with primary text.
  `ironMetric(.footnote, weight: .bold)`.
- API: `RestLengthRuler(value: Binding<TimeInterval>, range: 30...300, step: 15, onCommit:
  (TimeInterval) -> Void)`. It scrubs locally and calls `onCommit` **on release** (and on a
  preset tap). Notification, Watch and Live Activity updates happen in `onCommit` only, so
  dragging never stutters.
- Accessibility: `accessibilityElement`, label "Rest length", value "2 minutes 30 seconds",
  adjustable by ±15 s.

### B3.4 Where the ruler appears
1. **Running rest:** inline, directly under the rest strip, inserted with `.move(edge:
   .top).combined(with: .opacity)` and `IronMotion.collapse`. Changing the value changes the
   **running timer's total**. It cannot go below elapsed + 15 s; clamp it and play `.error`
   feedback at the clamp. It collapses automatically when the rest ends or is skipped.
2. **Exercise default rest** (B3.2 idle chip): inline under the exercise header. A second tap
   on the chip, or a tap on "Done" (a plain accent text button at the header's trailing edge),
   collapses it.
3. **Manual rest timer** (`restTimerTopBarButton` → `RestTimerView` sheet): replace the radial
   dial with `RestLengthRuler` plus a prominent "Start Rest" capsule button. Keep the sheet at
   `.height(~320)` with the system drag indicator.
4. Remove the dial (`activeSheet = .restTimer` from the strip, and the radial editor views)
   once nothing references them. Keep `IronDurationPickerSheet` for duration *sets*; that is a
   different feature.

**Acceptance:**
- −15, pause, +15 and skip behave exactly as before.
- Tapping the countdown toggles the ruler.
- Ruler changes apply on release.
- The exercise chip shows the countdown while resting.
- No modal dial is reachable from the live workout.

---

## B4. Set-type fills, softer

**Owner:** "I like filling in the set according to set type, but I want softer colors for
that." Normal sets keep today's blue exactly.

1. Add tokens to `IronStyle.swift`:
   - `setWarmUpTint = systemOrange`, `setDropTint = systemIndigo`, `setFailureTint = systemRed`;
   - container variants at 0.18 / 0.18 / 0.16 for badges;
   - `IronTheme.setFill(for tag: WorkoutSetTag?) -> (tint: Color, settled: Double, peak: Double)`:
     - normal (nil): accent, settled 0.12, peak 0.24 (**unchanged**);
     - warm-up: orange, 0.14, 0.22;
     - drop: indigo, 0.14, 0.22;
     - failure: red, 0.12, 0.20.
2. Extend `ironSetCompletion(isComplete:feedbackEnabled:tint:settledOpacity:peakOpacity:)`, with
   defaults equal to today's values so existing call sites do not change, and pass the set's
   tag values from `InlineWorkoutSetRow`.
3. Badges: the letter W/D/F in the tint color on its container; normal sets keep the accent
   badge.
4. Values on completed set-type rows stay **primary text**. Never white on a soft fill.
5. Upcoming and current rows are unchanged. Only completed rows are tinted by type.
6. `IronSessionStrip` kinds stay as they are (warm-up, normal, record).

**Acceptance:** at a glance, warm-up, drop and failure rows read as gently tinted; normal rows
look exactly as they do today; contrast passes in light and dark.

---

## B5. RPE picker redesign (replace the wheel)

**Owner:** "we need to remake the RPE selector, looks ugly too."

`RPE.allowedValues` is **5.0 … 10.0 in 0.5 steps** (11 values).

1. Generalize `EffortRatingGraph` into `IronIntensityGraph<Value: Hashable>(values: [Value],
   selection: Binding<Value?>, color: Color, label: (Value) -> String)`. Keep the rising-capsule
   geometry (height ratio 0.18 → 1.0, 5 pt spacing, active `color.gradient`, inactive
   `quaternarySystemFill`, the selected bar scaled 1.06 with a glow), tap and drag selection,
   the selection haptic and the adjustable action. Re-express `EffortRatingGraph` on top of it,
   so the session-effort UI is unchanged.
2. New `RPEPickerSheet` content inside `IronUtilitySheet(title: "Set effort", subtitle: "Rating
   of perceived exertion", systemImage: "gauge.with.dots.needle.50percent")`:
   - **Readout**, centered: "RPE" `.headline` `secondaryText`, then the value in
     `ironMetric(.largeTitle)` `metricEffort` with `numericText()` ("8.5"), then the
     description line `RPE.title(value)` (for example "1–2 reps left") in `.subheadline`
     `secondaryText`. If nothing is selected, show "—" and "Drag to rate this set".
   - **Graph:** `IronIntensityGraph` over the 11 values, 120 pt tall, in `metricEffort`. Under
     the bars, label whole numbers only (5 6 7 8 9 10) in `.caption2` `secondaryText`, aligned
     under their bars.
   - **Primary button:** full-width 50 pt capsule `.ironProminentGlassButtonStyle()`, "Set RPE
     8.5", disabled until a value is chosen.
   - **Secondary:** if the set already has an RPE, show a plain "Clear RPE" button in `danger`
     below it.
   - Detent `.height(400)` with the system drag indicator. Initial selection is the set's RPE,
     else the previous set's RPE in this exercise, else nil.
3. Keep the save path (`set.rpeValue`, `onChanged()`, the "Effort Not Saved" alert).
4. The focused editor's "Add RPE" pill and completed rows' RPE text open this sheet, as today.

**Acceptance:** no wheel anywhere for RPE; dragging across the bars selects with a tick per
step; VoiceOver can adjust.

---

## B6. Exercise detail: progress inline, target on the muscle map

Boards: canvas page **Round 5 · Exercises**, **"Exercise · progress inline + target map"** and
**"History segment"**. Lane B revises the first-pass code (`ExerciseInlineProgressView` in
`ExerciseStatisticsView.swift` and `ExerciseTargetMuscleMap` in `ExerciseDetailView.swift`) to
match this spec.

### B6.1 Header (replaces the big media hero at the top)
- A row with 4 pt inner padding. On the left, a VStack with 3 pt spacing:
  - the name in `.title.bold()` (two lines maximum, then wrap);
  - "Barbell · Chest, Triceps" (equipment, then primary muscles, capitalized) in
    `.subheadline` `secondaryText`.
- On the right, a **60 pt `ExerciseDiagramThumbnail` button** with a 22 pt accent circle badge
  at the bottom right (a white `play.fill` 9 pt glyph and a 2 pt background-colored ring).
  Tapping it presents the existing animated media (`mediaHero` content) in a sheet (`.large`)
  with a close button. Hide the badge when there is no animated media.

### B6.2 Progress card
`IronTheme.surface`, `heroCornerRadius`, padding 12 / 16 / 14, 12 pt vertical spacing. It sits
in a List row with clear background and zero insets apart from the 16 pt gutter, or in a
`ScrollView` (see B6.5).

1. **Segmented control** (§9.4): **1RM · Weight · Volume · History**. 1RM is Epley estimated
   one-rep max; Weight is top set weight per session; Volume is total volume per session. Use
   the existing `ExerciseProgressMetric` and `WorkoutExerciseChartData` math. Remember the
   choice per app (`@AppStorage("exerciseDetail.metric")`).
2. **Headline row** (1RM, Weight and Volume):
   - On the left, a label in `.footnote` `secondaryText` ("Estimated 1RM" / "Top weight" /
     "Volume per session") above a value in `ironMetric(.largeTitle)` plus the unit in
     `.headline.weight(.semibold)`. The value is accent for 1RM and Weight and `metricVolume`
     for Volume. It shows the **latest** value in range, or the scrubbed session.
   - On the right, aligned to the bottom: the delta from the first to the last session in range,
     as `arrow.up` 11 pt plus "18 lb" in `ironMetric(.subheadline, weight: .bold)`
     (`metricVolume` when up, `secondaryText` when flat or down), and below it a `.caption`
     `secondaryText` caption: "in 1 month", "in 3 months", "in 6 months", "in a year" or
     "all time".
   - While scrubbing, the label becomes the session date ("Wed, Oct 14") and the delta is
     hidden.
3. **Chart**, 140 pt plus a 14 pt x-axis band, following §10:
   - 1RM and Weight: a line with an area fill. Volume: rounded bars in `metricVolume`.
   - Three dashed gridlines with trailing y labels. The latest PR point uses the record
     treatment.
   - X labels are month abbreviations; for 1M, day numbers.
   - `chartXSelection` scrubbing updates the headline, with a selection haptic when the
     selected session changes.
4. **Range pills** (§9.5): 1M · 3M · 6M · 1Y · All, defaulting to 3M and remembered.
5. **History segment:** replaces items 2–4 with:
   - a header row: "Recent sessions" on the left, "Best e1RM" on the right, both `.footnote`
     `secondaryText`;
   - the **5 most recent sessions**, each a `NavigationLink` to that workout's detail:
     - line 1: the date ("Today", "Sat, Oct 17") in `.callout.weight(.semibold)`, then " ·
       Push A" (workout title) in `.footnote` `secondaryText`; on the right, the session's best
       e1RM in `ironMetric(.callout, weight: .bold)`, accent, or `metricRecord` if that session
       set a PR, plus "lb";
     - line 2: set chips (§9.3) that wrap, using a small flow `Layout`: warm-ups in sets colors,
       the PR set with the trophy treatment, other sets on `tertiaryFill`;
     - 0.5 pt separators between rows;
   - a **"Show all N sessions"** button: 44 pt capsule on `tertiaryFill`, accent semibold text
     with a chevron, linking to `ExerciseHistoryView`.
6. **Empty state** (never performed): hide the segments and show, centered and 24 pt padded, the
   `chart.xyaxis.line` symbol (28 pt, `secondaryText`), "No sessions yet" (`.headline`) and
   "Log this exercise in a workout and your progress will chart here." (`.subheadline`
   `secondaryText`).
7. Motion: switching segments cross-fades the content area (`IronMotion.snappy`; fade under
   Reduce Motion) and the headline digits roll (`numericText`). Changing the range animates the
   chart marks.

### B6.3 Target card
Same card style. Contents, top to bottom:
1. A header row: "Target" in `.title3.bold()` and, trailing, "Touch and hold a muscle" in
   `.footnote` `secondaryText`, baseline-aligned.
2. Front and back `BodyView`s, **96 × 169 pt each** (aspect 727:1280), 44 pt apart, centered.
   "Front" and "Back" captions sit under each in `.caption2` `secondaryText`. Use the **live
   workout's `BodyViewStyle` and highlight recipe exactly** (§3.4). **Do not use
   `showSubGroups()`.** The live map does not, and the two must look identical.
3. **Tooltip** (§9.8):
   - Touch-and-hold (0.25 s) on a highlighted muscle shows "● Chest Primary" above the touch
     point. Keep holding and drag to move between muscles: the tooltip follows and updates, with
     a `.selection` haptic per change.
   - Lift to dismiss. A quick tap shows it for 2 s.
   - The touched muscle shows the selection stroke (`.selected(_:)`).
   - Unhighlighted muscles produce nothing.
   - Implementation: read `MuscleMap/Views/BodyView.swift` (`onMuscleLongPressed(duration:)`,
     `onMuscleDragged`, `tooltip`), `InteractiveBodyOverlay.swift` and `MuscleTooltip.swift` in
     the package checkout (`/tmp/iron-spm/checkouts/MuscleMap/Sources/MuscleMap`). Prefer the
     package's long-press plus drag. If its drag recognizer would block vertical scrolling, gate
     the drag behind the long press:
     `LongPressGesture(minimumDuration: 0.25).sequenced(before: DragGesture(minimumDistance: 0))`
     on an overlay that maps the location to a muscle with the package's hit-testing. If no
     public hit-test API exists, use tap plus long-press only (no drag scrub), state that in the
     report, and do not hand-roll path data.
   - **2026-10-25 approved implementation update:** MuscleMap 1.6.4 is vendored under
     `Packages/MuscleMap` with its MIT license. The public `MuscleHitTester` facade wraps the
     existing renderer. An app-owned UIKit long press (0.25 s, 10 pt pre-hold tolerance)
     reports stationary hold onset and scrub locations; lift/cancel/failure clears selection.
     A tap waits for long-press failure and shows the tooltip for 2 s. No pan recognizer is
     attached, so pre-hold vertical drags remain available to List. This supersedes the
     tap-only fallback above.
4. A legend row: on the left, "Primary" and "Secondary" with 8 pt dots (accent and accent @
   0.42), in `.caption` `secondaryText`; on the right, equipment chips (capsule 24 pt,
   `tertiaryFill`, `.caption.weight(.semibold)`, primary text).
5. VoiceOver: one element, "Target muscles. Primary: Chest. Secondary: Shoulders, Triceps."
6. If no muscles map, show "No target muscles listed" in `.subheadline` `secondaryText` and keep
   the equipment chips.

### B6.4 Below
How to (instructions, numbered), Tips, Also Known As and References stay as today, as List
sections. The old "History" and "Progress" NavigationLinks are removed; the standalone screens
remain reachable through "Show all".

### B6.5 Container
Keep the existing `List` if the custom cards can sit in it cleanly
(`.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))`,
`.listRowBackground(Color.clear)`, `.listRowSeparator(.hidden)`). Do not switch to a
`ScrollView` unless the List fights the chart gestures.

**Acceptance:**
- Opening an exercise shows the chart with no extra tap.
- Segments and range work.
- History shows sessions inline.
- The muscle map is identical in style to the live workout's.
- Hold-and-drag shows a tooltip and never a sheet.
- The page scrolls when a vertical drag starts on the map or the chart.

---

## B7. Recency captions (optional polish)

Recency ordering is built. Optional: in the add-exercise sheet and the library, rows for
exercises you have done show a trailing `.caption` `secondaryText` relative date
(`RelativeDateTimeFormatter`, `.named`: "Today", "Yesterday", "7 days ago"), read from
`exerciseStore.lastPerformedDates`. Skip it if it crowds rows at AX sizes.

---

## B8. Workout tab redesign: Recent Workouts with one-tap Repeat

**Owner:** "the workout tab looks totally empty! Add a recent workouts section so if someone
wants to redo the same workout they did before they can." Repeat already exists, but only under
History → workout → ⋯ → Repeat (`WorkoutDetailView.repeatWorkout(blank:)`).

`StartWorkoutView` (`Iron/UI/Workout/StartWorkoutView.swift`), top to bottom, as a
`List(.insetGrouped)` with a large title "Workout":

1. **Start card** (first section, one row, custom content):
   - **No active workout:**
     - a 44 pt accent soft circle with `dumbbell.fill` (accent), "Empty Workout"
       (`.headline`) and "Add exercises as you go" (`.subheadline` `secondaryText`);
     - below that, a full-width 50 pt capsule "Start Workout"
       (`.ironProminentGlassButtonStyle()`) with `play.fill`.
   - **Active workout:** the title is the active workout's name, with the metric line
     (§9.2: elapsed · sets · volume) and a "Resume Workout" button in the same position.
2. **Recent Workouts** section (hide it if there is no history). Header "Recent Workouts" with a
   trailing "See All" text button that switches to the History tab. It holds the **5 most
   recent completed workouts** (any source, imports included), each row:
   - title (`.headline`); "Wed, Oct 14 · Chest, Triceps" (date per §13, then the top 2–3 muscle
     groups) in `.subheadline` `secondaryText`; the metric line (time · sets · volume); a
     compact `IronSessionStrip` is optional, if it fits without crowding;
   - trailing: a **Repeat** button, 36 pt circle, `.bordered` / glass, `arrow.clockwise` in
     accent, accessibility label "Repeat Push A";
   - row tap opens `WorkoutDetailView`; `contextMenu` and long press offer Repeat, Repeat with
     Blank Sets and View Details.
   - Extract the repeat logic from `WorkoutDetailView` into a shared helper (for example
     `WorkoutRepeater.start(from:blank:context:)`). Both screens call it. Keep the existing
     "workout already in progress" blocked alert, and reuse it.
   - Repeating immediately opens the live logger, as it does from History today.
3. **Saved Workouts** section (today's content, restyled rows):
   - title (`.headline`); "6 exercises · Last done 3 days ago" in `.subheadline`
     `secondaryText` (or "Never done");
   - neutral muscle tags (at most 3);
   - trailing compact "Start" capsule (30 pt, `.borderedProminent`, `.capsule`, `.controlSize(.small)`);
   - row tap opens the workout detail and the menu keeps edit, duplicate and delete; folders as
     today. Toolbar "+" menu: New Workout and Import Workout.
   - Empty: a `ContentUnavailableView`, "No saved workouts", "Save a workout for push/pull/legs,
     upper/lower, or any split you train.", plus a "New Workout" button.
4. Entrance: rows use `ironStaggeredEntrance(index:)` on first appearance only.

**Acceptance:** the tab is never visually empty for someone with history; one tap on Repeat
starts the same workout; Repeat from History still works.

---

## B9. Home: finish the Round 3 redesign

Board: **Round 3 → Home**; spec in `DESIGN_SYSTEM.md` §15.2. Audit `FeedView.swift` against
every element and build what is missing:

1. A greeting caption under the large title: "Good morning", "Good afternoon" or "Good
   evening", from the local hour (<12, <18, else). `.headline` `secondaryText`.
2. Week card (glass hero):
   - three metric chips (§9.1);
   - seven daily volume capsules, 22 pt wide and 80 pt tall, accent fill on a `tertiaryFill`
     track, with the fill height proportional to that day's volume over the week's best day;
     single-letter weekday labels, today's bold accent;
   - "Best day Saturday at **11.4k lb**";
   - a Resume or Start Workout button **inside** the card, full width, 50 pt, prominent glass.
3. A caption under the card: "Volume is up 12% on last week" (or "down", or "about the same as
   last week" within ±3%). Hide it if last week had no volume.
4. Last 4 Weeks: the header gets the streak chip (§9.3) when the streak is at least 2 weeks.
   Day circles are 34 pt: trained days solid accent with white bold numbers, untrained days
   `tertiaryFill` with `secondaryText`; today gets a 1.5 pt accent ring if untrained.
5. Keep Recent Training, Muscle Focus, Body and Pinned Charts, in today's order.

**Acceptance:** Home matches the board in both light and dark; all numbers use `ironMetric`
and metric colors.

---

## B10. Motion gaps

1. **Accessory → logger:** opening the active workout from the tab accessory zooms from the
   accessory (`matchedTransitionSource(id:in:)` on the accessory plus
   `.navigationTransition(.zoom(sourceID:in:))` on the presented logger), with a fade under
   Reduce Motion. Minimizing reverses it.
2. **Exercises library:** recency reorders use the default List animation; the search results
   transition is `IronMotion.fade`.
3. **Settings:** stock. No custom motion.

---

## Appendix: owner decisions log

| Date | Decision |
| --- | --- |
| 2026-10-17 | Apple-native direction; keep system blue; one color per metric |
| 2026-10-18 | SF Pro bold fixed-width numerals, never rounded; Apple-quality motion everywhere; original sounds instead of beeps |
| 2026-10-19 | Health: export only Iron-completed workouts, never imports |
| 2026-10-19 | Logger B focused current-set editor; keep today's blue completed fill |
| 2026-10-21 | Exercises ordered by recency everywhere, search included; history imports count |
| 2026-10-21 | Exercise detail: progress inline with metric segments and range; target on the live-workout muscle map; tooltip, not modal |
| 2026-10-22 | Keep the −15/+15 rest strip; rest chip at the top right of the exercise; ruler replaces the dial modal |
| 2026-10-22 | Set-type fills, softer; session bar under the top bar, persistent above the collapsed pill; keep the current summary |
| 2026-10-22 | Workout tab gets Recent Workouts with Repeat; finish the Home redesign; remake the RPE picker; fix the swipe overlap |
| 2026-10-25 | Approved the native Imported Data section after Import, with Hevy count/date range, replacement picker then confirmation, destructive removal confirmation, progress overlay, and no measurement removal |
| 2026-10-25 | Approved local vendoring of pinned MIT MuscleMap 1.6.4 and a small public hit-test facade for hold-and-scrub |
| 2026-10-25 | Approved simulator QA, including one additional Iron simulator; subsequently authorized direct coordination and trading the simulator/build slot with the Overland chat |

### Owner follow-up, 2026-10-25 morning

- Remove the blue haze from Home's greeting/week card: use an opaque neutral surface.
- Apply Iron styling to the exercise library: headline names, neutral metadata capsules.
- Exercise detail: one title in the page header, and custom cards aligned with native sections.
- Collapsed logger summary must own space above the scroll viewport, with a 12 pt bottom gap.
- Approved Previous-result capsules and 10 pt outlined compact input fields; keep completed blue fills.
- Extend SF Pro metric typography through remaining numeric controls, history/calendar rows and editors.
- Live Activity must show active rest immediately and keep ±15 countdown updates steady.

### Owner cohesion correction, 2026-10-25 afternoon

The owner rejected the partial font pass, explicitly including Home. The follow-up compares
full pages at matching size/appearance, not only the top of each screen. Apply the existing
type hierarchy across Home's lower sections, History, Workout, library/picker and logger:
headline data-row titles; shared number/unit readouts; subheadline inline summaries;
secondary smaller units. Keep native form/chrome typography. Home and Quick Start use native
prominent list buttons; exercise tags share one neutral capsule component. Logger input
values use bold, compact values title3, and nested corners use IronTheme tokens.

### Owner catalog direction, 2026-10-25

The owner stopped the V2 image comparison, chose to keep Iron and requested the current
OpenGym dataset plus matching of imported Hevy names (not account/API sync). Update the main
library with OpenGym text and preserve all existing UUIDs, original Hevy custom names and
workout relationships. Keep legacy entries absent upstream. Use persisted still thumbnails
from Iron's current provider and retain animations for demonstrations. OpenGym's restricted
artwork was not integrated; its non-commercial media exception is for OpenGym forks.

### Owner polish and performance requests, 2026-10-26

- Stop the OpenGym-fork direction. Keep working on Iron's native UI and Watch app.
- Restore native exercise-filter toolbar spacing; remove the extra label frames.
- Recent Workouts: full-width summary/disclosure, bold text Repeat button, and Save as
  Workout in the ellipsis menu. Saving opens a prefilled, cancellable draft.
- Keep History focused on Workouts and Insights; retain Exercise Progress in its options menu.
- Cache history aggregates off-main and use UUID lookup dictionaries. Home/History filter
  changes must not enumerate Core Data relationships or repeatedly scan the full catalog.
- Keep each chart and its controls in one grouped surface. Remove the transparent segmented
  rows that split the History, measurement and saved-workout chart sections.
- All active calendar dates open a Daily Recap before workout detail. Include totals, all
  sessions on that day, muscle focus and available measurements; rest days remain navigable.
- Complete the native type/control pass in Settings and deeper saved-workout editors. Numeric
  controls expose VoiceOver adjustments and accommodate accessibility text sizes. Preserve
  the existing meaningful chart, number, completion and navigation motion with Reduce Motion.

### 2026-10-26 logger focus, glass and high-refresh correction

- Restore the floating summary's glass: reserve top content clearance, then allow content to
  scroll behind the pill. The previous fixed strip above a clipped viewport hid refraction.
- Exactly one large next-set editor for the active workout. Supersets alternate in rounds;
  the progress marker, auto-scroll and Live Activity agree with the editor.
- Enable the iPhone high-refresh opt-in. Ruler touch position is continuous; only the chosen
  duration is discrete. Commit persistence/Watch synchronization on release. Clock ticks
  refresh duration labels, without rebuilding volume/set aggregates and muscle-map paths.

### 2026-10-26 owner correction: shape consistency and manual summary choice

- Previous results use the same continuous 10 pt corners as compact weight, reps and duration
  fields. Apply that set-data shape to the exercise-history result chips too.
- Expanded summary is the default for a new workout. Only the user's header-chevron/glass
  taps change it; remove both modern and legacy scroll-offset observers. Remember the mode
  per workout in `SceneState`, including minimize/reopen. Expanding keeps the scroll position.
- Preserve the floating glass, measured content clearance, motion and large-text reflow.

### 2026-10-26 header correction and approved organization flows

- Remove the gray summary-panel fill, all header divider rules and the progress-segment
  selection outline. Toolbar, progress and expanded summary share one `.bar` surface.
- Reserve separate duration/volume/set/map columns with 12 pt gutters. Use compact elapsed
  time (`m:ss` / `h:mm:ss`) and align captions when a long volume number scales down.
- Owner approved: native Superset sheet with exercise thumbnails, source and partner
  selection, set-order preview and explicit Save/Cancel. Existing external groups select
  together; former partners retain their own group when two or more remain.
- Owner approved: compact native Arrange Exercises sheet with handles and Done/Cancel, opened
  from a held exercise header or its Reorder menu action. Stage the order locally; preserve
  all set data and superset identities. The logger stays expanded while arranging in the sheet.
- Both mutations use the existing isolated persist/save boundary. Reject stale memberships or
  incomplete order snapshots before mutation; failed saves restore the prior graph.


### 2026-10-26 approved Light name and Set tile Live Activities

- Owner selected Set tile from the visual comparison and authorized implementation. Compact
  iPhone/Mac shows artwork plus blue per-exercise set cells; minimal shows the tile. Remove
  compact stopwatches. Watch uses a black card with exercise/name, set position, tile, and
  secondary rest/Skip. Expanded iPhone keeps its contents below the sensor in one inset region.
- Count actual completed sets rather than inferring from the current ordinal. Keep old payloads
  decodable and cap tile density at twelve cells with proportional fills above that.
- Owner reported compact clipping. Use 20 pt tile, 24 pt slot and 6 pt trailing clearance;
  require native visual verification before claiming the corner issue fully verified.
- Rename displayed app to Light and update README/About with current features and original Iron
  credit. Preserve installed-data identifiers and current icon; the owner will supply new art.
- Owner wants the Ultra 4 installation repaired and confirmed Developer Mode is on. Preserve
  device pairings/data. They explicitly prefer IPv6 stay Off; do not change network settings.

### Watch app Focus redesign — approved 2026-10-26

Scope is the **entire Watch app**. Owner explicitly says the phone is now solid; preserve its
visual design. Reviewable prototype: `light-watch-redesign.html` in this chat's visualization
directory. Owner selected Focus (one current set with paired fields) over the alternative
Set list (denser rows). Its original navigation is superseded by the approved exercise-first
flow below; shared visual tokens, native controls and recording requirements still apply.

1. **Navigation and foundation.** Replace nested NavigationView/NavigationStack ownership with
   one stack. One title at a time; reserve the system clock and navigation safe area. Use SF
   Pro and shared metric weight/digits, blue actions/completed fills, semantic metric colors,
   10 pt data fields, native watchOS sheets/menus. Liquid Glass belongs to floating navigation
   and controls; the OLED content canvas stays black. Remove legacy rounded typography.
2. **Current-set logger.** Open active workout entries at the next set, with exercise artwork,
   wrapping name, explicit set type/position and set-progress cells. Weight/reps (plus time or
   distance where relevant) open Crown-adjustable editors with accessible steppers. Keep a
   quiet previous result, RPE and one primary Log Set action. Use the same superset target as
   the phone: A1 → B1 → A2 → B2. No duplicate workout-title header over the exercise title.
3. **Rest.** Secondary cyan rest state with stable countdown, −15/pause/+15 and Start Next Set.
   Preview the next exercise. Completion fill, rest insertion and next-set navigation explain
   the transition; Reduce Motion uses a short fade. No decorative looping motion or beeps.
4. **Exercise management.** A compact overview with thumbnails, linked-group identity, completed
   counts and blue fills. Preserve Add/Replace/Delete Exercise, Add/Delete Set and all set
   types. Native lists scroll with the Crown; secondary actions stay in the relevant context.
   Edit drafts support Cancel; deletion confirms scope. Existing durable outbox and identities
   remain unchanged. Prototype catalogue choices are illustrative, not a new data source.
5. **Finish and edge states.** Effort bars and a concise recap: duration, sets, volume, estimated
   active calories and Health save state. Preserve save failure/retry and offline queued edits.
   Include ready, reconnecting, missing sensor/permission, no exercises and completed states.
   Distinguish edit sync from active HealthKit recording; when recovery finds no session, offer
   an explicit Record on Watch action that starts sensor collection now. Never invent earlier
   readings/calories. Watch-local readings continue when the phone is disconnected.
   Never report missing heart rate/calories as measured zero. Retain all existing accessibility.
6. **Acceptance.** Test on the actual Ultra 4 and a smaller Watch layout, default/large text,
   long exercise names, both weight units, zero/bodyweight/duration sets, unequal supersets,
   Watch disconnected, denied Health permission and crash recovery. Verify local Live Activity
   tap opens the current Watch workout, no title/control clipping, no overlapping hit regions,
   and no duplicate Health workout. Build/test/install only after owner approves the layout.

Independent correctness update delivered before the redesign: live heart rate/estimated active
calories in the phone connection row, best-effort UUID-scoped telemetry, native Watch Live
Activity launch declaration, and HealthKit stop/collect/save/end sequencing. Time edits remain
in Light; the Watch's HealthKit sample retains its recorded sensor window and associations.


### Focus implementation and Watch-only expansion (2026-10-26)

- Owner selected Focus and authorized every Watch screen and deep menu. One root NavigationStack;
  use a native top-leading options control. `primaryAction` did not render on Watch during QA,
  so New Workout is an explicit saved-library row. Saved draft sheets have Cancel/Save and no
  crowded navigation title. Body owns the focused exercise name.
- Primary Log Set precedes secondary RPE/previous controls; this keeps the action visible at
  default Ultra size. Smaller and accessibility layouts scroll. Weight/reps stack at large text.
- Watch-only: Start Workout; bundled exercise search; add/replace/remove/reorder exercises;
  add/edit/delete any set; type/RPE/notes/rest/duration/distance; linked superset rounds;
  pause/resume; effort/finish/discard; save/create/edit/delete saved workouts; history/repeat.
  Saved routine fields match the existing phone model (weight/repetition targets/duration);
  current/history set distance stays canonical meters. Import/export/body tools remain on phone.
- Library/history sync uses a separately cached immutable file. Durable edits serialize to ACK;
  conflicting phone and Watch current UUIDs never displace one another. Imported Health rule
  unchanged. Missing sensors are dashes; recording status/retry is separate from edit sync.


### Exercise-first Watch redesign (2026-10-26, approved and installed)

Owner replaces Focus as the default navigation. Workout → exercise list (red HR top left,
orange active kcal top right) → exercise sets/context → set values. Remove global ellipsis.
Home: New Workout, Saved Workouts, History; larger rows and useful exercise/set/muscle counts.
Live sync includes automatic Health recording/recovery whenever a native workout is active,
plus bidirectional edits and cached routines/history. Recording is not a normal opt-in.
Interactive proposal: light-watch-exercise-first.html. Owner approved implementation and
installation. 88 browser checks passed including narrow width/larger text. Native build 43
implements Home → exercise list → exercise sets → set editor throughout the Watch app.

- Pin red BPM/orange active kcal above scrolling content on every active-workout route,
  including deep set Settings, extra measurements, plate calculator and Crown sheets. Keep
  vitals unredacted in Always On; stack them for large text.
- No global ellipsis. Secondary set actions are behind Settings at the bottom of the set.
- Larger saved/history rows show exercise/set totals, primary muscles and history date/time.
  Preserve routine drafts, contextual superset editing, ordering and read-only history detail.
- Automatic recovery/start is the normal path. Keep paused/finalizing sessions intact; failed
  automatic attempts do not loop. Never create duplicate Health workouts or export imports.
- Signed phone/Watch builds and full iOS test-bundle compilation pass. Real Ultra 4 launch
  shows live heart rate and increasing active energy in the pinned header. Detailed layout,
  regression and install evidence is recorded in QA_2026-10-26.md.
