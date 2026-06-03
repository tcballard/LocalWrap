'use strict';

/**
 * Security: validate that a URL points at a localhost HTTP dev server on an
 * allowed port. Used to gate navigation and window-open handling in main.js,
 * and exercised directly by the test suite.
 *
 * @param {string} targetURL
 * @returns {boolean}
 */
function validateLocalhostURL(targetURL) {
  try {
    const parsedURL = new URL(targetURL);
    const port = parseInt(parsedURL.port, 10);
    return (
      (parsedURL.hostname === 'localhost' || parsedURL.hostname === '127.0.0.1') &&
      port >= 1000 &&
      port <= 65535 && // Valid port range
      parsedURL.protocol === 'http:'
    );
  } catch (error) {
    return false;
  }
}

module.exports = { validateLocalhostURL };
