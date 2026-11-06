import XCTest
@testable import Iron

final class LoggerAssistTests: XCTestCase {
    func testBarbellWithoutSavedSetupShowsPlateHint() {
        XCTAssertEqual(LoggerAssist.plateHintPresentation(
            isBarbell: true, equipment: ["barbell"], hasSavedSetup: false, showPlateCalculator: true
        ), .hint)
    }

    func testMachineWithoutSavedSetupShowsPlateSetupChip() {
        let equipment = [
            "machine", "chest machine", "machine: bench press", "machine: chest", "machine: butterfly",
            "smith machine", "lever", "lever machine", "leverage", "leverage machine",
            "sled", "sled machine", "t-bar machine", "plate-loaded", "plate loaded machine",
            " Smith Machine "
        ]
        for item in equipment {
            XCTAssertEqual(LoggerAssist.plateHintPresentation(
                isBarbell: false, equipment: [item], hasSavedSetup: false, showPlateCalculator: true
            ), .setUpChip, item)
        }
    }

    func testSavedMachineSetupShowsPlateHint() {
        let savedSetups = ["leg-press": PlateLoadout(mode: .machine(35), unit: .pound)]
        XCTAssertEqual(LoggerAssist.plateHintPresentation(
            isBarbell: false, equipment: ["sled machine"], hasSavedSetup: savedSetups["leg-press"] != nil,
            showPlateCalculator: true
        ), .hint)
    }

    func testSavedSetupInEveryModeShowsHintForOtherEquipment() {
        let savedSetups: [String: PlateLoadout] = [
            "bar": .standard(for: .pound),
            "no-bar": .init(mode: .noBar, loadedSides: .one, unit: .pound),
            "machine": .init(mode: .machine(0), unit: .pound)
        ]
        for key in savedSetups.keys {
            for equipment in [["dumbbell"], ["cable"], []] {
                XCTAssertEqual(LoggerAssist.plateHintPresentation(
                    isBarbell: false, equipment: equipment, hasSavedSetup: savedSetups[key] != nil,
                    showPlateCalculator: true
                ), .hint, key)
            }
        }
    }

    func testNonPlateEquipmentWithoutSavedSetupShowsNothing() {
        let equipment = [
            ["dumbbell"], ["cable"], ["body weight"], [], ["pin-stack machine"],
            ["machine", "cable"], ["machine", "pin-loaded"], ["machine", "weight stack"],
            ["selectorized machine"], ["elliptical machine"], ["skierg machine"], ["stepmill machine"]
        ]
        for items in equipment {
            XCTAssertEqual(LoggerAssist.plateHintPresentation(
                isBarbell: false, equipment: items, hasSavedSetup: false, showPlateCalculator: true
            ), .none, items.joined(separator: ", "))
        }
    }

    func testExplicitPlateLoadedEquipmentCanShowChipAlongsideCable() {
        XCTAssertEqual(LoggerAssist.plateHintPresentation(
            isBarbell: false, equipment: ["cable", "plate-loaded machine"], hasSavedSetup: false,
            showPlateCalculator: true
        ), .setUpChip)
    }

    func testPlateCalculatorOffHidesEveryPlateHintAndSetupChip() {
        for isBarbell in [false, true] {
            for hasSavedSetup in [false, true] {
                for equipment in [["barbell"], ["machine"], ["dumbbell"], ["cable"], []] {
                    XCTAssertEqual(LoggerAssist.plateHintPresentation(
                        isBarbell: isBarbell, equipment: equipment, hasSavedSetup: hasSavedSetup,
                        showPlateCalculator: false
                    ), .none)
                }
            }
        }
    }

    func testDecimalInputInEnglishLocale() {
        let locale = Locale(identifier: "en_US")
        let cases = [
            ("1,005", "1005"), ("1005", "1005"), ("102.5", "102.5"), (".5", "0.5"),
            ("1,005.25", "1005.25"), ("10,25", "1025")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(WeightUnit.sanitizedDecimalInput(
                input, maximumFractionDigits: 3,
                decimalSeparator: locale.decimalSeparator!, groupingSeparator: locale.groupingSeparator!
            ), expected, input)
        }
    }

    func testDecimalInputInGermanLocale() {
        let locale = Locale(identifier: "de_DE")
        let cases = [
            ("1.005", "1005"), ("2,5", "2,5"), ("2.5", "2,5"), (".5", "0,5"),
            ("1.005,25", "1005,25"), ("1.005.250", "1005250")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(WeightUnit.sanitizedDecimalInput(
                input, maximumFractionDigits: 3,
                decimalSeparator: locale.decimalSeparator!, groupingSeparator: locale.groupingSeparator!
            ), expected, input)
        }
    }

    func testDecimalInputCapsFractionDigits() {
        let cases = [
            ("102.56789", ".", ",", 3, "102.567"),
            ("2,56789", ",", ".", 2, "2,56"),
            ("2.56789", ",", ".", 2, "2,56"),
            ("102.5", ".", ",", 0, "102")
        ]
        for (input, decimal, grouping, maximum, expected) in cases {
            XCTAssertEqual(WeightUnit.sanitizedDecimalInput(
                input, maximumFractionDigits: maximum,
                decimalSeparator: decimal, groupingSeparator: grouping
            ), expected, input)
        }
    }

    func testDecimalInputDropsOtherCharactersAndExtraSeparators() {
        XCTAssertEqual(WeightUnit.sanitizedDecimalInput(
            " \n1,005.2.5 lb\t", maximumFractionDigits: 3,
            decimalSeparator: ".", groupingSeparator: ","
        ), "1005.25")
    }

    func testEntryNumberFormatterKeepsThousandsUngrouped() {
        for identifier in ["en_US", "de_DE"] {
            let formatter = WeightUnit.imperial.numberFormatter
            formatter.locale = Locale(identifier: identifier)
            XCTAssertFalse(formatter.usesGroupingSeparator)
            XCTAssertEqual(formatter.string(from: NSNumber(value: 1005)), "1005")
        }
    }

    private typealias Values = SetValuePrefill.Values
    private typealias Input = SetValuePrefill.SetInput

    private func filled(_ current: [Input], previous: [Input] = [], type: SetTrackingType = .weightReps) -> [Values] {
        SetValuePrefill.resolve(currentSets: current, previousSets: previous, trackingType: type)
    }

    func testSetTwoCopiesSetOneEvenWhenItIsNotCompleted() {
        let current: [Input] = [
            .init(values: .init(weight: 140, repetitions: 5), userEnteredFields: [.weight, .reps]), .init()
        ]
        XCTAssertEqual(filled(current)[1], .init(weight: 140, repetitions: 5))
        XCTAssertEqual(current[1].values, Values()) // The rule is pure.
    }

    func testSetThreeCopiesEditedSetTwoInsteadOfCompletedSetOne() {
        XCTAssertEqual(filled([
            .init(values: .init(weight: 140, repetitions: 5), isCompleted: true),
            .init(values: .init(weight: 135, repetitions: 7), userEnteredFields: [.weight, .reps]), .init()
        ])[2], .init(weight: 135, repetitions: 7))
    }

    func testFirstSetCopiesLastSessionsFirstWorkingSetSkippingWarmups() {
        let previous: [Input] = [
            .init(values: .init(weight: 40, repetitions: 10), isWarmup: true),
            .init(values: .init(weight: 140, repetitions: 5)),
            .init(values: .init(weight: 135, repetitions: 8))
        ]
        XCTAssertEqual(filled([.init(), .init(), .init()], previous: previous),
                       Array(repeating: Values(weight: 140, repetitions: 5), count: 3))
    }

    func testFirstWarmupCopiesLastSessionsFirstWarmup() {
        XCTAssertEqual(filled([.init(isWarmup: true)], previous: [
            .init(values: .init(weight: 140, repetitions: 5)),
            .init(values: .init(weight: 40, repetitions: 10), isWarmup: true),
            .init(values: .init(weight: 60, repetitions: 8), isWarmup: true)
        ]).first, .init(weight: 40, repetitions: 10))
    }

    func testNeverDoneStaysEmptyForEveryTrackingType() {
        for type in SetTrackingType.allCases {
            XCTAssertEqual(filled([.init(), .init(), .init()], type: type), [Values(), Values(), Values()], type.rawValue)
        }
    }

    func testTypedWeightIsKeptWhileRepetitionsFill() {
        XCTAssertEqual(filled([
            .init(values: .init(weight: 145), userEnteredFields: [.weight])
        ], previous: [.init(values: .init(weight: 140, repetitions: 5))]).first,
                       .init(weight: 145, repetitions: 5))
    }

    func testSavedWorkoutTargetsAreKeptIndependently() {
        XCTAssertEqual(filled([
            .init(targets: .init(repetitions: 5)),
            .init(targets: .init(weight: 150, repetitions: 8)), .init()
        ], previous: [.init(values: .init(weight: 140, repetitions: 10))]), [
            .init(weight: 140, repetitions: 5), .init(weight: 150, repetitions: 8), .init(weight: 150, repetitions: 8)
        ])
    }

    func testTypedValueBeatsSavedTargetIncludingExplicitZeroAndEmpty() {
        XCTAssertEqual(filled([
            .init(values: .init(weight: 0), userEnteredFields: [.weight, .reps], targets: .init(weight: 140, repetitions: 5))
        ]).first, .init(weight: 0))
    }

    func testChangingSetOneUpdatesAutomaticFollowersButNotTypedFields() {
        var current: [Input] = [
            .init(values: .init(weight: 140, repetitions: 5), userEnteredFields: [.weight, .reps]),
            .init(), .init(values: .init(weight: 130), userEnteredFields: [.weight]), .init()
        ]
        XCTAssertEqual(filled(current)[1], .init(weight: 140, repetitions: 5))
        current[0].values = .init(weight: 150, repetitions: 6)
        XCTAssertEqual(filled(current), [
            .init(weight: 150, repetitions: 6), .init(weight: 150, repetitions: 6),
            .init(weight: 130, repetitions: 6), .init(weight: 130, repetitions: 6)
        ])
    }

    func testCurrentWorkoutUsesImmediatePredecessorAcrossSetKinds() {
        XCTAssertEqual(filled([
            .init(values: .init(weight: 40, repetitions: 10), isCompleted: true, isWarmup: true), .init()
        ], previous: [.init(values: .init(weight: 140, repetitions: 5))])[1], .init(weight: 40, repetitions: 10))
    }

    func testEmptyPredecessorIsNotSkippedForHistory() {
        XCTAssertEqual(filled([
            .init(values: .init(weight: 140, repetitions: 5), isCompleted: true),
            .init(userEnteredFields: [.weight, .reps]), .init()
        ], previous: [.init(values: .init(weight: 135, repetitions: 8))])[2], Values())
    }

    func testDurationAndDistanceFillAndRespectIndependentEntries() {
        let previous: [Input] = [.init(values: .init(weight: 20, duration: 90, distance: 500))]
        XCTAssertEqual(filled([
            .init(values: .init(distance: 750), userEnteredFields: [.distance]), .init()
        ], previous: previous, type: .distanceDuration), [
            .init(duration: 90, distance: 750), .init(duration: 90, distance: 750)
        ])
        XCTAssertEqual(filled([.init(targets: .init(duration: 60)), .init()], previous: previous, type: .weightDuration),
                       [.init(weight: 20, duration: 60), .init(weight: 20, duration: 60)])
        XCTAssertEqual(filled([.init(), .init()], previous: previous, type: .weightDistance),
                       [.init(weight: 20, distance: 500), .init(weight: 20, distance: 500)])
    }

    func testCompletedSetsKeepExactlyTheirLoggedValues() {
        let values = Values(weight: 0, repetitions: 3, duration: 30, distance: 100)
        XCTAssertEqual(filled([.init(values: values, targets: .init(weight: 140, repetitions: 5), isCompleted: true)],
                              previous: [.init(values: .init(weight: 145, repetitions: 8))]), [values])
    }

    func testMissingMatchingHistoryKindStaysEmpty() {
        XCTAssertEqual(filled([.init(isWarmup: true)], previous: [.init(values: .init(weight: 140, repetitions: 5))]), [Values()])
    }

    func testLoggerOwnershipAndFrozenTargetsSurvivePreferenceTransport() throws {
        let id = UUID().uuidString
        var preferences = SetTrackingPreferences()
        preferences.loggerFields = [id: .init(fields: [.weight], targets: .init(repetitions: 5, duration: 60), updatedAt: 10)]
        let received = try XCTUnwrap(SetTrackingPreferences(payload: preferences.dictionaryRepresentation))
        XCTAssertEqual(received.loggerFields?[id]?.fields, [.weight])
        XCTAssertEqual(received.loggerFields?[id]?.targets, .init(repetitions: 5, duration: 60))
    }

    func testConcurrentDeviceEditsAndDelayedInitializationCannotUntypeFields() {
        let id = UUID().uuidString
        var phone = SetTrackingPreferences()
        phone.loggerFields = [id: .init(fields: [.weight], updatedAt: 10)]
        var watch = SetTrackingPreferences()
        watch.loggerFields = [id: .init(fields: [.reps], updatedAt: 20)]
        var delayed = SetTrackingPreferences()
        delayed.loggerFields = [id: .init(fields: [], updatedAt: 30)]
        let merged = phone.merging(watch).merging(delayed)
        XCTAssertEqual(merged.loggerFields?[id]?.fields, [.weight, .reps])
        XCTAssertTrue(merged.hasSameContent(as: delayed.merging(watch).merging(phone)))
    }

    func testNewWorkoutProvenanceReplacesOldSessionInEitherMergeOrder() {
        let oldSet = UUID().uuidString, newSet = UUID().uuidString
        var old = SetTrackingPreferences()
        old.loggerWorkoutID = UUID()
        old.loggerWorkoutStartedAt = 10
        old.loggerFields = [oldSet: .init(fields: [.weight], updatedAt: 11)]
        var current = SetTrackingPreferences()
        current.loggerWorkoutID = UUID()
        current.loggerWorkoutStartedAt = 20
        current.loggerFields = [newSet: .init(fields: [.reps], updatedAt: 21)]
        for merged in [old.merging(current), current.merging(old)] {
            XCTAssertEqual(merged.loggerWorkoutID, current.loggerWorkoutID)
            XCTAssertNil(merged.loggerFields?[oldSet])
            XCTAssertEqual(merged.loggerFields?[newSet]?.fields, [.reps])
        }
    }

    func testHitEveryTargetUsesRangeMinimumForNextWeight() {
        let sets: [LoggerAssist.PreviousSet] = [
            .init(weight: 200, repetitions: 8, minTarget: 5, maxTarget: 8),
            .init(weight: 200, repetitions: 9, minTarget: 5, maxTarget: 8)
        ]
        XCTAssertEqual(LoggerAssist.suggestion(previousWorkingSets: sets, workingSetIndex: 1, increment: 5),
                       .init(weight: 205, repetitions: 5))
    }

    func testSingleTargetKeepsPreviousRepetitions() {
        let sets: [LoggerAssist.PreviousSet] = [.init(weight: 200, repetitions: 6, minTarget: 5, maxTarget: 5)]
        XCTAssertEqual(LoggerAssist.suggestion(previousWorkingSets: sets, workingSetIndex: 0, increment: 5),
                       .init(weight: 205, repetitions: 6))
    }

    func testAnyMissedTargetSuppressesSuggestion() {
        let sets: [LoggerAssist.PreviousSet] = [
            .init(weight: 200, repetitions: 8, minTarget: 5, maxTarget: 8),
            .init(weight: 200, repetitions: 7, minTarget: 5, maxTarget: 8)
        ]
        XCTAssertNil(LoggerAssist.suggestion(previousWorkingSets: sets, workingSetIndex: 0, increment: 5))
    }

    func testNoTargetsWithDropOffSuppressesSuggestion() {
        let sets: [LoggerAssist.PreviousSet] = [
            .init(weight: 200, repetitions: 5), .init(weight: 200, repetitions: 4)
        ]
        XCTAssertNil(LoggerAssist.suggestion(previousWorkingSets: sets, workingSetIndex: 0, increment: 5))
    }

    func testNoTargetsWithoutDropOffUsesSameNumberedWorkingSet() {
        let sets: [LoggerAssist.PreviousSet] = [
            .init(weight: 195, repetitions: 5), .init(weight: 200, repetitions: 6)
        ]
        XCTAssertEqual(LoggerAssist.suggestion(previousWorkingSets: sets, workingSetIndex: 1, increment: 5),
                       .init(weight: 205, repetitions: 6))
        XCTAssertNil(LoggerAssist.suggestion(previousWorkingSets: sets, workingSetIndex: 2, increment: 5))
    }

    func testBodyweightAddsOneRep() {
        let sets: [LoggerAssist.PreviousSet] = [
            .init(weight: 0, repetitions: 10), .init(weight: 0, repetitions: 10)
        ]
        XCTAssertEqual(LoggerAssist.suggestion(previousWorkingSets: sets, workingSetIndex: 0, increment: 5),
                       .init(weight: 0, repetitions: 11))
    }

    func testBarbell225PoundsUsesStandardEnabledPlates() {
        let sets = LoggerAssist.warmupSets(workingWeight: 225, increment: 5,
                                          barbell: .standard(for: .pound))
        XCTAssertEqual(sets.map(\.weight), [45, 112.5, 157.5, 190])
        XCTAssertEqual(sets.map(\.repetitions), [10, 5, 3, 2])
    }

    func testDumbbell60PoundsRoundsDownToIncrement() {
        let sets = LoggerAssist.warmupSets(workingWeight: 60, increment: 5)
        XCTAssertEqual(sets.map(\.weight), [30, 40, 50])
        XCTAssertEqual(sets.map(\.repetitions), [8, 4, 2])
    }

    func testUnitConversionRoundoffDoesNotLoseAnIncrement() {
        XCTAssertEqual(LoggerAssist.warmupSets(workingWeight: Double(60).nextDown, increment: 5).map(\.weight),
                       [30, 40, 50])
    }

    func testWeightWithinOnePlatePairOfBarDropsBarOnly() {
        XCTAssertTrue(LoggerAssist.warmupSets(workingWeight: 47.5, increment: 5,
                                              barbell: .standard(for: .pound)).isEmpty)
        XCTAssertTrue(LoggerAssist.warmupSets(workingWeight: 45, increment: 5,
                                              barbell: .standard(for: .pound)).isEmpty)
    }

    func testKilogramBarbellAndDumbbell() {
        let barbell = LoggerAssist.warmupSets(workingWeight: 100, increment: 2.5,
                                             barbell: .standard(for: .kilogram))
        XCTAssertEqual(barbell.map(\.weight), [20, 50, 70, 85])
        XCTAssertEqual(barbell.map(\.repetitions), [10, 5, 3, 2])
        XCTAssertEqual(LoggerAssist.warmupSets(workingWeight: 24, increment: 2.5).map(\.weight),
                       [10, 15, 20])
    }

    func testLimitedInventoryDropsDuplicateLoads() {
        var inventory = PlateInventory()
        for weight in PlateInventory.availablePlates(for: .pound) {
            inventory.setEnabled(weight == 45, weight: weight, unit: .pound)
        }
        let sets = LoggerAssist.warmupSets(workingWeight: 225, increment: 5,
                                          barbell: .standard(for: .pound), inventory: inventory)
        XCTAssertEqual(sets.map(\.weight), [45, 135])
        XCTAssertEqual(sets.map(\.repetitions), [10, 3])
    }
}
