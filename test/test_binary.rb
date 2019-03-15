# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/ast"
require "dhall/binary"

class TestBinary < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "normalization/"

	Pathname.glob(TESTS + "**/*.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/.dhallb$/, "")
		define_method("test_#{test}") do
			assert_equal(
				path.binread,
				Dhall.from_binary(path.binread).to_binary
			)
		end
	end
end
