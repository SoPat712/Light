# Light decisions log

Calls made for the owner without his explicit sign-off on the detail. Newest first. Each entry says why, where it lives, and how to undo it. Once commits exist, each entry names its commit, so `git revert <sha>` undoes it.

Builds are installed with `~/.local/share/light/tools/install-NN.sh`. Lane briefs and reports live in `~/.local/share/light/lanes/ui/`.

**Checkpoint commit `fb0bd17`** (2026-11-06) contains every entry below dated up to and including build 97. Those entries can't be reverted one by one with git. Use each entry's "Roll back" steps instead. Entries added after this checkpoint each get their own commit.

---

## 2026-11-06

### Exercise pages show their name in the bar once scrolled (build 99)
- **Found in the overnight sweep at Extra Large text:** a scrolled exercise page, and a past workout's exercise page, had an empty navigation bar. Both also set an empty screen title, so VoiceOver had no page name. A finished workout's page already fades its name into the bar once its header scrolls away.
- **Decided:** both exercise pages copy the workout page's behavior through one shared modifier, `ListHeaderScrollTitleModifier` in `SwiftUISupport.swift`. The big header is unchanged; the bar shows a one-line copy once it's gone. Before iOS 18 the bar title just stays visible.
- **Roll back:** `git revert` this entry's commit (it touches only ExerciseDetailView, WorkoutExerciseDetailView and SwiftUISupport).

### Pinned search uses a hard top scroll edge (build 98)
- **Found in the overnight sweep:** with search pinned, scrolled rows read through the field and bar on Exercises, History and the add-exercise picker, in light and dark.
- **Decided:**
  - On iOS 26 and later, the lists use `.scrollEdgeEffectStyle(.hard, for: .top)`; iOS 16–25 get a visible navigation bar background.
  - The Exercises filter section loses its extra top spacing, to match History.
- **Roll back:** `git revert` this entry's commit (it touches only ExerciseMuscleGroupsView, HistoryView and AddExercisesSheet).

### A past workout's exercise page opens read-only (build 98)
- **Why:** the owner approved read-only-by-default for finished workouts (audit D1). The exercise page reached from a finished workout was still the live logger, so it was inconsistent.
- **Decided:**
  - Read rows match the workout page's ("1  115 lb × 4"). Edit/Done switches to the unchanged editor. Notes show as plain text.
  - Previous Sessions uses short list dates ("Thu, Oct 29").
- **Roll back:** `git revert` this entry's commit (it touches only WorkoutExerciseDetailView).

### WorkoutDataKit compiles optimized in Debug (build 97)
- **Decided:** set `SWIFT_OPTIMIZATION_LEVEL = "-O"` for the WorkoutDataKit target's Debug configuration only.
- **Why:**
  - The new performance test measured about 1.1 s per full-catalog search in Debug: 36.7 s for 32 searches.
  - The owner's phone runs Debug builds, and unoptimized Swift string code was the bottleneck.
  - Search logic and ranking are unchanged. ENABLE_TESTABILITY stays on, so `@testable import WorkoutDataKit` still works.
- **Trade-off:** stepping through WorkoutDataKit in the debugger is less precise.
- **Roll back:** set that one setting back to `"-Onone"` (WorkoutDataKit Debug, in `Light.xcodeproj/project.pbxproj`).

### Exercise search runs off the main thread and stays pinned at the top (build 97)
- **Asked:** "search is super laggy" and "search should stay atop!"
- **Decided:**
  - Search waits for a 120 ms typing pause, then ranks results in the background from cached, pre-sorted lists.
  - The list no longer animates while typing.
  - Thumbnails decode in the background.
  - The search field is pinned under the title on Exercises, History and the add-exercise picker (`.navigationBarDrawer(displayMode: .always)`).
- **Why:** each keystroke re-sorted about 5,749 exercises on the main thread, and the list animated a diff of thousands of rows.
- **Where:** `ExerciseMuscleGroupsView.swift`, `AddExercisesSheet.swift`, `ExercisesView.swift` (thumbnails), `HistoryView.swift`, `WorkoutDataKit/Model/ExerciseSearch.swift`.
- **Roll back:**
  - Placement only: remove the `placement:` argument from the three `.searchable` calls.
  - Performance: revert the lane SR files.

### Watch redesign, round 2 (build 96)
- **Asked:** "do a full redesign", no scroll-wheel editing on a scrolling page, and consistent radii.
- **Decided:**
  - One shape per role: rows and cards use `watchPlatter()`; navigation and secondary actions are glass capsules; one blue primary capsule per page.
  - Home Settings became a capsule.
  - The set editor became one screen, with a new Set Options page behind "⋯".
  - Bar Weight became one screen with preset capsules.
  - Option icons use one style, a solid role-color circle with a white symbol.
  - Row values are secondary text; accent marks only tappable items.
- **Where:** `WatchIron Extension/UI/ContentView.swift`, `WorkoutSessionView.swift`, `WatchDesign.swift`, `IronApp.swift` (demo routes).
- **Roll back:** revert lanes W2A and W2B. A pre-lane copy of the Watch UI files is at `~/.local/share/light/pre-watch-audit/files.tar`, but it predates rounds 1 and 2.

### Watch plate calculator layout (build 96)
- **Asked:** "diagram front and center? weight small? idk!"
- **Decided:**
  - One screen, with the scroll wheel always editing the weight.
  - The total sits small on top, and the full barbell is drawn large in the middle.
  - Each scroll step changes the weight by the smallest loadable increment.
  - Setup moved to its own page behind a toolbar button.
  - Plates are 12% of their height wide (8% for small plates).
- **Where:** `WatchPlateCalculatorView` in `WorkoutSessionView.swift`.

### Watch clock margins restored (build 95)
- **Decided:** reverted `WatchVitalsInset` margins to 34/22 pt (below 180 pt). Lanes had trimmed them to 32/18, which hid the clock on the owner's Ultra.
- **Rule:** don't change them without a device check.

## 2026-11-05

### Workout tab: "Most Rested" card (design A; build 93)
- **Owner approved** design A and said "don't shrink the start workout button".
- **Decided the logic:**
  - Rest per muscle group comes from the same data as Home's Muscle Week.
  - The pick is the saved workout whose least-rested muscle has rested longest; ties go to the one done longest ago.
  - Tags turn green at 2 or more days, orange under 2 days, and grey for "new".
  - Tags use broad groups ("Arms"), not "Biceps", to match Home.
- **Roll back:** remove the card from `StartWorkoutView.swift` (lane WT).

### Start Workout removed from Home (build 91+)
- **Owner note:** "Maybe not even have start workout on that page!"
- **Decided:** removed it entirely. The optional Next Workout card keeps its Start button, and the floating bar handles resume.

### Home defaults and cards (build 91+)
- Removed the date under the Home title, since the week range already shows it.
- Took Recent Training out of the default cards; saved layouts are unchanged.
- Merged Body Weight into Body; stored "bodyWeight" maps to "body".

### Prefill rule interpretation (build 93)
- **Owner rule:** a later set copies the previous set; the first set copies last time's; never done means empty.
- **Decided:** values the owner typed into a saved workout's targets count as typed and are kept. Warm-up sets copy last time's first warm-up.

### e1RM (build 92)
- **Asked:** count every set.
- **Decided:**
  - One formula, Epley, everywhere.
  - A 1-rep set counts as its exact weight.
  - Removed the "Count Sets Up To" setting; the stored key stays for backups.

### Exercise renaming (X3, build 93)
- **Approved** in the audit.
- **Decided:**
  - Only an allowlist of equipment words moves to the end: Barbell, EZ Bar, Dumbbell, Cable, Kettlebell, Band, Smith Machine, Trap Bar, Landmine.
  - Name collisions keep their original titles.
  - Siri suggestions match on the original title.
- **Roll back:** revert lane R1. U9's first attempt is saved at `~/.local/share/light/lanes/ui/U9.patch`.

### Tab titles use inline-large display (build 93)
- **Asked:** "why are they wasting vertical space".
- **Decided:** `.toolbarTitleDisplayMode(.inlineLarge)` on all five tab roots. Detail pages are unchanged.
- **Roll back:** switch back to `.navigationBarTitleDisplayMode(.large)`.
