'use strict';

/**
 * Server tests. Run with `node test.js` — no test framework, no dependencies.
 *
 * The parsers are pinned to the real shapes the portal returns, and the hourly
 * aggregation to the arithmetic it is supposed to perform. Between them they
 * cover everything that silently produces wrong numbers rather than crashing.
 */

const assert = require('node:assert');
const { parsePanel, parseMonthly, extractCsrfToken } = require('./nesco');
const { hourlyUsage, dailyProfile, parsePortalDate } = require('./store');

let passed = 0;
const test = (name, fn) => {
  try {
    fn();
    passed += 1;
    console.log('  ok  ', name);
  } catch (error) {
    console.error('  FAIL', name, '\n       ', error.message);
    process.exitCode = 1;
  }
};

console.log('\nCSRF');
test('reads the meta tag', () => {
  assert.equal(extractCsrfToken('<meta name="csrf-token" content="AjRYKMY9y2Qv">'), 'AjRYKMY9y2Qv');
});
test('reads the hidden input', () => {
  assert.equal(extractCsrfToken('<input name="_token" value="XyZ789">'), 'XyZ789');
});

console.log('\nPanel');
const INFO = ['MD X', '', 'ADDR', '017', 'S&D', 'FEEDER-7', '12345678',
  '05035014311', '2', 'LT-A', '1P Keypad', 'Active', '12/03/2022', '105', '229.97'];
const PANEL = `<div id="con_info_div">
${INFO.map((v) => `<input value="${v}">`).join('')}
</div><div>consumerRechargeData</div>
<tr><td>1</td><td></td><td><a data-totalamount="500" data-purchaseamount="354.36"
 data-purchaseenergy="73.36" data-rent="40" data-demandcharge="84" data-tax="23.81"
 data-token="1234567890123456" data-purchasedate="03-NOV-2026 2:22 PM"
 data-salename="NAGAD">x</a></td>
<td>0</td><td>73.36</td><td>NAGAD</td><td>03-NOV-2026 2:22 PM</td><td>Success</td></tr>`;

test('balance is the fifteenth input', () => {
  assert.equal(parsePanel(PANEL).info.balance, '229.97');
});
test('identity fields land in the right slots', () => {
  const { info } = parsePanel(PANEL);
  assert.equal(info.consumerNo, '12345678');
  assert.equal(info.meterNo, '05035014311');
  assert.equal(info.meterType, '1P Keypad');
});
test('recharge row and its deductions', () => {
  const [r] = parsePanel(PANEL).recharges;
  assert.equal(r.totalAmount, 500);
  assert.equal(r.electricityAmount, 354.36);
  assert.equal(r.meterRent, 40);
  assert.equal(r.demandCharge, 84);
});
test('status comes from the row last cell', () => {
  assert.equal(parsePanel(PANEL).recharges[0].status, 'Success');
});

console.log('\nMonthly table');
const HEADERS = ['বছর', 'মাস', 'সর্বমোট রিচার্জ (টাকা)', 'রেয়াত (টাকা)',
  'ব্যবহৃত বিদ্যুৎ (টাকা)', 'মিটার রেন্ট (টাকা)', 'ডিমান্ড চার্জ (টাকা)',
  'পিএফসি চার্জ (টাকা)', 'পরিশোধিত বকেয়া/জরিমানা (টাকা)', 'ভ্যাট (টাকা)',
  'সর্বমোট ব্যবহার/কর্তন (টাকা)', 'মাস শেষে মিটার ব্যালেন্স (টাকা)',
  'ব্যবহৃত বিদ্যুৎ (কি.ও.আ.)'];
const ROW = ['2026', 'October', '3790', '-17.76', '3614.77', '40', '84',
  '0', '0', '180.48', '3919.25', '127.9', '419.039'];
const TABLE = `<table><thead><tr>${HEADERS.map((h) => `<th>${h}</th>`).join('')}</tr></thead>` +
  `<tbody><tr>${ROW.map((c) => `<td>${c}</td>`).join('')}</tr></tbody></table>`;

test('picks consumption taka, not the recharge total', () => {
  const [m] = parseMonthly(TABLE);
  assert.equal(m.electricityTaka, 3614.77);
  assert.equal(m.totalRecharge, 3790);
});
test('reads units and closing balance', () => {
  const [m] = parseMonthly(TABLE);
  assert.equal(m.month, '2026-10');
  assert.equal(m.unit, 419.039);
  assert.equal(m.endBalance, 127.9);
});
test('matches the rebate column across Bengali encodings', () => {
  // রেয়াত contains য়, which has two valid encodings that compare unequal.
  assert.equal(parseMonthly(TABLE)[0].rebate, -17.76);
});

console.log('\nDates');
test('portal format, Dhaka time', () => {
  const parsed = parsePortalDate('03-NOV-2026 2:22 PM');
  assert.equal(new Date(parsed).toISOString(), '2026-11-03T08:22:00.000Z');
});
test('midnight hour handled', () => {
  const parsed = parsePortalDate('19-NOV-2026 12:30 AM');
  assert.equal(new Date(parsed).toISOString(), '2026-11-18T18:30:00.000Z');
});

console.log('\nHourly usage');
const BASE = Date.UTC(2026, 10, 19, 0, 0, 0);
const YEAR = { hours: 24 * 365 };

test('steady drain becomes a flat curve', () => {
  const readings = [];
  for (let i = 0; i <= 16; i += 1) {
    readings.push({ at: new Date(BASE + i * 15 * 60000).toISOString(), balance: 1000 - i * 1.25 });
  }
  const curve = hourlyUsage(readings, [], YEAR);
  assert.equal(curve.length, 4);
  assert.ok(curve.every((c) => Math.abs(c.taka - 5) < 0.01), JSON.stringify(curve));
});

const RISE = [
  { at: new Date(BASE).toISOString(), balance: 100 },
  { at: new Date(BASE + 3600000).toISOString(), balance: 1050 },
];

test('a recharge is added back before measuring use', () => {
  // 100 + 1000 credited − 1050 = 50 consumed.
  const curve = hourlyUsage(RISE, [
    { date: '19-NOV-2026 6:30 AM', electricityAmount: 1000, status: 'Success' },
  ], YEAR);
  assert.equal(curve.length, 1);
  assert.ok(Math.abs(curve[0].taka - 50) < 0.01, JSON.stringify(curve));
});

test('a failed recharge is not credited', () => {
  const curve = hourlyUsage(RISE, [
    { date: '19-NOV-2026 6:30 AM', electricityAmount: 1000, status: 'Failed' },
  ], YEAR);
  assert.equal(curve.length, 0, 'an unexplained rise must be discarded');
});

test('an unexplained rise is discarded', () => {
  assert.equal(hourlyUsage(RISE, [], YEAR).length, 0);
});

test('a long gap is not treated as a measurement', () => {
  const gap = [
    { at: new Date(BASE).toISOString(), balance: 1000 },
    { at: new Date(BASE + 12 * 3600000).toISOString(), balance: 940 },
  ];
  assert.equal(hourlyUsage(gap, [], YEAR).length, 0);
});

console.log('\nDaily profile');
test('buckets by Dhaka hour', () => {
  const readings = [];
  for (let i = 0; i <= 16; i += 1) {
    readings.push({ at: new Date(BASE + i * 15 * 60000).toISOString(), balance: 1000 - i * 1.25 });
  }
  const profile = dailyProfile(hourlyUsage(readings, [], YEAR));
  assert.equal(profile.length, 24);
  // 00:00 UTC is 06:00 in Dhaka.
  assert.equal(profile[6].samples, 1);
  assert.equal(profile[6].taka, 5);
});

console.log(`\n${passed} passed\n`);
