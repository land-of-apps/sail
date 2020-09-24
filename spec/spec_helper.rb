# frozen_string_literal: true

require "appmap/rspec"

ENV["RAILS_ENV"] = "test"
require File.expand_path("dummy/config/environment.rb", __dir__)
require "bundler/setup"
require "rspec/rails"
require "simplecov"
require "rails/all"
require "database_cleaner"
require "capybara/rspec"
require "capybara/rails"
require "sail"
require "selenium/webdriver"
require "webdrivers/chromedriver"
require "rspec/retry"

SimpleCov.start

if ENV["ON_CI"].present?
  require "codecov"
  SimpleCov.formatter = SimpleCov::Formatter::Codecov
end

DatabaseCleaner.strategy = :truncation

class User
  def admin?
    true
  end

  def id
    1
  end
end

class WardenObject
  def user
    User.new
  end
end

=begin
# This successfully started and finished recording around an `it`
block. It didn't capture any application events, though, because all
the interesting stuff happens in the `before` block when `visit` is
called.

module DoRemoteRecording
  def server
    [:host,:port].map{|a| Capybara.current_session.server.send(a)}.join(':')
  end
  def begin_spec(example)
    super

    Faraday.post("http://#{server}/_appmap/record")
  end

  def end_spec(example)
    f = super
    
    conn = Faraday.new("http://#{server}/_appmap/record") do |c|
      c.response :raise_error
      c.adapter Faraday.default_adapter
    end
    appmap = conn.delete.body
    
    File.write(f.sub('.appmap.json', '-remote.appmap.json'), appmap, mode: 'wb')
  end
end


AppMap::RSpec.singleton_class.prepend(DoRemoteRecording)
=end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.infer_spec_type_from_file_location!
  config.order = :random

  config.before(:each) do
    DatabaseCleaner.clean
  end

  config.before(:each, type: :controller) do
    controller.request.env["warden"] = WardenObject.new
  end

  config.before(:each, type: :feature) do
    allow_any_instance_of(Sail::ApplicationController).to receive(:current_user).and_return(User.new)
  end

  config.around :each, :js do |ex|
    ex.run_with_retry retry: 3
  end

  config.around :each , type: :feature do |ex|
    require 'faraday'

    # `Capybara.current_session.server` currently fails, because
    # there's no session yet -- it gets created sometime during the
    # processing of `visit`.
    server = [:host,:port].map{|a| Capybara.current_session.server.send(a)}.join(':')
    Faraday.post("http://#{server}/_appmap/record")
    begin
      ex.run
    ensure
      conn = Faraday.new("http://#{server}/_appmap/record") do |c|
        c.response :raise_error
        c.adapter Faraday.default_adapter
      end
      appmap = conn.delete.body
      true
    end
  end
  
  Capybara.register_driver :chrome do |app|
    Capybara::Selenium::Driver.new(app, browser: :chrome)
  end

  Capybara.register_driver :headless_chrome do |app|
    options = ::Selenium::WebDriver::Chrome::Options.new

    options.add_argument("--headless")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1920,1180")
    options.add_argument("--disable-gpu")

    Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
  end

  # Capybara starts a new instance of puma in the current process. I'm
  # not sure whether it clears out the environment, so I don't know
  # for sure that `APPMAP` needs to be specified here.
  Capybara.register_server :sail_puma do |app, port, host, **options|
    Capybara.servers[:puma].call(app, port, host, environment: {:Verbose => true, 'APPMAP' => 'true', 'DEBUG' => 'true'})
  end
  
  Capybara.javascript_driver = :headless_chrome
  Capybara.server = :sail_puma
  Capybara.default_max_wait_time = 9999
  Webdrivers.install_dir = "~/bin/chromedriver" if ENV["ON_CI"].present?
end

# rubocop:disable Metrics/AbcSize
def expect_setting(setting)
  expect(page).to have_text(setting.name.titleize)
  expect(page).to have_text(setting.cast_type)
  expect(page).to have_link(setting.group)
  expect(page).to have_button("SAVE")

  if setting.boolean? || setting.ab_test?
    expect(page).to have_css(".slider")
  else
    expect(page).to have_field("value")
  end
end
# rubocop:enable Metrics/AbcSize

# Patch to avoid failures for
# Ruby 2.6.x combined with Rails 4.x.x
# More details in https://github.com/rails/rails/issues/34790
if RUBY_VERSION >= "2.6.0" && Rails.version < "5"
  module ActionController
    class TestResponse < ActionDispatch::TestResponse
      def recycle!
        @mon_mutex_owner_object_id = nil
        @mon_mutex = nil
        initialize
      end
    end
  end
end
