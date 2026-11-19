'use strict';

/**
 * The Bidyut poller.
 *
 * Reads the NESCO portal every few minutes and keeps the history the portal
 * itself does not: a balance reading every quarter hour, which differentiates
 * into an hourly usage curve. A phone cannot do this — it is asleep most of the
 * day — which is the whole reason this process exists.
 *
 * Zero dependencies: Node 18 or newer, `node server/index.js`, nothing else.
 */

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const { fetchMeter } = require('./nesco');
const { Store, hourlyUsage, dailyProfile } = require('./store');

const CONFIG_PATH = process.env.BIDYUT_CONFIG || path.join(__dirname, 'config.json');

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    console.error(`No config at ${CONFIG_PATH}. Copy config.example.json and fill it in.`);
    process.exit(1);
  }
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));

  if (!Array.isArray(config.meters) || config.meters.length === 0) {
    console.error('config.meters must list at least one customer number.');
    process.exit(1);
  }
  // The API serves one household's electricity data, so it is not left open.
  if (!config.token || config.token.length < 16) {
    console.error('config.token must be set to a random string of at least 16 characters.');
    process.exit(1);
  }
  return config;
}

const config = loadConfig();
const store = new Store(config.dataDir || path.join(__dirname, 'data'));

const POLL_MINUTES = Math.max(5, config.pollMinutes || 15);
const PORT = config.port || 8099;

// MARK: - Polling

let lastPollError = null;
let lastPollAt = null;

async function pollOnce() {
  for (const customerNo of config.meters) {
    try {
      const payload = await fetchMeter(customerNo);

      if (payload.balance != null) {
        const stored = store.appendReading(customerNo, {
          at: payload.fetchedAt,
          balance: payload.balance,
        });
        if (stored) {
          console.log(`[${payload.fetchedAt}] ${customerNo} balance ${payload.balance}`);
        }
      }

      store.saveState(customerNo, payload);
      lastPollError = null;
    } catch (error) {
      lastPollError = `${customerNo}: ${error.message}`;
      console.error(`[poll] ${lastPollError}`);
    }
  }
  lastPollAt = new Date().toISOString();
}

function schedulePolling() {
  pollOnce();
  setInterval(pollOnce, POLL_MINUTES * 60 * 1000);
}

// MARK: - API

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
  });
  res.end(payload);
}

function authorised(req) {
  const header = req.headers.authorization || '';
  return header === `Bearer ${config.token}`;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const parts = url.pathname.split('/').filter(Boolean);

  // Health needs no token so an uptime check can reach it.
  if (url.pathname === '/health') {
    return send(res, 200, {
      ok: lastPollError == null,
      lastPollAt,
      lastPollError,
      meters: config.meters.length,
      pollMinutes: POLL_MINUTES,
    });
  }

  if (!authorised(req)) {
    return send(res, 401, { error: 'unauthorised' });
  }

  // /api/meter/:customerNo
  if (parts[0] === 'api' && parts[1] === 'meter' && parts[2]) {
    const customerNo = parts[2].replace(/\D/g, '');
    if (!config.meters.includes(customerNo)) {
      return send(res, 404, { error: 'meter not configured' });
    }

    const state = store.state(customerNo);
    if (!state) return send(res, 503, { error: 'no reading yet' });

    // /api/meter/:customerNo/hourly
    if (parts[3] === 'hourly') {
      const hours = Math.min(Number(url.searchParams.get('hours')) || 168, 24 * 90);
      const since = Date.now() - hours * 3600 * 1000;
      const curve = hourlyUsage(store.readings(customerNo, since), state.recharges, { hours });
      return send(res, 200, {
        customerNo,
        hours,
        hourly: curve,
        profile: dailyProfile(curve),
      });
    }

    // /api/meter/:customerNo/readings
    if (parts[3] === 'readings') {
      const days = Math.min(Number(url.searchParams.get('days')) || 30, 365);
      return send(res, 200, {
        customerNo,
        readings: store.readings(customerNo, Date.now() - days * 86400000),
      });
    }

    return send(res, 200, {
      customerNo,
      fetchedAt: state.fetchedAt,
      balance: state.balance,
      info: state.info,
      recharges: state.recharges,
      monthly: state.monthly,
      readingCount: store.readings(customerNo).length,
    });
  }

  send(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`Bidyut poller on :${PORT}, every ${POLL_MINUTES} min, ${config.meters.length} meter(s)`);
  schedulePolling();
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
