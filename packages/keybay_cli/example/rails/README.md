# Rails app example

This minimal Rails web application runs with a development-only Stripe value
supplied by Keybay and renders it at a loopback-only URL.

Rails 8.1 requires Ruby 3.2 or newer. Activate a current Ruby with your usual
version manager. On Homebrew, select the installation matching the Mac rather
than relying on whichever `brew` happens to be first on `PATH`:

```sh
# Apple Silicon
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"

# Intel Mac (use this instead)
# export PATH="/usr/local/opt/ruby/bin:$PATH"

hash -r
ruby -e 'puts RUBY_DESCRIPTION'
```

The reported architecture should match `uname -m`. Mixing an Intel Ruby from
`/usr/local` with an Apple Silicon compiler causes native gems such as
`io-console` and Puma to fail during installation.

Then choose an installed or source-checkout executable as described in the
[examples guide](../README.md). From this directory:

```sh
bundle config set --local path vendor/bundle
bundle install
cp secrets.env.example .secrets.env
keybay run -- bin/rails server --binding 127.0.0.1 --port 3000
keybay set keybay-rails/stripe-secret-key
keybay run -- bin/rails server --binding 127.0.0.1 --port 3000
```

The first run fails closed before Rails boots. Enter any disposable value at
the hidden prompt. The app then listens only on `http://127.0.0.1:3000`. Open
that URL in a browser to see the public endpoint and exact value inherited by
the Rails process. The controller rejects non-loopback requests and disables
caching and referrers, but the value can still appear in screenshots or
browser tooling, so never enter a production credential. Stop the server with
Control-C.

After the example:

```sh
keybay rm keybay-rails/stripe-secret-key
rm .secrets.env
```
