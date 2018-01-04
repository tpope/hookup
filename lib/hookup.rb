require 'hookup/post_checkout'

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

  def self.debug(message)
    puts "\e[33m[debug] #{message}\e[0m" if debug?
  end

  def self.debug?
    ENV["DEBUG_HOOKUP"] == "1"
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
    PostCheckout.new("post-checkout", ENV, *args).run
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
