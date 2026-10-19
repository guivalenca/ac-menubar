import AppKit
import SwiftUI

@main
struct ACMenubarApp: App {
    // The App must not observe ACStore: every store change would re-evaluate the scene, and
    // MenuBarExtra writes its isInserted binding back during that evaluation. Observing only
    // MenuBarVisibility, which ignores same-value writes, keeps that from turning into a loop.
    private let store: ACStore
    @StateObject private var visibility: MenuBarVisibility

    init() {
        Watchdog.start()
        if let path = Snapshot.requestedPath {
            exit(Snapshot.render(to: path) ? 0 : 1)
        }
        store = ACStore.shared
        _visibility = StateObject(wrappedValue: ACStore.shared.visibility)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $visibility.isVisible) {
            PanelView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Whether the menu bar item is inserted. Unlike @Published, writing the current value is a no-op,
/// so SwiftUI echoing the binding back doesn't trigger another update.
@MainActor
final class MenuBarVisibility: ObservableObject {
    private var inserted = false

    var isVisible: Bool {
        get { inserted }
        set {
            guard newValue != inserted else { return }
            objectWillChange.send()
            inserted = newValue
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: ACStore

    var body: some View {
        let symbol = store.isOn ? "air.conditioner.horizontal.fill" : "air.conditioner.horizontal"
        if let text = store.menuBarText {
            Text("\(Image(systemName: symbol)) \(text)")
        } else {
            Image(systemName: symbol)
        }
    }
}
