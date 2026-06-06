'use strict';

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);
const LOCAL_PROTOCOLS = new Set(['http:', 'https:']);

/**
 * Security: validate that a URL points at a local development server on an
 * allowed port.
 *
 * @param {string} targetURL
 * @param {object} [options]
 * @param {boolean} [options.https=false]
 * @returns {boolean}
 */
function validateLocalhostURL(targetURL, options = {}) {
  try {
    const parsedURL = new URL(targetURL);
    const port = parseInt(parsedURL.port, 10);
    const allowedProtocols = options.https ? LOCAL_PROTOCOLS : new Set(['http:']);
    return (
      LOCAL_HOSTS.has(parsedURL.hostname) &&
      port >= 1000 &&
      port <= 65535 && // Valid port range
      allowedProtocols.has(parsedURL.protocol)
    );
  } catch (error) {
    return false;
  }
}

function validateLocalProjectURL(targetURL) {
  return validateLocalhostURL(targetURL, { https: true });
}

module.exports = {
  LOCAL_HOSTS,
  LOCAL_PROTOCOLS,
  validateLocalhostURL,
  validateLocalProjectURL,
};
