class Hookup

  class Error < RuntimeError
  end

  EMPTY_DIR = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

  def self.run(*argv)
    new.run(*argv)
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

  def install
    dir = %x{git rev-parse --git-dir}.chomp
    raise Error, dir unless $?.success?

    hook_dir = File.join(dir, 'hooks')
    Dir.mkdir(hook_dir, 0755) unless File.directory?(hook_dir)

    hook = File.join(hook_dir, 'post-checkout')

    unless File.exist?(hook)
      File.open(hook, 'w', 0777) do |f|
        f.puts "#!/bin/bash"
      end
    end
    if File.read(hook) =~ /^[^#]*\bhookup\b/
      puts "Already hooked up!"
    else
      File.open(hook, "a") do |f|
        f.puts %(hookup post-checkout "$@")
      end
      puts "Hooked up!"
    end
  end

  def post_checkout(*args)
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

    schema = %x{git diff --name-status #{old} #{new} -- db/schema.rb}
    if schema =~ /^A/
      system 'rake', 'db:create'
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
      system 'git', 'checkout', '--', 'db/schema.rb' if migrations.any?
    end
  end

end
