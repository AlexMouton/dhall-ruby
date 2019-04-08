.PHONY: lint test unit clean

lib/dhall/parser.citrus: dhall-lang/standard/dhall.abnf scripts/generate_citrus_parser.rb lib/dhall/parser.rb
	bundle exec ruby -E UTF-8 -Ilib scripts/generate_citrus_parser.rb < dhall-lang/standard/dhall.abnf > $@

lint:
	rubocop -D

test: lib/dhall/parser.citrus
	bundle exec ruby -E UTF-8 -Ilib test/test_suite.rb

unit: lib/dhall/parser.citrus
	bundle exec ruby -E UTF-8 -Ilib test/test_suite.rb -n'/unit|simple|failure|import/'

clean:
	$(RM) lib/dhall/parser.citrus
