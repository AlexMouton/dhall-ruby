# frozen_string_literal: true

require "base64"
require "securerandom"
require "webmock/minitest"
require "minitest/autorun"

require "dhall"

class TestResolve < Minitest::Test
	def setup
		@relative_to = Dhall::Import::RelativePath.new
		@resolver = Dhall::Resolvers::Default.new(
			path_reader:        lambda do |sources|
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
			end,
			environment_reader: lambda do |sources|
				sources.map do |source|
					Promise.resolve({
						"NAT"  => "1",
						"PATH" => "./var"
					}.fetch(source.var))
				end
			end
		)
	end

	def subject(expr)
		expr.resolve(resolver: @resolver, relative_to: @relative_to).sync
	end

	def test_nothing_to_resolve
		expr = Dhall::Function.of_arguments(
			Dhall::Variable["Natural"],
			body: Dhall::Variable["_"]
		)

		assert_equal expr, expr.resolve(resolver: Dhall::Resolvers::None.new).sync
	end

	def test_import_as_text
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Text,
			Dhall::Import::RelativePath.new("text")
		)

		assert_equal Dhall::Text.new(value: "hai"), subject(expr)
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

		assert_equal expr.with(body: Dhall::Variable["_"]), subject(expr)
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

		assert_equal expr.with(body: Dhall::Variable["_"]), subject(expr)
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
			subject(expr)
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
			subject(expr)
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
			subject(expr)
		)
	end

	def test_forever_no_loop
		resolver = Dhall::Resolvers::LocalOnly.new(
			path_reader: lambda do |sources|
				sources.map do |_|
					Promise.resolve(nil).then do
						"./#{SecureRandom.hex}"
					end
				end
			end
		)

		assert_raises Dhall::ImportFailedException do
			Dhall.load(
				"./start",
				resolver: resolver,
				timeout:  Float::INFINITY
			).sync
		end
	end

	def test_missing
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::MissingImport.new
		)

		assert_raises Dhall::ImportFailedException do
			subject(expr)
		end
	end

	def test_integrity_check_failure
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new("sha256", "badhash"),
			Dhall::Import::Expression,
			Dhall::Import::RelativePath.new("var")
		)

		assert_raises Dhall::Import::IntegrityCheck::FailureException do
			subject(expr)
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

		assert_equal(
			Dhall::Variable["fallback"],
			subject(expr)
		)
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

		assert_equal Dhall::Variable["_"], subject(expr)
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

		assert_equal Dhall::Variable["_"], subject(expr)
	end

	def test_env_natural
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::EnvironmentVariable.new("NAT")
		)

		assert_equal Dhall::Natural.new(value: 1), subject(expr)
	end

	def test_env_as_text
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Text,
			Dhall::Import::EnvironmentVariable.new("NAT")
		)

		assert_equal Dhall::Text.new(value: "1"), subject(expr)
	end

	def test_env_relative
		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new,
			Dhall::Import::Expression,
			Dhall::Import::EnvironmentVariable.new("PATH")
		)

		assert_equal Dhall::Variable["_"], subject(expr)
	end

	def test_cache
		req = stub_request(:get, "http://example.com/thing.dhall")
		      .to_return(status: 200, body: "\x00".b)

		expr = Dhall::Import.new(
			Dhall::Import::IntegrityCheck.new(
				"sha256", Dhall::Variable["_"].digest.hexdigest
			),
			Dhall::Import::Expression,
			Dhall::Import::Http.new(nil, "example.com", "thing.dhall", nil)
		)

		cache = Dhall::Resolvers::RamCache.new

		assert_equal(
			Dhall::Variable["_"],
			expr.resolve(
				resolver: Dhall::Resolvers::Default.new(cache: cache)
			).sync
		)

		assert_equal(
			Dhall::Variable["_"],
			expr.resolve(
				resolver: Dhall::Resolvers::Default.new(cache: cache)
			).sync
		)

		assert_requested(req, times: 1)
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
	TESTS = DIRPATH + "../dhall-lang/tests/import/"

	Pathname.glob(TESTS + "success/**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")

		define_method("test_#{test}") do
			assert_equal(
				Dhall::Parser.parse_file(TESTS + "#{test}B.dhall").value,
				Dhall::Parser.parse_file(path).value.resolve(
					relative_to: Dhall::Import::Path.from_string(path)
				).sync
			)
		end
	end

	Pathname.glob(TESTS + "failure/**/*.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/\.dhall$/, "")

		define_method("test_#{test}") do
			stub_request(
				:get,
				"https://raw.githubusercontent.com/dhall-lang/dhall-lang/" \
				"master/tests/import/data/referentiallyOpaque.dhall"
			).to_return(status: 200, body: "env:HOME as Text")

			assert_raises Dhall::ImportFailedException do
				Dhall::Parser.parse_file(path).value.resolve(
					relative_to: Dhall::Import::Path.from_string(path)
				).sync
			end
		end
	end

	NTESTS = DIRPATH + "../dhall-lang/tests/normalization/"

	# Sanity check that all expressions can pass through the resolver
	Pathname.glob(NTESTS + "**/*A.dhall").each do |path|
		test = path.relative_path_from(TESTS).to_s.sub(/A\.dhall$/, "")
		next if test =~ /prelude\/|remoteSystems/

		define_method("test_#{test}") do
			expr = Dhall::Parser.parse_file(path).value
			assert_equal expr, expr.resolve.sync
		end
	end
end
