import Foundation

/// Greedy interval partitioning: stacks possibly-overlapping date ranges into as few lanes (rows)
/// as possible — each item goes in the first lane whose last-placed item already ends by this one's
/// start, else it starts a new lane. Shared by TimelineOverviewView and CalendarView, which both
/// need exactly this ("lay out these date ranges without them visually colliding"), just at
/// different scales (one lane per whole project vs. one lane per calendar week).
enum IntervalPacking {
    /// `items` must already be sorted by `start` — the algorithm assumes it and won't re-sort.
    static func lanes<T>(_ items: [T], start: (T) -> Date, end: (T) -> Date) -> [[T]] {
        var lanes: [[T]] = []
        for item in items {
            let itemStart = start(item)
            if let laneIndex = lanes.firstIndex(where: { lane in
                guard let last = lane.last else { return true }
                return end(last) <= itemStart
            }) {
                lanes[laneIndex].append(item)
            } else {
                lanes.append([item])
            }
        }
        return lanes
    }
}
