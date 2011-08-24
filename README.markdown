Hookup
======

Hookup takes care of Rails tedium like bundling and migrating through
Git hooks.  It fires after events like

* pulling in upstream changes
* switching branches
* stepping through a bisect
* conflict in schema

Usage
-----

    $ cd yourproject
    $ gem install hookup
    $ hookup install
    Hooked up!

Bundling
--------

Each time your current HEAD changes, hookup checks to see if your
`Gemfile`, `Gemfile.lock`, or gem spec has changed.  If so, it runs
`bundle check`, and if that indicates any dependencies are unsatisfied,
it runs `bundle install`.

Migrating
---------

Each time your current HEAD changes, hookup checks to see if any
migrations have been added, deleted, or modified.  Deleted and modified
migrations are given the `rake db:migrate:down` treatment, then `rake
db:migrate` is invoked to bring everything else up to date.

Schema Resolving
----------------

Each time there's a conflict in `db/schema.rb` on the
`Rails::Schema.define` line, hookup resolves it in favor of the newer of
the two versions.
