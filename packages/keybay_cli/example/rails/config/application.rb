require_relative 'boot'

require 'action_controller/railtie'

Bundler.require(*Rails.groups)

module KeybayExample
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = false
  end
end
