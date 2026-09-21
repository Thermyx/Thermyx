import Charts
import SwiftUI

/// Forefoot / arch / heel temperature across the window, one cell per column.
///
/// Shared by the Insights hub, the Temperature detail, and the trusted-member
/// view rather than reimplemented in each — one colour scale, one row order,
/// one set of hour labels. Appears only when the insole actually reported
/// three zones; a single-sensor insole gets no heat map at all rather than a
/// map drawn from one repeated value.
struct ZoneHeatMap: View {
    let series: [FootZone: [Double]]
    let columnLabels: [String]
    let unit: TemperatureUnit
    var title: String = "Zone heat map · by hour"
    var showsChevron: Bool = false
    var showsScale: Bool = true

    private var columnCount: Int { series[.forefoot]?.count ?? 0 }

    /// Flattened ahead of the chart builder: inferring this inline pushed the
    /// nested ForEach past the type-checker's budget.
    private struct Cell: Identifiable {
        let zone: FootZone
        let column: Int
        let value: Double
        var id: String { "\(zone.rawValue)-\(column)" }
    }

    private var cells: [Cell] {
        FootZone.allCases.flatMap { zone -> [Cell] in
            let row = series[zone] ?? []
            return row.enumerated().map { Cell(zone: zone, column: $0.offset, value: $0.element) }
        }
    }

    private var columnDomain: [String] {
        (0..<max(columnCount, 1)).map(String.init)
    }

    private var zoneDomain: [String] { FootZone.allCases.map(\.label) }

    var body: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                HStack {
                    SectionLabel(title)
                    Spacer(minLength: Thermyx.Space.xs)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }
                }

                Chart(cells) { cell in
                    RectangleMark(
                        x: .value("Column", String(cell.column)),
                        y: .value("Zone", cell.zone.label),
                        width: .ratio(0.9),
                        height: .ratio(0.62)
                    )
                    .foregroundStyle(ThermyxTemperatureScale.tint(for: cell.value))
                    .cornerRadius(4)
                }
                .frame(height: 96)
                .chartXScale(domain: columnDomain)
                .chartYScale(domain: zoneDomain)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading, values: .automatic) { value in
                        AxisValueLabel(horizontalSpacing: Thermyx.Space.xs) {
                            if let label = value.as(String.self) {
                                ThermyxChartStyle.axisLabel(label)
                                    .frame(width: 62, alignment: .leading)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilitySummary)

                ChartAxisRow(labels: columnLabels)

                if showsScale {
                    FlowRow(spacing: Thermyx.Space.m) {
                        ForEach(ThermyxTemperatureScale.Band.allCases) { band in
                            ChartLegendChip(color: band.color, label: band.label)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// VoiceOver cannot see a colour grid, so it gets each zone's current and
    /// peak value instead of a description of the picture.
    private var accessibilitySummary: String {
        FootZone.allCases.compactMap { zone -> String? in
            guard let row = series[zone], let last = row.last, let peak = row.max() else { return nil }
            return "\(zone.label) now \(TemperatureFormat.full(last, in: unit)), peak \(TemperatureFormat.full(peak, in: unit))"
        }
        .joined(separator: ". ")
    }
}
