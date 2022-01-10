require "delegate"

class Hookup
  class PostCheckout

    attr_reader :old_sha, :new_sha, :env, :hook

    def partial?
      @partial
    end

    def schema_dir
      @schema_dir ||= File.join(working_dir, env['HOOKUP_SCHEMA_DIR']).gsub(/^\.\//, "")
    end

    def possible_schemas
      %w(development_structure.sql schema.rb structure.sql).map do |file|
        File.join schema_dir, file
      end
    end

    def working_dir
      env['HOOKUP_WORKING_DIR'] || '.'
    end

    def initialize(hook, environment, *args)
      @hook = hook
      @env ||= environment.to_hash.dup
      require 'optparse'
      opts = OptionParser.new
      opts.banner = "Usage: hookup post-checkout <old> <new> <full>"
      opts.on('-Cdirectory', 'cd to directory') do |directory|
        env['HOOKUP_WORKING_DIR'] = directory
      end
      opts.on('--schema-dir=DIRECTORY', 'Path to DIRECTORY containing schema.rb and migrate/') do |directory|
        env['HOOKUP_SCHEMA_DIR'] = directory
      end
      opts.on('--load-schema=COMMAND', 'Run COMMAND on migration failure') do |command|
        env['HOOKUP_LOAD_SCHEMA'] = command
      end
      opts.parse!(args)

      @old_sha = args.shift
      if @old_sha == '0000000000000000000000000000000000000000'
        @old_sha = EMPTY_DIR
      elsif @old_sha.nil?
        @old_sha = '@{-1}'
      end
      @new_sha = args.shift || 'HEAD'
      @partial = (args.shift == '0')

      debug "#{hook}: #{old_sha} -> #{new_sha}"

      env['HOOKUP_SCHEMA_DIR'] = 'db' unless env['HOOKUP_SCHEMA_DIR'] && File.directory?(schema_dir)
    end

    def run
      return if skipped? || no_change? || checkout_during_rebase? || partial?

      update_submodules
      bundle
      yarn_install
      rebuild_containers
      migrate
    end

    def update_submodules
      system "git submodule update --init"
    end

    def bundler?
      File.exist?('Gemfile')
    end

    def docker?
      File.exist?('docker-compose.yml')
    end

    def bundle
      return if docker?
      return unless bundler?
      if changes.grep(/^Gemfile|\.gemspec$/).any?
        begin
          # If Bundler in turn spawns Git, it can get confused by $GIT_DIR
          git_dir = ENV.delete('GIT_DIR')
          unless rbenv_system("bundle check > /dev/null 2> /dev/null")
            Dir.chdir(working_dir) do
              rbenv_system("bundle")
            end
          end
        ensure
          ENV['GIT_DIR'] = git_dir
        end
      end
    end

    def migrate
      schemas = possible_schemas.select do |schema|
        change = changes[schema]
        rake 'db:create' if change && change.added?
        change && !change.deleted?
      end

      return if schemas.empty?

      migrations = changes.grep(/^#{schema_dir}\/migrate/)
      begin
        migrations.select { |migration| migration.deleted? || migration.modified? }.reverse.each do |migration|
          file = migration.file
          begin
            system 'git', 'checkout', old_sha, '--', file
            rake 'db:migrate:down', "VERSION=#{File.basename(file)}"
          ensure
            if migration.deleted?
              system 'git', 'rm', '--force', '--quiet', '--', file
            else
              system 'git', 'checkout', new_sha, '--', file
            end
          end
        end

        if migrations.any? { |migration| migration.added? || migration.modified? }
          rake 'db:migrate'
        end

      ensure
        _changes = x("git diff --name-status #{new_sha} -- #{schemas.join(' ')}")

        unless _changes.empty?
          puts "\e[33mSchema out of sync.\e[0m"

          system 'git', 'checkout', '--', *schemas

          fallback = env['HOOKUP_LOAD_SCHEMA']
          if fallback && fallback != ''
            puts "Trying #{fallback}..."
            rbenv_system fallback
          end
        end
      end
    end

    def rake(*args)
      Dir.chdir(working_dir) do
        if docker? # Assumes one of the containers is named "rails"
          system "docker-compose", "run", "rails", "rake", *args
        elsif File.executable?('bin/rake')
          rbenv_system 'bin/rake', *args
        elsif bundler?
          rbenv_system 'bundle', 'exec', 'rake', *args
        else
          rbenv_system 'rake', *args
        end
      end
    end

    def rbenv?
      File.exist?('.ruby-version')
    end

    def rbenv_version
      return unless rbenv?
      File.open(".ruby-version", "r") do |f|
        f.gets.gsub(/\n/, "")
      end
    end

    def rbenv_path
      version = rbenv_version
      return unless version
      path = File.join(ENV["RBENV_ROOT"], "versions", version, "bin")
      Dir.exist?(path) ? path : nil
    end

    def yarn?
      yarn_lock_files.any?
    end

    def yarn_install
      return if docker?
      return unless yarn?

      yarn_lock_files.each do |lock_file|
        Dir.chdir(File.dirname(lock_file)) do
          system "yarn install"
        end
      end
    end

    def yarn_lock_files
      @yarn_lock_files ||= Dir.glob("**/yarn.lock").reject { |path| path =~ /node_modules/ }
    end

    def rebuild_containers
      return unless docker?

      # Rebuilding the containers should pick up any changes to either
      # Gemfile.lock or yarn.lock and rebuild ... or just used the
      # cached version if there are no changes.
      system "docker-compose build"
    end

    def skipped?
      env['SKIP_HOOKUP']
    end

    def checkout_during_rebase?
      debug "GIT_REFLOG_ACTION: #{env['GIT_REFLOG_ACTION']}"
      hook == "post-checkout" && env['GIT_REFLOG_ACTION'] =~ /^(?:pull|rebase)/
    end

    def no_change?
      old_sha == new_sha
    end

    def system(*args)
      puts "\e[90m[#{File.basename Dir.pwd}] #{args.join(" ")}\e[0m"
      super
    end

    def rbenv_system(*args)
      begin
        original_version = ENV["RBENV_VERSION"]
        original_path = ENV["PATH"]
        temp_version = rbenv_version
        temp_path = rbenv_path
        ENV["RBENV_VERSION"] = temp_version if temp_version
        ENV["PATH"] = "#{temp_path}:#{ENV["PATH"]}" if temp_path

        system(*args)
      ensure
        ENV["RBENV_VERSION"] = original_version
        ENV["PATH"] = original_path
      end
    end

    def x(command)
      puts "\e[90m[#{File.basename Dir.pwd}] #{command}\e[0m"
      %x{#{command}}
    end

    def debug(message)
      Hookup.debug(message)
    end

    def changes
      @changes ||= DiffChanges.new(x("git diff --name-status #{old_sha} #{new_sha}"))
    end

    class DiffChange < Struct.new(:type, :file)
      def added?
        type == "A"
      end

      def copied?
        type == "C"
      end

      def deleted?
        type == "D"
      end

      def modified?
        type == "M"
      end

      def renamed?
        type == "R"
      end

      def type_changed?
        type == "T"
      end

      def unmerged?
        type == "U"
      end

      def broken?
        type == "B"
      end
    end

    class DiffChanges < SimpleDelegator
      def initialize(diff)
        super diff.to_s.scan(/^([^\t]+)\t(.*)$/).map { |(type, file)| DiffChange.new(type, file) }
      end

      def grep(regex)
        __getobj__.select { |change| change.file =~ regex }
      end

      def [](filename)
        __getobj__.detect { |change| change.file == filename }
      end
    end

  end
end
