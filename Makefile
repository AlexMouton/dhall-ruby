.PHONY: test

lib/dhall/parser.citrus: dhall-lang/standard/dhall.abnf
	bundle exec ruby -Ilib scripts/generate_citrus_parser.rb < $< > $@

test: lib/dhall/parser.citrus
	bundle exec ruby -Ilib test/test_suite.rb
