import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';

const securityHeaders = {
  'cache-control': 'no-store',
  'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'content-type': 'text/html; charset=utf-8',
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
};

export function createExampleServer({ openAiApiKey }) {
  if (!openAiApiKey) {
    throw new Error('OPENAI_API_KEY was not injected');
  }

  return createServer((request, response) => {
    if (request.method !== 'GET' || request.url !== '/') {
      response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      response.end('Not found\n');
      return;
    }

    response.writeHead(200, securityHeaders);
    response.end(renderPage(openAiApiKey));
  });
}

export function renderPage(openAiApiKey) {
  const escapedKey = escapeHtml(openAiApiKey);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Keybay Node example</title>
  <style>
    :root { color-scheme: dark; font-family: system-ui, sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #101114; color: #f5f7ff; }
    main { width: min(680px, calc(100% - 48px)); }
    h1 { margin-bottom: 8px; }
    p { color: #b8bdcc; line-height: 1.5; }
    .value { margin: 28px 0; padding: 20px; overflow-wrap: anywhere; border-radius: 12px; background: #20222a; font-family: ui-monospace, monospace; color: #fff; }
    .warning { color: #ff8f8f; font-size: 0.9rem; }
  </style>
</head>
<body>
  <main>
    <h1>Keybay Node example</h1>
    <p>This disposable value reached the running Node process through its environment.</p>
    <div class="value" data-testid="openai-api-key">${escapedKey}</div>
    <p class="warning">Demo only — never use a production credential here.</p>
  </main>
</body>
</html>
`;
}

function escapeHtml(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

const entryPoint = process.argv[1];
if (entryPoint && import.meta.url === pathToFileURL(entryPoint).href) {
  const port = Number.parseInt(process.env.PORT ?? '', 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('PORT must be an integer from 1 through 65535');
  }

  const server = createExampleServer({
    openAiApiKey: process.env.OPENAI_API_KEY,
  });
  server.listen(port, '127.0.0.1', () => {
    console.log(`Keybay Node example listening on http://127.0.0.1:${port}`);
    console.log('Open that loopback URL to view the disposable value.');
  });
}
