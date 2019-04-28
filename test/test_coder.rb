# frozen_string_literal: true

require "minitest/autorun"

require "dhall"

class TestCoder < Minitest::Test
	def test_dump_integer
		assert_equal "\x82\x0F\x01".b, Dhall::Coder.dump(1)
	end

	def test_dump_integer_negative
		assert_equal "\x82\x10 ".b, Dhall::Coder.dump(-1)
	end

	def test_dump_float
		assert_equal "\xFA?\x80\x00\x00".b, Dhall::Coder.dump(1.0)
	end

	def test_dump_string
		assert_equal "\x82\x12ehello".b, Dhall::Coder.dump("hello")
	end

	def test_dump_nil
		assert_nil Dhall::Coder.dump(nil)
	end

	def test_dump_array
		assert_equal(
			"\x84\x04\xF6\x82\x0F\x01\x82\x0F\x02".b,
			Dhall::Coder.dump([1, 2])
		)
	end

	def test_dump_array_with_nil
		assert_equal(
			"\x84\x04\xF6\x83\x05\xF6\x82\x0F\x01\x83\x00dNonegNatural".b,
			Dhall::Coder.dump([1, nil])
		)
	end

	def test_dump_array_heterogenous
		assert_equal(
			"\x86\x04\xF6\x83\x00\x83\t\x82\v\xA4fDoublefDoublegNatural" \
			"gNaturaldNone\xF6dTextdTextgNatural\x82\x0F\x01\x83\t\x82\v\xA4" \
			"fDoublefDoublegNaturalgNaturaldNone\xF6dTextdTextdNone\x83\x00\x83" \
			"\t\x82\v\xA4fDoublefDoublegNaturalgNaturaldNone\xF6dTextdText" \
			"fDouble\xFA?\x80\x00\x00\x83\x00\x83\t\x82\v\xA4fDoublefDoubleg" \
			"NaturalgNaturaldNone\xF6dTextdTextdText\x82\x12ehello".b,
			Dhall::Coder.dump([1, nil, 1.0, "hello"])
		)
	end

	def test_dump_hash
		assert_equal(
			"\x82\b\xA2aa\x82\x0F\x01ab\xFA?\x80\x00\x00".b,
			Dhall::Coder.dump(a: 1, b: 1.0)
		)
	end

	def test_dump_object
		assert_raises ArgumentError do
			Dhall::Coder.dump(Object.new)
		end
	end

	def test_load_loaded
		assert_equal 1, Dhall::Coder.load(1)
	end

	def test_load_integer
		assert_equal 1, Dhall::Coder.load("\x82\x0F\x01".b)
	end

	def test_load_integer_negative
		assert_equal(-1, Dhall::Coder.load("\x82\x10 ".b))
	end

	def test_load_float
		assert_equal 1.0, Dhall::Coder.load("\xFA?\x80\x00\x00".b)
	end

	def test_load_string
		assert_equal "hello", Dhall::Coder.load("\x82\x12ehello".b)
	end

	def test_load_nil
		assert_nil Dhall::Coder.load(nil)
	end

	def test_load_array
		assert_equal(
			[1, 2],
			Dhall::Coder.load("\x84\x04\xF6\x82\x0F\x01\x82\x0F\x02".b)
		)
	end

	def test_load_array_with_nil
		assert_equal(
			[1, nil],
			Dhall::Coder.load(
				"\x84\x04\xF6\x83\x05\xF6\x82\x0F\x01\x83\x00dNonegNatural".b
			)
		)
	end

	def test_load_array_heterogenous
		assert_equal(
			[1, nil, 1.0, "hello"],
			Dhall::Coder.load(
				"\x86\x04\xF6\x83\x00\x83\t\x82\v\xA4fDoublefDoublegNatural" \
				"gNaturaldNone\xF6dTextdTextgNatural\x82\x0F\x01\x83\t\x82\v\xA4" \
				"fDoublefDoublegNaturalgNaturaldNone\xF6dTextdTextdNone\x83\x00\x83" \
				"\t\x82\v\xA4fDoublefDoublegNaturalgNaturaldNone\xF6dTextdText" \
				"fDouble\xFA?\x80\x00\x00\x83\x00\x83\t\x82\v\xA4fDoublefDoubleg" \
				"NaturalgNaturaldNone\xF6dTextdTextdText\x82\x12ehello".b
			)
		)
	end

	def test_load_hash
		assert_equal(
			{ "a" => 1, "b" => 1.0 },
			Dhall::Coder.load("\x82\b\xA2aa\x82\x0F\x01ab\xFA?\x80\x00\x00".b)
		)
	end

	def test_load_hash_symbolize
		assert_equal(
			{ a: 1, b: 1.0 },
			Dhall::Coder.load(
				"\x82\b\xA2aa\x82\x0F\x01ab\xFA?\x80\x00\x00".b,
				transform_keys: :to_sym
			)
		)
	end

	def test_load_object
		assert_raises ArgumentError do
			Dhall::Coder.load(
				"\x83\x00\x83\t\x82\v\xA1fObject\x82\a\xA0fObject\x82\b\xA0".b
			)
		end
	end

	class Custom
		attr_reader :a, :b

		def initialize
			@a = true
			@b = "true"
		end

		def ==(other)
			a == other.a && b == other.b
		end
	end

	def test_bad_default
		assert_raises ArgumentError do
			Dhall::Coder.new(safe: Custom)
		end
	end

	def test_dump_custom
		assert_equal(
			"\x83\x00\x83\t\x82\v\xA1qTestCoder::Custom\x82\a\xA2aadBoolabd" \
			"TextqTestCoder::Custom\x82\b\xA2aa\xF5ab\x82\x12dtrue".b,
			Dhall::Coder.new(default: Custom.new, safe: Custom).dump(Custom.new)
		)
	end

	def test_load_custom
		coder = Dhall::Coder.new(
			default: Custom.new,
			safe:    Dhall::Coder::JSON_LIKE + [Custom]
		)
		assert_equal(
			Custom.new,
			coder.load(
				"\x83\x00\x83\t\x82\v\xA1qTestCoder::Custom\x82\a\xA2aadBoolabd" \
				"TextqTestCoder::Custom\x82\b\xA2aa\xF5ab\x82\x12dtrue".b
			)
		)
	end

	class CustomCoding
		attr_reader :a, :b

		def initialize
			@a = true
			@b = "true"
		end

		def ==(other)
			a == other.a && b == other.b
		end

		def init_with(coder)
			@a = coder["abool"]
			@b = coder["astring"]
		end

		def encode_with(coder)
			coder["abool"] = @a
			coder["astring"] = @b
		end
	end

	def test_dump_custom_coding
		assert_equal(
			"\x83\x00\x83\t\x82\v\xA1wTestCoder::CustomCoding\x82\a\xA2" \
			"eabooldBoolgastringdTextwTestCoder::CustomCoding\x82\b\xA2" \
			"eabool\xF5gastring\x82\x12dtrue".b,
			Dhall::Coder.new(
				default: CustomCoding.new,
				safe:    CustomCoding
			).dump(CustomCoding.new)
		)
	end

	def test_load_custom_coding
		coder = Dhall::Coder.new(
			default: CustomCoding.new,
			safe:    Dhall::Coder::JSON_LIKE + [CustomCoding]
		)
		assert_equal(
			CustomCoding.new,
			coder.load(
				"\x83\x00\x83\t\x82\v\xA1wTestCoder::CustomCoding\x82\a\xA2" \
				"eabooldBoolgastringdTextwTestCoder::CustomCoding\x82\b\xA2" \
				"eabool\xF5gastring\x82\x12dtrue".b
			)
		)
	end

	class CustomDhall
		using Dhall::AsDhall

		attr_reader :str

		def self.from_dhall(expr)
			new(expr.to_s)
		end

		def initialize(str="test")
			@str = str
		end

		def ==(other)
			str == other.str
		end

		def as_dhall
			Dhall::Union.from(
				Dhall::UnionType.new(
					alternatives: { self.class.name => Dhall::Text.as_dhall }
				),
				self.class.name,
				@str.as_dhall
			)
		end
	end

	def test_dump_custom_dhall
		assert_equal(
			"\x83\x00\x83\t\x82\v\xA1vTestCoder::CustomDhalldText" \
			"vTestCoder::CustomDhall\x82\x12dtest".b,
			Dhall::Coder.new(
				default: CustomDhall.new,
				safe:    CustomDhall
			).dump(CustomDhall.new)
		)
	end

	def test_load_custom_dhall
		coder = Dhall::Coder.new(
			default: CustomDhall.new,
			safe:    Dhall::Coder::JSON_LIKE + [CustomDhall]
		)
		assert_equal(
			CustomDhall.new,
			coder.load(
				"\x83\x00\x83\t\x82\v\xA1vTestCoder::CustomDhalldText" \
				"vTestCoder::CustomDhall\x82\x12dtest".b
			)
		)
	end
end
