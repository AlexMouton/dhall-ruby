# frozen_string_literal: true

require "minitest/autorun"
require "pathname"
require "cbor"

require "dhall/ast"
require "dhall/binary"

class TestAsJson < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/**/success/"

	Pathname.glob(TESTS + "**/*.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/.dhallb$/, "")
		next if test =~ /binary-decode/
		define_method("test_#{test}") do
			skip "double as_json" if test =~ /double/i
			assert_equal(
				CBOR.decode(path.read),
				Dhall.from_binary(path.read).as_json
			)
		end
	end
end
