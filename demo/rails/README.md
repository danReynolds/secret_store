# Rails runner demo

This minimal Rails application runs ordinary application code with a
development-only Stripe credential supplied by Keyway. It prints the Rails
version, the public endpoint, and a safe availability status—not the secret.

Rails 8.1 requires Ruby 3.2 or newer. Activate a current Ruby with your usual
version manager. On a Homebrew installation:

```sh
export PATH="$(brew --prefix ruby)/bin:$PATH"
```

Then, from this directory:

```sh
bundle install
keyway run -- bin/rails runner script/check_configuration.rb
keyway set demo-rails/stripe-secret-key
keyway run -- bin/rails runner script/check_configuration.rb
```

The first run fails closed before Rails boots. Enter any disposable value at
the hidden prompt. The second run prints:

```text
Keyway Rails demo booted on Rails 8.1.3.
  PAYMENTS_API_URL: https://payments.example.com
  STRIPE_SECRET_KEY: available (value not printed)
```

After the demo:

```sh
keyway rm demo-rails/stripe-secret-key
```
