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

	def test_shift_1_x_0_x
		assert_equal(
			Dhall::Variable.new(name: "x", index: 1),
			Dhall::Variable.new(name: "x").shift(1, "x", 0)
		)
	end

	def test_shift_1_x_1_x
		assert_equal(
			Dhall::Variable.new(name: "x", index: 0),
			Dhall::Variable.new(name: "x").shift(1, "x", 1)
		)
	end

	def test_shift_1_x_0_y
		assert_equal(
			Dhall::Variable.new(name: "y", index: 0),
			Dhall::Variable.new(name: "y").shift(1, "x", 0)
		)
	end

	def test_shift_neg1_x_0_x1
		assert_equal(
			Dhall::Variable.new(name: "x", index: 0),
			Dhall::Variable.new(name: "x", index: 1).shift(-1, "x", 0)
		)
	end

	def test_shift_closed
		assert_equal(
			Dhall::Function.new(
				var: "x",
				type: Dhall::Variable.new(name: "Type"),
				body: Dhall::Variable.new(name: "x", index: 0)
			),
			Dhall::Function.new(
				var: "x",
				type: Dhall::Variable.new(name: "Type"),
				body: Dhall::Variable.new(name: "x", index: 0)
			).shift(1, "x", 0)
		)
	end

	def test_shift_free
		assert_equal(
			Dhall::Function.new(
				var: "y",
				type: Dhall::Variable.new(name: "Type"),
				body: Dhall::Variable.new(name: "x", index: 1)
			),
			Dhall::Function.new(
				var: "y",
				type: Dhall::Variable.new(name: "Type"),
				body: Dhall::Variable.new(name: "x", index: 0)
			).shift(1, "x", 0)
		)
	end
end
