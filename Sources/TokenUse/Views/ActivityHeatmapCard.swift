import SwiftUI

enum ActivityChartScope: String, Equatable, Sendable {
    case today
    case ninetyDays
}

private enum TodayChartMode: String, CaseIterable, Identifiable {
    case heatmap = "活力图"
    case hourly = "每小时"
    case cumulative = "累计总量"

    var id: String { rawValue }
}

private enum NinetyDayChartMode: String, CaseIterable, Identifiable {
    case daily = "每天"
    case weekly = "每周"
    case cumulative = "累计总量"

    var id: String { rawValue }
}

private enum HeatmapLevel {
    case future
    case empty
    case l1
    case l2
    case l3
    case l4

    var fillColor: Color {
        switch self {
        case .future:
            return .white.opacity(0.03)
        case .empty:
            return .white.opacity(0.075)
        case .l1:
            return Color(.sRGB, red: 0.68, green: 0.87, blue: 1.00)
        case .l2:
            return Color(.sRGB, red: 0.35, green: 0.70, blue: 1.00)
        case .l3:
            return Color(.sRGB, red: 0.08, green: 0.49, blue: 0.98)
        case .l4:
            return Color(.sRGB, red: 0.03, green: 0.26, blue: 0.64)
        }
    }

    var needsHighlightBorder: Bool {
        self == .l4
    }
}

private struct DayGridItem {
    let dayIndex: Int?
    let date: Date?
    let bucket: ActivityBucket?
}

private struct WeekSummary {
    let index: Int
    let startDate: Date
    let endDate: Date
    let tokens: Int
    let cost: Double
    let requests: Int
    let activeDays: Int
    let topProvidersText: String?
}

private struct CumulativePoint {
    let label: String
    let cumulativeTokens: Int
    let deltaTokens: Int
    let cost: Double
}

struct ActivityHeatmapCard: View {
    let scope: ActivityChartScope
    let timeline: UsageActivityTimeline?
    let selectedProvider: TrackedProvider?
    let showEstimatedCost: Bool
    let onClose: () -> Void

    @State private var todayMode: TodayChartMode = .heatmap
    @State private var ninetyDayMode: NinetyDayChartMode = .daily
    @State private var hoveredIndex: Int? = nil

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        return formatter
    }()

    private static let weekdayLabels = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if let timeline {
                if scope == .today {
                    todayContent(timeline: timeline)
                } else {
                    ninetyDayContent(timeline: timeline)
                }
            } else {
                emptyTimelinePlaceholder
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.11), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.8)
                )
        )
        .onChange(of: scope) { _, _ in
            hoveredIndex = nil
        }
        .onChange(of: todayMode) { _, _ in
            hoveredIndex = nil
        }
        .onChange(of: ninetyDayMode) { _, _ in
            hoveredIndex = nil
        }
        .onChange(of: selectedProvider) { _, _ in
            hoveredIndex = nil
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(scope == .today ? "今日 Token 活动" : "近 90 天 Token 活动")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            if let selectedProvider {
                HStack(spacing: 4) {
                    ProviderBrandIcon(provider: selectedProvider, size: 12, cornerRadius: 3)
                    Text(selectedProvider.shortName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(selectedProvider.accentColor.opacity(0.22))
                        .overlay(
                            Capsule()
                                .stroke(selectedProvider.accentColor.opacity(0.45), lineWidth: 0.6)
                        )
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if scope == .today {
                    ForEach(TodayChartMode.allCases) { mode in
                        modeTabButton(title: mode.rawValue, isSelected: todayMode == mode) {
                            todayMode = mode
                        }
                    }
                } else {
                    ForEach(NinetyDayChartMode.allCases) { mode in
                        modeTabButton(title: mode.rawValue, isSelected: ninetyDayMode == mode) {
                            ninetyDayMode = mode
                        }
                    }
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("收起活动图")
        }
    }

    private func modeTabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.52))
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private var emptyTimelinePlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在同步活动时间线数据...")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, minHeight: 110)
    }

    // MARK: - Today Content

    @ViewBuilder
    private func todayContent(timeline: UsageActivityTimeline) -> some View {
        let nowSlot = currentTodayTenMinuteSlot(todayStart: timeline.todayStart)
        let nowHour = nowSlot / 6

        switch todayMode {
        case .heatmap:
            todayHeatmapView(timeline: timeline, nowSlot: nowSlot)
        case .hourly:
            todayHourlyBarView(timeline: timeline, nowHour: nowHour)
        case .cumulative:
            todayCumulativeView(timeline: timeline, nowSlot: nowSlot)
        }
    }

    private func todayHeatmapView(timeline: UsageActivityTimeline, nowSlot: Int) -> some View {
        let cellSize: CGFloat = 15
        let spacing: CGFloat = 4
        let positiveValues = (0..<144).compactMap { slot -> Int? in
            let v = bucketTokens(timeline.todayTenMinuteBuckets[slot])
            return v > 0 ? v : nil
        }
        let maxTokens = positiveValues.max() ?? 0
        let minPositive = positiveValues.min() ?? 0
        let totalToday = positiveValues.reduce(0, +)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: spacing) {
                    ForEach(0..<6, id: \.self) { row in
                        let label = (row == 0 || row == 2 || row == 4) ? String(format: ":%02d", row * 10) : ""
                        Text(label)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                            .frame(width: 20, height: cellSize, alignment: .trailing)
                    }
                }

                HStack(spacing: spacing) {
                    ForEach(0..<24, id: \.self) { hour in
                        VStack(spacing: spacing) {
                            ForEach(0..<6, id: \.self) { subRow in
                                let slot = hour * 6 + subRow
                                let isFuture = slot > nowSlot
                                let tokens = bucketTokens(timeline.todayTenMinuteBuckets[slot])
                                let level = heatmapLevel(
                                    tokens: tokens,
                                    isFuture: isFuture,
                                    maxTokens: maxTokens,
                                    minPositive: minPositive
                                )
                                heatmapCell(
                                    size: cellSize,
                                    cornerRadius: 3.5,
                                    level: level,
                                    isHovered: hoveredIndex == slot
                                )
                                .onHover { inside in
                                    hoveredIndex = inside ? slot : (hoveredIndex == slot ? nil : hoveredIndex)
                                }
                            }
                        }
                    }
                }
            }

            todayHourAxis(columnWidth: cellSize, spacing: spacing, leadingOffset: 26)

            HStack(spacing: 8) {
                detailFooterText(todaySlotDetailText(
                    timeline: timeline,
                    hoveredSlot: hoveredIndex,
                    nowSlot: nowSlot,
                    totalToday: totalToday
                ))
                Spacer(minLength: 0)
                legendStrip
            }
        }
    }

    private func todayHourlyBarView(timeline: UsageActivityTimeline, nowHour: Int) -> some View {
        let hourlyData: [(hour: Int, tokens: Int, cost: Double, requests: Int, topProviders: String?)] = (0..<24).map { hour in
            var tokens = 0
            var cost = 0.0
            var requests = 0
            var providerTotals: [String: Int] = [:]
            for sub in 0..<6 {
                let slot = hour * 6 + sub
                if let b = timeline.todayTenMinuteBuckets[slot] {
                    tokens += bucketTokens(b)
                    cost += bucketCost(b)
                    requests += bucketRequests(b)
                    for (k, v) in b.byProvider where v > 0 {
                        providerTotals[k, default: 0] += v
                    }
                }
            }
            return (hour, tokens, cost, requests, formatTopProviders(providerTotals))
        }

        let maxTokens = max(1, hourlyData.map(\.tokens).max() ?? 0)
        let totalToday = hourlyData.reduce(0) { $0 + $1.tokens }
        let barWidth: CGFloat = 15
        let spacing: CGFloat = 4
        let chartHeight: CGFloat = 100

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(hourlyData, id: \.hour) { item in
                    let isFuture = item.hour > nowHour
                    let isHovered = hoveredIndex == item.hour
                    let ratio = item.tokens > 0 ? CGFloat(item.tokens) / CGFloat(maxTokens) : 0
                    let barHeight = item.tokens > 0 ? max(5, ratio * (chartHeight - 8)) : 3

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(
                                isFuture
                                    ? HeatmapLevel.future.fillColor
                                    : (item.tokens > 0
                                        ? (isHovered ? HeatmapLevel.l4.fillColor : HeatmapLevel.l3.fillColor)
                                        : HeatmapLevel.empty.fillColor)
                            )
                            .frame(width: barWidth, height: barHeight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .stroke(.white.opacity(isHovered ? 0.85 : 0), lineWidth: 1)
                            )
                    }
                    .frame(width: barWidth, height: chartHeight)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hoveredIndex = inside ? item.hour : (hoveredIndex == item.hour ? nil : hoveredIndex)
                    }
                }
            }
            .padding(.leading, 26)

            todayHourAxis(columnWidth: barWidth, spacing: spacing, leadingOffset: 26)

            detailFooterText(
                todayHourlyDetailText(
                    hourlyData: hourlyData,
                    hoveredHour: hoveredIndex,
                    totalToday: totalToday
                )
            )
        }
    }

    private func todayCumulativeView(timeline: UsageActivityTimeline, nowSlot: Int) -> some View {
        let clampedMaxSlot = max(0, min(143, nowSlot))
        var running = 0
        var points: [CumulativePoint] = []
        points.reserveCapacity(clampedMaxSlot + 1)

        for slot in 0...clampedMaxSlot {
            let bucket = timeline.todayTenMinuteBuckets[slot]
            let delta = bucketTokens(bucket)
            let cost = bucketCost(bucket)
            running += delta
            let startMin = slot * 10
            let label = String(format: "%02d:%02d", startMin / 60, startMin % 60)
            points.append(CumulativePoint(label: label, cumulativeTokens: running, deltaTokens: delta, cost: cost))
        }

        let totalToday = points.last?.cumulativeTokens ?? 0

        return VStack(alignment: .leading, spacing: 6) {
            CumulativeAreaChart(
                points: points,
                hoveredIndex: $hoveredIndex,
                axisLabels: ["00:00", "06:00", "12:00", "18:00", points.last?.label ?? "当前"]
            )
            .frame(height: 118)

            detailFooterText(
                cumulativeDetailText(
                    points: points,
                    hoveredIndex: hoveredIndex,
                    emptyPrefix: "今日累计",
                    totalTokens: totalToday
                )
            )
        }
    }

    private func todayHourAxis(columnWidth: CGFloat, spacing: CGFloat, leadingOffset: CGFloat) -> some View {
        let labeledHours: Set<Int> = [0, 4, 8, 12, 16, 20, 23]
        return HStack(spacing: spacing) {
            ForEach(0..<24, id: \.self) { hour in
                Text(labeledHours.contains(hour) ? "\(hour)时" : "")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: columnWidth, alignment: hour == 23 ? .trailing : .leading)
            }
        }
        .padding(.leading, leadingOffset)
    }

    // MARK: - 90-Day Content

    @ViewBuilder
    private func ninetyDayContent(timeline: UsageActivityTimeline) -> some View {
        switch ninetyDayMode {
        case .daily:
            ninetyDayHeatmapView(timeline: timeline)
        case .weekly:
            ninetyDayWeeklyBarView(timeline: timeline)
        case .cumulative:
            ninetyDayCumulativeView(timeline: timeline)
        }
    }

    private func ninetyDayHeatmapView(timeline: UsageActivityTimeline) -> some View {
        let calendar = Calendar.current
        let columns = buildNinetyDayColumns(timeline: timeline, calendar: calendar)
        let cellSize: CGFloat = 15
        let spacing: CGFloat = 4

        let dailyValues = (0..<90).map { idx in
            bucketTokens(timeline.ninetyDayDailyBuckets[idx])
        }
        let positiveValues = dailyValues.filter { $0 > 0 }
        let maxTokens = positiveValues.max() ?? 0
        let minPositive = positiveValues.min() ?? 0
        let activeDays = positiveValues.count
        let totalTokens = dailyValues.reduce(0, +)
        let avgActive = activeDays > 0 ? totalTokens / activeDays : 0

        let streak = computeCurrentStreak(dailyValues: dailyValues)
        let peakEntry: (idx: Int, tokens: Int)? = dailyValues.enumerated()
            .filter { $0.element > 0 }
            .max(by: { $0.element < $1.element })
            .map { ($0.offset, $0.element) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 5) {
                        VStack(alignment: .trailing, spacing: spacing) {
                            ForEach(0..<7, id: \.self) { row in
                                let label: String = switch row {
                                case 0: "一"
                                case 2: "三"
                                case 4: "五"
                                case 6: "日"
                                default: ""
                                }
                                Text(label)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.42))
                                    .frame(width: 12, height: cellSize, alignment: .trailing)
                            }
                        }

                        HStack(spacing: spacing) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                                VStack(spacing: spacing) {
                                    ForEach(0..<7, id: \.self) { row in
                                        let item = week[row]
                                        if let dayIdx = item.dayIndex {
                                            let tokens = bucketTokens(item.bucket)
                                            let level = heatmapLevel(
                                                tokens: tokens,
                                                isFuture: false,
                                                maxTokens: maxTokens,
                                                minPositive: minPositive
                                            )
                                            heatmapCell(
                                                size: cellSize,
                                                cornerRadius: 3.5,
                                                level: level,
                                                isHovered: hoveredIndex == dayIdx
                                            )
                                            .onHover { inside in
                                                hoveredIndex = inside ? dayIdx : (hoveredIndex == dayIdx ? nil : hoveredIndex)
                                            }
                                        } else {
                                            Color.clear
                                                .frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    ninetyDayMonthAxis(
                        columns: columns,
                        columnWidth: cellSize,
                        spacing: spacing,
                        leadingOffset: 17,
                        calendar: calendar
                    )
                }

                // 右侧统计与图例面板（2x2 紧凑网格 + 独立图例行，避免纵向撑高后与底部明细重合）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        statMetricRow(title: "活跃天数", value: "\(activeDays) / 90 天")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statMetricRow(title: "当前连续", value: "\(streak) 天")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        statMetricRow(
                            title: "活跃日均",
                            value: activeDays > 0 ? NumberFormatterUtil.formatCompact(avgActive) : "0"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let peakEntry,
                           let peakDate = calendar.date(byAdding: .day, value: peakEntry.idx, to: timeline.ninetyDayStart) {
                            statMetricRow(
                                title: "单日峰值",
                                value: "\(Self.shortDateFormatter.string(from: peakDate)) · \(NumberFormatterUtil.formatCompact(peakEntry.tokens))"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            statMetricRow(title: "单日峰值", value: "暂无")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 0.6)

                    HStack(spacing: 6) {
                        Text("活跃度")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.50))
                        Spacer(minLength: 0)
                        legendStrip
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(.white.opacity(0.09), lineWidth: 0.6)
                        )
                )
                .clipped()
            }

            detailFooterText(
                ninetyDayDailyDetailText(
                    timeline: timeline,
                    hoveredDayIdx: hoveredIndex,
                    totalTokens: totalTokens,
                    activeDays: activeDays,
                    calendar: calendar
                )
            )
        }
    }

    private func ninetyDayWeeklyBarView(timeline: UsageActivityTimeline) -> some View {
        let calendar = Calendar.current
        let columns = buildNinetyDayColumns(timeline: timeline, calendar: calendar)
        let weeks: [WeekSummary] = columns.enumerated().compactMap { colIdx, col in
            let validItems = col.compactMap { item -> (Date, ActivityBucket?)? in
                guard let d = item.date else { return nil }
                return (d, item.bucket)
            }
            guard let firstDate = validItems.first?.0, let lastDate = validItems.last?.0 else {
                return nil
            }
            var tokens = 0
            var cost = 0.0
            var requests = 0
            var activeDays = 0
            var providerTotals: [String: Int] = [:]

            for (_, b) in validItems {
                let dayTokens = bucketTokens(b)
                if dayTokens > 0 { activeDays += 1 }
                tokens += dayTokens
                cost += bucketCost(b)
                requests += bucketRequests(b)
                if let b {
                    for (k, v) in b.byProvider where v > 0 {
                        providerTotals[k, default: 0] += v
                    }
                }
            }

            return WeekSummary(
                index: colIdx,
                startDate: firstDate,
                endDate: lastDate,
                tokens: tokens,
                cost: cost,
                requests: requests,
                activeDays: activeDays,
                topProvidersText: formatTopProviders(providerTotals)
            )
        }

        let maxTokens = max(1, weeks.map(\.tokens).max() ?? 0)
        let totalTokens = weeks.reduce(0) { $0 + $1.tokens }
        let chartHeight: CGFloat = 104

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(weeks, id: \.index) { week in
                    let isHovered = hoveredIndex == week.index
                    let ratio = week.tokens > 0 ? CGFloat(week.tokens) / CGFloat(maxTokens) : 0
                    let barHeight = week.tokens > 0 ? max(6, ratio * (chartHeight - 8)) : 3

                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                week.tokens > 0
                                    ? (isHovered ? HeatmapLevel.l4.fillColor : HeatmapLevel.l3.fillColor)
                                    : HeatmapLevel.empty.fillColor
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: barHeight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(.white.opacity(isHovered ? 0.85 : 0), lineWidth: 1)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: chartHeight)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hoveredIndex = inside ? week.index : (hoveredIndex == week.index ? nil : hoveredIndex)
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(weeks, id: \.index) { week in
                    let month = calendar.component(.month, from: week.startDate)
                    let prevMonth = week.index > 0 ? calendar.component(.month, from: weeks[week.index - 1].startDate) : -1
                    let showMonth = week.index == 0 || month != prevMonth
                    Text(showMonth ? "\(month)月" : "")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            detailFooterText(
                ninetyDayWeeklyDetailText(
                    weeks: weeks,
                    hoveredWeekIdx: hoveredIndex,
                    totalTokens: totalTokens
                )
            )
        }
    }

    private func ninetyDayCumulativeView(timeline: UsageActivityTimeline) -> some View {
        let calendar = Calendar.current
        var running = 0
        var points: [CumulativePoint] = []
        points.reserveCapacity(90)

        for idx in 0..<90 {
            let bucket = timeline.ninetyDayDailyBuckets[idx]
            let delta = bucketTokens(bucket)
            let cost = bucketCost(bucket)
            running += delta
            let date = calendar.date(byAdding: .day, value: idx, to: timeline.ninetyDayStart)
                ?? timeline.ninetyDayStart.addingTimeInterval(Double(idx) * 86_400)
            points.append(
                CumulativePoint(
                    label: Self.dateFormatter.string(from: date),
                    cumulativeTokens: running,
                    deltaTokens: delta,
                    cost: cost
                )
            )
        }

        let totalTokens = points.last?.cumulativeTokens ?? 0
        let axisLabels: [String] = [0, 30, 60, 89].compactMap { idx in
            guard let date = calendar.date(byAdding: .day, value: idx, to: timeline.ninetyDayStart) else { return nil }
            return Self.shortDateFormatter.string(from: date)
        }

        return VStack(alignment: .leading, spacing: 6) {
            CumulativeAreaChart(
                points: points,
                hoveredIndex: $hoveredIndex,
                axisLabels: axisLabels
            )
            .frame(height: 118)

            detailFooterText(
                cumulativeDetailText(
                    points: points,
                    hoveredIndex: hoveredIndex,
                    emptyPrefix: "近 90 天累计",
                    totalTokens: totalTokens
                )
            )
        }
    }

    // MARK: - Helpers & Subviews

    private func statMetricRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func heatmapCell(
        size: CGFloat,
        cornerRadius: CGFloat,
        level: HeatmapLevel,
        isHovered: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(level.fillColor)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isHovered
                            ? .white.opacity(0.9)
                            : (level.needsHighlightBorder ? .white.opacity(0.28) : .clear),
                        lineWidth: isHovered ? 1.2 : 0.6
                    )
            )
            .contentShape(Rectangle())
    }

    private var legendStrip: some View {
        let levels: [HeatmapLevel] = [.empty, .l1, .l2, .l3, .l4]
        return HStack(spacing: 3) {
            Text("少")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.45))
            ForEach(0..<levels.count, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(levels[idx].fillColor)
                    .frame(width: 10, height: 10)
            }
            Text("多")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.45))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func detailFooterText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.76))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ninetyDayMonthAxis(
        columns: [[DayGridItem]],
        columnWidth: CGFloat,
        spacing: CGFloat,
        leadingOffset: CGFloat,
        calendar: Calendar
    ) -> some View {
        var rawMarks: [(col: Int, month: Int)] = []
        var lastSeenMonth = -1
        for (colIdx, col) in columns.enumerated() {
            if let firstValidDate = col.compactMap(\.date).first {
                let month = calendar.component(.month, from: firstValidDate)
                if month != lastSeenMonth {
                    rawMarks.append((colIdx, month))
                    lastSeenMonth = month
                }
            }
        }

        // 若首列仅占上月末尾几天（距下个月起跳列不足 2 列），跳过首标签避免重叠
        if rawMarks.count >= 2 && (rawMarks[1].col - rawMarks[0].col) < 2 {
            rawMarks.removeFirst()
        }

        let markMap = Dictionary(uniqueKeysWithValues: rawMarks.map { ($0.col, "\($0.month)月") })

        return HStack(spacing: spacing) {
            ForEach(0..<columns.count, id: \.self) { colIdx in
                Text(markMap[colIdx] ?? "")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: columnWidth, alignment: .leading)
            }
        }
        .padding(.leading, leadingOffset)
    }

    private func buildNinetyDayColumns(
        timeline: UsageActivityTimeline,
        calendar: Calendar
    ) -> [[DayGridItem]] {
        let startWeekday = calendar.component(.weekday, from: timeline.ninetyDayStart)
        let leadingPad = (startWeekday + 5) % 7 // Monday = 0 ... Sunday = 6

        var flat: [DayGridItem] = Array(
            repeating: DayGridItem(dayIndex: nil, date: nil, bucket: nil),
            count: leadingPad
        )

        for idx in 0..<90 {
            let date = calendar.date(byAdding: .day, value: idx, to: timeline.ninetyDayStart)
                ?? timeline.ninetyDayStart.addingTimeInterval(Double(idx) * 86_400)
            flat.append(
                DayGridItem(
                    dayIndex: idx,
                    date: date,
                    bucket: timeline.ninetyDayDailyBuckets[idx]
                )
            )
        }

        let remainder = flat.count % 7
        if remainder != 0 {
            flat.append(
                contentsOf: Array(
                    repeating: DayGridItem(dayIndex: nil, date: nil, bucket: nil),
                    count: 7 - remainder
                )
            )
        }

        return stride(from: 0, to: flat.count, by: 7).map { start in
            Array(flat[start..<min(start + 7, flat.count)])
        }
    }

    private func computeCurrentStreak(dailyValues: [Int]) -> Int {
        guard !dailyValues.isEmpty else { return 0 }
        var idx = dailyValues.count - 1
        // 若今天尚无请求但昨天有，允许从昨天起算连续天数；若昨天也无则连续天数为 0
        if dailyValues[idx] == 0 {
            idx -= 1
        }
        var streak = 0
        while idx >= 0 && dailyValues[idx] > 0 {
            streak += 1
            idx -= 1
        }
        return streak
    }

    private func currentTodayTenMinuteSlot(todayStart: Date) -> Int {
        let elapsed = Date().timeIntervalSince(todayStart)
        if elapsed < 0 { return 0 }
        return min(143, max(0, Int(elapsed / 600.0)))
    }

    private func bucketTokens(_ bucket: ActivityBucket?) -> Int {
        bucket?.tokens(for: selectedProvider) ?? 0
    }

    private func bucketCost(_ bucket: ActivityBucket?) -> Double {
        bucket?.cost(for: selectedProvider) ?? 0.0
    }

    private func bucketRequests(_ bucket: ActivityBucket?) -> Int {
        bucket?.requests(for: selectedProvider) ?? 0
    }

    private func heatmapLevel(
        tokens: Int,
        isFuture: Bool,
        maxTokens: Int,
        minPositive: Int
    ) -> HeatmapLevel {
        if isFuture { return .future }
        guard tokens > 0, maxTokens > 0 else { return .empty }
        if maxTokens == minPositive { return .l3 }
        let ratio = log1p(Double(tokens)) / log1p(Double(maxTokens))
        switch ratio {
        case ..<0.28: return .l1
        case ..<0.55: return .l2
        case ..<0.82: return .l3
        default: return .l4
        }
    }

    private func formatTopProviders(_ byProvider: [String: Int]) -> String? {
        guard selectedProvider == nil, !byProvider.isEmpty else { return nil }
        let sorted = byProvider
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(2)
        let parts: [String] = sorted.compactMap { raw, val in
            guard let provider = TrackedProvider(rawValue: raw) else { return nil }
            return "\(provider.shortName) \(NumberFormatterUtil.formatCompact(val))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Detail Text Builders

    private func todaySlotDetailText(
        timeline: UsageActivityTimeline,
        hoveredSlot: Int?,
        nowSlot: Int,
        totalToday: Int
    ) -> String {
        if let slot = hoveredSlot {
            let startMin = slot * 10
            let endMin = startMin + 10
            let rangeText = String(
                format: "%02d:%02d–%02d:%02d",
                startMin / 60, startMin % 60,
                endMin / 60, endMin % 60
            )
            if slot > nowSlot {
                return "\(rangeText) · 尚未到来"
            }
            let bucket = timeline.todayTenMinuteBuckets[slot]
            let tokens = bucketTokens(bucket)
            guard tokens > 0 else {
                return "\(rangeText) · 无本机活动"
            }
            let reqs = bucketRequests(bucket)
            var parts = [rangeText, "\(NumberFormatterUtil.formatCompact(tokens)) Tokens"]
            if showEstimatedCost {
                parts.append(NumberFormatterUtil.formatCurrency(bucketCost(bucket)))
            }
            if reqs > 0 {
                parts.append("\(reqs) 次请求")
            }
            if let bucket, let top = formatTopProviders(bucket.byProvider) {
                parts.append(top)
            }
            return parts.joined(separator: " · ")
        }

        if totalToday == 0 {
            return "当前暂无本机会话记录 · 悬停方格查看每 10 分钟分布"
        }
        return "每格代表 10 分钟 · 今日累计 \(NumberFormatterUtil.formatCompact(totalToday)) Tokens · 悬停查看详情"
    }

    private func todayHourlyDetailText(
        hourlyData: [(hour: Int, tokens: Int, cost: Double, requests: Int, topProviders: String?)],
        hoveredHour: Int?,
        totalToday: Int
    ) -> String {
        if let h = hoveredHour, hourlyData.indices.contains(h) {
            let item = hourlyData[h]
            let rangeText = String(format: "%02d:00–%02d:59", h, h)
            guard item.tokens > 0 else {
                return "\(rangeText) · 无本机活动"
            }
            var parts = [rangeText, "\(NumberFormatterUtil.formatCompact(item.tokens)) Tokens"]
            if showEstimatedCost {
                parts.append(NumberFormatterUtil.formatCurrency(item.cost))
            }
            if item.requests > 0 {
                parts.append("\(item.requests) 次请求")
            }
            if let top = item.topProviders {
                parts.append(top)
            }
            return parts.joined(separator: " · ")
        }
        if totalToday == 0 {
            return "当前暂无本机会话记录"
        }
        return "按小时统计 · 今日累计 \(NumberFormatterUtil.formatCompact(totalToday)) Tokens · 悬停柱状查看详情"
    }

    private func ninetyDayDailyDetailText(
        timeline: UsageActivityTimeline,
        hoveredDayIdx: Int?,
        totalTokens: Int,
        activeDays: Int,
        calendar: Calendar
    ) -> String {
        if let idx = hoveredDayIdx, (0..<90).contains(idx) {
            let date = calendar.date(byAdding: .day, value: idx, to: timeline.ninetyDayStart)
                ?? timeline.ninetyDayStart.addingTimeInterval(Double(idx) * 86_400)
            let weekdayIdx = max(0, min(6, calendar.component(.weekday, from: date) - 1))
            let dateStr = "\(Self.dateFormatter.string(from: date)) (周\(Self.weekdayLabels[weekdayIdx]))"
            let bucket = timeline.ninetyDayDailyBuckets[idx]
            let tokens = bucketTokens(bucket)
            guard tokens > 0 else {
                return "\(dateStr) · 无本机活动"
            }
            let reqs = bucketRequests(bucket)
            var parts = [dateStr, "\(NumberFormatterUtil.formatCompact(tokens)) Tokens"]
            if showEstimatedCost {
                parts.append(NumberFormatterUtil.formatCurrency(bucketCost(bucket)))
            }
            if reqs > 0 {
                parts.append("\(reqs) 次请求")
            }
            if let bucket, let top = formatTopProviders(bucket.byProvider) {
                parts.append(top)
            }
            return parts.joined(separator: " · ")
        }

        if totalTokens == 0 {
            return "当前暂无本机会话记录 · 悬停方格查看每日消耗"
        }
        return "近 90 天本机共活跃 \(activeDays) 天 · 累计 \(NumberFormatterUtil.formatCompact(totalTokens)) Tokens · 悬停查看详情"
    }

    private func ninetyDayWeeklyDetailText(
        weeks: [WeekSummary],
        hoveredWeekIdx: Int?,
        totalTokens: Int
    ) -> String {
        if let idx = hoveredWeekIdx, weeks.indices.contains(idx) {
            let w = weeks[idx]
            let range = "\(Self.shortDateFormatter.string(from: w.startDate))–\(Self.shortDateFormatter.string(from: w.endDate))"
            guard w.tokens > 0 else {
                return "\(range) · 无本机活动"
            }
            var parts = [range, "\(NumberFormatterUtil.formatCompact(w.tokens)) Tokens"]
            if showEstimatedCost {
                parts.append(NumberFormatterUtil.formatCurrency(w.cost))
            }
            parts.append("活跃 \(w.activeDays) 天")
            if let top = w.topProvidersText {
                parts.append(top)
            }
            return parts.joined(separator: " · ")
        }
        if totalTokens == 0 {
            return "当前暂无本机会话记录"
        }
        return "按周统计（共 \(weeks.count) 周）· 累计 \(NumberFormatterUtil.formatCompact(totalTokens)) Tokens · 悬停查看详情"
    }

    private func cumulativeDetailText(
        points: [CumulativePoint],
        hoveredIndex: Int?,
        emptyPrefix: String,
        totalTokens: Int
    ) -> String {
        if let idx = hoveredIndex, points.indices.contains(idx) {
            let pt = points[idx]
            var parts = [
                pt.label,
                "累计 \(NumberFormatterUtil.formatCompact(pt.cumulativeTokens)) Tokens"
            ]
            if pt.deltaTokens > 0 {
                parts.append("时段 +\(NumberFormatterUtil.formatCompact(pt.deltaTokens))")
            }
            if showEstimatedCost && pt.cost > 0 {
                parts.append(NumberFormatterUtil.formatCurrency(pt.cost))
            }
            return parts.joined(separator: " · ")
        }
        if totalTokens == 0 {
            return "当前暂无本机会话记录"
        }
        return "\(emptyPrefix) \(NumberFormatterUtil.formatCompact(totalTokens)) Tokens · 移动鼠标查看累计曲线"
    }
}

// MARK: - Cumulative Area Chart

private struct CumulativeAreaChart: View {
    let points: [CumulativePoint]
    @Binding var hoveredIndex: Int?
    let axisLabels: [String]

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let height = max(1, geo.size.height)
                let maxVal = max(1, points.map(\.cumulativeTokens).max() ?? 1)
                let coords = pointCoordinates(width: width, height: height, maxVal: maxVal)

                ZStack(alignment: .topLeading) {
                    // 水平辅助参考线
                    ForEach([0.25, 0.5, 0.75], id: \.self) { ratio in
                        Path { path in
                            let y = height * (1 - ratio)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: width, y: y))
                        }
                        .stroke(.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    }

                    if coords.count >= 2 {
                        Path { path in
                            path.move(to: CGPoint(x: coords[0].x, y: height))
                            for pt in coords {
                                path.addLine(to: pt)
                            }
                            path.addLine(to: CGPoint(x: coords.last!.x, y: height))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(.sRGB, red: 0.25, green: 0.68, blue: 1.00).opacity(0.36),
                                    Color(.sRGB, red: 0.19, green: 0.50, blue: 0.86).opacity(0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        Path { path in
                            path.move(to: coords[0])
                            for pt in coords.dropFirst() {
                                path.addLine(to: pt)
                            }
                        }
                        .stroke(
                            Color(.sRGB, red: 0.48, green: 0.87, blue: 1.00),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )
                    } else if let only = coords.first {
                        Circle()
                            .fill(Color(.sRGB, red: 0.48, green: 0.87, blue: 1.00))
                            .frame(width: 6, height: 6)
                            .position(only)
                    }

                    if let idx = hoveredIndex, coords.indices.contains(idx) {
                        let pt = coords[idx]
                        Path { path in
                            path.move(to: CGPoint(x: pt.x, y: 0))
                            path.addLine(to: CGPoint(x: pt.x, y: height))
                        }
                        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))

                        Circle()
                            .fill(Color(.sRGB, red: 0.48, green: 0.87, blue: 1.00))
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .position(pt)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard !points.isEmpty else {
                            hoveredIndex = nil
                            return
                        }
                        if points.count == 1 {
                            hoveredIndex = 0
                        } else {
                            let ratio = min(1, max(0, location.x / width))
                            hoveredIndex = Int((ratio * CGFloat(points.count - 1)).rounded())
                        }
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }

            HStack {
                ForEach(Array(axisLabels.enumerated()), id: \.offset) { idx, label in
                    if idx > 0 {
                        Spacer(minLength: 0)
                    }
                    Text(label)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
        }
    }

    private func pointCoordinates(width: CGFloat, height: CGFloat, maxVal: Int) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        let topPad: CGFloat = 6
        let usableHeight = max(1, height - topPad)
        if points.count == 1 {
            let y = height - CGFloat(points[0].cumulativeTokens) / CGFloat(maxVal) * usableHeight
            return [CGPoint(x: width / 2, y: y)]
        }
        return points.enumerated().map { idx, pt in
            let x = width * CGFloat(idx) / CGFloat(points.count - 1)
            let y = height - CGFloat(pt.cumulativeTokens) / CGFloat(maxVal) * usableHeight
            return CGPoint(x: x, y: y)
        }
    }
}
