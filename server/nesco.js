'use strict';

/**
 * NESCO customer portal client.
 *
 * The portal has no API. It renders everything server-side inside a session
 * that starts with a CSRF token and a cookie, so this replays the browser's own
 * three-step flow:
 *
 *   1. GET  /pre/panel                      -> token + session cookie
 *   2. POST /pre/panel  (রিচার্জ হিস্ট্রি)  -> customer info + recharge rows
 *   3. POST /pre/panel  (মাসিক ব্যবহার)     -> monthly consumption table
 *
 * The portal answers only from Bangladeshi networks; anywhere else returns 403.
 * Host this on a VPS inside Bangladesh, or the poller will never get a reading.
 *
 * Parsers are pure functions so they can be tested against saved fixtures. When
 * NESCO redesigns the portal, this file is the only one to fix.
 */

const PORTAL_ORIGIN = 'https://customer.nesco.gov.bd';
const PANEL_URL = `${PORTAL_ORIGIN}/pre/panel`;

// Written as escapes, not literals: the submit values must match the portal's
// own bytes, and a source file can carry Bengali in either composed form.
const SUBMIT_HISTORY = 'রিচার্জ হিস্ট্রি';
const SUBMIT_MONTHLY = 'মাসিক ব্যবহার';

const USER_AGENT =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

/** Several Bengali letters have two valid encodings; normalise before matching. */
const nfc = (s) => String(s == null ? '' : s).normalize('NFC');

const stripTags = (html) =>
  String(html || '')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/\s+/g, ' ')
    .trim();

const toNumber = (value) => {
  if (value == null || value === '') return null;
  const cleaned = String(value).replace(/,/g, '').replace(/[^\d.-]/g, '');
  if (!cleaned || cleaned === '-' || cleaned === '.') return null;
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : null;
};

function extractCsrfToken(html) {
  const patterns = [
    /name=["']_token["'][^>]*value=["']([^"']+)["']/i,
    /value=["']([^"']+)["'][^>]*name=["']_token["']/i,
    /<meta[^>]+name=["']csrf-token["'][^>]+content=["']([^"']+)["']/i,
  ];
  for (const pattern of patterns) {
    const match = String(html || '').match(pattern);
    if (match) return match[1];
  }
  return null;
}

function cookieHeaderFrom(headers) {
  const raw =
    typeof headers.getSetCookie === 'function'
      ? headers.getSetCookie()
      : [headers.get('set-cookie')].filter(Boolean);

  const jar = new Map();
  for (const entry of raw) {
    const [pair] = String(entry).split(';');
    const index = pair.indexOf('=');
    if (index > 0) jar.set(pair.slice(0, index).trim(), pair.slice(index + 1).trim());
  }
  return [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
}

/**
 * Fields inside #con_info_div are unnamed inputs read positionally. This order
 * is the portal's own, confirmed against its visible labels.
 */
const INFO_FIELDS = [
  'name', 'fatherOrHusband', 'address', 'mobile', 'office', 'feeder',
  'consumerNo', 'meterNo', 'sanctionedLoad', 'tariff', 'meterType',
  'meterStatus', 'installDate', 'minimumRecharge', 'balance',
];

function parsePanel(html) {
  const source = String(html || '');
  const info = {};

  const start = source.indexOf('id="con_info_div"');
  if (start >= 0) {
    let end = source.indexOf('consumerRechargeData', start);
    if (end < 0) end = Math.min(start + 40000, source.length);
    const segment = source.slice(start, end);

    const values = [...segment.matchAll(/<input\b[^>]*>/gi)]
      .map((m) => (m[0].match(/value\s*=\s*["']([^"']*)["']/i) || [])[1])
      .filter((v) => v !== undefined)
      .map((v) => v.trim());

    INFO_FIELDS.forEach((field, index) => {
      if (values[index]) info[field] = values[index];
    });
  }

  const attr = (tag, name) => {
    const m = tag.match(new RegExp(`data-${name}\\s*=\\s*["']([^"']*)["']`, 'i'));
    return m ? m[1].trim() : '';
  };

  // Recharge rows carry the full breakdown in data-* attributes on an <a>
  // nested in the third cell; the status is the row's last cell.
  const recharges = [];
  const rowRe = /<[^>]*?data-totalamount\s*=\s*["'][^"']*["'][^>]*>/gi;
  let row;
  while ((row = rowRe.exec(source))) {
    const tag = row[0];
    const from = row.index + tag.length;
    const window = source.slice(from, Math.min(from + 20000, source.length));
    const rowEnd = window.indexOf('</tr>');
    const cells = [...window.slice(0, rowEnd < 0 ? undefined : rowEnd)
      .matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)]
      .map((c) => stripTags(c[1]))
      .filter(Boolean);

    let status = cells.length ? cells[cells.length - 1] : '';
    if (status.length > 30) status = '';

    recharges.push({
      token: attr(tag, 'token'),
      date: attr(tag, 'purchasedate'),
      totalAmount: toNumber(attr(tag, 'totalamount')),
      electricityAmount: toNumber(attr(tag, 'purchaseamount')),
      energyUnit: toNumber(attr(tag, 'purchaseenergy')),
      meterRent: toNumber(attr(tag, 'rent')),
      demandCharge: toNumber(attr(tag, 'demandcharge')),
      vat: toNumber(attr(tag, 'tax')),
      pfc: toNumber(attr(tag, 'pfc')),
      subsidy: toNumber(attr(tag, 'subsidyamount')),
      method: attr(tag, 'salename'),
      status,
    });
  }

  return { info, recharges };
}

/**
 * Monthly table columns, matched by the distinguishing words in their headers.
 * Six of the thirteen headers end in "(টাকা)", so matching that alone picks the
 * recharge column instead of the consumption one.
 */
const MONTHLY_COLUMNS = {
  totalRecharge: /সর্বমোট\s*রিচার্জ|total\s*recharge/i,
  rebate: /রেয়াত|rebate/i,
  electricityTaka: /ব্যবহৃত\s*বিদ্যুৎ\s*\(\s*টাকা/i,
  meterRent: /মিটার\s*রেন্ট|meter\s*rent/i,
  demandCharge: /ডিমান্ড|demand/i,
  pfc: /পিএফসি|pfc/i,
  arrears: /বকেয়া|জরিমানা|arrear/i,
  vat: /ভ্যাট|vat/i,
  totalDeducted: /সর্বমোট\s*ব্যবহার|কর্তন/i,
  endBalance: /মাস\s*শেষে|closing\s*balance/i,
  unit: /কি\.ও\.আ|kwh|unit/i,
};

const MONTH_NAMES = {
  january: 1, february: 2, march: 3, april: 4, may: 5, june: 6,
  july: 7, august: 8, september: 9, october: 10, november: 11, december: 12,
};

function parseMonthly(html) {
  const tables = [...String(html || '').matchAll(/<table[\s\S]*?<\/table>/gi)].map((m) => m[0]);
  for (const table of tables) {
    const headMatch = table.match(/<thead[^>]*>([\s\S]*?)<\/thead>/i);
    if (!headMatch) continue;

    const headers = [...headMatch[1].matchAll(/<th[^>]*>([\s\S]*?)<\/th>/gi)].map((m) =>
      nfc(stripTags(m[1]))
    );

    const index = {};
    for (const [key, pattern] of Object.entries(MONTHLY_COLUMNS)) {
      const at = headers.findIndex((h) => new RegExp(nfc(pattern.source), 'i').test(h));
      if (at >= 0) index[key] = at;
    }
    if (index.unit === undefined && index.electricityTaka === undefined) continue;

    const rows = [];
    for (const match of table.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)) {
      const cells = [...match[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)].map((c) => stripTags(c[1]));
      if (cells.length < 4) continue;

      let year = null;
      let month = null;
      for (const cell of cells) {
        const trimmed = cell.trim();
        if (!year && /^(19|20)\d{2}$/.test(trimmed)) year = trimmed;
        if (!month) {
          const name = MONTH_NAMES[trimmed.toLowerCase()];
          if (name) month = String(name).padStart(2, '0');
        }
      }
      if (!year || !month) continue;

      const record = { month: `${year}-${month}` };
      for (const [key, at] of Object.entries(index)) {
        record[key] = toNumber(cells[at]);
      }
      rows.push(record);
    }

    if (rows.length) return rows.sort((a, b) => a.month.localeCompare(b.month));
  }
  return [];
}

async function startSession() {
  const response = await fetch(PANEL_URL, {
    headers: { 'User-Agent': USER_AGENT, Referer: `${PORTAL_ORIGIN}/` },
  });
  if (!response.ok) throw new Error(`portal GET failed: HTTP ${response.status}`);

  const text = await response.text();
  const token = extractCsrfToken(text);
  if (!token) throw new Error('portal returned no CSRF token — layout may have changed');

  return { token, cookie: cookieHeaderFrom(response.headers) };
}

async function submit(session, customerNo, action) {
  const body = new URLSearchParams({
    _token: session.token,
    cust_no: customerNo,
    submit: action,
  }).toString();

  const response = await fetch(PANEL_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': USER_AGENT,
      Origin: PORTAL_ORIGIN,
      Referer: PANEL_URL,
      ...(session.cookie ? { Cookie: session.cookie } : {}),
    },
    body,
  });

  if (!response.ok) throw new Error(`portal POST failed: HTTP ${response.status}`);
  return response.text();
}

/** Reads everything the portal knows about one meter. */
async function fetchMeter(customerNo) {
  const customer = String(customerNo).replace(/\D/g, '');
  if (customer.length < 5 || customer.length > 14) {
    throw new Error('customer number must be 5 to 14 digits');
  }

  const session = await startSession();
  const historyHtml = await submit(session, customer, SUBMIT_HISTORY);
  const { info, recharges } = parsePanel(historyHtml);

  if (!info.consumerNo && !info.meterNo && recharges.length === 0) {
    throw new Error('no data for that customer number');
  }

  // Monthly usage is a bonus; a failure here must not lose the balance reading.
  let monthly = [];
  try {
    monthly = parseMonthly(await submit(session, customer, SUBMIT_MONTHLY));
  } catch {
    monthly = [];
  }

  return {
    customerNo: customer,
    fetchedAt: new Date().toISOString(),
    balance: toNumber(info.balance),
    info,
    recharges,
    monthly,
  };
}

module.exports = {
  fetchMeter,
  parsePanel,
  parseMonthly,
  extractCsrfToken,
  toNumber,
  PANEL_URL,
};
