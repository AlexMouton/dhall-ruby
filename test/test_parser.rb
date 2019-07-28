# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/parser"
require "dhall/binary"

class TestParser < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/parser/"

	Pathname.glob(TESTS + "success/**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		define_method("test_#{test}") do
			skip "very slow" if !ENV.key?("CI") && test =~ /largeExpression/
			match = Dhall::Parser.parse_file(path)
			assert(match)
			assert_kind_of(Dhall::Expression, match.value)
			assert_equal(
				(TESTS + "#{test}B.dhallb").binread,
				match.value.to_cbor
			)
		end
	end

	Pathname.glob(TESTS + "failure/**/*.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		define_method("test_#{test}") do
			# ArgumentError for non-utf8
			assert_raises Citrus::ParseError, ArgumentError do
				Dhall::Parser.parse_file(path).value
			end
		end
	end
end
