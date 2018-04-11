require 'thread'

# A complete web framework for Ruby
#
# @since 0.1.0
#
# @see http://hanamirb.org
module Hanami
  require 'hanami/version'
  require 'hanami/frameworks'
  require 'hanami/environment'
  require 'hanami/app'
  require 'hanami/application'
  require 'hanami/components'
  require 'hanami/configuration'

  # @api private
  # @since 0.6.0
  DEFAULT_PUBLIC_DIRECTORY = 'public'.freeze

  # @api private
  # @since 0.9.0
  @_mutex = Mutex.new
  @_plugins = Concurrent::Array.new

  # Configure Hanami project
  #
  # Please note that the code for this method is generated by `hanami new`.
  #
  # @param blk [Proc] the configuration block
  #
  # @since 0.9.0
  #
  # @example
  #   # config/environment.rb
  #
  #   # ...
  #
  #   Hanami.configure do
  #     mount Admin::Application, at: "/admin"
  #     mount Web::Application,   at: "/"
  #
  #     model do
  #       adapter :sql, ENV['DATABASE_URL']
  #
  #       migrations "db/migrations"
  #       schema     "db/schema.sql"
  #     end
  #
  #     mailer do
  #       root "lib/bookshelf/mailers"
  #
  #       delivery do
  #         development :test
  #         test        :test
  #         # production :smtp, address: ENV['SMTP_HOST'], port: ENV['SMTP_PORT']
  #       end
  #     end
  #   end
  def self.configure(&blk)
    @_mutex.synchronize do
      @_configuration = Hanami::Configuration.new(&blk)
    end
  end

  # Hanami configuration
  #
  # @return [Hanami::Configuration] the configuration
  #
  # @see Hanami.configure
  #
  # @since 0.9.0
  # @api private
  def self.configuration
    @_mutex.synchronize do
      raise "Hanami not configured" unless defined?(@_configuration)
      @_configuration
    end
  end

  # Configure a plugin
  #
  # @see Hanami.configure
  #
  # @since 1.2.0
  def self.plugin(&blk)
    @_plugins << blk
  end

  # Plugins registry
  #
  # NOTE: We can't use `Components` registry.
  #
  # Plugins are loaded when Bundler requires `Gemfile` gems.
  # During this phase the `Components` that we can resolve are erased by the
  # first incoming request in development.
  # They are erased by a workaround that we had to put in place in `Hanami.boot`.
  # This workaround is `Components.release` and it was introduced because
  # `shotgun` failed to reload components, so we have to release for each
  # incoming request.
  # After the `Components` registry is cleared up, Hanami is able to resolve all
  # the components from scratch.
  #
  # When we'll switch to `hanami-reloader` for development, we can remove
  # `Components.release` and we'll be able to store plugins in `Components` and
  # remove `Hanami.plugins` as well.
  #
  # @since 1.2.0
  # @api private
  def self.plugins
    @_plugins
  end

  # Boot your Hanami project
  #
  # NOTE: In case this is invoked many times, it guarantees that the boot
  #   process happens only once.
  #
  # NOTE: This MUST NOT be wrapped by a Mutex, because it would cause a deadlock.
  #
  # @return [NilClass]
  #
  # @since 0.9.0
  def self.boot
    Components.release if code_reloading?
    Components.resolve('all')
    Hanami::Model.disconnect if defined?(Hanami::Model)
    nil
  end

  # Main application that mounts many Rack and/or Hanami applications.
  #
  # This is used as integration point for:
  #
  #   * `config.ru` (`run Hanami.app`)
  #   * Feature tests (`Capybara.app = Hanami.app`)
  #
  #
  #
  # It lazily loads your Hanami project, in case it wasn't booted on before.
  # This is the case when `hanami server` isn't invoked, but we use different
  # ways to run the project (eg. `rackup`).
  #
  # @return [Hanami::App] the app
  #
  # @since 0.9.0
  # @api private
  #
  # @see Hanami.boot
  def self.app
    boot
    App.new(configuration, environment)
  end

  # Check if an application is allowed to load.
  #
  # The list of applications to be loaded can be set via the `HANAMI_APPS`
  # env variable. If the HANAMI_APPS env variable is not set, it defaults
  # to loading all applications.
  #
  # @return [TrueClass,FalseClass] the result of the check
  #
  # @since 1.1.0
  #
  # @example
  #
  #   # Mount hanami app for specific app
  #   Hanami.configure do
  #     if Hanami.app?(:web)
  #       require_relative '../apps/web/application'
  #       mount Web::Application, at: '/'
  #     end
  #   end
  #
  def self.app?(app)
    return true unless ENV.key?('HANAMI_APPS')

    allowed_apps = ENV['HANAMI_APPS'].to_s.split(',')
    allowed_apps.include?(app.to_s.downcase)
  end

  # Return root of the project (top level directory).
  #
  # @return [Pathname] root path
  #
  # @since 0.3.2
  #
  # @example
  #   Hanami.root # => #<Pathname:/Users/luca/Code/bookshelf>
  def self.root
    environment.root
  end

  # Project public directory
  #
  # @return [Pathname] public directory
  #
  # @since 0.6.0
  #
  # @example
  #   Hanami.public_directory # => #<Pathname:/Users/luca/Code/bookshelf/public>
  def self.public_directory
    root.join(DEFAULT_PUBLIC_DIRECTORY)
  end

  # Return the current environment
  #
  # @return [String] the current environment
  #
  # @since 0.3.1
  #
  # @see Hanami::Environment#environment
  #
  # @example
  #   Hanami.env => "development"
  def self.env
    environment.environment
  end

  # Check to see if specified environment(s) matches the current environment.
  #
  # If multiple names are given, it returns true, if at least one of them
  # matches the current environment.
  #
  # @return [TrueClass,FalseClass] the result of the check
  #
  # @since 0.3.1
  #
  # @see Hanami.env
  #
  # @example Single name
  #   puts ENV['HANAMI_ENV'] # => "development"
  #
  #   Hanami.env?(:development)  # => true
  #   Hanami.env?('development') # => true
  #
  #   Hanami.env?(:production)   # => false
  #
  # @example Multiple names
  #   puts ENV['HANAMI_ENV'] # => "development"
  #
  #   Hanami.env?(:development, :test)   # => true
  #   Hanami.env?(:production, :staging) # => false
  def self.env?(*names)
    environment.environment?(*names)
  end

  # Current environment
  #
  # @return [Hanami::Environment] environment
  #
  # @api private
  # @since 0.3.2
  def self.environment
    Components.resolved('environment') do
      Environment.new
    end
  end

  # Check if code reloading is enabled.
  #
  # @return [TrueClass,FalseClass] the result of the check
  #
  # @since 1.0.0
  # @api private
  #
  # @see http://hanamirb.org/guides/projects/code-reloading/
  def self.code_reloading?
    environment
    Components.resolve('code_reloading')
    Components['code_reloading']
  end

  # Project logger
  #
  # @return [Hanami::Logger] the logger
  #
  # @since 1.0.0
  def self.logger
    Components['logger']
  end
end
