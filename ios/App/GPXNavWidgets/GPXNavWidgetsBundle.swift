import SwiftUI
import WidgetKit

/// The extension's entry point.
///
/// One bundle, one widget: this app has a Live Activity and nothing else that
/// belongs on a home screen or in a gallery, so there is no second widget to
/// register and no configuration to speak of.
@main
struct GPXNavWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HikeLiveActivity()
    }
}