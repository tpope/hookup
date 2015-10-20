class Hookup

  class Error < RuntimeError
  end

  class Failure < Error
  end

  EMPTY_DIR = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

  def self.run(*argv)
    new.run(*argv)
  rescue Failure => e
    puts e
    exit 1
  rescue Error => e
    puts e
    exit
  end

  def run(*argv)
    if argv.empty?
      install
    else
      command = argv.shift
      begin
        send(command.tr('-', '_'), *argv)
      rescue NoMethodError
        raise Error, "Unknown command #{command}"
      rescue ArgumentError
        raise Error, "Invalid arguments for #{command}"
      end
    end
  end

  def git_dir
    unless @git_dir
      @git_dir = %x{git rev-parse --git-dir}.chomp
      raise Error unless $?.success?
    end
    @git_dir
  end

  def bundler?
    !!ENV['BUNDLE_GEMFILE']
  end

  def make_command(command)
    bundler? ? command.insert(0, "bundle exec ") : command
  end

  def post_checkout_file
    File.join(git_dir, 'hooks', 'post-checkout')
  end

  def info_attributes_file
    File.join(git_dir, 'info', 'attributes')
  end

  def install
    append(post_checkout_file, 0777) do |body, f|
      f.puts "#!/bin/bash" unless body
      f.puts make_command(%(hookup post-checkout "$@")) if body !~ /hookup/
    end

    append(info_attributes_file) do |body, f|
      map = 'db/schema.rb merge=railsschema'
      f.puts map unless body.to_s.include?(map)
    end

    system 'git', 'config', 'merge.railsschema.driver', make_command('hookup resolve-schema %A %O %B %L')

    puts "Hooked up!"
  end

  def remove
    body = IO.readlines(post_checkout_file)
    body.reject! { |item| item =~ /hookup/ }
    File.open(post_checkout_file, 'w') { |file| file.puts body.join }

    body = IO.readlines(info_attributes_file)
    body.reject! { |item| item =~ /railsschema/ }
    File.open(info_attributes_file, 'w') { |file| file.puts body.join }

    system 'git', 'config', '--unset', 'merge.railsschema.driver'

    puts "Hookup removed!"
  end

  def append(file, *args)
    Dir.mkdir(File.dirname(file)) unless File.directory?(File.dirname(file))
    body = File.read(file) if File.exist?(file)
    File.open(file, 'a', *args) do |f|
      yield body, f
    end
  end
  protected :append

  def post_checkout(*args)
    PostCheckout.new(ENV, *args).run
  end

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
      if %x{git diff --name-only #{old} #{new}} =~ /^Gemfile|\.gemspec$/
        begin
          # If Bundler in turn spawns Git, it can get confused by $GIT_DIR
          git_dir = ENV.delete('GIT_DIR')
          %x{bundle check}
          unless $?.success?
            puts "Bundling..."
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
        status = %x{git diff --name-status #{old} #{new} -- #{schema}}.chomp
        rake 'db:create' if status =~ /^A/
        status !~ /^D/ && !status.empty?
      end

      return if schemas.empty?

      migrations = %x{git diff --name-status #{old} #{new} -- #{schema_dir}/migrate}.scan(/.+/).map {|l| l.split(/\t/) }
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
        changes = %x{git diff --name-status #{new} -- #{schemas.join(' ')}}

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

  end

  def resolve_schema(a, o, b, marker_size = 7)
    system 'git', 'merge-file', "--marker-size=#{marker_size}", a, o, b
    body = File.read(a)
    resolve_schema_version body, ":version =>"
    resolve_schema_version body, "version:"
    File.open(a, 'w') { |f| f.write(body) }
    if body.include?('<' * marker_size.to_i)
      raise Failure, 'Failed to automatically resolve schema conflict'
    end
  end

  def resolve_schema_version(body, version)
    asd = "ActiveRecord::Schema.define"
    body.sub!(/^<+ .*\n#{asd}\(#{version} (\d+)\) do\n=+\n#{asd}\(#{version} (\d+)\) do\n>+ .*/) do
      "#{asd}(#{version} #{[$1, $2].max}) do"
    end
  end

end
