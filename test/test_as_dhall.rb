# frozen_string_literal: true

require "minitest/autorun"

require "dhall"

class TestAsDhall < Minitest::Test
	using Dhall::AsDhall

	def test_string
		assert_equal Dhall::Text.new(value: "hai"), "hai".as_dhall
	end

	def test_string_encoding
		assert_equal(
			Dhall::Text.new(value: "hai"),
			"hai".encode("UTF-16BE").as_dhall
		)
	end

	def test_string_failure
		assert_raises Encoding::UndefinedConversionError do
			"\xff".b.as_dhall
		end
	end

	def test_symbol
		assert_equal(
			Dhall::Union.new(
				tag:          "hai",
				value:        nil,
				alternatives: Dhall::UnionType.new(alternatives: {})
			),
			:hai.as_dhall
		)
	end

	def test_natural
		assert_equal Dhall::Natural.new(value: 1), 1.as_dhall
	end

	def test_big_natural
		assert_equal(
			Dhall::Natural.new(value: 10000000000000000000000000000000000),
			10000000000000000000000000000000000.as_dhall
		)
	end

	def test_negative_integer
		assert_equal Dhall::Integer.new(value: -1), -1.as_dhall
	end

	def test_double
		assert_equal Dhall::Double.new(value: 1.0), 1.0.as_dhall
	end

	def test_double_infinity
		assert_equal(
			Dhall::Double.new(value: Float::INFINITY),
			Float::INFINITY.as_dhall
		)
	end

	def test_true
		assert_equal Dhall::Bool.new(value: true), true.as_dhall
	end

	def test_false
		assert_equal Dhall::Bool.new(value: false), false.as_dhall
	end

	def test_nil
		assert_raises RuntimeError do
			nil.as_dhall
		end
	end

	def test_empty_array
		assert_equal(
			Dhall::EmptyList.new(element_type: Dhall::UnionType.new(alternatives: {})),
			[].as_dhall
		)
	end

	def test_array_one_natural
		assert_equal(
			Dhall::List.new(elements: [Dhall::Natural.new(value: 1)]),
			[1].as_dhall
		)
	end

	def test_array_natural_and_nil
		assert_equal(
			Dhall::List.new(elements: [
				Dhall::Optional.new(value: Dhall::Natural.new(value: 1)),
				Dhall::OptionalNone.new(value_type: Dhall::Variable["Natural"])
			]),
			[1, nil].as_dhall
		)
	end

	def test_array_natural_and_bignum_and_nil
		assert_equal(
			Dhall::List.new(elements: [
				Dhall::Optional.new(value: Dhall::Natural.new(value: 1)),
				Dhall::Optional.new(value: Dhall::Natural.new(
					value: 10000000000000000000000000000000000
				)),
				Dhall::OptionalNone.new(value_type: Dhall::Variable["Natural"])
			]),
			[1, 10000000000000000000000000000000000, nil].as_dhall
		)
	end

	def test_array_mixed
		array_key = "Array_f256441295d38d19e84f2de0596f5ae2377" \
		            "c923c4162351d88f7648d741cdd0c"
		hash_key = "Hash_76cf2d18fa656820d79d13cad11bf3e613fdb0" \
		           "6ff80f968ba1755d27cdf5eab3"
		union_type = Dhall::UnionType.new(
			alternatives: {
				"Natural" => Dhall::Variable["Natural"],
				"Text"    => Dhall::Variable["Text"],
				"None"    => nil,
				"Bool"    => Dhall::Variable["Bool"],
				hash_key  => Dhall::RecordType.new(
					record: {
						"a" => Dhall::Variable["Natural"]
					}
				),
				array_key => Dhall::Application.new(
					function: Dhall::Variable["List"],
					argument: Dhall::Variable["Natural"]
				)
			}
		)

		assert_equal(
			Dhall::List.new(elements: [
				Dhall::Union.from(union_type, "Natural", Dhall::Natural.new(value: 1)),
				Dhall::Union.from(union_type, "Text", Dhall::Text.new(value: "hai")),
				Dhall::Union.from(union_type, "None", nil),
				Dhall::Union.from(union_type, "Bool", Dhall::Bool.new(value: true)),
				Dhall::Union.from(union_type, "Bool", Dhall::Bool.new(value: false)),
				Dhall::Union.from(union_type, hash_key, Dhall::Record.new(
					record: { "a" => Dhall::Natural.new(value: 1) }
				)),
				Dhall::Union.from(union_type, array_key, Dhall::List.new(
					elements: [Dhall::Natural.new(value: 1)]
				))
			]),
			[1, "hai", nil, true, false, { a: 1 }, [1]].as_dhall
		)
	end

	def test_empty_hash
		assert_equal Dhall::EmptyRecord.new, {}.as_dhall
	end

	def test_hash_of_natural
		assert_equal(
			Dhall::Record.new(record: { "a" => Dhall::Natural.new(value: 1) }),
			{ "a" => 1 }.as_dhall
		)
	end

	def test_hash_of_natural_symbol_keys
		assert_equal(
			Dhall::Record.new(record: { "a" => Dhall::Natural.new(value: 1) }),
			{ a: 1 }.as_dhall
		)
	end

	def test_hash_mixed
		assert_equal(
			Dhall::Record.new(
				record: {
					"a" => Dhall::Natural.new(value: 1),
					"b" => Dhall::Text.new(value: "hai"),
					"c" => Dhall::Bool.new(value: true)
				}
			),
			{ a: 1, b: "hai", c: true }.as_dhall
		)
	end

	def test_hash_nested
		assert_equal(
			Dhall::Record.new(
				record: { "a" => Dhall::Record.new(
					record: { "b" => Dhall::Natural.new(value: 1) }
				) }
			),
			{ a: { b: 1 } }.as_dhall
		)
	end

	def test_openstruct
		assert_equal(
			Dhall::Union.new(
				tag:          "OpenStruct",
				value:        Dhall::TypeAnnotation.new(
					type:  Dhall::EmptyRecordType.new,
					value: Dhall::EmptyRecord.new
				),
				alternatives: Dhall::UnionType.new(alternatives: {})
			),
			OpenStruct.new({}).as_dhall
		)
	end

	class SomeTestClass
		def initialize
			@a = 1
			@b = "hai"
		end
	end

	def test_object
		assert_equal(
			Dhall::Union.new(
				tag:          "TestAsDhall::SomeTestClass",
				value:        Dhall::TypeAnnotation.new(
					type:  Dhall::RecordType.new(
						record: {
							"a" => Dhall::Variable["Natural"],
							"b" => Dhall::Variable["Text"]
						}
					),
					value: Dhall::Record.new(
						record: {
							"a" => Dhall::Natural.new(value: 1),
							"b" => Dhall::Text.new(value: "hai")
						}
					)
				),
				alternatives: Dhall::UnionType.new(alternatives: {})
			),
			SomeTestClass.new.as_dhall
		)
	end
end
