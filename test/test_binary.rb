# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/ast"
require "dhall/binary"

DIRPATH = Pathname.new(File.dirname(__FILE__))
TESTS = DIRPATH + "../dhall-lang/tests/parser/success/"

class TestParser < Minitest::Test
	Pathname.glob(TESTS + "*B.dhallb").each do |path|
		test = path.basename("B.dhallb").to_s
		define_method("test_#{test}") do
			assert_kind_of Dhall::Expression, Dhall.from_binary(path.read)
		end
	end
end
