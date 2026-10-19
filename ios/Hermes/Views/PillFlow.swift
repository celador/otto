import SwiftUI

/// Wraps pills onto as many lines as they need. Each subview is laid out at its ideal size (give pills
/// `.fixedSize()` so labels never truncate); a pill wider than the whole line gets a line to itself.
/// `alignment` positions each line within the proposed width (`.leading` for pickers, `.center` for
/// the empty-chat starters under centered text).
struct PillFlow: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        // Fill a finite proposed width (so lines can align inside it); otherwise hug the widest line.
        if let w = proposal.width, w.isFinite { return CGSize(width: w, height: height) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            let slack = max(bounds.width - row.width, 0)
            var x = bounds.minX
            switch alignment {
            case .center: x += slack / 2
            case .trailing: x += slack
            default: break
            }
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                // Vertically center shorter pills within the line.
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
