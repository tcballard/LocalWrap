'use strict';

const http = require('http');

const port = Number(process.env.PORT || 3000);
const startedAt = new Date();

function sendJson(response, payload) {
  response.writeHead(200, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
  });
  response.end(`${JSON.stringify(payload, null, 2)}\n`);
}

function sendHtml(response) {
  response.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>LocalWrap Sample Project</title>
    <style>
      :root {
        color-scheme: light;
        font-family: "Segoe UI", Tahoma, Arial, sans-serif;
      }

      body {
        min-height: 100vh;
        margin: 0;
        display: grid;
        place-items: center;
        background: #d8d8d8;
        color: #111;
      }

      main {
        width: min(680px, calc(100vw - 32px));
        border: 1px solid #4d4d4d;
        background: #f0f0f0;
        box-shadow:
          1px 1px 0 #fff inset,
          -1px -1px 0 #7d7d7d inset;
      }

      header {
        padding: 8px 10px;
        background: linear-gradient(to bottom, #1479d4 0%, #064a9d 100%);
        color: #fff;
        font-weight: 700;
      }

      section {
        padding: 18px;
      }

      h1 {
        margin: 0 0 8px;
        color: #003c74;
        font-size: 24px;
      }

      p {
        margin: 0 0 14px;
        line-height: 1.5;
      }

      dl {
        display: grid;
        grid-template-columns: max-content 1fr;
        gap: 8px 14px;
        margin: 0;
        padding: 12px;
        border: 1px inset #f0f0f0;
        background: #fff;
      }

      dt {
        font-weight: 700;
      }
    </style>
  </head>
  <body>
    <main>
      <header>LocalWrap Sample Project</header>
      <section>
        <h1>Ready</h1>
        <p>This dependency-free app is here so LocalWrap has a reliable project to import, start, diagnose, and open.</p>
        <dl>
          <dt>Port</dt>
          <dd>${port}</dd>
          <dt>Started</dt>
          <dd>${startedAt.toISOString()}</dd>
          <dt>Status API</dt>
          <dd><a href="/api/status">/api/status</a></dd>
          <dt>Health</dt>
          <dd><a href="/health">/health</a></dd>
        </dl>
      </section>
    </main>
  </body>
</html>`);
}

const server = http.createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || `localhost:${port}`}`);
  console.log(`[sample] ${request.method} ${url.pathname}`);

  if (url.pathname === '/health') {
    sendJson(response, { ok: true });
    return;
  }

  if (url.pathname === '/api/status') {
    sendJson(response, {
      ok: true,
      port,
      startedAt: startedAt.toISOString(),
      uptimeSeconds: Math.round(process.uptime()),
    });
    return;
  }

  sendHtml(response);
});

server.listen(port, 'localhost', () => {
  console.log(`[sample] LocalWrap sample project listening on http://localhost:${port}`);
  console.log('[sample] Try this through LocalWrap first launch or Add Project.');
});

function shutdown(signal) {
  console.log(`[sample] ${signal} received, shutting down.`);
  server.close(() => {
    process.exit(0);
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
