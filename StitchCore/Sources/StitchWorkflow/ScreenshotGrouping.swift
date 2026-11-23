import Foundation

public enum ScreenshotGrouping {
    public static let maximumInputCount = 30
    public static let maximumBatchEncodedBytes = 512 * 1_024 * 1_024
    public static let discoveryLimit = 300
    public static let lookback: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumGap: TimeInterval = 5 * 60

    /// Continuous chronological segments; never combines disjoint buckets of equal dimensions.
    public static func groups(from assets: [ScreenshotAsset], now: Date = Date(),
                              excluding hidden: Set<String> = []) -> [ScreenshotGroup] {
        let cutoff = now.addingTimeInterval(-lookback)
        let recent = assets.enumerated().filter { _, asset in
            guard let date = asset.createdAt else { return false }
            return date >= cutoff && date <= now
        }.sorted {
            if $0.element.createdAt == $1.element.createdAt { return $0.offset < $1.offset }
            return $0.element.createdAt! > $1.element.createdAt!
        }.prefix(discoveryLimit).reversed().map(\.element)
        var result: [[ScreenshotAsset]] = []
        var atBoundary = true
        for asset in recent {
            guard !hidden.contains(asset.id), asset.size.pixelCount != nil else {
                atBoundary = true
                continue
            }
            if !atBoundary, let previous = result.last?.last,
               previous.size == asset.size,
               asset.createdAt!.timeIntervalSince(previous.createdAt!) <= maximumGap {
                result[result.count - 1].append(asset)
            } else {
                result.append([asset])
            }
            atBoundary = asset.separatedFromNewer
        }
        return result.reversed().map { ScreenshotGroup(assets: $0) }
    }
}
