# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/binary"
require "dhall/parser"
require "dhall/normalize"

class TestCacheKey < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/semantic-hash/success/"

	Pathname.glob(TESTS + "**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		define_method("test_#{test}") do
			skip "requires resolve" if test =~ /prelude\/|remoteSystems/

			assert_equal(
				(TESTS + "#{test}B.hash").read.chomp,
				Dhall::Parser.parse_file(path).value.cache_key
			)
		end
	end
end
