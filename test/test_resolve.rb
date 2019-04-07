# frozen_string_literal: true

require "base64"
require "webmock/minitest"
require "minitest/autorun"

require "dhall"

class TestResolve < Minitest::Test
	def setup
		@resolver = Dhall::Resolvers::Default.new(
			path_reader: lambda do |sources|
				sources.map do |source|
					Promise.resolve(Base64.decode64({
						"var"      => "AA",
						"import"   => "hRgY9gADY3Zhcg",
						"a"        => "hRgY9gADYWI",
						"b"        => "hRgY9gADYWE",
						"self"     => "hRgY9gADZHNlbGY",
						"text"     => "aGFp",
						"moretext" => "hRgY9gEDZHRleHQ",
						"2text"    => "hAMGhRgY9gEDZHRleHSFGBj2AANobW9yZXRleHQ",
						"using"    => "iBgY9gAAhRgY9gADZ2hlYWRlcnNkZS50ZGF09g",
						"headers"  => "gwT2ggiiZmhlYWRlcoISYnRoZXZhbHVlghJidHY"
					}.fetch(source.pathname.to_s)))
				end
			end
		)
	end

	def test_nothing_to_resolve
		expr = Dhall::Function.of_arguments(
			Dhall::Variable["Natural"],
			body: Dhall::Variable["_"]
		)

		assert_equal expr, expr.resolve(Dhall::Resolvers::None.new).sync
	end

	def test_import_as_text
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Text,
			Dhall::Import::RelativePath.new("text")
		)

		assert_equal(
			Dhall::Text.new(value: "hai"),
			expr.resolve(@resolver).sync
		)
	end

	def test_one_level_to_resolve
		expr = Dhall::Function.of_arguments(
			Dhall::Variable["Natural"],
			body: Dhall::Import.new(
				Dhall::Import::IntegrityCheck.new,
				Dhall::Import::Expression,
				Dhall::Import::RelativePath.new("var")
			)
		)

		assert_equal(
			expr.with(body: Dhall::Variable["_"]),
			expr.resolve(@resolver).sync
		)
	end

	def test_two_levels_to_resolve
		expr = Dhall::Function.of_arguments(
			Dhall::Variable["Natural"],
			body: Dhall::Import.new(
				Dhall::Import::IntegrityCheck.new,
				Dhall::Import::Expression,
				Dhall::Import::RelativePath.new("import")
			)
		)

		assert_equal(
			expr.with(body: Dhall::Variable["_"]),
			expr.resolve(@resolver).sync
		)
	end

	def test_self_loop
		expr = Dhall::Function.of_arguments(
			Dhall::Variable["Natural"],
			body: Dhall::Import.new(
				Dhall::Import::IntegrityCheck.new,
				Dhall::Import::Expression,
				Dhall::Import::RelativePath.new("self")
			)
		)

		assert_raises Dhall::ImportLoopException do
			expr.resolve(@resolver).sync
		end
	end

	def test_two_level_loop
		expr = Dhall::Function.of_arguments(
			Dhall::Variable["Natural"],
			body: Dhall::Import.new(
				Dhall::Import::IntegrityCheck.new,
				Dhall::Import::Expression,
				Dhall::Import::RelativePath.new("a")
			)
		)

		assert_raises Dhall::ImportLoopException do
			expr.resolve(@resolver).sync
		end
	end

	def test_two_references_no_loop
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::RelativePath.new("2text")
		)

		assert_equal(
			Dhall::Operator::TextConcatenate.new(
				lhs: Dhall::Text.new(value: "hai"),
				rhs: Dhall::Text.new(value: "hai")
			),
			expr.resolve(@resolver).sync
		)
	end

	def test_missing
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::MissingImport.new
		)

		assert_raises Dhall::ImportFailedException do
			expr.resolve(@resolver).sync
		end
	end

	def test_integrity_check_failure
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new("sha256", "badhash"),
			Dhall::Import::Expression,
			Dhall::Import::RelativePath.new("var")
		)

		assert_raises Dhall::Import::IntegrityCheck::FailureException do
			expr.resolve(@resolver).sync
		end
	end

	def test_fallback_to_expr
		expr = Dhall::Operator::ImportFallback.new(
			lhs: Dhall::Import.new(
				Dhall::Import::IntegrityCheck.new,
				Dhall::Import::Expression,
				Dhall::Import::MissingImport.new
			),
			rhs: Dhall::Variable["fallback"]
		)

		assert_equal Dhall::Variable["fallback"], expr.resolve(@resolver).sync
	end

	def test_fallback_to_import
		expr = Dhall::Operator::ImportFallback.new(
			lhs: Dhall::Import.new(
				Dhall::Import::IntegrityCheck.new,
				Dhall::Import::Expression,
				Dhall::Import::MissingImport.new
			),
			rhs: Dhall::Import.new(
				Dhall::Import::IntegrityCheck.new,
				Dhall::Import::Expression,
				Dhall::Import::RelativePath.new("import")
			)
		)

		assert_equal Dhall::Variable["_"], expr.resolve(@resolver).sync
	end

	def test_headers
		stub_request(:get, "http://e.td/t")
			.with(headers: { "Th" => "tv" })
			.to_return(status: 200, body: "\x00".b)

		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::RelativePath.new("using")
		)

		assert_equal Dhall::Variable["_"], expr.resolve(@resolver).sync
	end

	def test_ipfs
		stub_request(:get, "http://localhost:8000/ipfs/TESTCID")
			.to_return(status: 200, body: "\x00".b)

		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::AbsolutePath.new("ipfs", "TESTCID")
		)

		assert_equal Dhall::Variable["_"], expr.resolve.sync
	end

	def test_ipfs_public_gateway
		stub_request(:get, "http://localhost:8000/ipfs/TESTCID")
			.to_return(status: 500)

		stub_request(:get, "https://cloudflare-ipfs.com/ipfs/TESTCID")
			.to_return(status: 200, body: "_")

		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::AbsolutePath.new("ipfs", "TESTCID")
		)

		assert_equal Dhall::Variable["_"], expr.resolve.sync
	end

	DIRPATH = Pathname.new(File.dirname(__FILE__))
	TESTS = DIRPATH + "../dhall-lang/tests/normalization/"

	# Sanity check that all expressions can pass through the resolver
	Pathname.glob(TESTS + "**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		next if test =~ /prelude\/|remoteSystems/

		define_method("test_#{test}") do
			expr = Dhall::Parser.parse_file(path).value
			assert_equal expr, expr.resolve.sync
		end
	end
end
