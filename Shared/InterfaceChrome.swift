import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How a continuous meter is drawn for one interface style.
///
/// Classic stays a thin pill. Screen Time uses a short-cornered block, the
/// way Screen Time draws a category bar. Liquid Glass stays a pill, with a
/// stronger track so it reads on a blurred surface.
struct UsageMeterMetrics: Equatable, Sendable {
    var height: CGFloat
    var cap: UsageMeterCap
    var trackOpacity: Double
}

enum UsageMeterCap: Equatable, Sendable {
    case round
    case square
}

extension InterfaceStyle {
    func continuousMeter(prominent: Bool) -> UsageMeterMetrics {
        switch self {
        case .classic:
            return UsageMeterMetrics(height: 6, cap: .round, trackOpacity: 0.14)
        case .screenTime:
            return UsageMeterMetrics(height: prominent ? 14 : 9, cap: .square, trackOpacity: 0.10)
        case .liquidGlass:
            return UsageMeterMetrics(height: prominent ? 8 : 6, cap: .round, trackOpacity: 0.28)
        }
    }
}

enum InterfacePalette {
    static func screenTimeCanvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.07, green: 0.08, blue: 0.11)
            : Color(red: 0.88, green: 0.91, blue: 0.96)
    }

    /// Opaque page fill. `UIColor.systemBackground` has no macOS name.
    static var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/// Saturated field behind Liquid Glass, so the blur has something to blur.
struct InterfaceGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(
            colors: dark
                ? [
                    Color(red: 0.05, green: 0.08, blue: 0.22),
                    Color(red: 0.20, green: 0.06, blue: 0.24),
                    Color(red: 0.03, green: 0.16, blue: 0.18),
                ]
                : [
                    Color(red: 0.42, green: 0.68, blue: 0.98),
                    Color(red: 0.74, green: 0.50, blue: 0.96),
                    Color(red: 0.32, green: 0.84, blue: 0.80),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

/// Widget and Live Activity fill. Follows the same three surfaces as the app.
struct InterfaceWidgetBackground: View {
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch interfaceStyle {
        case .classic:
            InterfacePalette.pageBackground
        case .screenTime:
            InterfacePalette.screenTimeCanvas(colorScheme)
        case .liquidGlass:
            ZStack {
                InterfaceGlassBackdrop()
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }
}

struct UsageListSurface: ViewModifier {
    var style: InterfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime:
            content
                .blinkyScreenTimeListSpacing()
                .scrollContentBackground(.hidden)
                .background(InterfacePalette.screenTimeCanvas(colorScheme).ignoresSafeArea())
        case .liquidGlass:
            content
                .scrollContentBackground(.hidden)
                .background(InterfaceGlassBackdrop())
        }
    }
}

struct UsageAccountChrome: ViewModifier {
    var style: InterfaceStyle

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime:
            content
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .listRowBackground(InterfacePalette.pageBackground)
        case .liquidGlass:
            content
                .blinkyGlassPlate()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
    }
}

private struct BlinkyNavigationChrome: ViewModifier {
    var style: InterfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime, .liquidGlass:
            content.blinkyNavigationBarBackground(style, colorScheme: colorScheme)
        }
    }
}

private struct SettingsCanvasModifier: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime:
            content
                .scrollContentBackground(.hidden)
                .background(InterfacePalette.screenTimeCanvas(colorScheme).ignoresSafeArea())
                .blinkyNavigationBarBackground(style, colorScheme: colorScheme)
        case .liquidGlass:
            content
                .scrollContentBackground(.hidden)
                .background(InterfaceGlassBackdrop())
                .blinkyNavigationBarBackground(style, colorScheme: colorScheme)
        }
    }
}

private struct SettingsSectionModifier: ViewModifier {
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime:
            content.listRowBackground(InterfacePalette.pageBackground)
        case .liquidGlass:
            content.listRowBackground(GlassSectionFill())
        }
    }
}

private struct GlassSectionFill: View {
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
    }
}

extension View {
    /// Extra air between account cards. The spacing API is iOS-only.
    @ViewBuilder
    func blinkyScreenTimeListSpacing() -> some View {
        #if os(iOS)
        self.listSectionSpacing(18)
        #else
        self
        #endif
    }

    /// Navigation-bar material. `ToolbarPlacement.navigationBar` is iOS-only.
    @ViewBuilder
    func blinkyNavigationBarBackground(_ style: InterfaceStyle, colorScheme: ColorScheme) -> some View {
        #if os(iOS)
        switch style {
        case .classic:
            self
        case .screenTime:
            self
                .toolbarBackground(InterfacePalette.screenTimeCanvas(colorScheme), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        case .liquidGlass:
            self
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        #else
        self
        #endif
    }

    func blinkyNavigationGlass(_ style: InterfaceStyle) -> some View {
        modifier(BlinkyNavigationChrome(style: style))
    }

    func blinkySettingsCanvas() -> some View {
        modifier(SettingsCanvasModifier())
    }

    func blinkySettingsSection() -> some View {
        modifier(SettingsSectionModifier())
    }

    /// Floating plate. iOS 26 uses system glass; earlier systems use a material,
    /// a light rim, and a shadow so the plate still separates from the page.
    @ViewBuilder
    func blinkyGlassPlate() -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        #if os(iOS)
        if #available(iOS 26, *) {
            self
                .padding(14)
                .glassEffect(.regular, in: shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.45), lineWidth: 1) }
                .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
                .padding(.vertical, 4)
        } else {
            blinkyMaterialPlate(shape)
        }
        #else
        blinkyMaterialPlate(shape)
        #endif
    }

    func blinkyMaterialPlate(_ shape: RoundedRectangle) -> some View {
        padding(14)
            .background(.ultraThinMaterial, in: shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.55), lineWidth: 1) }
            .shadow(color: Color.black.opacity(0.16), radius: 16, y: 8)
            .padding(.vertical, 4)
    }

    /// Frosted inset for secondary card details.
    @ViewBuilder
    func blinkyInsetGlass() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        #if os(iOS)
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

/// Home Screen multi-account list. The three styles stay readable at widget size:
/// Classic is a plain stack, Screen Time adds a category rail and a block bar,
/// Liquid Glass puts each account on its own chip.
struct StyledMultiAccountList: View {
    var snapshots: [UsageSnapshot]
    var showsSecondLimit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Usage")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(snapshots, id: \.accountID) { snapshot in
                StyledMultiAccountRow(snapshot: snapshot, showsSecondLimit: showsSecondLimit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StyledMultiAccountRow: View {
    var snapshot: UsageSnapshot
    var showsSecondLimit: Bool
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch interfaceStyle {
        case .classic:
            row.padding(.vertical, 1)
        case .screenTime:
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(width: 3)
                row
            }
        case .liquidGlass:
            row
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5)
                }
        }
    }

    private var row: some View {
        let headline = snapshot.headlineWindow(pinnedMetricID: nil)
        let secondary = headline.flatMap { snapshot.secondaryLimit(after: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ProviderIcon(providerID: snapshot.accountProviderID ?? .chatGPT, symbolName: snapshot.accountSymbolName)
                    .frame(width: 16, height: 16)
                Text(snapshot.resolvedAccountName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let headline {
                    if headline.showsCountdown {
                        Text(CountdownDisplay.compactString(until: headline.resetsAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(UsageText.remainingPercent(headline.remainingPercent))
                        .font(.caption.weight(interfaceStyle == .screenTime ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(interfaceStyle == .screenTime ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                }
            }
            if let headline {
                UsageMeter(remainingFraction: headline.remainingPercent / 100)
                if showsSecondLimit, let secondary {
                    HStack {
                        Text(secondary.displayTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(UsageText.remainingPercent(secondary.remainingPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var tint: Color {
        let remaining = (snapshot.headlineWindow(pinnedMetricID: nil)?.remainingPercent ?? 100) / 100
        return UsageMeterTint.color(remainingFraction: remaining, colorScheme: colorScheme)
    }
}

#if os(iOS)
struct StyledLiveAccountList: View {
    var rows: [UsageActivityAccountRow]
    var onDarkSurface = false
    var limit = 4
    @Environment(\.interfaceStyle) private var interfaceStyle

    var body: some View {
        VStack(alignment: .leading, spacing: interfaceStyle == .screenTime ? 10 : 8) {
            ForEach(rows.prefix(limit)) { account in
                StyledLiveAccountRow(account: account, onDarkSurface: onDarkSurface)
            }
        }
    }
}

struct StyledLiveAccountRow: View {
    var account: UsageActivityAccountRow
    var onDarkSurface = false
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch interfaceStyle {
        case .classic:
            stack
        case .screenTime:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 4)
                stack
            }
        case .liquidGlass:
            if onDarkSurface {
                stack
            } else {
                stack
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5)
                    }
            }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ProviderIcon(providerID: account.providerID, symbolName: account.symbolName)
                    .frame(width: 14, height: 14)
                Text(account.accountName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if account.isSoonestReset {
                    Text(UsageText.soonestBadge())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 4)
                        .background(.orange.opacity(onDarkSurface ? 0.35 : 0.85), in: .capsule)
                }
                Spacer(minLength: 4)
                if let reset = account.headlineResetsAt {
                    Text(CountdownDisplay.compactString(until: reset))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(UsageText.remainingPercent(account.headlineRemainingPercent))
                    .font((interfaceStyle == .screenTime ? Font.subheadline.weight(.bold) : Font.caption).monospacedDigit())
                    .foregroundStyle(interfaceStyle == .screenTime ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            UsageMeter(
                remainingFraction: account.headlineRemainingPercent / 100,
                prominent: interfaceStyle == .screenTime
            )
            if let secondary = account.secondaryTitle, let percent = account.secondaryRemainingPercent {
                Text("\(secondary) \(UsageText.remainingPercent(percent))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(onDarkSurface ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    private var tint: Color {
        UsageMeterTint.color(
            remainingFraction: account.headlineRemainingPercent / 100,
            colorScheme: onDarkSurface ? .dark : colorScheme
        )
    }
}
#endif
