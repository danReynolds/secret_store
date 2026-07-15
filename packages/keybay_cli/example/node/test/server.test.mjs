import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';

import { createExampleServer } from '../server.mjs';

const disposableKey = 'disposable<&key';
const server = createExampleServer({ openAiApiKey: disposableKey });
let baseUrl;

before(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
});

test('renders the escaped disposable value with no-store headers', async () => {
  const response = await fetch(`${baseUrl}/`);
  const body = await response.text();

  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  assert.match(body, /disposable&lt;&amp;key/);
  assert.doesNotMatch(body, /disposable<&key/);
});

test('returns 404 outside the app route', async () => {
  const response = await fetch(`${baseUrl}/missing`);
  assert.equal(response.status, 404);
});
