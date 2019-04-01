# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall/typecheck"
require "dhall/binary"

class TestTypechecker < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "typechecker/"

	Pathname.glob(TESTS + "success/**/*A.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhallb$/, "")
		next if test =~ /prelude/

		define_method("test_#{test}") do
			assert_respond_to(
				Dhall::TypeChecker.for(
					Dhall::TypeAnnotation.new(
						value: Dhall.from_binary(path.binread),
						type:  Dhall.from_binary((TESTS + "#{test}B.dhallb").binread)
					)
				).annotate(Dhall::TypeChecker::Context.new),
				:type
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
				).annotate(Dhall::TypeChecker::Context.new)
			end
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
