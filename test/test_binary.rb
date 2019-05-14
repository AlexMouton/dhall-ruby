# frozen_string_literal: true

require "base64"
require "minitest/autorun"
require "pathname"

require "dhall"

class TestBinary < Minitest::Test
	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/**/success/"

	Pathname.glob(TESTS + "**/*.dhallb").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/.dhallb$/, "")
		define_method("test_#{test}") do
			assert_kind_of(
				Dhall::Expression,
				Dhall.from_binary(path.binread)
			)
		end
	end

	DECODE_TESTS = DIRPATH + "../dhall-lang/tests/binary-decode/success/"
	Pathname.glob(DECODE_TESTS + "**/*A.dhallb").each do |path|
		test = path.relative_path_from(DECODE_TESTS).to_s.sub(/A.dhallb$/, "")
		define_method("test_#{test}") do
			assert_equal(
				Dhall::Parser.parse_file(DECODE_TESTS + "#{test}B.dhall").value,
				Dhall.from_binary(path.binread)
			)
		end
	end
end
