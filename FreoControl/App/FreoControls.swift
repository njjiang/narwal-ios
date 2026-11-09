import SwiftUI

struct FreoPrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, compact ? 7 : 12)
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 52)
            .foregroundStyle(isEnabled ? FreoPalette.onAccent : FreoPalette.secondaryText)
            .modifier(FreoControlSurface(shape: Capsule(), prominent: true,
                                         isEnabled: isEnabled, isPressed: configuration.isPressed))
    }
}

struct FreoSecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.subheadline : .body).weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, compact ? 6 : 16)
            .padding(.vertical, compact ? 6 : 10)
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48)
            .foregroundStyle(isEnabled ? FreoPalette.accent : FreoPalette.secondaryText)
            .modifier(FreoControlSurface(shape: Capsule(), prominent: false,
                                         isEnabled: isEnabled, isPressed: configuration.isPressed))
    }
}

struct FreoIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(isEnabled ? FreoPalette.accent : FreoPalette.secondaryText)
            .modifier(FreoControlSurface(shape: Circle(), prominent: false,
                                         isEnabled: isEnabled, isPressed: configuration.isPressed))
    }
}

/// One surface per control; toolbar containers should not add another background.
private struct FreoControlSurface<ControlShape: Shape>: ViewModifier {
    let shape: ControlShape
    let prominent: Bool
    let isEnabled: Bool
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .contentShape(shape)
                .glassEffect(.regular
                    .tint(prominent && isEnabled ? FreoPalette.buttonFill : nil)
                    .interactive(isEnabled && !reduceMotion), in: shape)
                .opacity(isEnabled ? (isPressed && reduceMotion ? 0.84 : 1) : 0.55)
        } else {
            content
                .background {
                    shape.fill(.regularMaterial)
                        .overlay {
                            if prominent && isEnabled {
                                // Tint the same material surface while retaining white-label contrast.
                                shape.fill(FreoPalette.buttonFill.opacity(0.96))
                            }
                        }
                }
                .contentShape(shape)
                .opacity(isEnabled ? (isPressed ? 0.84 : 1) : 0.55)
                .scaleEffect(isEnabled && isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isPressed)
        }
    }
}
