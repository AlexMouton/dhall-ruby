# frozen_string_literal: true

require "base64"
require "minitest/autorun"
require "pathname"

require "dhall/ast"
require "dhall/binary"

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

	def test_self_describing_cbor
		assert_equal(
			Dhall::Variable["x"],
			Dhall.from_binary(Base64.decode64("2dn3YXg"))
		)
	end
end
