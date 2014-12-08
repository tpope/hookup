class Hookup
  class PostCheckout

    attr_reader :old, :new, :env

    def partial?
      @partial
    end

    def schema_dir
      File.join(working_dir, env['HOOKUP_SCHEMA_DIR'])
    end

    def possible_schemas
      %w(development_structure.sql schema.rb structure.sql).map do |file|
        File.join schema_dir, file
      end
    end

    def working_dir
      env['HOOKUP_WORKING_DIR'] || '.'
    end

    def initialize(environment, *args)
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

      @old = args.shift
      if @old == '0000000000000000000000000000000000000000'
        @old = EMPTY_DIR
      elsif @old.nil?
        @old = '@{-1}'
      end
      @new = args.shift || 'HEAD'
      @partial = (args.shift == '0')

      env['HOOKUP_SCHEMA_DIR'] = 'db' unless env['HOOKUP_SCHEMA_DIR'] && File.directory?(schema_dir)
    end

    def run
      return if skipped? || env['GIT_REFLOG_ACTION'] =~ /^(?:pull|rebase)/
      unless partial?
        bundle
        migrate
      end
    end

    def bundler?
      File.exist?('Gemfile')
    end

    def bundle
      return unless bundler?
      if x("git diff --name-only #{old} #{new}") =~ /^Gemfile|\.gemspec$/
        begin
          # If Bundler in turn spawns Git, it can get confused by $GIT_DIR
          git_dir = ENV.delete('GIT_DIR')
          unless system("bundle check")
            Dir.chdir(working_dir) do
              system("bundle | grep -v '^Using ' | grep -v ' is complete'")
            end
          end
        ensure
          ENV['GIT_DIR'] = git_dir
        end
      end
    end

    def migrate
      schemas = possible_schemas.select do |schema|
        status = x("git diff --name-status #{old} #{new} -- #{schema}").chomp
        rake 'db:create' if status =~ /^A/
        status !~ /^D/ && !status.empty?
      end

      return if schemas.empty?

      migrations = x("git diff --name-status #{old} #{new} -- #{schema_dir}/migrate").scan(/.+/).map {|l| l.split(/\t/) }
      begin
        migrations.select {|(t,f)| %w(D M).include?(t)}.reverse.each do |type, file|
          begin
            system 'git', 'checkout', old, '--', file
            unless rake 'db:migrate:down', "VERSION=#{File.basename(file)}"
              raise Error, "Failed to rollback #{File.basename(file)}"
            end
          ensure
            if type == 'D'
              system 'git', 'rm', '--force', '--quiet', '--', file
            else
              system 'git', 'checkout', new, '--', file
            end
          end
        end

        if migrations.any? {|(t,f)| %w(A M).include?(t)}
          rake 'db:migrate'
        end

      ensure
        changes = x("git diff --name-status #{new} -- #{schemas.join(' ')}")

        unless changes.empty?
          system 'git', 'checkout', '--', *schemas

          puts "Schema out of sync."

          fallback = env['HOOKUP_LOAD_SCHEMA']
          if fallback && fallback != ''
            puts "Trying #{fallback}..."
            system fallback
          end
        end
      end
    end

    def rake(*args)
      Dir.chdir(working_dir) do
        if File.executable?('bin/rake')
          system 'bin/rake', *args
        elsif bundler?
          system 'bundle', 'exec', 'rake', *args
        else
          system 'rake', *args
        end
      end
    end

    def skipped?
      env['SKIP_HOOKUP']
    end

    def system(*args)
      puts "\e[90m#{args.join(" ")}\e[0m"
      super
    end

    def x(command)
      puts "\e[90m#{command}\e[0m"
      %x{#{command}}
    end

  end
end
