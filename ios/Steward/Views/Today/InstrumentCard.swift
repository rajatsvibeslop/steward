//
//  InstrumentCard.swift
//  Steward — Track E
//
//  Per Designer §2.3. Two-column grid; each card shows name, large primary
//  value + optional unit, delta line with muted color coding, and (if stale
//  ≥48h) a "last logged Nd ago" footer.
//

import SwiftUI

struct InstrumentCard: View {
    let item: TodayViewModel.InstrumentDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.display.primary)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if let unit = item.display.unit, !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !item.display.delta.text.isEmpty {
                HStack(spacing: 4) {
                    if !item.display.delta.symbol.isEmpty {
                        Image(systemName: item.display.delta.symbol)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.display.delta.text)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
            }

            if let stale = item.display.staleLabel {
                Text(stale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.instrument.\(item.id)")
    }
}
