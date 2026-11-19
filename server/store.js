'use strict';

const fs = require('node:fs');
const path = require('node:path');

/**
 * Append-only storage.
 *
 * Readings are written one JSON object per line. That makes the file trivially
 * recoverable — a truncated write loses at most the last reading, never the
 * history — and `tail`, `grep` and `wc -l` all work on it, which matters when
 * something goes wrong at 2am on a VPS.
 *
 * At 96 readings a day one meter produces well under 10 MB a year, so there is
 * no case for a database here.
 */
class Store {
  constructor(dataDir) {
    this.dataDir = dataDir;
    fs.mkdirSync(dataDir, { recursive: true });
  }

  readingsPath(customerNo) {
    return path.join(this.dataDir, `${customerNo}.readings.jsonl`);
  }

  statePath(customerNo) {
    return path.join(this.dataDir, `${customerNo}.state.json`);
  }

  /**
   * Records a reading, skipping one that says nothing new.
   *
   * The meter's balance only moves every so often, so storing an identical
   * figure would pad the history and flatten any rate computed from it.
   */
  appendReading(customerNo, reading) {
    const previous = this.latestReading(customerNo);
    if (previous && Math.abs(previous.balance - reading.balance) < 0.005) {
      return false;
    }
    fs.appendFileSync(
      this.readingsPath(customerNo),
      JSON.stringify({ at: reading.at, balance: reading.balance }) + '\n'
    );
    return true;
  }

  readings(customerNo, sinceMs = 0) {
    const file = this.readingsPath(customerNo);
    if (!fs.existsSync(file)) return [];

    return fs
      .readFileSync(file, 'utf8')
      .split('\n')
      .filter(Boolean)
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .filter((r) => r && Date.parse(r.at) >= sinceMs)
      .sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
  }

  latestReading(customerNo) {
    const all = this.readings(customerNo);
    return all.length ? all[all.length - 1] : null;
  }

  /** The full portal payload, overwritten each poll. */
  saveState(customerNo, state) {
    fs.writeFileSync(this.statePath(customerNo), JSON.stringify(state, null, 2));
  }

  state(customerNo) {
    const file = this.statePath(customerNo);
    if (!fs.existsSync(file)) return null;
    try {
      return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      return null;
    }
  }
}

/**
 * Turns balance readings into an hourly usage curve.
 *
 * Balance only falls through use and rises through recharge, so consumption
 * between two readings is `previous + credited - current`. The credited figure
 * is the electricity portion of a recharge, not the amount paid — NESCO takes
 * meter rent, demand charge and VAT off the top first.
 *
 * Each interval's consumption is then spread across the hours it covers, in
 * proportion to how much of each hour it occupies. A fifteen-minute poll makes
 * that spreading fine enough to show when a household actually uses power.
 */
function hourlyUsage(readings, recharges, { hours = 168 } = {}) {
  if (readings.length < 2) return [];

  const credits = (recharges || [])
    .filter((r) => r.status && !/fail|ব্যর্থ/i.test(r.status))
    .map((r) => ({
      at: parsePortalDate(r.date),
      amount: r.electricityAmount != null ? r.electricityAmount : r.totalAmount,
    }))
    .filter((r) => r.at && r.amount != null);

  const buckets = new Map();

  for (let i = 1; i < readings.length; i += 1) {
    const from = Date.parse(readings[i - 1].at);
    const to = Date.parse(readings[i].at);
    const spanMs = to - from;
    if (!(spanMs > 0) || spanMs > 6 * 3600 * 1000) continue; // a long gap is not a measurement

    const credited = credits
      .filter((c) => c.at > from && c.at <= to)
      .reduce((sum, c) => sum + c.amount, 0);

    const consumed = readings[i - 1].balance + credited - readings[i].balance;
    // A negative result means a recharge was missed or landed outside the
    // window; including it would drag the curve below zero.
    if (!(consumed >= 0)) continue;

    const ratePerMs = consumed / spanMs;

    let cursor = from;
    while (cursor < to) {
      const hourStart = Math.floor(cursor / 3600000) * 3600000;
      const hourEnd = hourStart + 3600000;
      const sliceEnd = Math.min(to, hourEnd);
      const key = new Date(hourStart).toISOString();

      buckets.set(key, (buckets.get(key) || 0) + ratePerMs * (sliceEnd - cursor));
      cursor = sliceEnd;
    }
  }

  const cutoff = Date.now() - hours * 3600 * 1000;
  return [...buckets]
    .filter(([hour]) => Date.parse(hour) >= cutoff)
    .map(([hour, taka]) => ({ hour, taka: Number(taka.toFixed(3)) }))
    .sort((a, b) => a.hour.localeCompare(b.hour));
}

/** Average consumption by hour of the day, in Dhaka time. */
function dailyProfile(hourly) {
  const sums = new Array(24).fill(0);
  const counts = new Array(24).fill(0);

  for (const entry of hourly) {
    // Dhaka is UTC+6 with no daylight saving, so the shift is a constant.
    const hour = (new Date(entry.hour).getUTCHours() + 6) % 24;
    sums[hour] += entry.taka;
    counts[hour] += 1;
  }

  return sums.map((total, hour) => ({
    hour,
    taka: counts[hour] ? Number((total / counts[hour]).toFixed(3)) : 0,
    samples: counts[hour],
  }));
}

/** Portal dates look like `08-NOV-2026 12:59 PM`, in Dhaka time. */
function parsePortalDate(text) {
  if (!text) return null;
  const match = String(text)
    .trim()
    .match(/^(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)?/i);
  if (!match) {
    const fallback = Date.parse(text);
    return Number.isNaN(fallback) ? null : fallback;
  }

  const months = { jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11 };
  const month = months[match[2].toLowerCase()];
  if (month === undefined) return null;

  let hour = Number(match[4]);
  const meridiem = (match[6] || '').toUpperCase();
  if (meridiem === 'PM' && hour !== 12) hour += 12;
  if (meridiem === 'AM' && hour === 12) hour = 0;

  // Dhaka is UTC+6.
  return Date.UTC(Number(match[3]), month, Number(match[1]), hour - 6, Number(match[5]));
}

module.exports = { Store, hourlyUsage, dailyProfile, parsePortalDate };
