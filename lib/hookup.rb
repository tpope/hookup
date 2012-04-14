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
      raise Error, dir unless $?.success?
    end
    @git_dir
  end

  def install
    append(File.join(git_dir, 'hooks', 'post-checkout'), 0777) do |body, f|
      f.puts "#!/bin/bash" unless body
      f.puts %(hookup post-checkout "$@") if body !~ /hookup/
    end

    append(File.join(git_dir, 'info', 'attributes')) do |body, f|
      map = 'db/schema.rb merge=railsschema'
      f.puts map unless body.to_s.include?(map)
    end

    system 'git', 'config', 'merge.railsschema.driver', 'hookup resolve-schema %A %O %B %L'

    puts "Hooked up!"
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
    return if ENV['GIT_REFLOG_ACTION'] =~ /^pull/
    old, new = args.shift, args.shift || 'HEAD'
    if old == '0000000000000000000000000000000000000000'
      old = EMPTY_DIR
    elsif old.nil?
      old = '@{-1}'
    end
    bundle(old, new, *args)
    migrate(old, new, *args)
  end

  def bundle(old, new, *args)
    return if args.first == '0'

    return unless File.exist?('Gemfile')
    if %x{git diff --name-only #{old} #{new}} =~ /^Gemfile|\.gemspec$/
      begin
        # If Bundler in turn spawns Git, it can get confused by $GIT_DIR
        git_dir = ENV.delete('GIT_DIR')
        %x{bundle check}
        unless $?.success?
          puts "Bundling..."
          system("bundle | grep -v '^Using ' | grep -v ' is complete'")
        end
      ensure
        ENV['GIT_DIR'] = git_dir
      end
    end
  end

  def migrate(old, new, *args)
    return if args.first == '0'

    schemas = %w(db/schema.rb db/development_structure.sql).select do |schema|
      status = %x{git diff --name-status #{old} #{new} -- #{schema}}.chomp
      system 'rake', 'db:create' if status =~ /^A/
      status !~ /^D/ && !status.empty?
    end

    migrations = %x{git diff --name-status #{old} #{new} -- db/migrate}.scan(/.+/).map {|l| l.split(/\t/) }
    begin
      migrations.select {|(t,f)| %w(D M).include?(t)}.reverse.each do |type, file|
        begin
          system 'git', 'checkout', old, '--', file
          unless system 'rake', 'db:migrate:down', "VERSION=#{File.basename(file)}"
            raise Error, "Failed to rollback #{File.basename(file)}. Consider rake db:setup"
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
        system 'rake', 'db:migrate'
      end

    ensure
      system 'git', 'checkout', '--', *schemas if schemas.any?
    end
  end

  def resolve_schema(a, o, b, marker_size = 7)
    system 'git', 'merge-file', "--marker-size=#{marker_size}", a, o, b
    body = File.read(a)
    asd = "ActiveRecord::Schema.define"
    x = body.sub!(/^<+ .*\n#{asd}\(:version => (\d+)\) do\n=+\n#{asd}\(:version => (\d+)\) do\n>+ .*/) do
      "#{asd}(:version => #{[$1, $2].max}) do"
    end
    File.open(a, 'w') { |f| f.write(body) }
    if body.include?('<' * marker_size.to_i)
      raise Failure, 'Failed to automatically resolve schema conflict'
    end
  end

end
