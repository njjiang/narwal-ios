import SwiftUI
import UIKit

enum FreoPalette {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let accent = Color(uiColor: .systemBlue)
    static let buttonFill = accent
    static let onAccent = Color.white
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let separator = Color(uiColor: .separator)
    static let selection = accent.opacity(0.12)
    static let warning = Color(uiColor: .systemOrange)
    static let warningBackground = Color(uiColor: .systemOrange).opacity(0.12)
    static let success = accent
}

