# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/ast"
require "dhall/binary"
require "dhall/normalize"

class TestNormalization < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "normalization/"

	Pathname.glob(TESTS + "**/*A.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhallb$/, "")
		next if test =~ /prelude\//
		next if test =~ /remoteSystems/
		next if test =~ /multiline\//

		define_method("test_#{test.gsub(/\//, "_")}") do
			Dhall::Function.disable_alpha_normalization! if test =~ /^standard\//
			assert_equal(
				Dhall.from_binary((TESTS + "#{test}B.dhallb").binread),
				Dhall.from_binary(path.binread).normalize
			)
			Dhall::Function.enable_alpha_normalization! if test =~ /^standard\//
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
		expr = Dhall::Function.new(
			var:  "x",
			type: Dhall::Variable.new(name: "Type"),
			body: Dhall::Variable.new(name: "x", index: 0)
		)

		assert_equal(expr, expr.shift(1, "x", 0))
	end

	def test_shift_free
		assert_equal(
			Dhall::Function.new(
				var:  "y",
				type: Dhall::Variable.new(name: "Type"),
				body: Dhall::Variable.new(name: "x", index: 1)
			),
			Dhall::Function.new(
				var:  "y",
				type: Dhall::Variable.new(name: "Type"),
				body: Dhall::Variable.new(name: "x", index: 0)
			).shift(1, "x", 0)
		)
	end

	def test_substitute_variable
		assert_equal(
			Dhall::Natural.new(value: 1),
			Dhall::Variable.new(name: "x", index: 0).substitute(
				Dhall::Variable.new(name: "x", index: 0),
				Dhall::Natural.new(value: 1)
			)
		)
	end

	def test_substitute_variable_different_name
		assert_equal(
			Dhall::Variable.new(name: "y", index: 0),
			Dhall::Variable.new(name: "y", index: 0).substitute(
				Dhall::Variable.new(name: "x", index: 0),
				Dhall::Natural.new(value: 1)
			)
		)
	end

	def test_substitute_variable_different_index
		assert_equal(
			Dhall::Variable.new(name: "x", index: 1),
			Dhall::Variable.new(name: "x", index: 1).substitute(
				Dhall::Variable.new(name: "x", index: 0),
				Dhall::Natural.new(value: 1)
			)
		)
	end
end
