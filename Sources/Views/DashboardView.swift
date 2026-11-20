import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Meter.createdAt) private var meters: [Meter]

    @State private var selectedID: PersistentIdentifier?
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var showingAddMeter = false
    @State private var showingSettings = false
    @State private var showingRecharge = false

    private var selectedMeter: Meter? {
        if let selectedID, let match = meters.first(where: { $0.persistentModelID == selectedID }) {
            return match
        }
        return meters.first { $0.isPrimary } ?? meters.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let meter = selectedMeter {
                    content(for: meter)
                } else {
                    ContentUnavailableView("No meter yet", systemImage: "bolt.horizontal")
                }
            }
            .background { Theme.GlassBackdrop() }
            .navigationTitle(selectedMeter?.displayName ?? "Bidyut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .refreshable { await sync() }
            .sheet(isPresented: $showingAddMeter) { AddMeterView(isOnboarding: false) }
            .sheet(isPresented: $showingSettings) {
                if let meter = selectedMeter { MeterSettingsView(meter: meter) }
            }
            .sheet(isPresented: $showingRecharge) {
                if let meter = selectedMeter {
                    let summary = ConsumptionAnalytics.summarize(meter: meter)
                    let estimate = UsageEstimator.estimate(meter: meter, summary: summary)
                    RechargeSheet(
                        meter: meter,
                        plan: RechargePlanner.plan(meter: meter, summary: summary, estimate: estimate)
                    )
                    .presentationDetents([.large])
                }
            }
            .task(id: selectedMeter?.persistentModelID) { await syncIfStale() }
            .alert("Sync failed", isPresented: .constant(syncError != nil)) {
                Button("OK") { syncError = nil }
            } message: {
                Text(syncError ?? "")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for meter: Meter) -> some View {
        let summary = ConsumptionAnalytics.summarize(meter: meter)
        let estimate = UsageEstimator.estimate(meter: meter, summary: summary)
        let projection = RechargePlanner.projectMonth(meter: meter, estimate: estimate)

        VStack(spacing: 14) {
            BalanceHeroCard(meter: meter, summary: summary, isSyncing: isSyncing)

            // The errand the balance usually sends you on, one tap from the
            // number that prompted it.
            Button {
                showingRecharge = true
            } label: {
                Label(L10n.recharge, systemImage: "bolt.badge.clock.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        summary.isRunningLow ? Theme.Status.critical.color : Theme.accent,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if estimate.averageWatts != nil {
                LiveUsageCard(estimate: estimate)
            }

            // A change in usage is only useful while something can still be
            // done about it, so it sits high rather than buried in a chart.
            if let anomaly = AnomalyDetector.detect(meter: meter) {
                AnomalyCard(anomaly: anomaly)
            }

            ForecastCard(summary: summary)

            // When the power actually stops matters more than when the balance
            // reaches zero, because Friendly Hour usually sits in between.
            if let prediction = SupplyPredictor.predict(
                balance: summary.currentBalance ?? 0,
                dailyBurn: summary.dailyBurn ?? 0
            ) {
                SupplyPredictionCard(prediction: prediction, meterType: meter.meterType)
            }

            if let projection {
                SlabProgressCard(projection: projection)
            }

            if let plan = RechargePlanner.plan(meter: meter, summary: summary, estimate: estimate) {
                RechargeAdviceCard(plan: plan, minimumRecharge: meter.minimumRecharge)
            }

            ApplianceCostCard(monthToDateUnits: projection?.monthToDateUnits ?? 0)

            BalanceTrendChart(meter: meter)

            DailySpendChart(meter: meter)

            if !meter.monthlyUsage.isEmpty {
                MonthlyUsageChart(meter: meter)
            }

            BillAuditCard(audits: BillAuditor.audit(meter: meter))

            RechargeSummaryCard(meter: meter, summary: summary)

            NavigationLink {
                RechargeHistoryView(meter: meter)
            } label: {
                HStack {
                    Label("Recharge history", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Text("\(meter.recharges.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)

            MeterDetailsCard(meter: meter)

            Text("Data from the NESCO customer portal. Daily figures are estimated by this app — NESCO publishes consumption monthly only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if meters.count > 1 {
                Menu {
                    ForEach(meters) { meter in
                        Button {
                            selectedID = meter.persistentModelID
                        } label: {
                            Label(meter.displayName, systemImage: meter.persistentModelID == selectedMeter?.persistentModelID ? "checkmark" : "bolt")
                        }
                    }
                    Divider()
                    Button("Add meter", systemImage: "plus") { showingAddMeter = true }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            } else {
                Button("Add meter", systemImage: "plus") { showingAddMeter = true }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await sync() }
            } label: {
                if isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isSyncing)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                .disabled(selectedMeter == nil)
        }
    }

    // MARK: - Syncing

    /// Refreshes on open when the last reading is more than an hour old, so the
    /// dashboard is current without hammering the portal on every launch.
    private func syncIfStale() async {
        guard let meter = selectedMeter else { return }

        // A tap on the widget's refresh button opened this; honour it whatever
        // the cached figure's age.
        if SharedStore.consumeRefreshRequest() {
            await sync()
            return
        }

        let age = meter.lastSyncedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 3_600 else { return }
        await sync()
    }

    private func sync() async {
        guard let meter = selectedMeter, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let service = SyncService(context: context)
            try await service.sync(meter: meter)
            let summary = ConsumptionAnalytics.summarize(meter: meter)
            await NotificationService.refreshAlerts(for: meter, summary: summary)
            syncError = nil
        } catch {
            let nesco = error as? NescoError
            syncError = [nesco?.errorDescription ?? error.localizedDescription, nesco?.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }
    }
}

// MARK: - Hero

struct BalanceHeroCard: View {
    let meter: Meter
    let summary: ConsumptionAnalytics.Summary
    let isSyncing: Bool

    private var status: Theme.Status {
        .from(daysRemaining: summary.daysRemaining, balance: summary.currentBalance)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: status.symbol)
                Text(status.label)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(status.color.opacity(0.14), in: Capsule())

            Text(Formatters.taka(summary.currentBalance))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(status.color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())

            if let balance = summary.currentBalance, balance < 0 {
                Text("Emergency balance in use")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.color)
            }

            Text("Updated \(Formatters.relative(meter.lastSyncedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if isSyncing {
                ProgressView().padding(12)
            }
        }
    }
}

// MARK: - Forecast

struct ForecastCard: View {
    let summary: ConsumptionAnalytics.Summary

    var body: some View {
        Card(title: "Forecast") {
            HStack(spacing: 12) {
                StatTile(
                    label: "Days left",
                    value: summary.daysRemaining.map { Formatters.days($0) } ?? "—",
                    caption: summary.depletionDate.map { "until \(Formatters.dayMonth($0))" }
                )
                Divider()
                StatTile(
                    label: "Daily usage",
                    value: Formatters.taka(summary.dailyBurn),
                    caption: "per day"
                )
            }

            if summary.confidence != .high {
                Label(
                    confidenceMessage,
                    systemImage: summary.confidence == .none ? "info.circle" : "clock.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    private var confidenceMessage: String {
        switch summary.confidence {
        case .none:
            return "Open the app over a few days — the forecast needs at least two readings to measure usage."
        case .low where summary.intervalCount == 0:
            return "Based on NESCO's last monthly statement. It sharpens once the app has taken a few readings of its own."
        case .low:
            return "\(summary.confidence.label) from \(Formatters.days(summary.observedDays)) of readings. It sharpens with use."
        case .medium:
            return "\(summary.confidence.label) from \(Formatters.days(summary.observedDays)) of readings."
        case .high:
            return ""
        }
    }
}

// MARK: - Recharge advice

struct RechargeAdviceCard: View {
    let plan: RechargePlanner.Plan
    let minimumRecharge: Double?

    var body: some View {
        Card(title: "Recharge suggestion") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.takaShort(plan.suggested))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                if let units = plan.unitsBought {
                    Text("≈ \(Int(units)) units")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let days = plan.coversDays {
                Text("Covers about \(Formatters.days(days)) at your current usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Worth saying out loud: the month's fixed charges come out of
            // whichever recharge happens to be first, which makes that one look
            // unexpectedly expensive.
            if plan.isFirstOfMonth, plan.fixedChargesDue > 0 {
                Label(
                    "First recharge this month, so \(Formatters.takaShort(plan.fixedChargesDue)) of meter rent and demand charge comes out of it. Later top-ups this month will not carry them again.",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                if plan.expectedRebate > 0 {
                    Label("\(Formatters.taka(plan.expectedRebate)) rebate", systemImage: "arrow.uturn.backward")
                }
                if let minimum = minimumRecharge, minimum > 0 {
                    Label("Min \(Formatters.takaShort(minimum))", systemImage: "arrow.down.to.line")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Recharge summary

struct RechargeSummaryCard: View {
    let meter: Meter
    let summary: ConsumptionAnalytics.Summary

    var body: some View {
        Card(title: "This month") {
            HStack(spacing: 12) {
                StatTile(
                    label: "Recharged",
                    value: Formatters.takaShort(summary.thisMonthRecharged),
                    caption: "so far"
                )
                Divider()
                StatTile(
                    label: "Last recharge",
                    value: summary.lastRecharge.map { Formatters.takaShort($0.totalAmount) } ?? "—",
                    caption: summary.lastRecharge.map { Formatters.dayMonth($0.date) }
                )
            }
        }
    }
}

// MARK: - Meter details

struct MeterDetailsCard: View {
    let meter: Meter

    var body: some View {
        Card(title: "Meter") {
            VStack(spacing: 8) {
                row("Customer no.", meter.customerNumber)
                if let value = meter.meterNumber { row("Meter no.", value) }
                if let value = meter.customerName { row("Name", value) }
                if let value = meter.tariff { row("Tariff", value) }
                if let value = meter.sanctionedLoad { row("Sanctioned load", value) }
                if let value = meter.office { row("Office", value) }
                if let value = meter.feeder { row("Feeder", value) }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }
}
