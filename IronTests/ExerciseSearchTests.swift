import XCTest
import Dispatch
import Combine
import CoreData
@testable import WorkoutDataKit
@testable import Iron

final class ExerciseSearchTests: XCTestCase {
    private typealias Candidate = ExerciseSearch.Prepared<String>

    private var curls: [Candidate] {
        [
            Candidate(id: "preacher", title: "Preacher Curl: Machine", aliases: ["Machine Biceps Curl"]),
            Candidate(id: "band", title: "Band Alternating Biceps Curl"),
            Candidate(id: "machine", title: "Bicep Curl (Machine)"),
            Candidate(id: "barbell", title: "Bicep Curl (Barbell)"),
            Candidate(id: "dumbbell", title: "Bicep Curl (Dumbbell)")
        ]
    }

    private func ids(_ candidates: [Candidate], query: String, dates: [String: Date] = [:]) -> [String] {
        ExerciseSearch.ranked(candidates, matching: .init(query), lastPerformedDates: dates).map(\.id)
    }

    func testSingularAndPluralBicepQueriesPutAllCanonicalVariantsFirst() {
        let dates = ["preacher": Date(timeIntervalSince1970: 200), "band": Date(timeIntervalSince1970: 100)]
        for query in ["bicep curl", "biceps curl"] {
            let result = ids(curls, query: query, dates: dates)
            XCTAssertEqual(Set(result.prefix(3)), Set(["machine", "barbell", "dumbbell"]), query)
            XCTAssertEqual(Set(result.suffix(2)), Set(["preacher", "band"]), query)
        }
    }

    func testCurlsFindsCurlsAndTransposedBicepStillPutsVariantsFirst() {
        XCTAssertEqual(Set(ids(curls, query: "curls")), Set(curls.map(\.id)))
        let typoMatches = ids(curls, query: "bicpe curl")
        XCTAssertEqual(Set(typoMatches.prefix(3)), Set(["machine", "barbell", "dumbbell"]))
        XCTAssertEqual(Set(typoMatches), Set(curls.map(\.id)))
    }

    func testDumbbellAbbreviationPutsDumbbellCurlFirst() {
        XCTAssertEqual(ids(curls, query: "db curl").first, "dumbbell")
    }

    func testAbbreviationsExpandOnBothSides() {
        for (short, expanded) in [
            ("db", "dumbbell"), ("bb", "barbell"), ("kb", "kettlebell"),
            ("ohp", "overhead press"), ("rdl", "romanian deadlift")
        ] {
            XCTAssertEqual(ExerciseSearch.tier(for: Candidate(id: short, title: expanded), matching: .init(short)), .exactTitle)
            XCTAssertEqual(ExerciseSearch.tier(for: Candidate(id: short, title: short), matching: .init(expanded)), .exactTitle)
        }
    }

    func testPullupJoinedHyphenatedAndSpacedFormsMatchInBothDirections() {
        let candidates = ["Pull Up", "Pull-Up", "Pullup"].map { Candidate(id: $0, title: $0) }
        for query in ["pullup", "pull-up", "pull up", "pullups", "pull-ups"] {
            XCTAssertEqual(Set(ids(candidates, query: query)), Set(candidates.map(\.id)), query)
        }
        let weighted = Candidate(id: "weighted", title: "Weighted Pull Up")
        XCTAssertEqual(ExerciseSearch.tier(for: weighted, matching: .init("pullup")), .contiguousTitle)
        XCTAssertEqual(ExerciseSearch.tier(for: Candidate(id: "x", title: "Pullup Weighted"),
                                          matching: .init("weighted pull up")), .unorderedTitle)
    }

    func testExactTitleBeatsMoreRecentPartialMatch() {
        let candidates = [Candidate(id: "partial", title: "Bicep Curl (Machine)"),
                          Candidate(id: "exact", title: "Bicep Curl")]
        XCTAssertEqual(ids(candidates, query: "bicep curl", dates: ["partial": Date()]), ["exact", "partial"])
    }

    func testJoinedTokensRetainPrefixAndTypoTolerance() {
        let candidate = Candidate(id: "pullup", title: "Pullup")
        XCTAssertEqual(ExerciseSearch.tier(for: candidate, matching: .init("pull u")), .prefix)
        XCTAssertEqual(ExerciseSearch.tier(for: candidate, matching: .init("puul up")), .typo)
    }

    func testRecencyBreaksTiesWithinATierBeforeSpecificityAndAlphabeticalOrder() {
        let candidates = [Candidate(id: "short", title: "Bicep Curl (Barbell)"),
                          Candidate(id: "older", title: "Bicep Curl (Machine)"),
                          Candidate(id: "newest", title: "Bicep Curl Standing Dumbbell")]
        let dates = ["older": Date(timeIntervalSince1970: 100), "newest": Date(timeIntervalSince1970: 200)]
        XCTAssertEqual(ids(candidates, query: "bicep curl", dates: dates), ["newest", "older", "short"])
    }

    func testSpecificityThenAlphabeticalOrderBreakEqualRecencyTies() {
        let candidates = [Candidate(id: "long", title: "Bicep Curl Standing Dumbbell"),
                          Candidate(id: "machine", title: "Bicep Curl (Machine)"),
                          Candidate(id: "barbell", title: "Bicep Curl (Barbell)")]
        let dates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, Date(timeIntervalSince1970: 100)) })
        XCTAssertEqual(ids(candidates, query: "bicep curl", dates: dates), ["barbell", "machine", "long"])
    }

    func testAllSevenTiersBeatRecencyAcrossTiers() {
        let cases: [(String, [String], ExerciseSearch.Tier)] = [
            ("Bicep Curl", [], .exactTitle),
            ("Bicep Curl (Machine)", [], .titleStart),
            ("Standing Bicep Curl", [], .contiguousTitle),
            ("Curl Standing Bicep", [], .unorderedTitle),
            ("Preacher Machine", ["Biceps Curl"], .alias),
            ("Bicep Curling", [], .prefix),
            ("Bicpe Curl", [], .typo)
        ]
        let candidates = cases.map { Candidate(id: $0.0, title: $0.0, aliases: $0.1) }
        for (candidate, item) in zip(candidates, cases) {
            XCTAssertEqual(ExerciseSearch.tier(for: candidate, matching: .init("bicep curl")), item.2, candidate.id)
        }
        let dates = Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
            ($0.element.id, Date(timeIntervalSince1970: Double($0.offset)))
        })
        XCTAssertEqual(ids(Array(candidates.reversed()), query: "bicep curl", dates: dates), candidates.map(\.id))
    }

    func testTokensCannotBeCombinedAcrossTitleAndSeparateAliasesOrReused() {
        let candidates = [Candidate(id: "aliases", title: "Machine", aliases: ["Bicep", "Curl"]),
                          Candidate(id: "title", title: "Bicep", aliases: ["Curl"])]
        XCTAssertTrue(ids(candidates, query: "bicep curl").isEmpty)
        XCTAssertTrue(ids([Candidate(id: "one", title: "Curl")], query: "curl curl").isEmpty)
    }

    func testPrefixIsAllowedForLastTokenOrAnyTokenOfAtLeastThreeLetters() {
        let candidate = Candidate(id: "curl", title: "Bicep Curl")
        for query in ["bicep c", "bic curl"] {
            XCTAssertEqual(ExerciseSearch.tier(for: candidate, matching: .init(query)), .prefix, query)
        }
        XCTAssertNil(ExerciseSearch.tier(for: candidate, matching: .init("bi curl")))
        XCTAssertNil(ExerciseSearch.tier(for: Candidate(id: "row", title: "Raw"), matching: .init("row")))
    }

    func testTypoThresholdsAndUnrestrictedDamerauTransposition() {
        for (query, title, expected) in [
            ("bicpe", "Bicep", true), ("bicxe", "Bicep", false),
            ("dumnbeld", "Dumbbell", true), ("dxmnbeld", "Dumbbell", false),
            ("prefixca", "Prefixabc", true)
        ] {
            let tier = ExerciseSearch.tier(for: Candidate(id: title, title: title), matching: .init(query))
            XCTAssertEqual(tier, expected ? .typo : nil, query)
        }
    }

    func testNormalizationAndLightStemmingAreSymmetric() {
        let candidate = Candidate(id: "curl", title: "Bicep Curl (Dumbbell)")
        XCTAssertEqual(ExerciseSearch.tier(for: candidate, matching: .init(" \nBÍCÉPS:CÚRLS/(DB)-,.' ")), .exactTitle)
        for (plural, singular) in [("presses", "press"), ("lunges", "lunge"), ("biceps", "bicep"),
                                   ("triceps", "tricep"), ("curls", "curl"), ("raises", "raise"),
                                   ("flyes", "fly"), ("flies", "fly"), ("abs", "abs"), ("cross", "cross")] {
            XCTAssertEqual(ExerciseSearch.tier(for: Candidate(id: plural, title: plural), matching: .init(singular)), .exactTitle)
            XCTAssertEqual(ExerciseSearch.tier(for: Candidate(id: singular, title: singular), matching: .init(plural)), .exactTitle)
        }
    }

    func testEmptyQueryReturnsInputOrderIncludingWithHistory() {
        for query in ["", " \n\t", " :()/-,.' "] {
            XCTAssertEqual(ids(curls, query: query, dates: ["dumbbell": Date()]), curls.map(\.id))
        }
    }

    func testStoreFlatAndGroupedSearchShareRankingAndKeepGroupOrder() {
        let exact = exercise("Bicep Curl")
        let partial = exercise("Bicep Curl (Machine)")
        let other = exercise("Squat")
        let dates = [partial.uuid: Date()]
        let input = [partial, other, exact]
        XCTAssertEqual(ExerciseStore.filter(exercises: input, using: "biceps curl", lastPerformedDates: dates), [exact, partial])
        XCTAssertEqual(ExerciseStore.filter(exercises: input, using: ""), input)
        let groups = [ExerciseGroup(title: "first", exercises: [partial, exact]),
                      ExerciseGroup(title: "empty", exercises: []),
                      ExerciseGroup(title: "second", exercises: [other, partial, exact])]
        let matches = ExerciseStore.filter(exerciseGroups: groups, using: "biceps curl", lastPerformedDates: dates)
        XCTAssertEqual(matches.map(\.title), ["first", "second"])
        XCTAssertEqual(matches.map(\.exercises), [[exact, partial], [exact, partial]])
        XCTAssertEqual(ExerciseStore.filter(exerciseGroups: groups, using: "").map(\.title), groups.map(\.title))
    }

    func testStorePreparationRefreshesWhenTitleOrAliasesChangeForAnID() {
        let original = exercise("Curl", aliases: ["Arm Lift"])
        let renamed = exercise("Squat", id: original.uuid, aliases: ["Leg Lift"])
        XCTAssertEqual(ExerciseStore.filter(exercises: [original], using: "arm lift"), [original])
        XCTAssertTrue(ExerciseStore.filter(exercises: [renamed], using: "arm lift").isEmpty)
        XCTAssertEqual(ExerciseStore.filter(exercises: [renamed], using: "leg lift"), [renamed])
        let newAlias = exercise("Squat", id: original.uuid, aliases: ["Lower Body"])
        XCTAssertEqual(ExerciseStore.filter(exercises: [newAlias], using: "lower body"), [newAlias])
        XCTAssertTrue(ExerciseStore.filter(exercises: [newAlias], using: "leg lift").isEmpty)
    }

    func testAddCatalogKeepsMuscleAndEquipmentFiltersAndCanBroadenAfterAnotherLetter() throws {
        let dumbbell = exercise("Bicep Curl (Dumbbell)", equipment: ["dumbbell"])
        let barbell = exercise("Bicep Curl (Barbell)", equipment: ["barbell"])
        let legCurl = exercise("Leg Curl", muscle: "quads", equipment: ["machine"])
        let catalog = AddExerciseCatalog(exercises: [legCurl, barbell, dumbbell], store: try store([]))
        XCTAssertEqual(catalog.matches(search: "curls", muscleGroup: dumbbell.muscleGroup, equipment: "dumbbell"), [dumbbell])
        XCTAssertEqual(catalog.matches(search: "curls", muscleGroup: legCurl.muscleGroup, equipment: nil), [legCurl])
        XCTAssertTrue(catalog.matches(search: "curls", muscleGroup: dumbbell.muscleGroup, equipment: "machine").isEmpty)
        XCTAssertTrue(catalog.matches(search: "bix", muscleGroup: nil, equipment: nil).isEmpty)
        XCTAssertEqual(Set(catalog.matches(search: "bixep", muscleGroup: nil, equipment: nil)), Set([barbell, dumbbell]))
        XCTAssertEqual(catalog.moreCount, 0)
    }

    func testAddCatalogAppliesBrowsableSplitAfterRankingAndPreservesMoreBehavior() throws {
        let band = exercise("Band Bicep Curl")
        let canonical = exercise("Bicep Curl (Machine)")
        let unlisted = exercise("Bicep Curl", image: nil)
        let exercises = [band, unlisted, canonical]
        let catalog = AddExerciseCatalog(exercises: exercises, store: try store(exercises))
        XCTAssertEqual(catalog.matches(search: "", muscleGroup: nil, equipment: nil), [band, canonical])
        XCTAssertEqual(catalog.moreCount, 1)
        XCTAssertEqual(catalog.matches(search: "biceps curl", muscleGroup: nil, equipment: nil), [canonical, band, unlisted])
        XCTAssertEqual(catalog.moreCount, 0)
        XCTAssertEqual(catalog.matches(search: "", muscleGroup: nil, equipment: nil, showingAll: true), [band, canonical, unlisted])
        XCTAssertEqual(catalog.moreCount, 0)
    }

    func testBuiltInCatalogMovesOnlyAllowlistedEquipmentWithCanonicalSuffixes() throws {
        let fixtures: [(String, String, String)] = [
            ("Barbell Bench Press", "barbell", "Bench Press: Barbell"),
            ("dUmBbElL Fly", "dumbbell", "Fly: Dumbbell"),
            ("Cable Fly", "cable", "Fly: Cable"),
            ("Kettlebell Swing", "kettlebell", "Swing: Kettlebell"),
            ("Olympic Barbell Hammer Curl", "olympic barbell", "Hammer Curl: Barbell"),
            ("EZ Curl Bar Preacher Curl", "ez-curl-bar", "Preacher Curl: EZ Bar"),
            ("EZ Barbell Standing Curl", "ez barbell", "Standing Curl: EZ Bar"),
            ("eZ bAr Seated Curl", "ez barbell", "Seated Curl: EZ Bar"),
            ("Smith Machine Bench Press", "smith machine", "Bench Press: Smith Machine"),
            ("Smith Squat", "smith machine", "Squat: Smith Machine"),
            ("Resistance Band Hip Thrust", "band", "Hip Thrust: Band"),
            ("Band Leg Extension", "resistance band", "Leg Extension: Band"),
            ("Trap Bar Deadlift", "trap bar", "Deadlift: Trap Bar"),
            ("Landmine Squat and Press", "landmine", "Squat and Press: Landmine")
        ]
        let input = fixtures.map { exercise($0.0, aliases: ["Existing Alias"], equipment: [$0.1]) }
        let catalog = try store(input).builtInExercises
        XCTAssertEqual(catalog.map(\.title), fixtures.map { $0.2 })
        XCTAssertEqual(catalog.map(\.uuid), input.map(\.uuid))
        XCTAssertEqual(catalog.map(\.originalTitle), input.map(\.title))
        for (original, renamed) in zip(input, catalog) {
            XCTAssertEqual(renamed.equipment, original.equipment)
            XCTAssertEqual(renamed.alias, ["Existing Alias", original.title])
        }
    }

    func testBuiltInCatalogLeavesColonTitlesAndOtherEquipmentNamesInPlace() throws {
        let input = [exercise("Overhead Press: Barbell", equipment: ["barbell"]),
                     exercise("Cable Fly: High", equipment: ["cable"]),
                     exercise("Barbell Row", equipment: ["cable"]),
                     exercise("Barbells Row", equipment: ["barbell"]),
                     exercise("Landmine 180", equipment: ["barbell"]),
                     exercise("Tire Flip", equipment: ["tire"]),
                     exercise("Weighted Bench Dip", equipment: ["weighted"]),
                     exercise("Assisted Hanging Knee Raise", equipment: ["assisted"]),
                     exercise("Roller Back Stretch", equipment: ["roller"]),
                     exercise("Elliptical Machine Walk", equipment: ["elliptical machine"]),
                     exercise("Lever Chest Press", equipment: ["leverage machine"]),
                     exercise("Medicine Ball Chest Pass", equipment: ["medicine ball"]),
                     exercise("Stability Ball Crunch", equipment: ["stability ball"]),
                     exercise("Sled Push", equipment: ["sled machine"]),
                     exercise("Stationary Bike Run", equipment: ["stationary bike"])]
        XCTAssertEqual(try store(input).builtInExercises, input)
    }

    func testBuiltInCatalogStripsOnlyTrailingGenderSuffixesIncludingColonTitles() throws {
        let fixtures: [(String, [String], String)] = [
            ("Crunch (male)", [], "Crunch"),
            ("Dumbbell Fly (FeMaLe)", ["dumbbell"], "Fly: Dumbbell"),
            ("Overhead Press: Barbell (MALE)", ["barbell"], "Overhead Press: Barbell"),
            ("Lunge (female) Alternating", [], "Lunge (female) Alternating")
        ]
        let input = fixtures.map { exercise($0.0, equipment: $0.1) }
        let catalog = try store(input).builtInExercises
        XCTAssertEqual(catalog.map(\.title), fixtures.map { $0.2 })
        for (original, renamed) in zip(input, catalog) where original.title != renamed.title {
            XCTAssertTrue(renamed.alias.contains(original.title))
        }
    }

    func testBuiltInCatalogKeepsEveryOriginalInEquipmentAndGenderCollisionGroups() throws {
        let input = [exercise("Barbell Squat", equipment: ["barbell"]),
                     exercise("Squat: Barbell", equipment: ["barbell"]),
                     exercise("Crunch (male)"), exercise("Crunch (female)"),
                     exercise("Dumbbell Fly", equipment: ["dumbbell"]),
                     exercise("fly: dumbbell", equipment: ["dumbbell"]),
                     exercise("EZ Barbell Curl", equipment: ["ez barbell"]),
                     exercise("EZ Curl Bar Curl", equipment: ["ez-curl-bar"]),
                     exercise("Smith Machine Squat", equipment: ["smith machine"]),
                     exercise("Smith Squat", equipment: ["smith machine"])]
        XCTAssertEqual(try store(input).builtInExercises, input)
    }

    func testCustomExerciseTitlesAndAliasesAreNeverReformatted() throws {
        let custom = exercise("Barbell Bench Press (female)", aliases: ["My Bench"],
                              equipment: ["barbell"], everkineticID: 10000)
        let catalog = try store([], customExercises: [custom])
        XCTAssertEqual(catalog.customExercises, [custom])
        XCTAssertEqual(ExerciseCatalogMetadata.usingDisplayTitles([custom]), [custom])

        // Custom names do not prevent a built-in display change.
        let builtIn = exercise("Barbell Bench Press", equipment: ["barbell"])
        let sameDisplay = exercise("Bench Press: Barbell", everkineticID: 10000)
        XCTAssertEqual(ExerciseCatalogMetadata.usingDisplayTitles([builtIn, sameDisplay]).map(\.title),
                       ["Bench Press: Barbell", sameDisplay.title])
    }

    func testCatalogRenameRetainsIdentityMetadataAndSerializedSourceName() throws {
        let original = Exercise(uuid: UUID(), everkineticId: 1, title: "Barbell Bench Press", alias: ["Bench"],
                                description: "Description", primaryMuscle: ["chest"], secondaryMuscle: ["triceps"],
                                equipment: ["barbell"], steps: ["Step"], tips: ["Tip"], references: ["Reference"],
                                pdfPaths: ["fixture.pdf"], imageFilename: "fixture.gif", animationFilename: "motion.gif")
        let renamed = try XCTUnwrap(try store([original]).builtInExercises.first)
        let encoded = try JSONEncoder().encode(renamed)
        let decoded = try JSONDecoder().decode(Exercise.self, from: encoded)
        let expected = Exercise(uuid: original.uuid, everkineticId: original.everkineticId, title: original.title,
                                alias: original.alias + [original.title], description: original.description,
                                primaryMuscle: original.primaryMuscle, secondaryMuscle: original.secondaryMuscle,
                                equipment: original.equipment, steps: original.steps, tips: original.tips,
                                references: original.references, pdfPaths: original.pdfPaths,
                                imageFilename: original.imageFilename, animationFilename: original.animationFilename)
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(ExerciseCatalogMetadata.usingDisplayTitles([renamed]), [renamed])
    }

    func testOldCatalogTitleKeepsItsSearchTiersAndStoreFindsBothNames() throws {
        let original = exercise("Barbell Bench Press", aliases: ["Chest Lift"], equipment: ["barbell"])
        let catalog = try store([original])
        let renamed = try XCTUnwrap(catalog.builtInExercises.first)
        let before = Candidate(id: "bench", title: original.title, aliases: original.alias)
        let after = Candidate(id: "bench", title: renamed.title, aliases: renamed.alias,
                              originalTitle: renamed.originalTitle)
        for query in [original.title, "barbell bench", "bench press", "press barbell", "barbell ben", "barbell bnech press",
                      "Chest Lift"] {
            let oldTier = try XCTUnwrap(ExerciseSearch.tier(for: before, matching: .init(query)), query)
            let newTier = try XCTUnwrap(ExerciseSearch.tier(for: after, matching: .init(query)), query)
            XCTAssertLessThanOrEqual(newTier, oldTier, query)
            XCTAssertEqual(ExerciseStore.filter(exercises: catalog.exercises, using: query).map(\.uuid), [original.uuid], query)
        }
        XCTAssertEqual(ExerciseSearch.tier(for: after, matching: .init(renamed.title)), .exactTitle)
        XCTAssertEqual(ExerciseStore.filter(exercises: catalog.exercises, using: renamed.title), [renamed])
        let recentPartial = Candidate(id: "recent", title: "Barbell Bench Press Close Grip")
        XCTAssertEqual(ids([recentPartial, after], query: original.title, dates: ["recent": Date()]), ["bench", "recent"])
    }

    func testOldGenderedTitleStillFindsTheSameExercise() throws {
        let original = exercise("Crunch (female)")
        let catalog = try store([original])
        let renamed = try XCTUnwrap(catalog.builtInExercises.first)
        for query in [original.title, renamed.title, "crunch fem", "crnuch female"] {
            XCTAssertEqual(ExerciseStore.filter(exercises: catalog.exercises, using: query).map(\.uuid), [original.uuid], query)
        }
    }

    func testSearchPreparationRefreshesWhenOnlyTheOriginalTitleChanges() {
        let original = exercise("Bench Press: Barbell", originalTitle: "Barbell Bench Press (female)")
        let changed = exercise(original.title, id: original.uuid, originalTitle: "Barbell Bench Press (male)")
        XCTAssertEqual(ExerciseStore.filter(exercises: [original], using: "female"), [original])
        XCTAssertTrue(ExerciseStore.filter(exercises: [changed], using: "female").isEmpty)
        XCTAssertEqual(ExerciseStore.filter(exercises: [changed], using: "male"), [changed])
    }

    func testCustomCreationStillRejectsTheOriginalCatalogTitle() throws {
        let catalog = try store([exercise("Barbell Bench Press", equipment: ["barbell"])])
        for title in ["Barbell Bench Press", "Bench Press: Barbell"] {
            XCTAssertThrowsError(try catalog.stageCreatingCustomExercises([.init(title: title, type: .barbell)])) { error in
                guard case ExerciseStore.CustomExerciseMutationError.duplicateTitle(let duplicate) = error else {
                    return XCTFail("Expected a duplicate-title error, got \(error)")
                }
                XCTAssertEqual(duplicate, title)
            }
            XCTAssertThrowsError(try catalog.createCustomExercise(title: title, description: nil,
                                                                  primaryMuscle: [], secondaryMuscle: [], type: .barbell)) { error in
                guard case ExerciseStore.CustomExerciseMutationError.duplicateTitle = error else {
                    return XCTFail("Expected a duplicate-title error, got \(error)")
                }
            }
        }
    }

    func testAddCatalogRetainsOriginalTitlePriorityAfterRenaming() throws {
        let original = exercise("Barbell Bench Press", equipment: ["barbell"])
        let partial = exercise("Barbell Bench Press Close Grip", equipment: ["barbell"])
        let store = try store([partial, original])
        let catalog = AddExerciseCatalog(exercises: store.builtInExercises, store: store)
        XCTAssertEqual(catalog.matches(search: original.title, muscleGroup: nil, equipment: nil).map(\.uuid),
                       [original.uuid, partial.uuid])
    }

    func testCachedSearchInputPreservesStoreRankingAndBrowsablePartition() throws {
        let original = exercise("Barbell Bench Press", aliases: ["Chest Lift"], equipment: ["barbell"])
        let partial = exercise("Barbell Bench Press Close Grip", equipment: ["barbell"])
        let secondary = exercise("Bench Press", image: nil)
        let store = try store([partial, secondary, original])
        let catalog = AddExerciseCatalog(exercises: store.builtInExercises, store: store)
        let candidates = catalog.candidates(muscleGroup: nil, equipment: nil)
        let dates = [partial.uuid: Date(timeIntervalSince1970: 100), secondary.uuid: Date(timeIntervalSince1970: 200)]
        let input = AddExerciseCatalog.SearchInput(prepared: candidates.searchInput.prepared,
                                                  lastPerformedDates: dates,
                                                  browsableIDs: candidates.searchInput.browsableIDs)
        for text in ["barbell bench press", "bench", "chest lift", "bnech", "b", " : "] {
            let expected = store.listed(ExerciseStore.filter(exercises: candidates.exercises, using: text,
                                                              lastPerformedDates: dates), showingAll: true)
            XCTAssertEqual(input.rankedIDs(matching: .init(text)), expected.map(\.uuid), text)
        }
        XCTAssertEqual(candidates.sections.flatMap(\.exercises), candidates.exercises.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        })
    }

    @MainActor
    func testCatalogCandidatesRefreshRecentDatesWithUnchangedExercisesAndFilters() throws {
        let alpha = exercise("Alpha Press")
        let middle = exercise("Middle Curl")
        let zulu = exercise("Zulu Row")
        let unseen = exercise("Unseen Squat")
        let store = try store([alpha, middle, zulu, unseen])
        // Keep the source order fixed so a changed date, rather than a changed
        // shownExercises ordering, must invalidate the cached candidates.
        let library = store.builtInExercises
        let container = setUpInMemoryNSPersistentContainer()
        let context = container.viewContext
        var workouts: [Workout] = []
        for (exercise, time) in [(alpha, 200.0), (middle, 100.0), (zulu, 300.0)] {
            let workout = Workout.create(context: context)
            workout.start = Date(timeIntervalSince1970: time)
            workout.end = workout.start?.addingTimeInterval(3600)
            workout.isCurrentWorkout = false
            let entry = WorkoutExercise.create(context: context)
            entry.exerciseUuid = exercise.uuid
            entry.workout = workout
            let set = WorkoutSet.create(context: context)
            set.isCompleted = true
            set.workoutExercise = entry
            workouts.append(workout)
        }
        try context.save()

        let search = ExerciseCatalogSearch()
        search.refresh(exercises: library, store: store, muscleGroup: nil, equipment: nil)
        XCTAssertTrue(try XCTUnwrap(search.candidates).recent.isEmpty)
        let initialRevision = search.candidates?.revision
        // Match the lists' next-turn read: objectWillChange itself still sees
        // the old property value. No disposable debounce owns this queued work.
        let observation = store.objectWillChange.sink { _ in
            DispatchQueue.main.async {
                search.refresh(exercises: library, store: store, muscleGroup: nil, equipment: nil)
            }
        }

        func expectRecent(_ expected: [Exercise], mutation: () throws -> Void) rethrows {
            let updated = expectation(description: "Catalog recents updated after history publication")
            let subscription = search.$candidates
                .first { $0?.recent.map(\.uuid) == expected.map(\.uuid) }
                .sink { _ in updated.fulfill() }
            try mutation()
            wait(for: [updated], timeout: 3)
            withExtendedLifetime(subscription) {}
        }

        expectRecent([zulu, alpha, middle]) { store.observeWorkoutHistory(in: context) }
        let candidates = AddExerciseCatalog(exercises: library, store: store)
            .candidates(muscleGroup: nil, equipment: nil)
        XCTAssertEqual(candidates.recent.map(\.uuid), [zulu.uuid, alpha.uuid, middle.uuid])
        XCTAssertEqual(candidates.recent.count, 3, "Unperformed exercises must not appear in Recent.")
        XCTAssertNotEqual(search.candidates?.revision, initialRevision)
        let publishedRevision = search.candidates?.revision

        try expectRecent([alpha, middle, zulu]) {
            workouts[2].start = Date(timeIntervalSince1970: 50)
            try context.save()
        }
        XCTAssertNotEqual(search.candidates?.revision, publishedRevision)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testCatalogSearchReusesSnapshotsAndCancelsSupersededQueries() async throws {
        let curl = exercise("Bicep Curl")
        let squat = exercise("Squat")
        let store = try store([])
        let search = ExerciseCatalogSearch()
        search.refresh(exercises: [squat, curl], store: store, muscleGroup: nil, equipment: nil)
        let revision = search.candidates?.revision
        search.refresh(exercises: [squat, curl], store: store, muscleGroup: nil, equipment: nil)
        XCTAssertEqual(search.candidates?.revision, revision)

        let cancelled = Task { await search.search("squat") }
        cancelled.cancel()
        await cancelled.value
        XCTAssertTrue(search.searchResult.exercises.isEmpty)

        await search.search("curl")
        XCTAssertEqual(search.listing(for: "curl", showingAll: true).exercises, [curl])
        // Clearing the field exposes the cached browse list without another task.
        XCTAssertEqual(search.listing(for: "", showingAll: true).exercises, [curl, squat])

        let renamed = exercise("Arm Lift", id: curl.uuid)
        search.refresh(exercises: [squat, renamed], store: store, muscleGroup: nil, equipment: nil)
        XCTAssertNotEqual(search.candidates?.revision, revision)
        XCTAssertTrue(search.searchResult.exercises.isEmpty)
        XCTAssertEqual(search.listing(for: "", showingAll: true).exercises, [renamed, squat])
    }

    func testShortAndJoinedTokensMatchReferenceAtTierBoundaries() {
        let fixtures: [(id: String, title: String, aliases: [String], originalTitle: String?)] = [
            ("exact", "B", [], nil),
            ("start", "B Press", [], nil),
            ("contiguous", "Lift B", [], nil),
            ("alias", "Lift", ["B"], nil),
            ("prefix", "Barbell Row", [], nil),
            ("original", "Lift", [], "B Pull"),
            ("abbreviation", "Dumbbell Press", [], nil),
            ("typo", "Dumxbell", [], nil),
            ("joined", "Pull Up", [], nil),
            ("unicode", "Écarté", ["Жим"], nil),
            ("stable", "B Press", [], nil)
        ]
        let prepared = fixtures.map {
            Candidate(id: $0.id, title: $0.title, aliases: $0.aliases, originalTitle: $0.originalTitle)
        }
        let reference = fixtures.map {
            ExerciseSearchReference.Prepared(id: $0.id, title: $0.title, aliases: $0.aliases, originalTitle: $0.originalTitle)
        }
        for text in ["b", "ba", "db", "bb", "kb", "ohp", "rdl", "pullup", "pull u", "puul up", "é", "жи", "жми", "b press"] {
            XCTAssertEqual(ids(prepared, query: text), ExerciseSearchReference.ranked(reference, matching: .init(text)).map(\.id), text)
            for (candidate, original) in zip(prepared, reference) {
                XCTAssertEqual(ExerciseSearch.tier(for: candidate, matching: .init(text))?.rawValue,
                               ExerciseSearchReference.tier(for: original, matching: .init(text))?.rawValue,
                               "\(candidate.id): \(text)")
            }
        }
    }

    func testBundledCatalogRankingMatchesFrozenReferenceAcross360Queries() throws {
        let catalog = try bundledCatalog()
        XCTAssertGreaterThan(catalog.count, 5_000)
        let prepared = catalog.map {
            ExerciseSearch.Prepared(id: $0.uuid, title: $0.title, aliases: $0.alias, originalTitle: $0.originalTitle)
        }
        let reference = catalog.map {
            ExerciseSearchReference.Prepared(id: $0.uuid, title: $0.title, aliases: $0.alias, originalTitle: $0.originalTitle)
        }
        let dates = Dictionary(uniqueKeysWithValues: catalog.prefix(64).enumerated().map {
            // Equal dates exercise the token-count, alphabetical and input-order ties too.
            ($0.element.uuid, Date(timeIntervalSince1970: Double($0.offset % 4)))
        })
        var queries: [String] = []
        var seen: Set<String> = []
        func include(_ text: String) {
            if seen.insert(text).inserted { queries.append(text) }
        }
        for letter in "abcdefghijklmnopqrstuvwxyz" { include(String(letter)) }
        for text in [
            "ba", "be", "bi", "ca", "cu", "de", "dr", "fl", "le", "pu", "ro", "sq",
            "bench", "deadlift", "curl", "press", "row", "squat", "fly", "cable", "dumbbell", "barbell",
            "pull up", "pull-ups", "biceps curl", "romanian", "db", "bb", "kb", "ohp", "rdl",
            "barbell bench press", "Barbell Bench Press", "bench press barbell", "bench cable",
            "incline dumbbell press", "standing cable fly", "curl biceps dumbbell", "romanian deadlift",
            "close grip bench press", "seated cable row", "single arm dumbbell row", "weighted pull up",
            "pullup", "pullups", "pull u", "puul up", "bicep curl", "db curl", "overhead press",
            "front squat", "leg curl", "leg extension", "lying leg raise", "reverse fly", "machine chest press",
            "benhc", "dedlift", "squt", "curll", "bicpe curl", "dumbell", "cabel fly",
            "bench b", "b bench", "b c", "é", " :()/-,.' ", ""
        ] { include(text) }
        let renamed = catalog.filter { $0.title != $0.originalTitle }
        XCTAssertFalse(renamed.isEmpty, "Parity must exercise old titles from the real catalog.")
        for exercise in renamed.prefix(32) {
            include(exercise.originalTitle)
            include(exercise.title)
        }
        let aliases = Array(Set(catalog.flatMap(\.alias))).sorted()
        XCTAssertFalse(aliases.isEmpty, "Parity must exercise real catalog aliases.")
        for alias in aliases.prefix(48) { include(alias) }
        // Fill the remaining slots with real multi-word titles, old titles and
        // aliases, instead of artificial pairs that cannot occur in this library.
        for exercise in catalog {
            for text in [exercise.title, exercise.originalTitle] + exercise.alias {
                if queries.count < 360 { include(text) }
            }
            if queries.count == 360 { break }
        }
        XCTAssertEqual(queries.count, 360)
        // The frozen reference takes about 0.8 s per query, so the suite checks every 4th query
        // (all one-letter queries included) and LIGHT_FULL_PARITY=1 checks all 360.
        let full = ProcessInfo.processInfo.environment["LIGHT_FULL_PARITY"] == "1"
        let checked = full ? queries : queries.enumerated().filter { $0.offset % 4 == 0 || $0.element.count == 1 }.map(\.element)
        for text in checked {
            let expected = ExerciseSearchReference.ranked(reference, matching: .init(text), lastPerformedDates: dates).map(\.id)
            let actual = ExerciseSearch.ranked(prepared, matching: .init(text), lastPerformedDates: dates).map(\.id)
            XCTAssertEqual(actual, expected, "Ranking/order changed for \"\(text)\".")
        }
        // The standalone runner disables XCTest activities, so attachments would error; log instead.
        print("Bundled catalog ranking parity: compared \(checked.count) of \(queries.count) queries id-for-id against the frozen SR ranker.")
    }

    func testPreparedBundledCatalogSearchPerformance() throws {
        let catalog = try bundledCatalog()
        XCTAssertGreaterThan(catalog.count, 5_000, "Measure the real bundled library, not a small fixture.")
        let prepared = catalog.map {
            ExerciseSearch.Prepared(id: $0.uuid, title: $0.title, aliases: $0.alias, originalTitle: $0.originalTitle)
        }
        let dates = Dictionary(uniqueKeysWithValues: catalog.prefix(32).enumerated().map {
            ($0.element.uuid, Date(timeIntervalSince1970: Double($0.offset)))
        })
        // The Debug test target is -Onone; WorkoutDataKit uses -O. Keep the
        // existing budgets: 250 ms Debug and 50 ms in optimized test runs.
        #if DEBUG
        let budget: TimeInterval = 0.250
        #else
        let budget: TimeInterval = 0.050
        #endif
        var report: [String] = []
        for text in ["deadlif", "bench", "cable fly", "b"] {
            let expected = ExerciseSearch.ranked(prepared, matching: .init(text), lastPerformedDates: dates).map(\.id)
            XCTAssertFalse(expected.isEmpty, text)
            var samples: [TimeInterval] = []
            // Warm once above, then use a median so a scheduling pause or one
            // background simulator task does not fail a healthy implementation.
            for _ in 0..<7 {
                let start = DispatchTime.now().uptimeNanoseconds
                let matches = ExerciseSearch.ranked(prepared, matching: .init(text), lastPerformedDates: dates)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                samples.append(elapsed)
                XCTAssertEqual(matches.map(\.id), expected, text)
            }
            let median = samples.sorted()[samples.count / 2]
            report.append("\(text): median \(median * 1_000) ms; budget \(budget * 1_000) ms")
            XCTAssertLessThan(median, budget, "Prepared search for \"\(text)\" exceeded its warm-query budget.")
        }
        print("Prepared bundled catalog search timings:\n" + report.joined(separator: "\n"))
    }

    func testBundledCatalogTrackingInferenceMatchesEveryOriginalTitle() throws {
        let catalog = try bundledCatalog()
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertTrue(catalog.contains { $0.title != $0.originalTitle })
        for exercise in catalog where !exercise.isCustom {
            XCTAssertEqual(
                Iron.SetTrackingType.defaultType(name: exercise.title, equipment: exercise.equipment, category: exercise.muscleGroup),
                SetTrackingType.defaultType(name: exercise.originalTitle, equipment: exercise.equipment, category: exercise.muscleGroup),
                "\(exercise.uuid): \(exercise.originalTitle) → \(exercise.title)"
            )
        }
    }

    func testEveryRenamedBuiltInKeepsItsOriginalAliasAndExactSearchTier() throws {
        let catalog = try bundledCatalog()
        for exercise in catalog where exercise.title != exercise.originalTitle {
            XCTAssertTrue(exercise.alias.contains(exercise.originalTitle), exercise.uuid.uuidString)
            let prepared = ExerciseSearch.Prepared(id: exercise.uuid, title: exercise.title,
                                                   aliases: exercise.alias, originalTitle: exercise.originalTitle)
            XCTAssertEqual(ExerciseSearch.tier(for: prepared, matching: .init(exercise.originalTitle)),
                           .exactTitle, exercise.uuid.uuidString)
            XCTAssertEqual(ExerciseSearch.tier(for: prepared, matching: .init(exercise.title)),
                           .exactTitle, exercise.uuid.uuidString)
        }
    }

    func testTrackingInferenceKeepsHoldAndPlankTokensBeforeEquipmentSuffixes() {
        for (original, shown, expected) in [
            ("Barbell Hold", "Hold: Barbell", Iron.SetTrackingType.duration),
            ("Dumbbell Plank", "Plank: Dumbbell", .duration),
            ("Cable Weighted Hold", "Weighted Hold: Cable", .weightDuration)
        ] {
            XCTAssertEqual(SetTrackingType.defaultType(name: original, equipment: []), expected)
            XCTAssertEqual(SetTrackingType.defaultType(name: shown, equipment: []), expected)
        }
        // These existing source names must not acquire a different default as a
        // side effect of recognizing the new equipment separator.
        XCTAssertEqual(Iron.SetTrackingType.defaultType(name: "Chest Out Hands Behind (hold)", equipment: ["body weight"]),
                       .bodyweightReps)
        XCTAssertEqual(Iron.SetTrackingType.defaultType(name: "Suspension Single Leg Split Squat (self Assisted)",
                                                  equipment: ["suspension trainer"]), .weightReps)
    }

    func testBundledWatchCatalogNamesMatchPhoneByID() throws {
        let phone = try bundledCatalog()
        let watch = try bundledWatchCatalog()
        let byID = Dictionary(uniqueKeysWithValues: phone.map { ($0.uuid, $0) })
        XCTAssertEqual(watch.count, phone.count)
        XCTAssertEqual(Set(watch.map(\.id)), Set(phone.map(\.uuid)))
        for pick in watch {
            let exercise = try XCTUnwrap(byID[pick.id], pick.id.uuidString)
            XCTAssertEqual(pick.name, exercise.title, pick.id.uuidString)
            if exercise.title != exercise.originalTitle {
                XCTAssertTrue(pick.aliases?.contains(exercise.originalTitle) == true, pick.id.uuidString)
            }
        }
    }

    func testWatchExercisePickAliasesDecodeWhenMissingAndRoundTripWhenPresent() throws {
        let id = UUID()
        let legacy = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "name": "Barbell Bench Press"])
        let oldPick = try JSONDecoder().decode(WatchExercisePick.self, from: legacy)
        XCTAssertEqual(oldPick.id, id)
        XCTAssertNil(oldPick.aliases)
        let pick = WatchExercisePick(id: id, name: "Bench Press: Barbell", muscle: nil, imageURL: nil,
                                     aliases: ["Barbell Bench Press", "Bench Press"])
        XCTAssertEqual(try JSONDecoder().decode(WatchExercisePick.self, from: JSONEncoder().encode(pick)), pick)
    }

    func testBundledWatchDemoExerciseIDsRemainAvailable() throws {
        let watch = try bundledWatchCatalog()
        for (id, originalTitle) in [
            ("C0D3C3CD-9F1F-4A89-B845-DAB5923B22A7", "Barbell Bench Press"),
            ("13664A80-F9E2-5E0E-A2D5-F5EEEB1769EF", "Dumbbell Bent Over Row")
        ] {
            let pick = try XCTUnwrap(watch.first { $0.id.uuidString == id }, id)
            XCTAssertTrue(pick.name == originalTitle || pick.aliases?.contains(originalTitle) == true, id)
        }
    }

    private func bundledCatalog() throws -> [Exercise] {
        let suite = "ExerciseSearchTests.Bundled.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return ExerciseStore(customExercisesURL: nil, userDefaults: defaults).builtInExercises
    }

    private func bundledWatchCatalog() throws -> [WatchExercisePick] {
        // This JSON belongs to the Watch target. Prefer its embedded bundle, then
        // read that same checked-in bundle resource when testing the phone alone.
        let watchRoot = Bundle.main.bundleURL.appendingPathComponent("Watch", isDirectory: true)
        let bundledFiles = FileManager.default.enumerator(at: watchRoot, includingPropertiesForKeys: nil)
        let embeddedURL = bundledFiles?.compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "WatchExerciseCatalog.json" }
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WatchIron Extension/WatchExerciseCatalog.json")
        let data = try Data(contentsOf: embeddedURL ?? sourceURL)
        return try JSONDecoder().decode([WatchExercisePick].self, from: data)
    }

    private func exercise(_ title: String, id: UUID = UUID(), aliases: [String] = [], muscle: String = "biceps",
                          equipment: [String] = [], image: String? = "fixture.gif", everkineticID: Int = 1,
                          originalTitle: String? = nil) -> Exercise {
        Exercise(uuid: id, everkineticId: everkineticID, title: title, alias: aliases, description: nil,
                 primaryMuscle: [muscle], secondaryMuscle: [], equipment: equipment, steps: [], tips: [],
                 references: [], pdfPaths: [], imageFilename: image, originalTitle: originalTitle)
    }

    /// A tiny isolated catalog, with no bundled resources or persistence history required.
    private func store(_ exercises: [Exercise], customExercises: [Exercise] = []) throws -> ExerciseStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("exercises.json")
        try JSONEncoder().encode(exercises).write(to: url)
        let customURL = folder.appendingPathComponent("custom.json")
        try JSONEncoder().encode(customExercises).write(to: customURL)
        let suite = "ExerciseSearchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return ExerciseStore(builtInExercisesURL: url, customExercisesURL: customURL, userDefaults: defaults)
    }
}
