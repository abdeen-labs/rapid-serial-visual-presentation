import SwiftUI
import SwiftData
import Charts

/// How much and how fast the user reads over the last week, month, year, or
/// all time (``ReadingStatistics``): totals and averages, time read per day
/// or month, and speed with the words alone and with the voice.
///
/// It counts every session in the library's store, including one a reader
/// in another window is still adding to, so the sheet keeps up as it goes.
struct StatisticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [ReadingSession]
    @State private var period: ReadingStatistics.Period = .week

    var body: some View {
        let stats = ReadingStatistics(sessions: sessions.map(\.snapshot), period: period)

        #if os(iOS)
        NavigationStack {
            content(stats: stats)
                .navigationTitle("Statistics")
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        // A macOS sheet shows no navigation title. The period picker sits
        // under the title rather than in a form row, which a grouped macOS
        // form would box like a setting.
        VStack(spacing: 0) {
            Text("Statistics")
                .font(.headline)
                .padding(.top, 18)
            if !sessions.isEmpty {
                periodPicker
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
            content(stats: stats)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 700)
        #endif
    }

    private func content(stats: ReadingStatistics) -> some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Reading Yet",
                    systemImage: "chart.bar",
                    description: Text("Your reading time, words read, and speed show here once you've read for a while.")
                )
            } else {
                form(stats: stats)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func form(stats: ReadingStatistics) -> some View {
        Form {
            #if os(iOS)
            Section {
                periodPicker
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            #endif

            if stats.isEmpty {
                Section {
                    Text("No reading \(period.phrase).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } footer: {
                    Text(Self.footnote)
                }
            } else {
                let timeline = ChartTimeline(stats)
                let modes = ReadingMode.shown(in: stats)

                Section {
                    SummaryTiles(stats: stats)
                }

                Section("Time Read") {
                    TimeReadChart(timeline: timeline)
                }

                Section {
                    ForEach(modes) { mode in
                        SpeedRow(mode: mode, wordsPerMinute: mode.amount(in: stats).wordsPerMinute)
                    }
                    SpeedChart(timeline: timeline, modes: modes)
                } header: {
                    Text("Speed")
                } footer: {
                    Text(Self.footnote)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The one filter, above everything it scopes.
    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(ReadingStatistics.Period.allCases) { period in
                Text(period.title).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// What counts, as ``ReadingSessionTracker`` counts it.
    private static var footnote: String {
        let pause = Int(ReadingSessionTracker.maximumPause / 60)
        return "Time counts while words play, pauses between sentences included, and a pause of more than \(pause) minutes starts a new session. With iCloud sync on, reading on your other devices counts too."
    }
}

// MARK: - Summary

/// The period's totals and averages, two by two, or in one column at
/// accessibility text sizes, where two would cut the values short.
private struct SummaryTiles: View {
    let stats: ReadingStatistics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let tiles = [
            StatTile(
                label: "Time read",
                value: StatisticsFormat.time(stats.total.seconds),
                spokenValue: StatisticsFormat.spokenTime(stats.total.seconds)
            ),
            StatTile(
                label: "Words read",
                value: StatisticsFormat.words(stats.total.words),
                spokenValue: StatisticsFormat.spokenWords(stats.total.words)
            ),
            StatTile(
                label: "Daily average",
                value: StatisticsFormat.time(stats.dailyAverage.seconds),
                spokenValue: "\(StatisticsFormat.spokenTime(stats.dailyAverage.seconds)) a day"
            ),
            StatTile(
                label: "Average session",
                value: StatisticsFormat.time(stats.averageSessionSeconds ?? 0),
                spokenValue: StatisticsFormat.spokenTime(stats.averageSessionSeconds ?? 0)
            ),
        ]

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(tiles, id: \.label) { $0 }
                }
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow { tiles[0]; tiles[1] }
                    GridRow { tiles[2]; tiles[3] }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// One figure: a small label over its value, read as one by VoiceOver.
private struct StatTile: View {
    let label: String
    let value: String
    let spokenValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrobeTheme.metadataFont)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }
}

// MARK: - Speed

/// A way of reading the Speed section compares, with its series color. The
/// two colors stay apart for every kind of color vision against the dark
/// grouped rows.
private enum ReadingMode: CaseIterable, Identifiable {
    /// Reading with the words alone.
    case wordsOnly
    /// Reading while the voice paces the words.
    case readAloud

    var id: Self { self }

    /// The modes the Speed section compares. Reading aloud shows where it
    /// runs, and elsewhere only when another device's reading aloud synced
    /// here for the period.
    static func shown(in stats: ReadingStatistics) -> [ReadingMode] {
        allCases.filter { mode in
            mode != .readAloud || KokoroVoiceModel.isSupported || stats.voiced.seconds > 0
        }
    }

    var title: String {
        switch self {
        case .wordsOnly: "Words only"
        case .readAloud: "Read aloud"
        }
    }

    /// Words only takes Strobe Red, which marks reading; read aloud the
    /// system's dark-mode blue.
    var color: Color {
        switch self {
        case .wordsOnly: StrobeTheme.accent
        case .readAloud: Color(hex: "0A84FF")
        }
    }

    func amount(in stats: ReadingStatistics) -> ReadingAmount {
        switch self {
        case .wordsOnly: stats.plain
        case .readAloud: stats.voiced
        }
    }

    func amount(in bucket: ReadingStatistics.Bucket) -> ReadingAmount {
        switch self {
        case .wordsOnly: bucket.plain
        case .readAloud: bucket.voiced
        }
    }
}

/// A mode's speed over the period, keyed by its series color. The text
/// stays in text colors; the dot beside it carries the identity.
private struct SpeedRow: View {
    let mode: ReadingMode
    let wordsPerMinute: Double?

    var body: some View {
        LabeledContent {
            Text(StatisticsFormat.speed(wordsPerMinute))
                .foregroundStyle(.secondary)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(mode.color)
                    .frame(width: 8, height: 8)
                Text(mode.title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.title)
        .accessibilityValue(StatisticsFormat.spokenSpeed(wordsPerMinute))
    }
}

// MARK: - Charts

/// A bucket placed on the charts' time axis.
private struct ChartBucket: Identifiable {
    let bucket: ReadingStatistics.Bucket
    /// The whole day, month, or year, so both charts span the same period
    /// whatever was read in it.
    let interval: DateInterval

    var id: Date { bucket.start }

    /// Where a line's point, an axis label, and the selection rule sit:
    /// over the middle of the bucket's bar.
    var middle: Date { interval.start.addingTimeInterval(interval.duration / 2) }
}

/// What the two charts share: one time axis over the period's buckets,
/// its labels, and the names of its buckets.
private struct ChartTimeline {
    let unit: Calendar.Component
    let buckets: [ChartBucket]

    init(_ stats: ReadingStatistics, calendar: Calendar = .current) {
        unit = stats.unit
        buckets = stats.buckets.map { bucket in
            let next = calendar.date(byAdding: stats.unit, value: 1, to: bucket.start)
            let end = next.map { max($0, bucket.start) } ?? bucket.start
            return ChartBucket(bucket: bucket, interval: DateInterval(start: bucket.start, end: end))
        }
    }

    /// Set on both charts, so the line chart spans the period even where
    /// nothing was read, and its points line up with the bars above.
    var domain: ClosedRange<Date> {
        guard let first = buckets.first, let last = buckets.last else { return Date.now...Date.now }
        return first.interval.start...last.interval.end
    }

    /// The bucket under the pointer, held to the period's ends.
    func bucket(at date: Date) -> ChartBucket? {
        buckets.last { $0.interval.start <= date } ?? buckets.first
    }

    // MARK: Axis

    /// The buckets the x axis names: every one up to a week or a year of
    /// months, and otherwise about five or six, counted back from the latest
    /// so the current day or month is always named.
    private var labeledBuckets: [ChartBucket] {
        let count = buckets.count
        let most = switch unit {
        case .day: count <= 7 ? 7 : 5
        case .month: count <= 12 ? 12 : 6
        default: 6
        }
        let step = max(1, (count + most - 1) / most)
        return buckets.indices.filter { (count - 1 - $0) % step == 0 }.map { buckets[$0] }
    }

    /// Weekday names over a week of days, day numbers over more, month
    /// names over months (initials where `plotWidth` leaves too little room
    /// between them for three letters), and years.
    private func labelFormat(plotWidth: CGFloat) -> Date.FormatStyle {
        switch unit {
        case .day:
            return buckets.count <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day()
        case .month:
            let spacing = plotWidth / CGFloat(max(1, labeledBuckets.count))
            // Unmeasured, the width is 0: take the names, as most plots fit them.
            return plotWidth > 0 && spacing < 30 ? .dateTime.month(.narrow) : .dateTime.month(.abbreviated)
        default:
            return .dateTime.year()
        }
    }

    /// Labels under the buckets' middles, with no grid lines or ticks: the
    /// bars and points show where each bucket is.
    @AxisContentBuilder
    func xAxis(plotWidth: CGFloat) -> some AxisContent {
        AxisMarks(values: labeledBuckets.map(\.middle)) { _ in
            AxisValueLabel(format: labelFormat(plotWidth: plotWidth))
        }
    }

    // MARK: Names

    /// The bucket as the selection callout names it: "Mon, Oct 27",
    /// "October 2026", or "2026".
    func title(of bucket: ChartBucket) -> String {
        let start = bucket.interval.start
        return switch unit {
        case .day: start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .month: start.formatted(.dateTime.month(.wide).year())
        default: start.formatted(.dateTime.year())
        }
    }

    /// The bucket as VoiceOver names its mark: "Monday, October 27".
    func spokenTitle(of bucket: ChartBucket) -> String {
        let start = bucket.interval.start
        return switch unit {
        case .day: start.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .month: start.formatted(.dateTime.month(.wide).year())
        default: start.formatted(.dateTime.year())
        }
    }
}

/// Colors and type the charts share.
private enum ChartStyle {
    /// The selection rule: a hairline, recessive against the marks.
    static let rule = Color.primary.opacity(0.35)
    /// The callout's box: the system's dark tertiary surface, a step above
    /// the grouped row, opaque so the marks under it don't show through.
    static let calloutBackground = Color(hex: "2C2C2E")

    /// The callout's values, a step above its labels.
    static var calloutValueFont: Font {
        #if os(macOS)
        .body.weight(.semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    /// Keeps the callout inside the chart, over the top of the plot,
    /// rather than out over the rows around it.
    static let calloutOverflow = AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .chart))
}

/// The box a chart shows at the selected bucket: the bucket's name, then
/// its values, which lead.
private struct ChartCallout<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(StrobeTheme.metadataFont)
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ChartStyle.calloutBackground, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// Time read per bucket as bars, in minutes, or in hours once a bucket
/// reaches two. Selecting a bucket keeps its bar and dims the rest.
private struct TimeReadChart: View {
    let timeline: ChartTimeline
    @State private var selectedDate: Date?
    @State private var plotWidth: CGFloat = 0

    /// The most one bucket can hold before the axis counts hours.
    private static let minutesLimit: TimeInterval = 2 * 60 * 60

    var body: some View {
        let longest = timeline.buckets.map(\.bucket.total.seconds).max() ?? 0
        let inHours = longest >= Self.minutesLimit
        let scale: Double = inHours ? 3600 : 60
        let axisName = inHours ? "Hours" : "Minutes"
        let selected = selectedDate.flatMap(timeline.bucket(at:))

        Chart {
            ForEach(timeline.buckets) { item in
                BarMark(
                    x: .value("Date", item.bucket.start, unit: timeline.unit),
                    y: .value(axisName, item.bucket.total.seconds / scale),
                    width: barWidth
                )
                .foregroundStyle(StrobeTheme.accent)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .opacity(selected == nil || selected?.id == item.id ? 1 : 0.5)
                .accessibilityLabel(timeline.spokenTitle(of: item))
                .accessibilityValue(StatisticsFormat.spokenAmount(item.bucket.total))
            }

            if let selected {
                RuleMark(x: .value("Date", selected.middle))
                    .foregroundStyle(ChartStyle.rule)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .zIndex(-1)
                    .accessibilityHidden(true)
                // The callout rides a clear rule of its own, drawn last, so
                // the bars never cover it while the visible rule stays
                // behind them.
                RuleMark(x: .value("Date", selected.middle))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: ChartStyle.calloutOverflow) {
                        ChartCallout(title: timeline.title(of: selected)) {
                            let total = selected.bucket.total
                            if total.seconds > 0 {
                                Text(StatisticsFormat.time(total.seconds))
                                    .font(ChartStyle.calloutValueFont)
                                Text(StatisticsFormat.spokenWords(total.words))
                                    .font(StrobeTheme.metadataFont)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No reading")
                                    .font(ChartStyle.calloutValueFont)
                            }
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: timeline.domain)
        .chartXAxis { timeline.xAxis(plotWidth: plotWidth) }
        .chartYAxisLabel(axisName)
        .chartXSelection(value: $selectedDate)
        .chartPlotStyle { plot in
            plot.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
        }
        .frame(height: 180)
        .padding(.vertical, 8)
    }

    /// Bars take most of their bucket's width, up to 24 points, so a week's
    /// few bars stay slim and a month's many keep a gap between them.
    private var barWidth: MarkDimension {
        guard plotWidth > 0, !timeline.buckets.isEmpty else { return .ratio(0.6) }
        let band = plotWidth / CGFloat(timeline.buckets.count)
        return .fixed(min(24, band * 0.6))
    }
}

/// One bucket's speed in one mode, as the speed chart plots it.
private struct SpeedPoint: Identifiable {
    let bucket: ChartBucket
    let mode: ReadingMode
    let wordsPerMinute: Double
    /// The unbroken run of buckets read in this mode that the point belongs
    /// to. Each run is a line of its own, so a bucket without reading in
    /// the mode breaks its line rather than dropping it to zero.
    let run: String

    var id: String { "\(run) \(bucket.interval.start.timeIntervalSinceReferenceDate)" }

    /// Every bucket's speed in each of `modes` it was read in, oldest
    /// first.
    static func points(in timeline: ChartTimeline, modes: [ReadingMode]) -> [SpeedPoint] {
        var points: [SpeedPoint] = []
        var runs: [ReadingMode: Int] = [:]
        for item in timeline.buckets {
            for mode in modes {
                if let speed = mode.amount(in: item.bucket).wordsPerMinute {
                    let run = "\(mode.title) \(runs[mode, default: 0])"
                    points.append(SpeedPoint(bucket: item, mode: mode, wordsPerMinute: speed, run: run))
                } else {
                    runs[mode, default: 0] += 1
                }
            }
        }
        return points
    }
}

/// Words per minute per bucket, a line for each mode, on one axis from
/// zero. The legend names the lines; the rows above it give the period's
/// speeds.
private struct SpeedChart: View {
    let timeline: ChartTimeline
    let modes: [ReadingMode]
    @State private var selectedDate: Date?
    @State private var plotWidth: CGFloat = 0

    var body: some View {
        let points = SpeedPoint.points(in: timeline, modes: modes)
        let selected = selectedDate.flatMap(timeline.bucket(at:))

        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Date", point.bucket.middle),
                    y: .value("Words per minute", point.wordsPerMinute),
                    series: .value("Run", point.run)
                )
                .foregroundStyle(by: .value("Mode", point.mode.title))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // The point says it; the line would say it again.
                .accessibilityHidden(true)
            }

            ForEach(points) { point in
                #if os(iOS)
                // A ring of the row's own color keeps a point clear of the
                // other mode's line and point where they cross. macOS
                // draws its rows in a color of its own, which a ring
                // wouldn't match.
                PointMark(
                    x: .value("Date", point.bucket.middle),
                    y: .value("Words per minute", point.wordsPerMinute)
                )
                .symbolSize(CGSize(width: 12, height: 12))
                .foregroundStyle(StrobeTheme.elevatedSurface)
                .accessibilityHidden(true)
                #endif
                PointMark(
                    x: .value("Date", point.bucket.middle),
                    y: .value("Words per minute", point.wordsPerMinute)
                )
                .symbolSize(CGSize(width: 8, height: 8))
                .foregroundStyle(by: .value("Mode", point.mode.title))
                .accessibilityLabel("\(timeline.spokenTitle(of: point.bucket)), \(point.mode.title.lowercased())")
                .accessibilityValue(StatisticsFormat.spokenSpeed(point.wordsPerMinute))
            }

            if let selected {
                RuleMark(x: .value("Date", selected.middle))
                    .foregroundStyle(ChartStyle.rule)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .zIndex(-1)
                    .accessibilityHidden(true)
                // As in the time chart: the callout on a clear rule drawn
                // last, over the lines.
                RuleMark(x: .value("Date", selected.middle))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: ChartStyle.calloutOverflow) {
                        ChartCallout(title: timeline.title(of: selected)) {
                            ForEach(modes) { mode in
                                SpeedCalloutRow(
                                    mode: mode,
                                    wordsPerMinute: mode.amount(in: selected.bucket).wordsPerMinute
                                )
                            }
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(
            domain: modes.map(\.title),
            range: modes.map(\.color)
        )
        .chartXScale(domain: timeline.domain)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis { timeline.xAxis(plotWidth: plotWidth) }
        .chartYAxisLabel("Words per minute")
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXSelection(value: $selectedDate)
        .chartPlotStyle { plot in
            plot.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
        }
        .frame(height: 210)
        .padding(.vertical, 8)
    }
}

/// One mode's speed in the speed chart's callout: a short stroke of the
/// line's color, the speed, then the mode's name.
private struct SpeedCalloutRow: View {
    let mode: ReadingMode
    let wordsPerMinute: Double?

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(mode.color)
                .frame(width: 12, height: 2)
            Text(StatisticsFormat.speed(wordsPerMinute))
                .font(ChartStyle.calloutValueFont)
            Text(mode.title)
                .font(StrobeTheme.metadataFont)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Formatting

/// How the sheet writes times, words, and speeds, on screen and for
/// VoiceOver.
private enum StatisticsFormat {
    /// "5 hr 12 min" or "45 min"; "< 1 min" for a few seconds, so a little
    /// reading never reads as none, and "0 min" for none.
    static func time(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return minutes(0, width: .abbreviated) }
        if seconds < 60 { return "< \(minutes(1, width: .abbreviated))" }
        return ReadingTime.label(minutes: wholeMinutes(seconds))
    }

    /// "5 hours 12 minutes", "Less than 1 minute", or "0 minutes".
    static func spokenTime(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return minutes(0, width: .wide) }
        if seconds < 60 { return "Less than \(minutes(1, width: .wide))" }
        return ReadingTime.spokenLabel(minutes: wholeMinutes(seconds))
    }

    /// Grouped below 10,000 ("3,400") and compact from there ("12K"), so a
    /// tile's value stays short.
    static func words(_ count: Int) -> String {
        count < 10_000 ? count.formatted() : count.formatted(.number.notation(.compactName))
    }

    static func spokenWords(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count.formatted()) words"
    }

    /// "312 wpm", or a dash without any time to measure.
    static func speed(_ wordsPerMinute: Double?) -> String {
        guard let wordsPerMinute else { return "—" }
        return "\(Int(wordsPerMinute.rounded()).formatted()) wpm"
    }

    static func spokenSpeed(_ wordsPerMinute: Double?) -> String {
        guard let wordsPerMinute else { return "No reading" }
        return "\(Int(wordsPerMinute.rounded()).formatted()) words per minute"
    }

    /// "12 minutes, 3,400 words", or "No reading".
    static func spokenAmount(_ amount: ReadingAmount) -> String {
        guard amount.seconds > 0 else { return "No reading" }
        return "\(spokenTime(amount.seconds)), \(spokenWords(amount.words))"
    }

    private static func wholeMinutes(_ seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded())
    }

    private static func minutes(_ value: Int, width: Measurement<UnitDuration>.FormatStyle.UnitWidth) -> String {
        Measurement(value: Double(value), unit: UnitDuration.minutes)
            .formatted(.measurement(width: width, usage: .asProvided))
    }
}
