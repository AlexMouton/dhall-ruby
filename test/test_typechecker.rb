# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/typecheck"
require "dhall/parser"

class TestTypechecker < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/typecheck/"

	Pathname.glob(TESTS + "success/**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")

		define_method("test_#{test}") do
			skip "needs resolve" if test =~ /prelude/
			assert_respond_to(
				Dhall::TypeChecker.for(
					Dhall::TypeAnnotation.new(
						value: Dhall::Parser.parse_file(path).value,
						type:  Dhall::Parser.parse_file(TESTS + "#{test}B.dhall").value
					)
				).annotate(Dhall::TypeChecker::Context.new),
				:type
			)
		end
	end

	Pathname.glob(TESTS + "failure/**/*.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/.dhall$/, "")

		define_method("test_#{test}") do
			assert_raises TypeError do
				Dhall::TypeChecker.for(
					Dhall::Parser.parse_file(path).value
				).annotate(Dhall::TypeChecker::Context.new)
			end
		end
	end

	ITESTS = DIRPATH + "../dhall-lang/tests/type-inference/"

	Pathname.glob(ITESTS + "success/**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")

		define_method("test_#{test}") do
			assert_equal(
				Dhall::Parser.parse_file(ITESTS + "#{test}B.dhall").value,
				Dhall::TypeChecker.for(
					Dhall::Parser.parse_file(path).value
				).annotate(Dhall::TypeChecker::Context.new).type
			)
		end
	end

	def forall(var, type)
		Dhall::Forall.new(var: var, type: type, body: Dhall::Variable["UNKNOWN"])
	end

	def test_variable_in_context
		context =
			Dhall::TypeChecker::Context
			.new
			.add(forall("x", Dhall::Variable["Type"]))
			.add(forall("x", Dhall::Variable["Kind"]))

		assert_equal(
			Dhall::Variable["Kind"],
			Dhall::TypeChecker.for(
				Dhall::Variable["x"]
			).annotate(context).type
		)
	end

	def test_variable_in_parent_context
		context =
			Dhall::TypeChecker::Context
			.new
			.add(forall("x", Dhall::Variable["Type"]))
			.add(forall("x", Dhall::Variable["Kind"]))

		assert_equal(
			Dhall::Variable["Type"],
			Dhall::TypeChecker.for(
				Dhall::Variable["x", 1]
			).annotate(context).type
		)
	end
end
