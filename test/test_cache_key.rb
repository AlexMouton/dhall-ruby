# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall"

class TestCacheKey < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/semantic-hash/success/"

	Pathname.glob(TESTS + "**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		define_method("test_#{test}") do
			parsed_a = Dhall::Parser.parse_file(path).value
			hash_a = if test !~ /unit|simple/
				parsed_a.resolve(
					relative_to: Dhall::Import::Path.from_string(path)
				)
			else
				Promise.resolve(parsed_a)
			end.then(&:cache_key).sync

			assert_equal (TESTS + "#{test}B.hash").read.chomp, hash_a
		end
	end
end
