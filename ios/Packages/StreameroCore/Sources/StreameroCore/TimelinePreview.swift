import Foundation

/// Locates the sprite-sheet tile for a scrub position (server packs 10x10 thumbnails per sheet).
public struct TimelineTile: Sendable, Equatable {
    public var sheet: Int
    public var column: Int
    public var row: Int
    public var x: Int
    public var y: Int
}

public func timelineTile(at time: TimeInterval, interval: Double, columns: Int, rows: Int, tileWidth: Int, tileHeight: Int, sheetCount: Int) -> TimelineTile? {
    guard interval > 0, columns > 0, rows > 0, sheetCount > 0 else { return nil }
    let perSheet = columns * rows
    let index = max(0, Int((max(0, time) / interval).rounded(.down)))
    let sheet = min(sheetCount - 1, index / perSheet)
    let within = sheet == sheetCount - 1 && index / perSheet > sheet ? perSheet - 1 : index % perSheet
    let col = within % columns
    let row = within / columns
    return TimelineTile(sheet: sheet, column: col, row: row, x: col * tileWidth, y: row * tileHeight)
}
