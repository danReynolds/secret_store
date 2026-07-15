# Quickstart example

This language-neutral example proves both halves of a mixed Keybay manifest:
the literal `API_URL` and the referenced `OPENAI_API_KEY` reach exactly one
child process.

These commands require `keybay` on `PATH`. Source contributors can choose the
repository runner in the
[examples guide](https://github.com/danReynolds/keybay/tree/main/packages/keybay_cli/example).
Then, from this directory:

```sh
cp secrets.env.example .secrets.env
keybay run -- ./app.sh
keybay set acme-example/openai-api-key
keybay run -- ./app.sh
```

The copied manifest contains only a public URL and a `kb://` reference. In a
real repository, commit `.secrets.env` so the secret contract is reviewed and
shared while each developer supplies their own value. This packaged example
uses a visible template so every distribution channel carries it predictably.

The first `run` fails closed and prints the `set` command without launching the
app. Enter any disposable value at the hidden prompt. The second `run` shows
the literal URL and confirms that the secret reached the app without printing
its value:

```text
Keybay example app started.
  API_URL: https://staging.example.com
  OPENAI_API_KEY: available (value not printed)
```

Remove the disposable example value and generated manifest when finished:

```sh
keybay rm acme-example/openai-api-key
rm .secrets.env
```

`keybay rm` is silent and succeeds even if the value is already absent.
