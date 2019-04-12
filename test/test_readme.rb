# frozen_string_literal: true

require "minitest/autorun"

require "dhall"

class TestReadme < Minitest::Test
	# Load, as_dhall, and resolver tests are in their own files

	FUNCTION = Dhall.load("\\(x: Natural) -> x + 1").sync
	CURRIED_FUNCTION = Dhall.load(
		"\\(x: Natural) -> \\(y: Natural) -> x + y"
	).sync
	BOOL = Dhall.load("True").sync
	NAT = Dhall.load("1").sync
	INT = Dhall.load("+1").sync
	DOUBLE = Dhall.load("1.0").sync
	TEXT = Dhall.load("\"abc\"").sync
	SOME = Dhall.load("Some 1").sync
	NONE = Dhall.load("None Natural").sync
	LIST = Dhall.load("[1,2]").sync
	REC = Dhall.load("{ a = 1 }").sync
	ENUM = Dhall.load("< one | two >.one").sync
	UNION = Dhall.load("< Natural: Natural | Text: Text >.Natural 1").sync

	def test_function_send_call
		assert_equal Dhall::Natural.new(value: 2), FUNCTION.call(1)
	end

	def test_function_send_staples
		assert_equal Dhall::Natural.new(value: 2), FUNCTION[1]
	end

	def test_function_use_as_proc
		assert_equal(
			[Dhall::Natural.new(value: 2), Dhall::Natural.new(value: 3)],
			[1, 2].map(&FUNCTION)
		)
	end

	def test_function_send_to_proc
		assert_kind_of Proc, FUNCTION.to_proc
		assert_equal Dhall::Natural.new(value: 2), FUNCTION.to_proc.call(1)
	end

	def test_curried_function_call_curried
		assert_equal(
			Dhall::Natural.new(value: 2),
			CURRIED_FUNCTION.call(1).call(1)
		)
	end

	def test_curried_function_call_uncurried
		assert_equal(
			Dhall::Natural.new(value: 2),
			CURRIED_FUNCTION.call(1, 1)
		)
	end

	def test_bool_and_false
		assert_equal false, BOOL & false
	end

	def test_bool_or_false
		assert_equal Dhall::Bool.new(value: true), BOOL | false
	end

	def test_not_bool
		assert_equal Dhall::Bool.new(value: false), !BOOL
	end

	def test_bool_match_true
		assert_equal true, BOOL === true
	end

	def test_bool_reduce_true_false
		assert_equal true, BOOL.reduce(true, false)
	end

	def test_bool_to_s
		assert_equal "True", BOOL.to_s
	end

	def test_nat_plus_1
		assert_equal Dhall::Natural.new(value: 2), NAT + 1
	end

	def test_1_plus_nat
		assert_equal Dhall::Natural.new(value: 2), 1 + NAT
	end

	def test_nat_times_2
		assert_equal Dhall::Natural.new(value: 2), NAT * 2
	end

	def test_2_times_nat
		assert_equal Dhall::Natural.new(value: 2), 2 * NAT
	end

	def test_nat_match_1
		assert_equal true, NAT === 1
	end

	def test_nat_zero
		assert_equal false, NAT.zero?
	end

	def test_nat_even
		assert_equal false, NAT.even?
	end

	def test_nat_odd
		assert_equal true, NAT.odd?
	end

	def test_nat_pred
		assert_equal Dhall::Natural.new(value: 0), NAT.pred
	end

	def test_nat_to_s
		assert_equal "1", NAT.to_s
	end

	def test_nat_to_i
		assert_equal 1, NAT.to_i
	end

	def test_int_match_1
		assert_equal true, INT === 1
	end

	def test_int_to_s
		assert_equal "+1", INT.to_s
	end

	def test_int_to_i
		assert_equal 1, INT.to_i
	end

	def test_double_match_one
		assert_equal true, DOUBLE === 1.0
	end

	def test_double_to_s
		assert_equal "1.0", DOUBLE.to_s
	end

	def test_double_to_f
		assert_equal 1.0, DOUBLE.to_f
	end

	def test_text_match_abc
		assert_equal true, TEXT === "abc"
	end

	def test_text_to_s
		assert_equal "abc", TEXT.to_s
	end

	def test_some_map
		assert_equal(
			Dhall::Optional.new(
				value:      Dhall::Natural.new(value: 2),
				value_type: nil
			),
			SOME.map { |x| x + 1 }
		)
	end

	def test_some_map_with_type
		assert_equal(
			Dhall::Optional.new(
				value:      Dhall::Natural.new(value: 2),
				value_type: Dhall::Variable["Natural"]
			),
			SOME.map(type: Dhall::Variable["Natural"]) { |x| x + 1 }
		)
	end

	def test_some_reduce
		assert_equal Dhall::Natural.new(value: 1), SOME.reduce(nil) { |x| x }
	end

	def test_some_to_s
		assert_equal "1", SOME.to_s
	end

	def test_none_map
		assert_equal(
			Dhall::OptionalNone.new(value_type: Dhall::Variable["Natural"]),
			NONE.map { |x| x + 1 }
		)
	end

	def test_none_map_with_type
		assert_equal(
			Dhall::OptionalNone.new(value_type: Dhall::Variable["Natural"]),
			NONE.map(type: Dhall::Variable["Natural"]) { |x| x + 1 }
		)
	end

	def test_none_reduce
		assert_equal nil, NONE.reduce(nil) { |x| x }
	end

	def test_none_to_s
		assert_equal "", NONE.to_s
	end

	def test_list_map
		assert_equal(
			Dhall::List.new(elements: [
				Dhall::Natural.new(value: 2),
				Dhall::Natural.new(value: 3)
			], element_type: nil),
			LIST.map { |x| x + 1 }
		)
	end

	def test_list_map_with_type
		assert_equal(
			Dhall::List.new(elements: [
				Dhall::Natural.new(value: 2),
				Dhall::Natural.new(value: 3)
			], element_type: Dhall::Variable["Natural"]),
			LIST.map(type: Dhall::Variable["Natural"]) { |x| x + 1 }
		)
	end

	def test_list_reduce
		assert_equal(
			Dhall::Natural.new(value: 1),
			LIST.reduce(nil) { |x, _| x }
		)
	end

	def test_list_first
		assert_equal(
			Dhall::Optional.new(
				value:      Dhall::Natural.new(value: 1),
				value_type: Dhall::Variable["Natural"]
			),
			LIST.first
		)
	end

	def test_list_last
		assert_equal(
			Dhall::Optional.new(
				value:      Dhall::Natural.new(value: 2),
				value_type: Dhall::Variable["Natural"]
			),
			LIST.last
		)
	end

	def test_list_index_0
		assert_equal(
			Dhall::Optional.new(
				value:      Dhall::Natural.new(value: 1),
				value_type: Dhall::Variable["Natural"]
			),
			LIST[0]
		)
	end

	def test_list_index_100
		assert_equal(
			Dhall::OptionalNone.new(value_type: Dhall::Variable["Natural"]),
			LIST[100]
		)
	end

	def test_list_reverse
		assert_equal(
			Dhall::List.new(elements: [
				Dhall::Natural.new(value: 2),
				Dhall::Natural.new(value: 1)
			], element_type: Dhall::Variable["Natural"]),
			LIST.reverse
		)
	end

	def test_list_join
		assert_equal "1,2", LIST.join(",")
	end

	def test_list_to_a
		assert_equal(
			[Dhall::Natural.new(value: 1), Dhall::Natural.new(value: 2)],
			LIST.to_a
		)
	end

	def test_rec_index_a_string
		assert_equal Dhall::Natural.new(value: 1), REC["a"]
	end

	def test_rec_index_a_symbol
		assert_equal Dhall::Natural.new(value: 1), REC[:a]
	end

	def test_rec_index_b_string
		assert_equal nil, REC["b"]
	end

	def test_rec_fetch_a_string
		assert_equal Dhall::Natural.new(value: 1), REC.fetch("a")
	end

	def test_rec_fetch_a_symbol
		assert_equal Dhall::Natural.new(value: 1), REC.fetch(:a)
	end

	def test_rec_fetch_b_string
		assert_raises KeyError do
			REC.fetch("b")
		end
	end

	def test_rec_dig_a
		assert_equal Dhall::Natural.new(value: 1), REC.dig(:a)
	end

	def test_rec_dig_b
		assert_equal nil, REC.dig(:b)
	end

	def test_rec_slice_a
		assert_equal(
			Dhall::Record.new(record: { "a" => Dhall::Natural.new(value: 1) }),
			REC.slice(:a)
		)
	end

	def test_rec_slice
		assert_equal Dhall::EmptyRecord.new, REC.slice
	end

	def test_rec_keys
		assert_equal ["a"], REC.keys
	end

	def test_rec_values
		assert_equal [Dhall::Natural.new(value: 1)], REC.values
	end

	def test_rec_map
		assert_equal(
			Dhall::Record.new(record: { "a" => Dhall::Natural.new(value: 2) }),
			REC.map { |k, v| [k, v + 1] }
		)
	end

	def test_rec_merge
		assert_equal(
			Dhall::Record.new(
				record: {
					"a" => Dhall::Natural.new(value: 1),
					"b" => Dhall::Natural.new(value: 2)
				}
			),
			REC.merge(b: 2)
		)
	end

	def test_rec_deep_merge
		assert_equal(
			Dhall::Record.new(
				record: {
					"a" => Dhall::Natural.new(value: 1),
					"b" => Dhall::Natural.new(value: 2)
				}
			),
			REC.deep_merge(b: 2)
		)
	end

	def test_enum_to_s
		assert_equal "one", ENUM.to_s
	end

	def test_enum_reduce
		assert_equal 1, ENUM.reduce(one: 1, two: 2)
	end

	def test_enum_extract
		assert_equal :one, ENUM.extract
	end

	def test_union_to_s
		assert_equal "1", UNION.to_s
	end

	def test_union_reduce
		assert_equal 1, UNION.reduce(Natural: :to_i, Text: :to_i)
	end

	def test_union_extract
		assert_equal Dhall::Natural.new(value: 1), UNION.extract
	end
end
