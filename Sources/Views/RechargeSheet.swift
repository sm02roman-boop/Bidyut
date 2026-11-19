import SwiftUI
import UIKit

/// The recharge errand, without leaving for a notepad.
///
/// Recharging means getting the customer number into bKash, Nagad or a USSD
/// menu. Typing eight digits from memory into a payment app is where mistakes
/// happen, so this screen copies it, offers the dial codes, and — the part that
/// actually rescues a bad day — keeps the last token to hand.
struct RechargeSheet: View {
    let meter: Meter
    let plan: RechargePlanner.Plan?

    @Environment(\.dismiss) private var dismiss
    @State private var copied: CopyTarget?
    @State private var amount: Double

    init(meter: Meter, plan: RechargePlanner.Plan?) {
        self.meter = meter
        self.plan = plan
        _amount = State(initialValue: plan?.suggested ?? 500)
    }

    private enum CopyTarget: Equatable { case customer, token, amount }

    private var lastToken: Recharge? {
        meter.recharges
            .filter { $0.isSuccessful && !$0.token.isEmpty }
            .max { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    amountCard
                    customerNumberCard
                    walletCard
                    if let lastToken { tokenCard(lastToken) }
                    helpCard
                }
                .padding(16)
            }
            .background(Theme.pageBackground)
            .navigationTitle(L10n.recharge)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                }
            }
        }
    }

    // MARK: - Amount

    private var amountCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.rechargeSuggestion)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Formatters.takaShort(amount))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    if let units = plan?.unitsBought {
                        Text("≈ \(BengaliDigits.localize("\(Int(units))")) \(L10n.callAttention("units", "ইউনিট"))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Round amounts, because that is how recharges are actually made.
                HStack(spacing: 8) {
                    ForEach([500.0, 1_000, 2_000, 3_000], id: \.self) { value in
                        Button {
                            withAnimation(.snappy) { amount = value }
                        } label: {
                            Text(Formatters.takaShort(value))
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    amount == value ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let plan, plan.isFirstOfMonth, plan.fixedChargesDue > 0 {
                    Label(
                        L10n.callAttention(
                            "First recharge this month — \(Formatters.takaShort(plan.fixedChargesDue)) of meter rent and demand charge comes out of it.",
                            "এই মাসের প্রথম রিচার্জ — এখান থেকে \(Formatters.takaShort(plan.fixedChargesDue)) মিটার ভাড়া ও ডিমান্ড চার্জ কাটা যাবে।"
                        ),
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Customer number

    private var customerNumberCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.customerNumber)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(BengaliDigits.localize(meter.customerNumber))
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    copyButton(meter.customerNumber, target: .customer)
                }

                Text(L10n.callAttention(
                    "Copy this, then paste it into the payment app — it is the number every wallet asks for.",
                    "এটা কপি করে পেমেন্ট অ্যাপে পেস্ট করুন — সব ওয়ালেট এই নম্বরটাই চায়।"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Wallets

    /// Opens a wallet app when its scheme is installed, and otherwise sends the
    /// user somewhere real.
    ///
    /// Neither bKash nor Nagad publishes a documented URL scheme, so these are
    /// best-effort: `canOpenURL` decides, and the USSD code — which is published
    /// and always works — is offered alongside rather than hidden behind a
    /// button that may do nothing.
    private var walletCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.callAttention("Pay with", "যেভাবে দিবেন"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    walletButton(
                        name: "bKash",
                        schemes: ["bkash://", "bKash://"],
                        fallback: "https://www.bkash.com/en/products-services/electricity-paybill",
                        ussd: "*247#"
                    )
                    walletButton(
                        name: "Nagad",
                        schemes: ["nagad://", "com.konasl.nagad://"],
                        fallback: "https://apps.apple.com/app/nagad/id1471844924",
                        ussd: "*167#"
                    )
                }

                Text(L10n.callAttention(
                    "The month's first electricity payment is free on bKash. The token arrives by SMS a few moments later.",
                    "মাসের প্রথম বিদ্যুৎ পেমেন্টে bKash চার্জ নেয় না। টোকেন কিছুক্ষণ পর SMS-এ আসবে।"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func walletButton(name: String, schemes: [String], fallback: String, ussd: String) -> some View {
        VStack(spacing: 8) {
            Button {
                openWallet(schemes: schemes, fallback: fallback)
            } label: {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                dial(ussd)
            } label: {
                Text(ussd)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func openWallet(schemes: [String], fallback: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        for scheme in schemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        if let url = URL(string: fallback) {
            UIApplication.shared.open(url)
        }
    }

    /// `#` has to be percent-encoded or the dialler drops everything after it.
    private func dial(_ code: String) {
        let encoded = code.replacingOccurrences(of: "#", with: "%23")
        guard let url = URL(string: "tel://\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Token

    /// The rescue card.
    ///
    /// When a recharge reports success but the meter balance has not moved, the
    /// fix is to key the 20-digit token into the meter by hand. The app already
    /// holds that token, so it is grouped into fours here to be read aloud or
    /// typed without losing your place.
    private func tokenCard(_ recharge: Recharge) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.callAttention("Last token", "সর্বশেষ টোকেন"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatters.dayMonth(recharge.date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(BengaliDigits.localize(grouped(recharge.token)))
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack {
                    Text(L10n.callAttention(
                        "If a recharge succeeded but the meter did not update, key this into the meter and press Enter.",
                        "রিচার্জ সফল হলেও মিটারে টাকা না উঠলে এই টোকেন মিটারে লিখে Enter চাপুন।"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    copyButton(recharge.token, target: .token)
                }
            }
        }
    }

    /// Twenty digits in groups of four, which is how the meter's own display
    /// and the SMS both present them.
    private func grouped(_ token: String) -> String {
        let digits = token.filter(\.isNumber)
        return stride(from: 0, to: digits.count, by: 4).map { offset in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            let end = digits.index(start, offsetBy: min(4, digits.count - offset))
            return String(digits[start..<end])
        }
        .joined(separator: "-")
    }

    // MARK: - Help

    private var helpCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.callAttention("Something wrong?", "সমস্যা হয়েছে?"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button {
                    if let url = URL(string: "tel://16603") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(L10n.callNesco, systemImage: "phone.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Text(L10n.callAttention(
                    "Money taken but the recharge shows as failed, or the token never arrived — that is what the hotline is for. complain@nesco.gov.bd also works.",
                    "টাকা কেটেছে কিন্তু রিচার্জ ব্যর্থ দেখাচ্ছে, বা টোকেন আসেনি — এই হটলাইনেই জানাতে হবে। complain@nesco.gov.bd-তেও লেখা যায়।"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Copy

    private func copyButton(_ value: String, target: CopyTarget) -> some View {
        Button {
            UIPasteboard.general.string = value
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { copied = target }

            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) { if copied == target { copied = nil } }
            }
        } label: {
            Label(
                copied == target ? L10n.copied : L10n.copy,
                systemImage: copied == target ? "checkmark" : "doc.on.doc"
            )
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                (copied == target ? Theme.Status.healthy.color : Theme.accent).opacity(0.16),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}
