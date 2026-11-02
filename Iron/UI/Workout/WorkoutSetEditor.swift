//
//  WorkoutSetEditor.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 29.06.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

private enum KeyboardType {
    case weight
    case repetitions
    case none
}

struct WorkoutSetEditor : View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var exerciseStore: ExerciseStore
    
    @ObservedObject var workoutSet: WorkoutSet
    var onDone: () -> Void = {}
    
    @State private var showHelpAlert = false
    
    @State private var activeSheet: SheetType?
    @State private var showKeyboard: KeyboardType = .none
    @State private var alwaysShowDecimalSeparator = false
    @State private var minimumFractionDigits = 0
    
    // used to immediatelly update the weight & rep texts so the keyboard feels more smooth
    @ObservedObject private var refresher = Refresher()

    private enum SheetType: String, Identifiable {
        case details
        case plates
        case warmups

        var id: String { rawValue }
    }
    
    private var workoutSetWeight: Binding<Double?> {
        Binding(
            get: {
                WeightUnit.convert(weight: self.workoutSet.weightValue, from: .metric, to: self.settingsStore.weightUnit)
            },
            set: { newValue in
                self.workoutSet.weightValue = max(min(WeightUnit.convert(weight: newValue ?? 0, from: self.settingsStore.weightUnit, to: .metric), WorkoutSet.MAX_WEIGHT), 0)
                self.refresher.refresh()
            }
        )
    }
    
    private var workoutSetRepetitions: Binding<Double?> {
        Binding(
            get: {
                Double(self.workoutSet.repetitionsValue)
            },
            set: { newValue in
                self.workoutSet.repetitionsValue = Int16(max(min(newValue ?? 0, Double(WorkoutSet.MAX_REPETITIONS)), 0))
                self.refresher.refresh()
            }
        )
    }

    private var weightNumberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.allowsFloats = true
        formatter.maximumFractionDigits = settingsStore.weightUnit.maximumFractionDigits
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.alwaysShowsDecimalSeparator = alwaysShowDecimalSeparator
        return formatter
    }
    
    private func textButton(label: Text, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous)
                    .fill(color)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var tagButton: some View {
        Button(action: {
            self.activeSheet = .details
        }) {
            HStack(spacing: 0) {
                Image(systemName: "tag")
                    .frame(width: IronTheme.controlHeight, height: IronTheme.controlHeight)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set options")
    }
    
    private var doneButton: some View {
        textButton(label: Text(workoutSet.isCompleted ? "Ok" : "Complete Set").foregroundColor(IronTheme.onAccent), color: IronTheme.accent, action: {
            self.onDone()
        })
    }
    
    private var nextButton: some View {
        textButton(label: Text("Next").foregroundColor(IronTheme.onAccent), color: IronTheme.accent, action: { self.showKeyboard = .repetitions })
    }
        
    private var hideKeyboardButton: some View {
        Button(action: {
            withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                self.showKeyboard = .none
            }
        }) {
            HStack {
                Spacer()
                ZStack {
                    Text("More") // placeholder for button size
                        .foregroundColor(.clear)
                    HStack {
                        Image(systemName: "keyboard")
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.compact.down")
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .frame(minHeight: IronTheme.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous)
                    .fill(IronTheme.field)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide keyboard")
    }
    
    private var weightStepSize: Double {
        // TODO: let the user configure this for barbell, dumbell and others
        (workoutSet.workoutExercise?.exercise(in: exerciseStore.exercises)?.type == .barbell) ? settingsStore.weightUnit.barbellIncrement : 1
    }
    
    private var weightDragger: some View {
        WorkoutSetEditorValueField(
            value: workoutSetWeight,
            numberFormatter: weightNumberFormatter,
            unit: settingsStore.weightUnit.unit.symbol,
            stepSize: weightStepSize,
            minValue: 0,
            maxValue: WeightUnit.convert(weight: WorkoutSet.MAX_WEIGHT, from: .metric, to: settingsStore.weightUnit),
            showCursor: showKeyboard == .weight,
            onDragStep: { _ in
                self.alwaysShowDecimalSeparator = false
                self.minimumFractionDigits = self.settingsStore.weightUnit.defaultFractionDigits
            },
            onDragCompleted: {
                self.alwaysShowDecimalSeparator = false
                self.minimumFractionDigits = 0
            },
            onTextTapped: {
                if self.showKeyboard == .none {
                    withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                        self.showKeyboard = .weight
                    }
                } else {
                    self.showKeyboard = .weight
                }
            })
    }
    
    private var repetitionsDragger: some View {
        WorkoutSetEditorValueField(
            value: workoutSetRepetitions,
            unit: "reps",
            minValue: 0,
            maxValue: Double(WorkoutSet.MAX_REPETITIONS),
            showCursor: showKeyboard == .repetitions,
            onTextTapped: {
                if self.showKeyboard == .none {
                    withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                        self.showKeyboard = .repetitions
                    }
                } else {
                    self.showKeyboard = .repetitions
                }
        })
    }
    
    private var moreSheet: some View {
        NavigationStack {
            MoreView(workoutSet: workoutSet)
                .navigationTitle(workoutSet.displayTitle(weightUnit: settingsStore.weightUnit))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                        self.activeSheet = nil
                    }
                    }
                }
        }
    }

    @ViewBuilder private func sheet(for type: SheetType) -> some View {
        switch type {
        case .details:
            moreSheet
        case .plates:
            IronUtilitySheet(
                title: "Plate Calculator",
                subtitle: "",
                systemImage: "plusminus",
                showsDone: false,
                onClose: { activeSheet = nil }
            ) {
                PlateCalculatorView(
                    unit: settingsStore.weightUnit,
                    initialTarget: workoutSetWeight.wrappedValue ?? 0,
                    exerciseKey: workoutSet.workoutExercise?.exerciseUuid?.uuidString
                        ?? workoutSet.workoutExercise?.exercise(in: exerciseStore.exercises)?.title,
                    onClose: { activeSheet = nil },
                    onApply: { value in
                        workoutSetWeight.wrappedValue = value
                        activeSheet = nil
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        case .warmups:
            IronUtilitySheet(
                title: "Warm-Up Calculator",
                subtitle: "",
                systemImage: "flame",
                onClose: { activeSheet = nil }
            ) {
                WarmupCalculatorView(
                    unit: settingsStore.weightUnit,
                    workingWeight: workoutSetWeight.wrappedValue ?? 0,
                    exerciseKey: workoutSet.workoutExercise?.exerciseUuid?.uuidString
                        ?? workoutSet.workoutExercise?.exercise(in: exerciseStore.exercises)?.title,
                    onAdd: addWarmupSets
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func addWarmupSets(_ recommendations: [WarmupRecommendation]) {
        guard let exercise = workoutSet.workoutExercise,
              let context = workoutSet.managedObjectContext,
              exercise.workout?.isCurrentWorkout == true else { return }

        var insertionIndex = 0
        for recommendation in recommendations {
            let set = WorkoutSet.create(context: context)
            set.tagValue = .warmUp
            set.weightValue = WeightUnit.convert(weight: recommendation.weight, from: settingsStore.weightUnit, to: .metric)
            set.repetitionsValue = Int16(recommendation.repetitions)
            set.isCompleted = false
            exercise.insertIntoWorkoutSets(set, at: insertionIndex)
            insertionIndex += 1
        }
        context.saveOrCrash()
        activeSheet = nil
    }

    private var barbellTools: some View {
        editorFieldsLayout {
            Button(action: { activeSheet = .plates }) {
                Label("Plates", systemImage: "plusminus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
            }
            .buttonStyle(.bordered)

            Button(action: { activeSheet = .warmups }) {
                Label("Warm-up", systemImage: "flame.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
            }
            .buttonStyle(.bordered)
        }
    }
    
    private var keyboard: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                NumericKeyboard(
                    value: self.showKeyboard == .weight ? self.workoutSetWeight : self.workoutSetRepetitions,
                    alwaysShowDecimalSeparator: self.showKeyboard == .weight ? self.$alwaysShowDecimalSeparator : .constant(false),
                    minimumFractionDigits: self.showKeyboard == .weight ? self.$minimumFractionDigits : .constant(0),
                    maximumFractionDigits: self.showKeyboard == .weight ? self.settingsStore.weightUnit.maximumFractionDigits : 0
                )
                VStack(spacing: 0) {
                    NumericKeyboard.imageActionKeyboardButton(label: Image(systemName: "keyboard.chevron.compact.down"), width: geometry.size.width / 4) {
                        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                            self.showKeyboard = .none
                        }
                    }
                    
                    NumericKeyboard.imageActionKeyboardButton(label: Image(systemName: "questionmark"), width: geometry.size.width / 4) {
                        self.showHelpAlert = true
                    }
                    
                    NumericKeyboard.imageActionKeyboardButton(label: Image(systemName: "tag"), width: geometry.size.width / 4) {
                        self.activeSheet = .details
                    }
                    
                    Button(action: {
                        NumericKeyboard.playButtonSound()
                        if self.showKeyboard == .weight {
                            self.showKeyboard = .repetitions
                        } else if self.showKeyboard == .repetitions {
                            self.onDone()
                            self.showKeyboard = .weight
                        }
                    }) {
                        Image(systemName: self.showKeyboard == .weight ? "arrow.right" : "checkmark")
                            .padding()
                            .foregroundColor(IronTheme.onAccent)
                            .background(
                                RoundedRectangle(cornerRadius: IronTheme.compactCornerRadius, style: .continuous)
                                    .foregroundColor(Color.accentColor)
                        )
                            .frame(width: geometry.size.width / 4, height: geometry.size.height / 4)
                    }
                }
                .frame(width: geometry.size.width / 4)
            }
        }.frame(height: NumericKeyboard.HEIGHT)
    }
    
    private var editorFieldsLayout: AnyLayout {
        dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    var body: some View {
        VStack { /// no spacing to the keyboard
            VStack(spacing: 24) {
                editorFieldsLayout {
                    weightDragger
                    repetitionsDragger
                }
                
                if showKeyboard == .none {
                    if workoutSet.workoutExercise?.workout?.isCurrentWorkout == true,
                       workoutSet.workoutExercise?.exercise(in: exerciseStore.exercises)?.type == .barbell {
                        barbellTools
                    }
                    HStack(spacing: 16) {
                        tagButton
                        doneButton
                    }
                    .padding(.bottom, 8) /// pushes the draggers up and makes the buttons look more centered
                }
            }.padding(.horizontal, 10)
            
            if showKeyboard != .none {
                keyboard
            }
        }
        .padding([.top, .bottom])
//        .drawingGroup() /// fixes visual bug with show/hide animation of this view
        .gesture(DragGesture()
            .onEnded({ drag in
                let width = drag.predictedEndTranslation.width
                let height = drag.predictedEndTranslation.height
                
                if abs(height) > abs(width) {
                    if height > 200 {
                        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                            self.showKeyboard = .none
                        }
                    }
                } else {
                    if width > 200 {
                        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                            self.showKeyboard = .repetitions
                        }
                    } else if width < 200 {
                        withAnimation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion)) {
                            self.showKeyboard = .weight
                        }
                    }
                }
            })
        )
        .sheet(item: $activeSheet) { self.sheet(for: $0) }
        .alert(isPresented: $showHelpAlert) { Alert(title: Text("You can also drag ☰ up and down to adjust the values.")) }
    }
}

/// Full-width values with direct typing, one-tap steps and the existing
/// vertical drag adjustment. The legacy custom number pad remains unchanged.
private struct WorkoutSetEditorValueField: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Binding var value: Double?
    var numberFormatter: NumberFormatter = NumberFormatter()
    let unit: String
    var stepSize: Double = 1
    var minValue: Double = 0
    var maxValue: Double
    var showCursor: Bool = false
    var onDragStep: (Double?) -> Void = { _ in }
    var onDragCompleted: () -> Void = {}
    var onTextTapped: () -> Void = {}

    @State private var dragStart: Double?
    @State private var dragValue: Double?
    @State private var stepFeedback = 0

    private var valueTitle: String {
        numberFormatter.string(from: NSNumber(value: dragValue ?? value ?? 0)) ?? "0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(unit == "reps" ? "Reps" : "Weight")
                    .font(.subheadline)
                    .foregroundStyle(IronTheme.secondaryText)
                Spacer(minLength: 0)
                Image(systemName: "line.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(IronTheme.secondaryText)
                    .frame(width: IronTheme.controlHeight, height: IronTheme.controlHeight)
                    .contentShape(Rectangle())
                    .gesture(valueDrag)
                    .accessibilityHidden(true)
            }

            Button(action: onTextTapped) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(valueTitle)
                        .font(.ironMetric(.title2))
                        .foregroundStyle(IronTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(unit)
                        .font(.subheadline)
                        .foregroundStyle(IronTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(unit.capitalized)
            .accessibilityValue("\(valueTitle) \(unit)")
            .accessibilityHint("Swipe up or down to adjust. Double-tap to edit.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Edit"), onTextTapped)

            HStack(spacing: 8) {
                stepButton(-1)
                stepButton(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IronTheme.raisedSurface, in: RoundedRectangle(cornerRadius: IronTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IronTheme.cornerRadius, style: .continuous)
                .stroke(showCursor ? IronTheme.accent : IronTheme.outline, lineWidth: showCursor ? 2 : 0.5)
        }
        .sensoryFeedback(.selection, trigger: stepFeedback) { _, _ in settingsStore.workoutHaptics }
    }

    private func stepButton(_ direction: Double) -> some View {
        Button { step(direction) } label: {
            Image(systemName: direction > 0 ? "plus" : "minus")
                .font(.body.weight(.semibold))
                .foregroundStyle(IronTheme.primaryText)
                .frame(maxWidth: .infinity, minHeight: IronTheme.controlHeight)
                .background(IronTheme.field, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(direction > 0 ? "Increase" : "Decrease") \(unit == "reps" ? "reps" : "weight")")
    }

    private func step(_ direction: Double) {
        let next = min(max((value ?? 0) + direction * stepSize, minValue), maxValue)
        guard next != value else { return }
        value = next
        onDragStep(next)
        onDragCompleted()
        feedback()
    }

    private var valueDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag in
                if dragStart == nil { dragStart = value ?? 0 }
                let increment = (-Double(drag.translation.height) / 40).rounded(.towardZero) * stepSize
                var next = (dragStart ?? 0) + increment
                if increment != 0 {
                    let remainder = next.truncatingRemainder(dividingBy: stepSize)
                    if remainder > 0 {
                        next -= remainder
                        if increment < 0 { next += stepSize }
                    }
                }
                next = min(max(next, minValue), maxValue)
                guard next != (dragValue ?? value ?? 0) else { return }
                dragValue = next
                onDragStep(next)
                feedback()
            }
            .onEnded { _ in
                if let dragValue {
                    value = dragValue
                    onDragCompleted()
                }
                dragStart = nil
                dragValue = nil
            }
    }

    private func feedback() {
        stepFeedback += 1
        if settingsStore.workoutSounds { IronSoundPlayer.shared.play(.tick) }
    }
}

struct WarmupRecommendation: Identifiable, Hashable {
    let percentage: Double
    let weight: Double
    let repetitions: Int

    var id: String { "\(percentage)-\(weight)-\(repetitions)" }
}

/// Competition plate colors use the existing semantic palette.
enum PlateAppearance {
    static func color(for weight: Double, unit: WeightUnit) -> Color {
        switch (unit, weight) {
        case (.metric, 25), (.metric, 2.5), (.imperial, 55), (.imperial, 5): return IronTheme.metricHeartRate
        case (.metric, 20), (.imperial, 45): return IronTheme.accent
        case (.metric, 15), (.imperial, 35): return IronTheme.metricRecord
        case (.metric, 10), (.imperial, 25): return IronTheme.metricVolume
        case (.metric, 5), (.imperial, 10): return IronTheme.diagramCanvas
        default: return IronTheme.secondaryText
        }
    }

    static func height(for weight: Double, unit: WeightUnit, maximum: CGFloat) -> CGFloat {
        maximum * PlateProportions.height(for: weight, unit: unit.plateLoadUnit)
    }

    static func width(for weight: Double, unit: WeightUnit) -> CGFloat {
        let heaviest: Double = unit == .metric ? 25 : 45
        let ratio = min(max(weight / heaviest, 0.16), 1)
        return 7 + 7 * ratio
    }
}

extension WeightUnit {
    var plateLoadUnit: WatchWorkoutWeightUnit { self == .metric ? .kilogram : .pound }
}

private enum PlateCalculatorMode: String, CaseIterable, Identifiable {
    case bar, noBar, machine
    var id: Self { self }
    var title: String {
        switch self { case .bar: return "Bar"; case .noBar: return "No Bar"; case .machine: return "Machine" }
    }
}

private struct BarbellLoadDiagram: View {
    let platesPerSide: [(weight: Double, count: Int)]
    let unit: WeightUnit
    let loadout: PlateLoadout

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let center = size.width / 2
            let noBar = loadout.mode == .noBar
            let grip = noBar ? 20 : max(size.width * 0.22, 44)
            let room = max((size.width - grip) / 2 - 12, 0)
            // Bound the drawing's cost for very small plates; the list retains full counts.
            let stack = platesPerSide.flatMap { Array(repeating: $0.weight, count: min($0.count, 24)) }.prefix(24)
            let natural = stack.reduce(CGFloat.zero) { $0 + PlateAppearance.width(for: $1, unit: unit) + 2 }
            let scale = natural > room ? room / natural : 1
            func fill(_ rect: CGRect, _ color: Color, radius: CGFloat = 2) {
                context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(color))
            }
            if isMachine {
                // Both horns share the barbell's centerline and plate layout.
                let sleeveLength = (size.width - grip) / 2
                fill(CGRect(x: 0, y: midY - 3, width: sleeveLength, height: 6), IronTheme.secondaryText)
                fill(CGRect(x: center + grip / 2, y: midY - 3, width: sleeveLength, height: 6), IronTheme.secondaryText)
                drawMachine(context: context, size: size, width: grip)
            } else if !noBar {
                fill(CGRect(x: 0, y: midY - 3, width: size.width, height: 6), IronTheme.secondaryText)
            }
            let sides: [CGFloat] = loadout.loadedSides == .both ? [-1, 1] : [1]
            for side in sides {
                let inner = center + side * grip / 2
                if !noBar {
                    fill(CGRect(x: side > 0 ? inner : inner - 6, y: midY - 14, width: 6, height: 28), IronTheme.secondaryText)
                }
                var offset = inner + side * (noBar ? 0 : 6)
                for weight in stack {
                    let width = PlateAppearance.width(for: weight, unit: unit) * scale
                    let height = PlateAppearance.height(for: weight, unit: unit, maximum: size.height)
                    let x = side > 0 ? offset + 2 * scale : offset - 2 * scale - width
                    let rect = CGRect(x: x, y: midY - height / 2, width: width, height: height)
                    fill(rect, PlateAppearance.color(for: weight, unit: unit))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 2, style: .continuous), with: .color(IronTheme.outline), lineWidth: 0.5)
                    offset += side * (width + 2 * scale)
                }
            }
        }
        .frame(height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadout.mode == .noBar ? "Plate stack" : (isMachine ? "Front view of a plate-loaded machine with backrest, footplate and left and right plate horns" : "Barbell diagram"))
        .accessibilityValue("\(loadout.loadedSides == .both ? "Each side" : "One side"): " + (platesPerSide.isEmpty ? "No plates" : platesPerSide.map { "\($0.count) times \($0.weight.formatted()) \(unit.unit.symbol)" }.joined(separator: ", ")))
    }

    private func drawMachine(context: GraphicsContext, size: CGSize, width: CGFloat) {
        // Head-on silhouette fits entirely inside the space reserved for the bar grip.
        let bounds = CGRect(x: (size.width - width) / 2, y: 4, width: width, height: size.height - 8)
        func panel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
            let rect = CGRect(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height,
                              width: w * bounds.width, height: h * bounds.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 2, style: .continuous), with: .color(color))
        }
        // Uprights and crossmembers sit behind the centered carriage and pads.
        panel(0.09, 0.04, 0.06, 0.90, IronTheme.secondaryText)
        panel(0.85, 0.04, 0.06, 0.90, IronTheme.secondaryText)
        panel(0.09, 0.04, 0.82, 0.04, IronTheme.secondaryText)
        panel(0, 0.92, 1, 0.04, IronTheme.secondaryText)
        panel(0, 0.42, 1, 0.16, IronTheme.tertiaryFill)
        panel(0.27, 0.15, 0.46, 0.40, IronTheme.secondaryText)
        panel(0.21, 0.57, 0.58, 0.08, IronTheme.secondaryText)
        panel(0.14, 0.72, 0.72, 0.14, IronTheme.primaryText)
    }

    private var isMachine: Bool { if case .machine = loadout.mode { return true }; return false }
}

/// Reused by the calculator and Workout Preferences; inventory is shared across exercises.
struct PlateInventoryRows: View {
    let unit: WeightUnit
    @Binding var inventory: PlateInventory
    @State private var selectionFeedback = 0

    var body: some View {
        ForEach(PlateInventory.availablePlates(for: unit.plateLoadUnit), id: \.self) { weight in
            Toggle(isOn: Binding(
                get: { inventory.isEnabled(weight, unit: unit.plateLoadUnit) },
                set: {
                    guard inventory.isEnabled(weight, unit: unit.plateLoadUnit) != $0 else { return }
                    inventory.setEnabled($0, weight: weight, unit: unit.plateLoadUnit)
                    selectionFeedback += 1
                }
            )) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(PlateAppearance.color(for: weight, unit: unit))
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).stroke(IronTheme.outline, lineWidth: 0.5))
                        .frame(width: 12, height: 24)
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(weight.formatted()).font(.ironMetric(.body, weight: .semibold))
                        Text(unit.unit.symbol).font(.footnote).foregroundStyle(IronTheme.secondaryText)
                    }
                }
            }
            .accessibilityLabel("\(weight.formatted()) \(unit.unit.symbol) plates")
        }
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
    }
}

struct PlateCalculatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let unit: WeightUnit
    let exerciseKey: String?
    let onClose: () -> Void
    let onApply: (Double) -> Void
    private let initialTarget: Double

    @State private var targetWeight: Double
    @State private var loadout: PlateLoadout
    @State private var inventory: PlateInventory
    @State private var selectionFeedback = 0

    init(unit: WeightUnit, initialTarget: Double, exerciseKey: String? = nil, onClose: @escaping () -> Void = {}, onApply: @escaping (Double) -> Void) {
        self.unit = unit
        self.exerciseKey = exerciseKey
        self.onClose = onClose
        self.onApply = onApply
        let target = initialTarget.isFinite ? min(max(initialTarget, 0), 2000) : 0
        self.initialTarget = target
        _targetWeight = State(initialValue: target)
        _loadout = State(initialValue: PlateLoadout.load(exerciseKey: exerciseKey, unit: unit.plateLoadUnit))
        _inventory = State(initialValue: PlateInventory.load())
    }

    /// Compatibility for the live logger hint, including the user's enabled inventory.
    static func platesPerSide(for targetWeight: Double, unit: WeightUnit, barWeight: Double) -> [(weight: Double, count: Int)] {
        PlateLoadSolver.solve(target: targetWeight,
                              loadout: PlateLoadout(mode: .barbell(barWeight), unit: unit.plateLoadUnit),
                              inventory: .load()).platesPerSide.map { ($0.weight, $0.count) }
    }

    private var solution: PlateLoadSolution { PlateLoadSolver.solve(target: targetWeight, loadout: loadout, inventory: inventory) }
    private var platesPerSide: [(weight: Double, count: Int)] { solution.platesPerSide.map { ($0.weight, $0.count) } }
    private var targetStep: Double { unit.barbellIncrement }
    private var sideTitle: String { loadout.loadedSides == .both ? "Plates Per Side" : "Plates on One Side" }
    private var emptyTitle: String {
        switch loadout.mode { case .barbell: return "Empty bar"; case .noBar: return "No plates"; case .machine: return "Starting weight only" }
    }
    private var mode: PlateCalculatorMode {
        switch loadout.mode { case .barbell: return .bar; case .noBar: return .noBar; case .machine: return .machine }
    }
    private var modeBinding: Binding<PlateCalculatorMode> {
        Binding(get: { mode }, set: { mode in
            guard self.mode != mode else { return }
            switch mode {
            case .bar: loadout.mode = .barbell(unit.barbellWeight)
            case .noBar: loadout.mode = .noBar
            case .machine: loadout.mode = .machine(0)
            }
            selectionFeedback += 1
        })
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    VStack(spacing: 2) {
                        IronMetricValue(value: weightTitle(solution.loadedTotal), unit: unit.unit.symbol, style: .largeTitle)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                        Text(abs(solution.loadedTotal - targetWeight) < 0.001 ? "Loads your target exactly" : "Loaded toward \(weightTitle(targetWeight)) \(unit.unit.symbol)")
                            .font(.footnote).foregroundStyle(IronTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loaded weight")
                    .accessibilityValue("\(weightTitle(solution.loadedTotal)) \(unit.unit.symbol)")
                    BarbellLoadDiagram(platesPerSide: platesPerSide, unit: unit, loadout: loadout)
                    Text(platesPerSide.isEmpty ? emptyTitle : "\(weightTitle(solution.plateWeightPerSide)) \(unit.unit.symbol) \(loadout.loadedSides == .both ? "per side" : "on one side")")
                        .font(.footnote.weight(.medium)).foregroundStyle(IronTheme.secondaryText)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .listRowSeparator(.hidden)
                Stepper(onIncrement: targetWeight >= 2000 ? nil : { adjustTarget(by: targetStep) },
                        onDecrement: targetWeight <= 0 ? nil : { adjustTarget(by: -targetStep) }) {
                    weightLabel("Target", value: targetWeight)
                }
                .accessibilityLabel("Target weight")
                .accessibilityValue("\(weightTitle(targetWeight)) \(unit.unit.symbol)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target moves in \(weightTitle(targetStep)) \(unit.unit.symbol) steps and includes any bar or machine starting weight. Done saves a changed target; swipe down to leave the set as it was.")
                    if targetWeight < loadout.baseWeight {
                        Text("Your target is lighter than the \(mode == .machine ? "machine’s starting weight" : "bar on its own").")
                    } else if solution.shortfall > 0.001 {
                        Text("\(weightTitle(solution.shortfall)) \(unit.unit.symbol) short of your target with these plates.")
                    }
                }
            }

            if !platesPerSide.isEmpty {
                Section(sideTitle) {
                    ForEach(platesPerSide, id: \.weight) { plate in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(PlateAppearance.color(for: plate.weight, unit: unit))
                                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).stroke(IronTheme.outline, lineWidth: 0.5))
                                .frame(width: 12, height: 24).accessibilityHidden(true)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    IronMetricValue(value: weightTitle(plate.weight), unit: unit.unit.symbol, style: .title2).fixedSize()
                                    Spacer(minLength: 4)
                                    Text("× \(plate.count)").font(.ironMetric(.title2)).foregroundStyle(IronTheme.secondaryText).fixedSize()
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    IronMetricValue(value: weightTitle(plate.weight), unit: unit.unit.symbol, style: .title2)
                                    Text("× \(plate.count)").font(.ironMetric(.title2)).foregroundStyle(IronTheme.secondaryText)
                                }
                            }
                        }
                        .frame(minHeight: IronTheme.controlHeight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(plate.count) times \(weightTitle(plate.weight)) \(unit.unit.symbol) \(loadout.loadedSides == .both ? "per side" : "on one side")")
                    }
                }
            }

            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    equipmentPicker.pickerStyle(.menu)
                } else {
                    equipmentPicker.pickerStyle(.segmented)
                }
                if mode != .noBar {
                    Stepper(onIncrement: loadout.baseWeight >= 2000 ? nil : { adjustBase(by: 0.5) },
                            onDecrement: loadout.baseWeight <= 0 ? nil : { adjustBase(by: -0.5) }) {
                        weightLabel(mode == .bar ? "Bar" : "Starting Weight", value: loadout.baseWeight)
                    }
                    .accessibilityLabel(mode == .bar ? "Bar weight" : "Machine starting weight")
                    .accessibilityValue("\(weightTitle(loadout.baseWeight)) \(unit.unit.symbol)")
                }
                Picker("Loaded Sides", selection: Binding(
                    get: { loadout.loadedSides },
                    set: {
                        guard loadout.loadedSides != $0 else { return }
                        loadout.loadedSides = $0
                        selectionFeedback += 1
                    }
                )) {
                    Text("Both Sides").tag(PlateLoadout.LoadedSides.both)
                    Text("One Side").tag(PlateLoadout.LoadedSides.one)
                }
            } header: { Text("Setup") } footer: {
                Text("Machine starting weight includes the sled or carriage. One Side suits a landmine or single-side T-bar.\(exerciseKey == nil ? "" : " Setup is saved for this exercise.")")
            }

            Section {
                PlateInventoryRows(unit: unit, inventory: $inventory)
            } header: { Text("Available Plates") } footer: {
                Text("Enable the plates at your gym. This inventory is used for every exercise on this device. Plate counts are unlimited.")
                if inventory.enabledPlates(for: unit.plateLoadUnit).isEmpty {
                    Text("No plates enabled. Only the starting weight can be loaded.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // Opening this just to read the plates must not round the set's weight.
                Button("Done") {
                    if targetWeight != initialTarget { onApply(solution.loadedTotal) } else { onClose() }
                }
            }
        }
        .animation(IronMotion.preferred(IronMotion.snappy, reduceMotion: reduceMotion), value: targetWeight)
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
        .onChange(of: loadout) { loadout.save(exerciseKey: exerciseKey) }
        .onChange(of: inventory) { inventory.save() }
        .onAppear { inventory = .load() }
    }

    private var equipmentPicker: some View {
        Picker("Equipment", selection: modeBinding) {
            ForEach(PlateCalculatorMode.allCases) { Text($0.title).tag($0) }
        }
    }

    private func weightLabel(_ title: String, value: Double) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(title).fixedSize()
                Spacer(minLength: 4)
                IronMetricValue(value: weightTitle(value), unit: unit.unit.symbol, style: .title2).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                IronMetricValue(value: weightTitle(value), unit: unit.unit.symbol, style: .title2)
            }
        }
    }

    private func adjustTarget(by amount: Double) {
        let next = min(max(targetWeight + amount, 0), 2000)
        guard next != targetWeight else { return }
        targetWeight = next
        stepFeedback()
    }
    private func adjustBase(by amount: Double) {
        let value = min(max(loadout.baseWeight + amount, 0), 2000)
        guard value != loadout.baseWeight else { return }
        switch loadout.mode { case .barbell: loadout.mode = .barbell(value); case .machine: loadout.mode = .machine(value); case .noBar: break }
        stepFeedback()
    }
    private func stepFeedback() {
        selectionFeedback += 1
        IronSoundPlayer.shared.play(.tick)
    }
    private func weightTitle(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...3))) }
}

struct WarmupCalculatorView: View {
    @ObservedObject private var loadoutsCache = PlateCalculatorStorageKeys.loadoutsCache
    @ObservedObject private var inventoryCache = PlateCalculatorStorageKeys.inventoryCache
    let unit: WeightUnit
    let workingWeight: Double
    var exerciseKey: String? = nil
    let onAdd: ([WarmupRecommendation]) -> Void

    private var loadout: PlateLoadout? {
        exerciseKey.flatMap { PlateLoadout.loadAll()[$0] }
    }

    private var workingSetWeight: Double {
        // Keep the legacy sheet's bar floor, but allow lighter No Bar setups.
        loadout == nil ? max(workingWeight, unit.barbellWeight) : workingWeight
    }

    private var recommendations: [WarmupRecommendation] {
        WarmupPlan.recommendations(workingWeight: workingSetWeight, unit: unit.plateLoadUnit,
                                   loadout: loadout, inventory: PlateInventory.load()).map {
            WarmupRecommendation(percentage: $0.percentage, weight: $0.weight, repetitions: $0.repetitions)
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Working Set") {
                    Text("\(String(format: "%g", workingSetWeight)) \(unit.unit.symbol)")
                        .font(.ironMetric(.title2, weight: .bold))
                }
            } footer: {
                Text(loadout == nil ? "Warm-up weights are rounded to your barbell increment."
                     : "Warm-up weights use your exercise setup and available plates.")
            }

            if recommendations.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Warm-Up Needed",
                        systemImage: "checkmark.circle",
                        description: Text(loadout == nil ? "This working set is already at the selected bar weight."
                                          : "Your setup has no lighter warm-up weights for this working set.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Warm-Up Sets") {
                    ForEach(recommendations) { item in
                        LabeledContent {
                            Text("^[\(item.repetitions) rep](inflect: true)")
                                .font(.ironMetric(.title2, weight: .bold))
                                .foregroundStyle(IronTheme.secondaryText)
                        } label: {
                            Text("\(item.weight, specifier: "%g") \(unit.unit.symbol)")
                                .font(.ironMetric(.title2, weight: .bold))
                            Text("\(Int(item.percentage * 100))% of working set")
                                .font(.ironMetric(.caption, weight: .semibold))
                        }
                    }
                }

                Section {
                    Button("Add \(recommendations.count) Warm-Up Sets") {
                        onAdd(recommendations)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct MoreView: View {
    @ObservedObject var workoutSet: WorkoutSet
    
    @State private var activeAlert: AlertType?
    @State private var selectionFeedback = 0
    
    private enum AlertType: Identifiable {
        case tagInfo
        case rpeInfo
        
        var id: Self { self }
    }
    
    private func alertFor(type: AlertType) -> Alert {
        switch type {
        case .tagInfo:
            return Alert(title: Text("Mark a set as Failure if you've tried to do more reps but failed."))
        case .rpeInfo:
            return Alert(title: Text("The rating of perceived exertion (RPE) is a way to determine and regulate your workout intensity."))
        }
    }
    
    @State private var workoutSetCommentInput: String? // cannot use ValueHolder here, since it would be recreated on changes
    private var workoutSetComment: Binding<String> {
        Binding(
            get: {
                self.workoutSetCommentInput ?? self.workoutSet.comment ?? ""
            },
            set: { newValue in
                self.workoutSetCommentInput = newValue
            }
        )
    }
    private func adjustAndSaveWorkoutSetCommentInput() {
        guard let newValue = workoutSetCommentInput?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        workoutSetCommentInput = newValue
        workoutSet.comment = newValue.isEmpty ? nil : newValue
        workoutSet.managedObjectContext?.saveOrCrash()
    }

    private func tagButton(tag: WorkoutSetTag) -> some View {
        Button(action: {
            selectionFeedback += 1
            if self.workoutSet.tagValue == tag {
                self.workoutSet.tagValue = nil
            } else {
                self.workoutSet.tagValue = tag
            }
        }) {
            HStack {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundColor(tag.color)
                Text(tag.title.capitalized)
                Spacer()
                if self.workoutSet.tagValue == tag {
                    Image(systemName: "checkmark")
                        .foregroundColor(.secondary)
                }
            }.background(Color.fakeClear)
        }
        .buttonStyle(.plain)
    }
    
    private func rpeButton(rpe: Double) -> some View {
        Button(action: {
            selectionFeedback += 1
            if self.workoutSet.rpeValue == rpe {
                self.workoutSet.rpeValue = nil
            } else {
                self.workoutSet.rpeValue = rpe
            }
        }) {
            HStack {
                Text(String(format: "%.1f", rpe))
                    .font(.ironMetric(.body, weight: .semibold))
                Text(RPE.title(rpe) ?? "")
                    .lineLimit(nil)
                    .foregroundColor(.secondary)
                Spacer()
                if self.workoutSet.rpeValue == rpe {
                    Image(systemName: "checkmark")
                        .foregroundColor(.secondary)
                }
            }.background(Color.fakeClear)
        }
        .buttonStyle(.plain)
    }
    
    var body: some View {
        List {
            Section(header:
                HStack {
                    Text("Tag".uppercased())
                    Spacer()
                    Button(action: {
                        self.activeAlert = .tagInfo
                    }) {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.accentColor)
                    }
                }) {
                ForEach(WorkoutSetTag.allCases, id: \.self) { tag in
                    self.tagButton(tag: tag)
                }
            }
            
            Section(header: Text("Comment".uppercased())) {
                TextField("Comment", text: workoutSetComment, onEditingChanged: { isEditingTextField in
                    if !isEditingTextField {
                        self.adjustAndSaveWorkoutSetCommentInput()
                    }
                })
            }
            
            Section(header:
                HStack {
                    Text("RPE (Rating of Perceived Exertion)")
                    Spacer()
                    Button(action: {
                        self.activeAlert = .rpeInfo
                    }) {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.accentColor)
                    }
                }) {
                ForEach(RPE.allowedValues.reversed(), id: \.self) { rpe in
                    self.rpeButton(rpe: rpe)
                }
            }
        }
        .listStyleCompat_InsetGroupedListStyle()
        .alert(item: $activeAlert) { self.alertFor(type: $0) }
        .sensoryFeedback(.selection, trigger: selectionFeedback) { _, _ in SettingsStore.shared.workoutHaptics }
    }
}

#if DEBUG
struct WorkoutSetEditor_Previews : PreviewProvider {
    static var previews: some View {
        return Group {
            WorkoutSetEditor(workoutSet: MockWorkoutData.metricRandom.workoutSet)
                .mockEnvironment(weightUnit: .metric)
                .previewDisplayName("Metric")
                .previewLayout(.sizeThatFits)
            
            WorkoutSetEditor(workoutSet: MockWorkoutData.imperialRandom.workoutSet)
                .mockEnvironment(weightUnit: .imperial)
                .previewDisplayName("Imperial")
                .previewLayout(.sizeThatFits)
            
            MoreView(workoutSet: MockWorkoutData.metricRandom.workoutSet)
                .mockEnvironment(weightUnit: .metric)
                .previewLayout(.sizeThatFits)
                .listStyle(GroupedListStyle())
        }
    }
}
#endif
