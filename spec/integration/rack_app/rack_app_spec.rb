# frozen_string_literal: true

require "rack/test"
require "stringio"

RSpec.describe "Hanami web app", :app_integration do
  include Rack::Test::Methods

  let(:app) { Hanami.app }

  specify "Hanami.app returns a rack builder" do
    with_tmp_directory do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            root to: ->(env) { [200, {}, ["OK"]] }
          end
        end
      RUBY

      require "hanami/boot"

      expect(app).to be(TestApp::App)
    end
  end

  specify "Has rack monitor preconfigured with default request logging" do
    dir = Dir.mktmpdir

    with_tmp_directory(dir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
            config.actions.format :json
            config.logger.options = {colorize: true}
            config.logger.stream = config.root.join("test.log")
          end
        end
      RUBY

      write "app/actions/users/index.rb", <<~RUBY
        module TestApp
          module Actions
            module Users
              class Index < Hanami::Action
                def handle(req, _resp)
                  raise StandardError, "OH NOEZ"
                end
              end
            end
          end
        end
      RUBY

      write "app/actions/users/create.rb", <<~RUBY
        module TestApp
          module Actions
            module Users
              class Create < Hanami::Action
                def handle(req, resp)
                  resp.body = req.params.to_h.keys
                end
              end
            end
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            root to: ->(env) { [200, {}, ["OK"]] }
            get "/users", to: "users.index"
            post "/users", to: "users.create"
          end
        end
      RUBY

      require "hanami/prepare"

      expect(Hanami.app["rack.monitor"]).to be_instance_of(Dry::Monitor::Rack::Middleware)

      get "/"

      logs = -> { Pathname(dir).join("test.log").realpath.read }

      expect(logs.()).to match %r{GET 200 \d+(µs|ms) 127.0.0.1 /}

      post "/users", JSON.generate(name: "jane", password: "secret"), {"CONTENT_TYPE" => "application/json"}

      expect(logs.()).to match %r{POST 200 \d+(µs|ms) 127.0.0.1 /}

      begin
        get "/users"
      rescue => e # rubocop:disable Style/RescueStandardError
        raise unless e.to_s == "OH NOEZ"
      end

      err_log = logs.()

      expect(err_log).to include("OH NOEZ")
      expect(err_log).to include("app/actions/users/index.rb:6:in `handle'")
    end
  end

  specify "Logging via the rack monitor even when notifications bus has already been used" do
    dir = Dir.mktmpdir

    with_tmp_directory(dir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
            config.actions.format :json
            config.logger.options = {colorize: true}
            config.logger.stream = config.root.join("test.log")
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            post "/users", to: "users.create"
          end
        end
      RUBY

      write "app/actions/users/create.rb", <<~RUBY
        module TestApp
          module Actions
            module Users
              class Create < Hanami::Action
                def handle(req, resp)
                  resp.body = req.params.to_h.keys
                end
              end
            end
          end
        end
      RUBY

      require "hanami/prepare"

      # Simulate any component interacting with the notifications bus such that it creates its
      # internal bus with a duplicate copy of all currently registered events. This means that the
      # class-level Dry::Monitor::Notification events implicitly registered by the
      # Dry::Monitor::Rack::Middleware activated via the rack provider are ignored, unless our
      # provider explicitly re-registers them on _instance_ of the notifications bus.
      #
      # See Hanami::Providers::Rack for more detail.
      Hanami.app["notifications"].instrument(:sql)

      logs = -> { Pathname(dir).join("test.log").realpath.read }

      post "/users", JSON.generate(name: "jane", password: "secret"), {"CONTENT_TYPE" => "application/json"}
      expect(logs.()).to match %r{POST 200 \d+(µs|ms) 127.0.0.1 /}
    end
  end

  describe "Request logging when using slice router" do
    let(:app) { Main::Slice.rack_app }

    specify "Has rack monitor preconfigured with default request logging (when used via a slice)" do
      dir = Dir.mktmpdir

      with_tmp_directory(dir) do
        write "config/app.rb", <<~RUBY
          require "hanami"

          module TestApp
            class App < Hanami::App
              config.logger.stream = config.root.join("test.log")
            end
          end
        RUBY

        write "slices/main/config/routes.rb", <<~RUBY
          module Main
            class Routes < Hanami::Routes
              root to: ->(env) { [200, {}, ["OK"]] }
            end
          end
        RUBY

        require "hanami/prepare"

        get "/"

        logs = -> { Pathname(dir).join("test.log").realpath.read }

        expect(logs.()).to match %r{GET 200 \d+(µs|ms) 127.0.0.1 /}
      end
    end
  end

  describe "Request logging on production" do
    let(:app) { Main::Slice.rack_app }

    around do |example|
      @prev_hanami_env = ENV["HANAMI_ENV"]
      ENV["HANAMI_ENV"] = "production"
      example.run
    ensure
      ENV["HANAMI_ENV"] = @prev_hanami_env
    end

    specify "Has rack monitor preconfigured with default request logging (when used via a slice)" do
      dir = Dir.mktmpdir

      with_tmp_directory(dir) do
        write "config/app.rb", <<~RUBY
          require "hanami"

          module TestApp
            class App < Hanami::App
              config.logger.stream = config.root.join("test.log")
            end
          end
        RUBY

        write "slices/main/config/routes.rb", <<~RUBY
          module Main
            class Routes < Hanami::Routes
              root to: ->(env) { [200, {}, ["OK"]] }
            end
          end
        RUBY

        require "hanami/boot"

        get "/"

        logs = -> { Pathname(dir).join("test.log").realpath.read }

        log_content = logs.()

        expect(log_content).to match(%r["verb":"GET"])
        expect(log_content).to match(%r["path":"/"])
        expect(log_content).to match(%r[elapsed":\d+,"elapsed_unit":"µs"])
      end
    end
  end

  specify "Routing to actions based on their container identifiers" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
            config.logger.stream = StringIO.new
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            get "/health", to: "health.show"

            get "/inline" do
              "Inline"
            end

            slice :main, at: "/" do
              root to: "home.index"
            end

            slice :admin, at: "/admin" do
              get "/dashboard", to: "dashboard.show"
            end
          end
        end
      RUBY

      write "app/actions/health/show.rb", <<~RUBY
        require "hanami/action"

        module TestApp
          module Actions
            module Health
              class Show < Hanami::Action
                def handle(*, res)
                  res.body = "Health, OK"
                end
              end
            end
          end
        end
      RUBY

      write "slices/main/actions/home/index.rb", <<~RUBY
        require "hanami/action"

        module Main
          module Actions
            module Home
              class Index < Hanami::Action
                def handle(*, res)
                  res.body = "Hello world"
                end
              end
            end
          end
        end
      RUBY

      write "slices/admin/actions/dashboard/show.rb", <<~RUBY
        require "hanami/action"

        module Admin
          module Actions
            module Dashboard
              class Show < Hanami::Action
                def handle(*, res)
                  res.body = "Admin dashboard here"
                end
              end
            end
          end
        end
      RUBY

      require "hanami/boot"

      get "/"

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "Hello world"

      get "/inline"

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "Inline"

      get "/health"

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "Health, OK"

      get "/admin/dashboard"

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "Admin dashboard here"
    end
  end

  # TODO: is this test even needed, given this is standard hanami-router behavior?
  specify "It gives priority to the last declared route" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
            config.logger.stream = StringIO.new
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            root to: "home.index"

            slice :main, at: "/" do
              root to: "home.index"
            end
          end
        end
      RUBY

      write "app/actions/home/index.rb", <<~RUBY
        require "hanami/action"

        module TestApp
          module Actions
            module Home
              class Index < Hanami::Action
                def handle(*, res)
                  res.body = "Hello from App"
                end
              end
            end
          end
        end
      RUBY

      write "slices/main/actions/home/index.rb", <<~RUBY
        require "hanami/action"

        module Main
          module Actions
            module Home
              class Index < Hanami::Action
                def handle(*, res)
                  res.body = "Hello from Slice"
                end
              end
            end
          end
        end
      RUBY

      require "hanami/boot"

      get "/"

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "Hello from Slice"
    end
  end

  specify "It does not choose actions from slice to route in app" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
            config.logger.stream = StringIO.new
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            get "/feedbacks", to: "feedbacks.index"

            slice :api, at: "/api" do
              get "/people", to: "people.index"
            end
          end
        end
      RUBY

      write "app/action.rb", <<~RUBY
        # auto_register: false
        require "hanami/action"

        module TestApp
          class Action < Hanami::Action
          end
        end
      RUBY

      write "app/actions/feedbacks/index.rb", <<~RUBY
        module TestApp
          module Actions
            module Feedbacks
              class Index < TestApp::Action
                def handle(*, res)
                  res.body = "Feedbacks"
                end
              end
            end
          end
        end
      RUBY

      write "slices/api/action.rb", <<~RUBY
        module API
          class Action < TestApp::Action
          end
        end
      RUBY

      write "slices/api/actions/people/index.rb", <<~RUBY
        module API
          module Actions
            module People
              class Index < API::Action
                def handle(*, res)
                  res.body = "People"
                end
              end
            end
          end
        end
      RUBY

      require "hanami/boot"

      get "/api/people"

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "People"
    end
  end

  specify "For a booted app, rack_app raises an exception if a referenced action isn't registered in the app" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            get "/missing", to: "missing.action"
          end
        end
      RUBY

      require "hanami/boot"

      expect { Hanami.app.rack_app }.to raise_error do |exception|
        expect(exception).to be_kind_of(Hanami::Routes::MissingActionError)
        expect(exception.message).to include("Could not find action with key \"actions.missing.action\" in TestApp::App")
        expect(exception.message).to match(%r{define the action class TestApp::Actions::Missing::Action.+actions/missing/action.rb})
      end
    end
  end

  specify "For a booted app, rack_app raises an error if a referenced action isn't registered in a slice" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
            register_slice :admin
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            slice :admin, at: "/admin" do
              get "/missing", to: "missing.action"
            end
          end
        end
      RUBY

      require "hanami/boot"

      expect { Hanami.app.rack_app }.to raise_error do |exception|
        expect(exception).to be_kind_of(Hanami::Routes::MissingActionError)
        expect(exception.message).to include("Could not find action with key \"actions.missing.action\" in Admin::Slice")
        expect(exception.message).to match(%r{define the action class Admin::Actions::Missing::Action.+slices/admin/actions/missing/action.rb})
      end
    end
  end

  specify "For a non-booted app, rack_app does not raise an error if a referenced action isn't registered in the app" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            get "/missing", to: "missing.action"
          end
        end
      RUBY

      require "hanami/prepare"

      expect { Hanami.app.rack_app }.not_to raise_error

      expect { get "/missing" }.to raise_error do |exception|
        expect(exception).to be_kind_of(Hanami::Routes::MissingActionError)
        expect(exception.message).to include("Could not find action with key \"actions.missing.action\" in TestApp::App")
        expect(exception.message).to match(%r{define the action class TestApp::Actions::Missing::Action.+actions/missing/action.rb})
      end
    end
  end

  specify "For a non-booted app, rack_app does not raise an error if a referenced action isn't registered in a slice" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
            register_slice :admin
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            slice :admin, at: "/admin" do
              get "/missing", to: "missing.action"
            end
          end
        end
      RUBY

      require "hanami/prepare"

      expect { Hanami.app.rack_app }.not_to raise_error

      expect { get "/admin/missing" }.to raise_error do |exception|
        expect(exception).to be_kind_of(Hanami::Routes::MissingActionError)
        expect(exception.message).to include("Could not find action with key \"actions.missing.action\" in Admin::Slice")
        expect(exception.message).to match(%r{define the action class Admin::Actions::Missing::Action.+slices/admin/actions/missing/action.rb})
      end
    end
  end

  specify "rack_app raises an error if a referenced slice is not registered" do
    with_tmp_directory(Dir.mktmpdir) do
      write "config/app.rb", <<~RUBY
        require "hanami"

        module TestApp
          class App < Hanami::App
          end
        end
      RUBY

      write "config/routes.rb", <<~RUBY
        module TestApp
          class Routes < Hanami::Routes
            slice :foo, at: "/foo" do
              get "/bar", to: "bar.index"
            end
          end
        end
      RUBY

      require "hanami/prepare"

      expect { Hanami.app.rack_app }.to raise_error do |exception|
        expect(exception).to be_kind_of(Hanami::SliceLoadError)
        expect(exception.message).to include("Slice 'foo' not found")
      end
    end
  end
end
