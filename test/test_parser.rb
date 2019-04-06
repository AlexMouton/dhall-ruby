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
			skip "very slow" if !ENV["CI"] && test =~ /largeExpression/
			skip "deprecated syntax" if test =~ /collectionImportType|annotations/
			match = Dhall::Parser.parse_file(path)
			assert(match)
			assert_kind_of(Dhall::Expression, match.value)
			assert_equal(
				(TESTS + "#{test}B.dhallb").binread,
				match.value.to_binary
			)
		end
	end

	Pathname.glob(TESTS + "failure/**/*.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		define_method("test_#{test}") do
			assert_raises Citrus::ParseError do
				Dhall::Parser.parse_file(path).value
			end
		end
	end
end
