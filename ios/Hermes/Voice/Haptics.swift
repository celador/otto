import UIKit

@MainActor
enum Haptics {
    static func send() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func tap() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
