# frozen_string_literal: true

require "minitest/autorun"
require "pathname"
require "cbor"

require "dhall/ast"
require "dhall/binary"

class TestAsJson < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "normalization/"

	Pathname.glob(TESTS + "**/*.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/.dhallb$/, "")
		define_method("test_#{test}") do
			assert_equal(
				CBOR.decode(path.read).inspect,
				Dhall.from_binary(path.read).as_json.inspect
			)
		end
	end
end
