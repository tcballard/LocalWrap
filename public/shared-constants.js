/**
 * Constants shared across the IPC bridge — the single source of truth for
 * values the renderer and the main-process lib must agree on.
 *
 * This file lives in public/ because the renderer is the most constrained
 * consumer: it has no module system (sandboxed, CSP script-src 'self') and
 * can only load plain scripts from its own directory. lib modules require()
 * this same file, so the two sides cannot drift.
 */
(function () {
  'use strict';

  const constants = {
    // Runtime statuses during which a project counts as active. Must contain
    // exactly the in-flight statuses ProjectLifecycle emits.
    ACTIVE_STATUSES: ['starting', 'ready', 'running-unresponsive', 'stopping'],

    // Project Doctor checks, in display order: [id, label].
    DOCTOR_CHECKS: [
      ['directory', 'Directory'],
      ['command', 'Command'],
      ['dependencies', 'Dependencies'],
      ['port', 'Port'],
      ['url', 'URL'],
      ['process', 'Process'],
      ['readiness', 'Readiness'],
    ],

    DOCTOR_ACTIONS: {
      USE_FREE_PORT: 'use-free-port',
      SYNC_URL_TO_PORT: 'sync-url-to-port',
      REVEAL_DIRECTORY: 'reveal-directory',
      COPY_REPORT: 'copy-report',
      REVEAL_COMMAND: 'reveal-command',
    },

    DOCTOR_ACTION_LABELS: {
      'use-free-port': 'Find Free Port',
      'sync-url-to-port': 'Sync URL',
      'reveal-directory': 'Reveal Folder',
      'copy-report': 'Copy Report',
      'reveal-command': 'Reveal Command',
    },

    // Doctor actions that modify the saved project (port/URL patches).
    DOCTOR_MUTATING_ACTIONS: ['use-free-port', 'sync-url-to-port'],

    // A local app URL that LocalWrap generated itself and may auto-rewrite
    // when the port changes (hand-edited URLs are left alone).
    AUTO_LOCAL_URL_RE: /^https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):\d+$/,
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = constants;
  }
  if (typeof window !== 'undefined') {
    window.LocalWrapConstants = constants;
  }
})();
