require 'capistrano/bundler'
require 'capistrano/plugin'

module Capistrano
  module PumaCommon
    def puma_switch_user(role, &block)
      user = puma_user(role)
      if user == role.user
        block.call
      else
        backend.as user do
          block.call
        end
      end
    end

    def puma_user(role)
      properties = role.properties
      properties.fetch(:puma_user) || # local property for puma only
          fetch(:puma_user) ||
          properties.fetch(:run_as) || # global property across multiple capistrano gems
          role.user
    end

    def puma_bind
      Array(fetch(:puma_bind)).collect do |bind|
        "bind '#{bind}'"
      end.join("\n")
    end

    def service_unit_type
      ## Jruby don't support notify
      return "simple" if RUBY_ENGINE == "jruby"
      fetch(:puma_service_unit_type,
      ## Check if sd_notify is available in the bundle
        Gem::Specification.find_all_by_name("sd_notify").any? ? "notify" : "simple")

    end

    def compiled_template_puma(from, role)
      @role = role
      file = [
          "lib/capistrano/templates/#{from}-#{role.hostname}-#{fetch(:stage)}.rb",
          "lib/capistrano/templates/#{from}-#{role.hostname}.rb",
          "lib/capistrano/templates/#{from}-#{fetch(:stage)}.rb",
          "lib/capistrano/templates/#{from}.rb.erb",
          "lib/capistrano/templates/#{from}.rb",
          "lib/capistrano/templates/#{from}.erb",
          "config/deploy/templates/#{from}.rb.erb",
          "config/deploy/templates/#{from}.rb",
          "config/deploy/templates/#{from}.erb",
          File.expand_path("../templates/#{from}.erb", __FILE__),
          File.expand_path("../templates/#{from}.rb.erb", __FILE__)
      ].detect { |path| File.file?(path) }
      erb = File.read(file)
      StringIO.new(ERB.new(erb, trim_mode: '-').result(binding))
    end

    def template_puma(from, to, role)
      backend.upload! compiled_template_puma(from, role), to
    end

    PumaBind = Struct.new(:full_address, :kind, :address, :backup) do
      def unix?
        kind == :unix
      end

      def ssl?
        kind == :ssl
      end

      def tcp
        kind == :tcp || ssl?
      end

      def local
        if unix?
          self
        else
          PumaBind.new(
            localize_address(full_address),
            kind,
            localize_address(address)
          )
        end
      end

      def backup?
        backup == true
      end

      private

      def localize_address(address)
        address.gsub(/0\.0\.0\.0(.+)/, "127.0.0.1\\1")
      end
    end

    def puma_binds(backup: false)
      [
        *Array(fetch(:puma_bind)).map do |m|
          etype, address  = /(tcp|unix|ssl):\/{1,2}(.+)/.match(m).captures
          PumaBind.new(m, etype.to_sym, address, false)
        end,
        *(backup ? Array(fetch(:puma_backup_bind)).map do |m|
          etype, address  = /(tcp|unix|ssl):\/{1,2}(.+)/.match(m).captures
          PumaBind.new(m, etype.to_sym, address, true)
        end : nil)
      ]
    end
  end

  class Puma < Capistrano::Plugin
    include PumaCommon

    def define_tasks
      eval_rakefile File.expand_path('../tasks/puma.rake', __FILE__)
    end

    def set_defaults
      set_if_empty :puma_role, :web
      set_if_empty :puma_env, -> { fetch(:rack_env, fetch(:rails_env, fetch(:stage))) }
      # Configure "min" to be the minimum number of threads to use to answer
      # requests and "max" the maximum.
      set_if_empty :puma_threads, [0, 16]
      set_if_empty :puma_workers, 0
      set_if_empty :puma_rackup, -> { File.join(current_path, 'config.ru') }
      set_if_empty :puma_state, -> { File.join(shared_path, 'tmp', 'pids', 'puma.state') }
      set_if_empty :puma_backup_state, -> { File.join(shared_path, 'tmp', 'pids', 'puma_backup.state') }
      set_if_empty :puma_pid, -> { File.join(shared_path, 'tmp', 'pids', 'puma.pid') }
      set_if_empty :puma_backup_pid, -> { File.join(shared_path, 'tmp', 'pids', 'puma_backup.pid') }
      set_if_empty :puma_bind, -> { File.join("unix://#{shared_path}", 'tmp', 'sockets', 'puma.sock') }
      set_if_empty :puma_backup_bind, -> { File.join("unix://#{shared_path}", 'tmp', 'sockets', 'puma_backup.sock') }
      set_if_empty :puma_control_app, false
      set_if_empty :puma_default_control_app, -> { File.join("unix://#{shared_path}", 'tmp', 'sockets', 'pumactl.sock') }
      set_if_empty :puma_conf, -> { File.join(shared_path, 'puma.rb') }
      set_if_empty :puma_backup_conf, -> { File.join(shared_path, 'puma_backup.rb') }
      set_if_empty :puma_access_log, -> { File.join(shared_path, 'log', 'puma_access.log') }
      set_if_empty :puma_error_log, -> { File.join(shared_path, 'log', 'puma_error.log') }
      set_if_empty :puma_init_active_record, false
      set_if_empty :puma_preload_app, false
      set_if_empty :puma_daemonize, false
      set_if_empty :puma_tag, ''
      set_if_empty :puma_restart_command, 'bundle exec puma'
      set_if_empty :puma_access_log, -> { File.join(shared_path, 'log', "puma.log") }
      set_if_empty :puma_error_log, -> { File.join(shared_path, 'log', "puma.log") }

      # Chruby, Rbenv and RVM integration
      append :chruby_map_bins, 'puma', 'pumactl' if fetch(:chruby_map_bins)
      append :rbenv_map_bins, 'puma', 'pumactl' if fetch(:rbenv_map_bins)
      append :rvm_map_bins, 'puma', 'pumactl' if fetch(:rvm_map_bins)

      # Bundler integration
      append :bundle_bins, 'puma', 'pumactl'
    end

    def register_hooks
      after 'deploy:check', 'puma:check'
    end

    def puma_workers
      fetch(:puma_workers, 0)
    end

    def puma_preload_app?
      fetch(:puma_preload_app)
    end

    def puma_daemonize?
      fetch(:puma_daemonize)
    end

    def puma_plugins
      Array(fetch(:puma_plugins)).collect do |bind|
        "plugin '#{bind}'"
      end.join("\n")
    end

    def upload_puma_rb(role)
      template_puma 'puma', fetch(:puma_conf), role

      return unless fetch(:puma_backup_server)

      # pidfile, state_path, bind, workers

      pid = fetch(:puma_pid)
      set :puma_pid, fetch(:puma_backup_pid)
      state = fetch(:puma_state)
      set :puma_state, fetch(:puma_backup_state)
      bind = fetch(:puma_bind)
      set :puma_bind, fetch(:puma_backup_bind)
      workers = fetch(:puma_workers)
      set :puma_workers, 2

      template_puma 'puma', fetch(:puma_backup_conf), role

      set :puma_pid, pid
      set :puma_state, state
      set :puma_bind, bind
      set :puma_workers, workers
    end
  end
end

require 'capistrano/puma/systemd'
require 'capistrano/puma/nginx'
