require_relative '../test_helper'

class KeybayFlowTest < ActionDispatch::IntegrationTest
  test 'renders an escaped disposable value only for loopback requests' do
    with_environment(
      'PAYMENTS_API_URL' => 'https://payments.example.com',
      'STRIPE_SECRET_KEY' => 'disposable<&key'
    ) do
      get '/', headers: { 'REMOTE_ADDR' => '127.0.0.1' }

      assert_response :success
      assert_includes response.body, 'disposable&lt;&amp;key'
      refute_includes response.body, 'disposable<&key'
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_equal 'no-referrer', response.headers['Referrer-Policy']
    end
  end

  test 'rejects non-loopback requests' do
    with_environment(
      'PAYMENTS_API_URL' => 'https://payments.example.com',
      'STRIPE_SECRET_KEY' => 'disposable-key'
    ) do
      get '/', headers: { 'REMOTE_ADDR' => '203.0.113.1' }

      assert_response :forbidden
    end
  end

  private

  def with_environment(values)
    previous = values.to_h { |key, _value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
