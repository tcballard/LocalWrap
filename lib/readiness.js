'use strict';

const http = require('http');
const https = require('https');
const { validateLocalProjectURL } = require('./urlValidation');

function delay(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error('Readiness check cancelled.'));
      return;
    }

    const timer = setTimeout(resolve, ms);
    if (signal) {
      signal.addEventListener(
        'abort',
        () => {
          clearTimeout(timer);
          reject(new Error('Readiness check cancelled.'));
        },
        { once: true }
      );
    }
  });
}

function probeURL(url, options = {}) {
  const timeoutMs = options.timeoutMs || 1000;
  if (!validateLocalProjectURL(url)) {
    return Promise.resolve(false);
  }

  return new Promise((resolve) => {
    const parsed = new URL(url);
    const client = parsed.protocol === 'https:' ? https : http;
    const request = client.request(
      parsed,
      {
        method: 'HEAD',
        timeout: timeoutMs,
        rejectUnauthorized: false,
      },
      (response) => {
        response.resume();
        resolve(response.statusCode < 500);
      }
    );

    request.on('timeout', () => {
      request.destroy();
      resolve(false);
    });
    request.on('error', () => resolve(false));
    request.end();
  });
}

async function waitForReady(url, options = {}) {
  const timeoutMs = options.timeoutMs || 30000;
  const intervalMs = options.intervalMs || 500;
  const startedAt = Date.now();
  const probe = options.probe || probeURL;
  const signal = options.signal;

  while (Date.now() - startedAt <= timeoutMs) {
    if (signal?.aborted) {
      throw new Error('Readiness check cancelled.');
    }

    if (await probe(url, { timeoutMs: Math.min(intervalMs, 1000), signal })) {
      return true;
    }

    await delay(intervalMs, signal);
  }

  return false;
}

module.exports = {
  probeURL,
  waitForReady,
};
