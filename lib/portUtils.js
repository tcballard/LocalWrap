'use strict';

const net = require('net');

const MIN_PROJECT_PORT = 1000;
const MAX_PROJECT_PORT = 65535;

function parsePort(value) {
  if (typeof value === 'number' && Number.isInteger(value)) {
    return value;
  }

  if (typeof value === 'string' && /^\d+$/.test(value.trim())) {
    return Number(value.trim());
  }

  return NaN;
}

function isValidProjectPort(value) {
  const port = parsePort(value);
  return port >= MIN_PROJECT_PORT && port <= MAX_PROJECT_PORT;
}

function normalizeProjectPort(value, fallback = 3000) {
  const port = parsePort(value);
  if (isValidProjectPort(port)) {
    return port;
  }

  const fallbackPort = parsePort(fallback);
  if (isValidProjectPort(fallbackPort)) {
    return fallbackPort;
  }

  return 3000;
}

function checkPortAvailable(port, host = '127.0.0.1') {
  const targetPort = parsePort(port);
  if (!isValidProjectPort(targetPort)) {
    return Promise.resolve(false);
  }

  return new Promise((resolve) => {
    const server = net.createServer();
    let settled = false;

    const finish = (available) => {
      if (settled) return;
      settled = true;
      resolve(available);
    };

    server.once('error', () => finish(false));
    server.listen(targetPort, host, () => {
      server.once('close', () => finish(true));
      server.close();
    });
  });
}

async function findAvailablePort(preferred, options = {}) {
  const scanLimit = Number.isInteger(options.scanLimit) ? options.scanLimit : 100;
  const host = options.host || '127.0.0.1';
  const checker = options.checkPortAvailable || checkPortAvailable;
  let candidate = normalizeProjectPort(preferred);

  for (let checked = 0; checked < scanLimit && candidate <= MAX_PROJECT_PORT; checked += 1) {
    if (await checker(candidate, host)) {
      return candidate;
    }
    candidate += 1;
  }

  throw new Error('No available project port found.');
}

module.exports = {
  MIN_PROJECT_PORT,
  MAX_PROJECT_PORT,
  parsePort,
  isValidProjectPort,
  normalizeProjectPort,
  checkPortAvailable,
  findAvailablePort,
};
