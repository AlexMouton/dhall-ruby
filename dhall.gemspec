# frozen_string_literal: true

Gem::Specification.new do |spec|
	spec.name          = "dhall"
	spec.version       = `git describe --always --dirty`
	spec.authors       = ["Stephen Paul Weber"]
	spec.email         = ["dev@singpolyma.net"]
	spec.license       = "GPL-3.0"

	spec.summary       = "The non-repetitive alternative to YAML, in Ruby"
	spec.description   = "This is a Ruby implementation of the Dhall " \
	                     "configuration language. Dhall is a powerful, " \
	                     "but safe and non-Turing-complete configuration " \
	                     "language. For more information, see: " \
	                     "https://dhall-lang.org"
	spec.homepage      = "https://git.sr.ht/~singpolyma/dhall-ruby"

	spec.files         =
		["lib/dhall/parser.citrus"] +
		`git ls-files -z`.split("\x00".b).reject do |f|
			f.start_with?(".", "test/", "scripts/") ||
				f == "Makefile" || f == "Gemfile"
		end
	spec.bindir        = "bin"
	spec.executables   = spec.files.grep(/^bin\//) { |f| File.basename(f) }
	spec.require_paths = ["lib"]

	spec.add_dependency "base32", "~> 0.3.2"
	spec.add_dependency "cbor", "~> 0.5.9.3"
	spec.add_dependency "citrus", "~> 3.0"
	spec.add_dependency "lazy_object", "~> 0.0.3"
	spec.add_dependency "multihashes", "~> 0.1.3"
	spec.add_dependency "promise.rb", "~> 0.7.4"
	spec.add_dependency "value_semantics", "~> 3.0"

	spec.add_development_dependency "abnf", "~> 0.0.1"
	spec.add_development_dependency "minitest-fail-fast", "~> 0.1.0"
	spec.add_development_dependency "simplecov", "~> 0.16.1"
	spec.add_development_dependency "webmock", "~> 3.5"
end
