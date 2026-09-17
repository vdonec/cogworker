# frozen_string_literal: true

require 'capybara'
require 'capybara/dsl'
require 'capybara/cuprite'

Capybara.register_driver(:cogworker_cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, window_size: [1200, 800], js_errors: true,
                                     process_timeout: 30,
                                     browser_options: { 'no-sandbox' => nil })
end
Capybara.default_driver = :cogworker_cuprite
Capybara.app = Cogworker::Web
