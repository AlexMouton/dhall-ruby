# frozen_string_literal: true

require "securerandom"
require "minitest/autorun"

require "dhall"

class TestLoad < Minitest::Test
	def test_load_natural_source
		assert_equal Dhall::Natural.new(value: 1), Dhall.load("1").sync
	end

	def test_load_natural_source_mislabeled_encoding
		assert_equal Dhall::Natural.new(value: 1), Dhall.load("1".b).sync
	end

	def test_load_invalid_utf8
		assert_raises ArgumentError do
			Dhall.load("\xc3\x28").sync
		end
	end

	def test_load_natural_binary
		assert_equal(
			Dhall::Natural.new(value: 1),
			Dhall.load("\x82\x0f\x01".b).sync
		)
	end

	def test_load_normalizes
		assert_equal(
			Dhall::Natural.new(value: 2),
			Dhall.load("1 + 1").sync
		)
	end

	def test_load_resolves
		assert_equal(
			Dhall::Natural.new(value: 2),
			Dhall.load(
				"/path/to/source.dhall",
				resolver: Dhall::Resolvers::Default.new(
					path_reader: ->(s) { s.map { "1 + 1" } }
				)
			).sync
		)
	end

	def test_load_typechecks
		assert_raises TypeError do
			Dhall.load("1 + \"hai\"").sync
		end
	end

	def test_load_raw_not_normalizes_or_typechecks
		assert_equal(
			Dhall::Operator::Plus.new(
				lhs: Dhall::Natural.new(value: 1),
				rhs: Dhall::Text.new(value: "hai")
			),
			Dhall.load_raw("1 + \"hai\"")
		)
	end

	def test_load_parse_timeout
		Dhall::Parser.stub(:parse, ->(*) { sleep 1 }) do
			assert_raises Dhall::TimeoutException do
				Dhall.load("./start", timeout: 0.1).sync
			end
		end
	end

	def test_load_normalize_timeout
		ack = <<~DHALL
			let iter =
				λ(f : Natural → Natural) → λ(n : Natural) →
				Natural/fold n Natural f (f (1))
			in
				λ(m : Natural) →
					Natural/fold m (Natural → Natural) iter (λ(x : Natural) → x + 1)
		DHALL
		assert_raises Dhall::TimeoutException do
			Dhall.load("(#{ack}) 10 10", timeout: 0.1).sync
		end
	end

	def test_load_resolve_timeout
		resolver = Dhall::Resolvers::LocalOnly.new(
			path_reader: lambda do |sources|
				sources.map do |_|
					Promise.resolve(nil).then do
						sleep 0.1
						"./#{SecureRandom.hex}"
					end
				end
			end
		)

		assert_raises Dhall::TimeoutException do
			Dhall.load(
				"./start",
				resolver: resolver,
				timeout:  0.1
			).sync
		end
	end
end
