# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name        = "hookup"
  s.version     = "1.2.4"
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Tim Pope"]
  s.email       = ["code@tp"+'ope.net']
  s.homepage    = "https://github.com/tpope/hookup"
  s.summary     = %q{Automate the bundle/migration tedium of Rails with Git hooks}
  s.description = %q{Automatically bundle and migrate your Rails app when switching branches, merging upstream changes, and bisecting.}

  s.rubyforge_project = "hookup"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end
