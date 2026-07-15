# Node service example

This dependency-free Node web app demonstrates the common `npm start` path.
It inherits configuration from Keybay and renders the injected disposable
value at a loopback-only URL.

First choose an installed or source-checkout executable as described in the
[examples guide](../README.md). Then, from this directory:

```sh
cp secrets.env.example .secrets.env
keybay run -- npm start
keybay set keybay-node/openai-api-key
keybay run -- npm start
```

The first command fails closed before npm starts. Enter a disposable value at
the hidden prompt. The app then listens only on `http://127.0.0.1:4242`. Open
that URL in a browser to see the exact value inherited by the Node process.
The response disables caching and referrers, but the value can still appear in
screenshots or browser tooling, so never enter a production credential.

Stop the service with Control-C, then remove the disposable value:

```sh
keybay rm keybay-node/openai-api-key
rm .secrets.env
```
