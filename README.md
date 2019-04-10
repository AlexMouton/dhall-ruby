# Dhall for Ruby

This is a Ruby implementation of the Dhall configuration language.  Dhall is a powerful, but safe and non-Turing-complete configuration language.  For more information, see: https://dhall-lang.org

## Versioning and Standard Compliance

This project follows semantic versioning, and every tagged version claims to adhere to the version of the dhall-lang standard that is linked in the dhall-lang submodule.

For the purposes of considering what is a "breaking change" only the API as documented in this documentation is considered, regardless of any other exposed parts of the library.  Anything not documented here may change at any time, but backward-incompatible changes to anything documented here will be accompanied by a major-version increment.

## Installation

Add this line to your application's Gemfile:

    gem 'dhall'

And then execute:

    bundle

Or install it yourself as:

    gem install dhall

## Load Expressions

    require "dhall"
    Dhall.load("1 + 1").then do |value|
      value # => #<Dhall::Natural value=2>
    end

    Dhall.load("./path/to/config.dhall").then do |config|
      # ... use config from file
    end

    Dhall.load("https://example.com/config.dhall").then do |config|
      # ... use config from URL
    end

`Dhall.load` will parse a Dhall expression, resolve imports, check that the types are correct, and fully normalize.  The result is returned as a `Promise` to enable using import resolvers that use async I/O.

### Non-Async Load

Wherever possible, you should use the `Promise` API and treat `Dhall.load` as an async operation.  *If* that is not possible, or *if* you know you are using a resolver that is not async, or *if* you know that there are no imports in your expression, you may use the escape hatch:

    Dhall.load("1 + 1").sync # => #<Dhall::Natural value=2>

**This will block the thread it is run from until the whole load operation is complete.  Never call #sync from an async context.**

### Customizing Import Resolution

You may optionally pass `Dhall.load` a resolver that will be used to resolve all imports during the load process:

    Dhall.load(expr, resolver: some_resolver)

There are a few provided resolvers for you to choose from:

* `Dhall::Resolvers::Default` supports loading from http, https, local path, and IPFS sources.  IPFS imports will come from the local mountpoint, if present, with automatic fallbacks to the local gateway, if present, and finally a public gateway.
* `Dhall::Resolvers::Standard` should be used if you want strict dhall-lang standard compliance.  It supports loading from http, https, and local paths.
* `Dhall::Resolvers::LocalOnly` only allows imports from local paths.
* `Dhall::Resolvers::None` will not allow any imports.

It is possible to customize these options further, or provide your own resolver, but this is undocumented for now.

## Function

A Dhall expression may be a function, which can be used like any other Ruby proc:

    Dhall.load("\\(x: Natural) -> x + 1").then do |f|
      f.call(1)     # => #<Dhall::Natural value=2>
      f[1]          # => #<Dhall::Natural value=2>
      [1,2].map(&f) # => [#<Dhall::Natural value=2>, #<Dhall::Natural value=3>]
      f.to_proc     # => #<Proc:0xXXXX (lambda)>
    end

A curried function may be called either curried or uncurried:

    Dhall.load("\\(x: Natural) -> \\(y: Natural) -> x + y").then do |f|
      f.call(1).call(1) # => #<Dhall::Natural value=2>
      f.call(1, 1)      # => #<Dhall::Natural value=2>
    end

## Boolean

A Dhall expression may be a boolean, which supports some common messages:

    Dhall.load("True").then do |bool|
      bool & false             # => false
      bool | false             # => #<Dhall::Bool value=true>
      !bool                    # => #<Dhall::Bool value=false>
      bool === true            # => true
      bool.reduce(true, false) # => true
      bool.to_s                # => "True"
    end

If you need an actual instance of `TrueClass` or `FalseClass`, the suggested method is `bool === true`.

## Natural

A Dhall expression may be a natural (positive) number, which supports some common messages:

    Dhall.load("1").then do |nat|
      nat + 1   # => #<Dhall::Natural value=2>
      1 + nat   # => #<Dhall::Natural value=2>
      nat * 2   # => #<Dhall::Natural value=2>
      2 * nat   # => #<Dhall::Natural value=2>
      nat === 1 # => true
      nat.zero? # => false
      nat.even? # => false
      nat.odd?  # => true
      nat.pred  # => #<Dhall::Natural value=0>
      nat.to_s  # => "1"
      nat.to_i  # => 1
    end

## Integer

A Dhall expression may be an integer (positive or negative).  Dhall integers are opaque, and support fewer operations than naturals:

    Dhall.load("+1").then do |int|
      int === 1 # => true
      int.to_s  # "+1"
      int.to_i  # 1
    end

## Double

A Dhall expression may be a double-precision floating point number.  Dhall doubles are opaque, and support fewer operations than naturals:

    Dhall.load("1.0").then do |double|
      double === 1.0 # => true
      double.to_s    # "1.0"
      double.to_f    # 1.0
    end

## Text

A Dhall expression may be a string of text, which supports some common messages:

    Dhall.load("\"abc\"").then do |text|
      text === "abc" # => true
      text.to_s      # "abc"
    end

## Optional

A Dhall expression may be optionally present, like so:

    Dhall.load("Some 1").then do |some|
      some.map { |x| x + 1 }             # => #<Dhall::Optional value=#<Dhall::Natural value=2> value_type=nil>
      some.map(type: dhall_type) { ... } # => #<Dhall::Optional value=... value_type=dhall_type>
      some.reduce(nil) { |x| x }         # => #<Dhall::Natural value=1>
      some.to_s                          # => 1
    end

    Dhall.load("None Natural").then do |none|
      none.map { |x| x + 1 }             # => #<Dhall::OptionalNone ...>
      none.map(type: dhall_type) { ... } # => #<Dhall::OptionalNone value_type=dhall_type>
      none.reduce(nil) { |x| x }         # => nil
      none.to_s                          # => ""
    end

## List

A Dhall expression may be a list of other expressions.  Lists are `Enumerable` and support all operations that entails, with some special cases:

    Dhall.load("[1,2]").then do |list|
      list.map { |x| x + 1 }             # => #<Dhall::List elements=[#<Dhall::Natural value=2>, #<Dhall::Natural value=3>] element_type=nil>
      list.map(type: dhall_type) { ... } # => #<Dhall::List elements=[...] element_type=dhall_type>
      list.reduce(nil) { |x, _| x }      # => #<Dhall::Natural value=1>
      list.first                         # => #<Dhall::Optional value=#<Dhall::Natural value=1> value_type=...>
      list.last                          # => #<Dhall::Optional value=#<Dhall::Natural value=2> value_type=...>
      list[0]                            # => #<Dhall::Optional value=#<Dhall::Natural value=1> value_type=...>
      list[100]                          # => #<Dhall::OptionalNone value_type=...>
      list.reverse                       # => #<Dhall::List elements=[#<Dhall::Natural value=2>, #<Dhall::Natural value=1>] element_type=...>
      list.join(",")                     # => "1,2"
      list.to_a                          # => [1,2]
    end

## Record

A Dhall expression may be a record of keys mapped to other expressions.  Records are `Enumerable` and support many common operations:

    Dhall.load("{ a = 1 }").then do |rec|
      rec["a"]                      # => #<Dhall::Natural value=1>
      rec[:a]                       # => #<Dhall::Natural value=1>
      rec["b"]                      # => nil
      rec.fetch("a")                # => #<Dhall::Natural value=1>
      rec.fetch(:a)                 # => #<Dhall::Natural value=1>
      rec.fetch(:b)                 # => raise KeyError
      rec.dig(:a)                   # => #<Dhall::Natural value=1>
      rec.dig(:b)                   # => nil
      rec.slice(:a)                 # => #<Dhall::Record a=#<Dhall::Natural value=1>>
      rec.slice                     # => #<Dhall::EmptyRecord >
      rec.keys                      # => ["a"]
      rec.values                    # => [#<Dhall::Natural value=1>]
      rec.map { |k, v| [k, v + 1] } # => #<Dhall::Record a=#<Dhall::Natural value=2>>
      rec.merge(b: 2)               # => #<Dhall::Record a=#<Dhall::Natural value=1> b=#<Dhall::Natural value=2>>
      rec.deep_merge(b: 2)          # => #<Dhall::Record a=#<Dhall::Natural value=1> b=#<Dhall::Natural value=2>>
    end

## Union

A Dhall expression may be a union or enum.  These support both a way to handle each case, and a less safe method to extract a dynamically typed object:

    Dhall.load("< one | two >.one").then do |enum|
      enum.to_s                   # => "one"
      enum.reduce(one: 1, two: 2) # => 1
      enum.extract                # :one
    end

    Dhall.load("< Natural: Natural | Text: Text >.Natural 1").then do |union|
      union.to_s                                # => "1"
      union.reduce(Natural: :to_i, Text: :to_i) # => 1
      union.extract                             # => #<Dhall::Natural value=1>
    end

## Serializing Expressions

Dhall expressions may be serialized to a binary format for consumption by machines:

    expression.to_binary

If you are writing out an expression for later editing by a human, you should get [the Dhall command line tools](https://github.com/dhall-lang/dhall-haskell/releases) for your platform to make these easier to work with.  You can pretty print the binary format for human editing like so:

    dhall decode < path/to/binary/expression.dhallb

## Semantic Hash

Dhall expressions support creating a "semantic hash" that is the same for all expressions with the same normal form.  This makes it very useful as a cache key or an integrity check, since formatting changes to the source code will not change the hash:

    expression.cache_key

## Serializing Ruby Objects

You may wish to convert your existing Ruby objects to Dhall expressions.  This can be done using the AsDhall refinement:

    using Dhall::AsDhall
    1.as_dhall  # => #<Dhall::Natural value=1>
    {}.as_dhall # => #<Dhall::EmptyRecord >

Many methods on Dhall expressions call `#as_dhall` on their arguments, so you can define it on your own objects to produce a custom serialization.

## Porting from YAML or JSON Configuration

To aid in converting your existing configurations or serialized data, there are included some experimental scripts:

    bundle exec json-to-dhall < path/to/config.json | dhall decode
    bundle exec yaml-to-dhall < path/to/config.yaml | dhall decode

## Getting Help

If you have any questions about this library, or wish to report a bug, please send email to: dev@singpolyma.net

## Contributing

If you have code or patches you wish to contribute, the maintainer's preferred mechanism is a git pull request.  Push your changes to a git repository somewhere, for example:

    git remote rename origin upstream
    git remote add origin git@git.sr.ht:~yourname/dhall-ruby
    git push -u origin master

Then generate the pull request:

    git fetch upstream master
    git request-pull -p upstream/master origin

And copy-paste the result into a plain-text email to: dev@singpolyma.net

You may alternately use a patch-based approach as described on https://git-send-email.io

Contributions follow an inbound=outbound model -- you (or your employer) keep all copyright on your patches, but agree to license them according to this project's COPYING file.
