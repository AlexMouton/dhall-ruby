# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall"

class TestNormalization < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/{alpha-,}normalization/"

	Pathname.glob(TESTS + "success/**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")

		define_method("test_#{test}") do
			parsed_a = Dhall::Parser.parse_file(path).value
			resolved_a = if test !~ /unit|simple/
				parsed_a.resolve(
					relative_to: Dhall::Import::Path.from_string(path)
				)
			else
				Promise.resolve(parsed_a)
			end.sync

			# Dhall::Function.disable_alpha_normalization! if test !~ /alpha/
			binary_a = resolved_a.normalize.to_binary

			parsed_b = Dhall::Parser.parse_file(TESTS + "#{test}B.dhall").value
			# For now, normalize b side also so that alpha equivalence works out
			binary_b = parsed_b.normalize.to_binary
			# Dhall::Function.enable_alpha_normalization! if test !~ /alpha/

			assert_equal(binary_b, binary_a)
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
