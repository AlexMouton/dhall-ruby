.PHONY: lint test unit clean

lib/dhall/parser.citrus: dhall-lang/standard/dhall.abnf scripts/generate_citrus_parser.rb lib/dhall/parser.rb
	bundle exec ruby -E UTF-8 scripts/generate_citrus_parser.rb < dhall-lang/standard/dhall.abnf > $@

dhall.gem: lib/dhall/parser.citrus dhall.gemspec
	$(RM) dhall.gem
	gem build dhall.gemspec
	mv dhall*.gem dhall.gem

lint:
	rubocop -D

test: lib/dhall/parser.citrus
	bundle exec ruby -E UTF-8 test/test_suite.rb

unit: lib/dhall/parser.citrus
	bundle exec ruby -E UTF-8 test/test_suite.rb -n'/unit|import|TestReadme|TestLoad|TestAsDhall|TestResolvers|TestBinary|TestAsJson/'

clean:
	$(RM) lib/dhall/parser.citrus
