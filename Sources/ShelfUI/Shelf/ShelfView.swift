import ShelfCore
import SwiftUI

/// The root of the shelf panel: a glass slab with the top rail and the card strip.
public struct ShelfView: View {
    @Bindable var model: ShelfViewModel
    /// Drives the slide-up animation; owned by the panel controller.
    @Bindable var presentation: ShelfPresentation
    @FocusState private var searchFocused: Bool
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage(PrefKey.cardColors) private var cardColors = CardColorMode.app.rawValue

    public init(model: ShelfViewModel, presentation: ShelfPresentation) {
        self.model = model
        self.presentation = presentation
    }

    public var body: some View {
        let layout = model.layout
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                TopRail(model: model, searchFocused: $searchFocused)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .frame(height: layout.isCompact ? TopRail.compactHeight : TopRail.height)
                if layout.isHorizontal {
                    CardStrip(model: model, now: context.date)
                        .frame(height: CardView.size.height + CardStrip.inset * 2)
                } else {
                    CardStrip(model: model, now: context.date)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            // 28 = the cards' 16 point corners plus their 12 point inset: concentric.
            .shelfMaterial(cornerRadius: 28)
            .shadow(color: .black.opacity(layout.position == .center ? 0.22 : 0), radius: 28, y: 12)
            .overlay(alignment: .bottom) { toast }
            .overlay(alignment: .topLeading) { suggestions }
        }
        .environment(\.cardColorsFromApp, cardColors == CardColorMode.app.rawValue)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, layout.position == .bottom ? 0 : 8)
        .offset(x: presentation.horizontalOffset, y: presentation.offset)
        .scaleEffect(presentation.scale)
        .opacity(presentation.opacity)
        .onChange(of: model.focusRequest) { searchFocused = true }
        // A finished or cancelled rename hands the keyboard back to search.
        .onChange(of: model.renamingPinboardID) { _, id in if id == nil { searchFocused = true } }
        .onAppear {
            searchFocused = true
            model.isRightToLeft = layoutDirection == .rightToLeft
        }
        .alert(
            String(localized: "Delete pinboard?"),
            isPresented: Binding(
                get: { model.pinboardPendingDeletion != nil },
                set: { if !$0 { model.pinboardPendingDeletion = nil } }
            ),
            presenting: model.pinboardPendingDeletion
        ) { _ in
            Button(String(localized: "Delete"), role: .destructive) { model.confirmDeletion() }
            Button(String(localized: "Cancel"), role: .cancel) { model.pinboardPendingDeletion = nil }
        } message: { board in
            Text(String(localized: "“\(board.name)” and its \(board.itemCount) items will be deleted. Items that are still in your history stay there."))
        }
    }

    /// Completions for the filter being typed, under the search field. Tab or
    /// Return takes the highlighted one; ↑ and ↓ move; a click takes any.
    @ViewBuilder
    private var suggestions: some View {
        if model.hasSuggestions {
            HStack(spacing: 4) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    let highlighted = index == model.suggestionIndex
                    Button {
                        model.acceptSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 5) {
                            if let symbol = suggestion.symbol {
                                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                            }
                            Text(suggestion.label).lineLimit(1)
                        }
                        .font(.system(size: 12 * ShelfAppearance.textScale, weight: highlighted ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(highlighted ? Color.accentColor.opacity(0.25) : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(highlighted ? .isSelected : [])
                }
                Text("⇥")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
            }
            .padding(5)
            .shelfGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: .regularMaterial)
            .padding(.leading, 16)
            .padding(.top, 44)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Filter suggestions"))
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isWarning ? .orange : .green)
                Text(toast.message)
                    .font(.system(size: 12 * ShelfAppearance.textScale, weight: .medium))
                if toast.canUndo {
                    Button(String(localized: "Undo")) { model.undoRemoval() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .shelfGlass(in: Capsule(), fallback: .regularMaterial)
            .padding(.bottom, 10)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// Offset and opacity of the shelf content, animated by the panel controller.
@MainActor
@Observable
public final class ShelfPresentation {
    /// Vertical slide, for the bottom shelf.
    public var offset: CGFloat = 24
    /// Horizontal slide, for the left and right shelves.
    public var horizontalOffset: CGFloat = 0
    /// The centered panel grows in instead of sliding.
    public var scale: Double = 1
    public var opacity: Double = 0

    public init() {}
}
