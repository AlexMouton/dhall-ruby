# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

require "dhall"

class TestTypechecker < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/typecheck/"

	Pathname.glob(TESTS + "success/**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		bside = TESTS + "#{test}B.dhall"

		define_method("test_#{test}") do
			parsed_a = Dhall::Parser.parse_file(path).value
			parsed_b = Dhall::Parser.parse_file(bside).value

			final_a, final_b = if test !~ /unit|simple/
				Promise.all([parsed_a, parsed_b].map { |e|
					e.resolve(
						relative_to: Dhall::Import::Path.from_string(path)
					)
				})
			else
				Promise.resolve([parsed_a, parsed_b])
			end.sync

			assert_respond_to(
				Dhall::TypeChecker.for(
					Dhall::TypeAnnotation.new(value: final_a, type: final_b)
				).annotate(Dhall::TypeChecker::Context.new),
				:type
			)
		end
	end

	Pathname.glob(TESTS + "failure/**/*.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/.dhall$/, "")

		define_method("test_#{test}") do
			skip "duplicate union" if test =~ /UnionTypeDuplicateVariants/
			skip "duplicate record" if test =~ /RecordTypeDuplicateFields/

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
			skip "alpha normalizing equivalences" if test =~ /AssertAlpha/

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

	def test_unknown_expression
		assert_raises TypeError do
			Dhall::TypeChecker.for(Class.new.new).annotate(
				Dhall::TypeChecker::Context.new
			)
		end
	end

	def test_unknown_builtin
		assert_raises TypeError do
			Dhall::TypeChecker.for(Class.new(Dhall::Builtin).new).annotate(
				Dhall::TypeChecker::Context.new
			)
		end
	end

	def test_enum
		union = Dhall::Enum.new(
			tag:          "red",
			alternatives: Dhall::UnionType.new(alternatives: {})
		)

		assert_equal(
			Dhall::UnionType.new(alternatives: { "red" => nil }),
			Dhall::TypeChecker.for(union).annotate(
				Dhall::TypeChecker::Context.new
			).type
		)
	end
end
