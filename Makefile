.PHONY: test

lib/dhall/parser.citrus: dhall-lang/standard/dhall.abnf scripts/generate_citrus_parser.rb lib/dhall/parser.rb
	bundle exec ruby -Ilib scripts/generate_citrus_parser.rb < dhall-lang/standard/dhall.abnf > $@

test: lib/dhall/parser.citrus
	bundle exec ruby -Ilib test/test_suite.rb