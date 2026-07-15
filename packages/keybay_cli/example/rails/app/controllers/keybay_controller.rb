class KeybayController < ActionController::Base
  before_action :require_loopback_request

  def show
    @payments_api_url = ENV.fetch('PAYMENTS_API_URL')
    @stripe_secret_key = ENV.fetch('STRIPE_SECRET_KEY')
    raise 'STRIPE_SECRET_KEY was empty' if @stripe_secret_key.empty?

    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Security-Policy'] =
      "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; " \
      "form-action 'none'; frame-ancestors 'none'"
  end

  private

  def require_loopback_request
    head :forbidden unless request.local?
  end
end
