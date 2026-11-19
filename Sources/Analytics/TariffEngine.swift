import Foundation

/// The BERC residential tariff, as arithmetic.
///
/// Bangladesh bills households on a progressive slab: each band of the month's
/// units is charged at its own rate, so the unit that tips you into the next
/// band costs more than the one before it. Every distributor — NESCO included —
/// bills on this same national tariff.
///
/// Verified against meter 12345678's own statements:
///   October  419.039 units → ৳3,614.78 computed, ৳3,614.77 billed
///   September 391.039 units → ৳3,242.79 computed, ৳3,242.80 billed
///
/// The one-paisa gap is rounding. That agreement is what lets the app show a
/// projected bill rather than a guess, and what makes the slab warnings real.
enum TariffEngine {

    /// A band of monthly consumption and its price per unit.
    struct Slab: Equatable, Identifiable {
        /// First unit of the band, counted from 1.
        let from: Double
        /// Last unit of the band; `.infinity` for the top band.
        let through: Double
        let rate: Double

        var id: Double { from }

        var width: Double { through - from + 1 }

        var label: String {
            through.isInfinite ? "\(Int(from))+" : "\(Int(from))–\(Int(through))"
        }
    }

    /// Residential LT-A, BERC tariff effective June 2026.
    ///
    /// Figures confirmed against the published rate list and reproduced exactly
    /// by this meter's own bills.
    static let residentialSlabs: [Slab] = [
        Slab(from: 1, through: 75, rate: 5.26),
        Slab(from: 76, through: 200, rate: 8.50),
        Slab(from: 201, through: 300, rate: 9.10),
        Slab(from: 301, through: 400, rate: 9.62),
        Slab(from: 401, through: 600, rate: 15.01),
        Slab(from: 601, through: .infinity, rate: 17.35)
    ]

    /// A household using 50 units or fewer in the month pays this flat rate on
    /// every unit, instead of the progressive slabs above.
    static let lifelineLimit: Double = 50
    static let lifelineRate: Double = 4.63

    /// Demand charge per kilowatt of sanctioned load, once a month.
    static let demandChargePerKW: Double = 42

    /// VAT on the energy charge.
    static let vatRate: Double = 0.05

    /// The rebate NESCO applies to prepaid recharges.
    static let prepaidRebateRate: Double = 0.005

    // MARK: - Cost of units

    /// Energy charge for a whole month's consumption, before VAT and fixed charges.
    static func energyCharge(forUnits units: Double) -> Double {
        guard units > 0 else { return 0 }

        // Lifeline is a flat rate on everything, not a first band.
        if units <= lifelineLimit {
            return units * lifelineRate
        }

        var remaining = units
        var total = 0.0

        for slab in residentialSlabs {
            guard remaining > 0 else { break }
            let bandStart = slab.from - 1
            guard units > bandStart else { break }

            let inThisBand = min(units, slab.through) - bandStart
            total += inThisBand * slab.rate
            remaining -= inThisBand
        }

        return total
    }

    /// What the next unit costs at this point in the month.
    ///
    /// This is the number that should drive any "is it worth running the AC"
    /// decision — not the blended average, which is always lower.
    static func marginalRate(atUnits units: Double) -> Double {
        if units < lifelineLimit { return lifelineRate }
        let next = units + 0.0001
        return residentialSlabs.first { next <= $0.through }?.rate ?? residentialSlabs[residentialSlabs.count - 1].rate
    }

    /// The slab a given consumption level sits in.
    static func slab(atUnits units: Double) -> Slab? {
        residentialSlabs.first { units <= $0.through }
    }

    /// Units still available in the current slab before the rate steps up.
    static func unitsUntilNextSlab(atUnits units: Double) -> Double? {
        guard let current = slab(atUnits: units), !current.through.isInfinite else { return nil }
        return max(current.through - units, 0)
    }

    /// The slab boundary just below this consumption, when one has been crossed.
    static func lastCrossedBoundary(atUnits units: Double) -> Slab? {
        residentialSlabs.last { $0.from <= units && $0.from > 1 }
    }

    // MARK: - The cliff

    /// What crossing into the present slab is costing this month.
    struct CliffWarning: Equatable {
        /// Units already billed at the higher rate.
        let unitsOver: Double
        /// The boundary that was crossed, e.g. 400.
        let boundary: Double
        let previousRate: Double
        let currentRate: Double
        /// Extra taka paid versus staying under the boundary.
        let extraCost: Double

        var rateJump: Double { currentRate / previousRate - 1 }
    }

    /// Flags a crossing into a more expensive slab, with what it costs.
    ///
    /// The 400-unit boundary is the one that bites: the rate rises by more than
    /// half, so a household sitting just above it pays a disproportionate amount
    /// for those last few units.
    static func cliffWarning(atUnits units: Double) -> CliffWarning? {
        guard units > lifelineLimit,
              let current = slab(atUnits: units),
              current.from > 1,
              let index = residentialSlabs.firstIndex(of: current),
              index > 0
        else { return nil }

        let previous = residentialSlabs[index - 1]
        let boundary = previous.through
        let unitsOver = units - boundary
        guard unitsOver > 0 else { return nil }

        let extraCost = unitsOver * (current.rate - previous.rate)

        return CliffWarning(
            unitsOver: unitsOver,
            boundary: boundary,
            previousRate: previous.rate,
            currentRate: current.rate,
            extraCost: extraCost
        )
    }

    // MARK: - Full monthly bill

    struct MonthlyBill: Equatable {
        var units: Double
        var energyCharge: Double
        var meterRent: Double
        var demandCharge: Double
        var vat: Double
        var rebate: Double

        var total: Double {
            energyCharge + meterRent + demandCharge + vat - rebate
        }

        /// Blended cost per unit, which is always below the marginal rate.
        var effectiveRate: Double? {
            units > 0 ? total / units : nil
        }
    }

    /// Builds the full bill for a month's consumption.
    ///
    /// `meterRent` and `sanctionedLoadKW` come from the meter itself rather than
    /// being assumed, because they differ by connection.
    static func monthlyBill(
        units: Double,
        sanctionedLoadKW: Double,
        meterRent: Double,
        rechargedThisMonth: Double = 0
    ) -> MonthlyBill {
        let energy = energyCharge(forUnits: units)
        return MonthlyBill(
            units: units,
            energyCharge: energy,
            meterRent: meterRent,
            demandCharge: demandChargePerKW * sanctionedLoadKW,
            vat: energy * vatRate,
            rebate: rechargedThisMonth * prepaidRebateRate
        )
    }

    // MARK: - Working backwards

    /// How many units a given amount of credit buys, starting from a point in
    /// the month — the inverse of `energyCharge`, solved band by band.
    ///
    /// Used to turn a balance into "units left", correctly priced at the slabs
    /// the household is actually in rather than at an average.
    static func unitsAffordable(taka: Double, startingAtUnits start: Double = 0) -> Double {
        guard taka > 0 else { return 0 }

        var budget = taka
        var units = start

        // Below the lifeline threshold the whole month may reprice, so treat
        // this as the simple flat case.
        if start + budget / lifelineRate <= lifelineLimit {
            return budget / lifelineRate
        }

        for slab in residentialSlabs {
            guard budget > 0 else { break }
            guard units < slab.through else { continue }

            let roomInBand = slab.through - max(units, slab.from - 1)
            guard roomInBand > 0 else { continue }

            let costToFill = roomInBand * slab.rate
            if budget >= costToFill {
                budget -= costToFill
                units += roomInBand
            } else {
                units += budget / slab.rate
                budget = 0
            }
        }

        return units - start
    }

    /// Cost of running an appliance, priced at the marginal rate — what that
    /// hour of air conditioning actually adds to the bill.
    static func costOfRunning(
        watts: Double,
        hours: Double,
        monthToDateUnits: Double
    ) -> (units: Double, taka: Double) {
        let units = watts * hours / 1_000
        let rate = marginalRate(atUnits: monthToDateUnits)
        return (units, units * rate)
    }
}
