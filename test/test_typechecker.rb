# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/typecheck"
require "dhall/binary"

class TestNormalization < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "typechecker/"

	Pathname.glob(TESTS + "success/**/*A.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhallb$/, "")

		define_method("test_#{test}") do
			assert_equal(
				Dhall.from_binary((TESTS + "#{test}B.dhallb").binread),
				Dhall::TypeChecker.for(
					Dhall.from_binary(path.binread)
				).annotate(Dhall::TypeChecker::Context.new).type
			)
		end
	end

	Pathname.glob(TESTS + "failure/**/*.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/.dhallb$/, "")

		define_method("test_#{test}") do
			assert_raises TypeError do
				expr = Dhall.from_binary(path.binread)
				Dhall::TypeChecker.for(
					expr
				).annotate(Dhall::TypeChecker::Context.new).type
			end
		end
	end

	def test_variable_in_context
		context =
			Dhall::TypeChecker::Context.new
				.add("x", Dhall::Variable["Type"])
				.add("x", Dhall::Variable["Kind"])

		assert_equal(
			Dhall::Variable["Kind"],
			Dhall::TypeChecker.for(
				Dhall::Variable["x"]
			).annotate(context).type
		)
	end

	def test_variable_in_parent_context
		context =
			Dhall::TypeChecker::Context.new
				.add("x", Dhall::Variable["Type"])
				.add("x", Dhall::Variable["Kind"])

		assert_equal(
			Dhall::Variable["Type"],
			Dhall::TypeChecker.for(
				Dhall::Variable["x", 1]
			).annotate(context).type
		)
	end
end
