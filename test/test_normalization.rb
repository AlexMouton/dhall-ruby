# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/ast"
require "dhall/binary"
require "dhall/normalize"

DIRPATH = Pathname.new(File.dirname(__FILE__))
TESTS = DIRPATH + "normalization/beta/"

class TestParser < Minitest::Test
	Pathname.glob(TESTS + "*A.dhallb").each do |path|
		test = path.basename("A.dhallb").to_s
		define_method("test_#{test}") do
			assert_equal(
				Dhall.from_binary(TESTS + "#{test}B.dhallb"),
				Dhall.from_binary(path.read).normalize
			)
		end
	end
end
