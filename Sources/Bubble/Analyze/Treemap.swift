import SwiftUI

struct Treemap<Menu: View>: View {
    let entries: [DiskEntry]
    let onOpen: (DiskEntry) -> Void
    @ViewBuilder let menu: (DiskEntry) -> Menu

    private static var colors: [Color] {
        // Deep water: blues and violets, distinct but calm so the labels stay readable.
        [0x32418A, 0x433A8F, 0x2B5487, 0x55408A, 0x2F6478, 0x3C4B9A, 0x5A3F7E, 0x2E5A6E, 0x474C86, 0x3A3570]
            .map { Color(hex: $0) }
    }

    private var total: Double { entries.reduce(0) { $0 + $1.size } }

    var body: some View {
        GeometryReader { geo in
            let tiles = layout(in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { i, tile in
                    tileView(tile, color: tile.entry == nil ? Color(hex: 0x262C52) : Self.colors[i % Self.colors.count])
                        .frame(width: max(tile.rect.width - 6, 1), height: max(tile.rect.height - 6, 1))
                        .offset(x: tile.rect.minX + 3, y: tile.rect.minY + 3)
                }
            }
        }
    }

    private struct Tile { var rect: CGRect; var entry: DiskEntry?; var label: String; var size: Double }

    @ViewBuilder
    private func tileView(_ tile: Tile, color: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        let content = VStack(spacing: Space.xs) {
            if tile.rect.height > 46 && tile.rect.width > 70 {
                Label(tile.label, systemImage: tile.entry == nil ? "square.grid.2x2" : (tile.entry?.isDir == false ? "doc" : "folder"))
                    .font(.ui(.body, .semibold)).lineLimit(1).truncationMode(.middle)
                Text(tile.entry?.sizeLabel ?? Fmt.bytes(tile.size)).font(.num(.secondary, .medium)).opacity(0.85)
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color, in: shape)
        .contentShape(shape)
        let percent = Int((tile.size / max(total, 1) * 100).rounded())

        if let e = tile.entry {
            Button { onOpen(e) } label: { content }
                .buttonStyle(.quiet)
                .contextMenu { menu(e) }
                .help("\(Fmt.abbreviate(e.path)), \(Fmt.bytes(e.size))")
                .accessibilityLabel("\(e.name), \(Fmt.bytes(e.size)), \(percent) percent of this folder")
                .accessibilityHint(e.isDir == false ? "Shows it in Finder" : "Opens the folder")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(tile.label) smaller items, \(Fmt.bytes(tile.size)) together")
        }
    }

    /// Shows the biggest items individually and folds the long tail into one tile.
    private func layout(in rect: CGRect) -> [Tile] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let total = entries.reduce(0) { $0 + $1.size }
        guard total > 0 else { return [] }
        var shown: [DiskEntry] = []
        for e in entries {
            if shown.count >= 14 || (shown.count >= 4 && e.size / total < 0.015) { break }
            shown.append(e)
        }
        let rest = entries.dropFirst(shown.count)
        var items: [(DiskEntry?, String, Double)] = shown.map { ($0, $0.name, $0.size) }
        if !rest.isEmpty {
            let restSize = rest.reduce(0) { $0 + $1.size }
            items.append((nil, "\(rest.count) items", max(restSize, total * 0.02)))
        }
        let rects = Squarify.layout(items.map(\.2), in: rect)
        return zip(items, rects).map { Tile(rect: $1, entry: $0.0, label: $0.1, size: $0.0?.size ?? $0.2) }
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk). Values must be sorted descending.
enum Squarify {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        var areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var free = rect
        while !areas.isEmpty {
            let side = Double(min(free.width, free.height))
            var row: [Double] = [areas.removeFirst()]
            while let next = areas.first, worst(row + [next], side) <= worst(row, side) {
                row.append(areas.removeFirst())
            }
            let rowArea = row.reduce(0, +)
            if free.width >= free.height {
                let w = CGFloat(rowArea / Double(free.height))
                var y = free.minY
                for a in row {
                    let h = CGFloat(a) / w
                    result.append(CGRect(x: free.minX, y: y, width: w, height: h))
                    y += h
                }
                free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
            } else {
                let h = CGFloat(rowArea / Double(free.width))
                var x = free.minX
                for a in row {
                    let w = CGFloat(a) / h
                    result.append(CGRect(x: x, y: free.minY, width: w, height: h))
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
            }
        }
        return result
    }

    private static func worst(_ row: [Double], _ side: Double) -> Double {
        let s = row.reduce(0, +)
        guard s > 0, side > 0, let mx = row.max(), let mn = row.min() else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }
}
