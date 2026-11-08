import Foundation

enum DashboardPane: CaseIterable { case attention, work, detail }
enum NavigationIntent: Equatable {
    case consumed, move(Int), first, last
}

/// Keyboard interpretation lives separately from actions so pane movement can never approve or dismiss work.
struct DashboardNavigation {
    var focus: DashboardPane = .attention
    var detailSource: DashboardPane = .attention
    private var lastSidebar: DashboardPane = .attention
    private var windowPrefix = false
    private var firstPrefix = false
    var viewport = DetailViewport()
    var listCapacities: [DashboardPane: Int] = [.attention: 1, .work: 1]

    mutating func sidebar(_ pane: DashboardPane, task: Bool = false) {
        focus = pane; lastSidebar = pane; detailSource = pane
        viewport = DetailViewport(followTail: task)
    }
    mutating func selected(task: Bool = false) {
        detailSource = focus == .detail ? lastSidebar : focus
        viewport = DetailViewport(followTail: task)
    }
    mutating func handle(_ key: Int32, dashboard: Bool) -> NavigationIntent? {
        if windowPrefix {
            windowPrefix = false
            switch key {
            case 104: focus = lastSidebar
            case 108: focus = .detail
            case 106: if dashboard && focus == .attention { focus = .work; lastSidebar = .work; detailSource = .work; viewport = DetailViewport(followTail: true) }
            case 107: if dashboard && focus == .work { focus = .attention; lastSidebar = .attention; detailSource = .attention; viewport = DetailViewport() }
            case 119: cycle(dashboard: dashboard)
            default: break
            }
            return .consumed
        }
        if firstPrefix {
            firstPrefix = false
            if key == 103 {
                if focus == .detail { viewport.top(); return .consumed }
                return .first
            }
            return .consumed
        }
        switch key {
        case 23: windowPrefix = true; return .consumed // Ctrl-W
        case 9: cycle(dashboard: dashboard); return .consumed
        case 104: focus = lastSidebar; return .consumed
        case 108: focus = .detail; return .consumed
        case 106, 107:
            let delta = key == 106 ? 1 : -1
            if focus == .detail { viewport.move(delta); return .consumed }
            return .move(delta)
        case 4, 21, 6, 2: // Ctrl-D/U/F/B
            let direction = key == 4 || key == 6 ? 1 : -1
            if focus == .detail {
                let amount = key == 6 || key == 2 ? viewport.height : max(1, viewport.height / 2)
                viewport.move(direction * amount); return .consumed
            }
            let capacity = listCapacities[focus] ?? 1
            let amount = key == 6 || key == 2 ? capacity : max(1, capacity / 2)
            return .move(direction * amount)
        case 103: firstPrefix = true; return .consumed
        case 71:
            if focus == .detail { viewport.bottom(); return .consumed }
            return .last
        default: return nil
        }
    }
    private mutating func cycle(dashboard: Bool) {
        if dashboard {
            switch focus {
            case .attention: sidebar(.work, task: true)
            case .work: focus = .detail
            case .detail: sidebar(.attention)
            }
        } else { focus = focus == .detail ? .work : .detail; lastSidebar = .work }
    }
}

struct DetailViewport {
    private(set) var offset = 0
    private(set) var height = 1
    private(set) var count = 0
    private(set) var followTail = false
    init(followTail: Bool = false) { self.followTail = followTail }
    mutating func update(count: Int, height: Int) {
        self.count = count; self.height = max(1, height)
        offset = followTail ? max(0, count - self.height) : min(offset, max(0, count - self.height))
    }
    mutating func move(_ amount: Int) { followTail = false; offset = min(max(0, count - height), max(0, offset + amount)) }
    mutating func top() { followTail = false; offset = 0 }
    mutating func bottom() { followTail = true; offset = max(0, count - height) }
}
