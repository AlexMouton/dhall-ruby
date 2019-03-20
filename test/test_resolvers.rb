# frozen_string_literal: true

require "minitest/autorun"

require "dhall/resolve"
require "dhall/normalize"

class TestResolvers < Minitest::Test
	def test_default_resolver_path
		resolver = Dhall::Resolvers::Default.new(
			path_reader: lambda do |sources|
				sources.map { |source| Promise.resolve(source) }
			end
		)
		source = Dhall::Import::AbsolutePath.new("dhall", "common", "x.dhall")
		promise = source.resolve(resolver)
		resolver.finish!
		assert_equal source, promise.sync
	end

	def test_default_resolver_path_from_env
		ENV["__DHALL_IMPORT_TEST"] = "/dhall/common/x.dhall"
		resolver = Dhall::Resolvers::Default.new(
			path_reader: lambda do |sources|
				sources.map { |source| Promise.resolve(source) }
			end
		)
		source = Dhall::Import::EnvironmentVariable.new("__DHALL_IMPORT_TEST")
		promise = source.resolve(resolver)
		resolver.finish!

		expected = Dhall::Import::AbsolutePath.new("dhall", "common", "x.dhall")
		assert_equal expected, promise.sync
	end

	def test_default_resolver_http
		resolver = Dhall::Resolvers::Default.new(
			http_reader: lambda do |sources|
				sources.map { |source| Promise.resolve(source) }
			end
		)
		source = Dhall::Import::Http.new(nil, "example.com", "x.dhall", nil, nil)
		promise = source.resolve(resolver)
		resolver.finish!
		assert_equal source, promise.sync
	end

	def test_default_resolver_https
		resolver = Dhall::Resolvers::Default.new(
			https_reader: lambda do |sources|
				sources.map { |source| Promise.resolve(source) }
			end
		)
		source = Dhall::Import::Https.new(nil, "example.com", "x.dhall", nil, nil)
		promise = source.resolve(resolver)
		resolver.finish!
		assert_equal source, promise.sync
	end

	def test_default_resolver_https_uses_http
		resolver = Dhall::Resolvers::Default.new(
			http_reader: lambda do |sources|
				sources.map { |source| Promise.resolve(source) }
			end
		)
		source = Dhall::Import::Https.new(nil, "example.com", "x.dhall", nil, nil)
		promise = source.resolve(resolver)
		resolver.finish!
		assert_equal source, promise.sync
	end

	def test_local_only_resolver_rejects_http
		resolver = Dhall::Resolvers::LocalOnly.new
		source = Dhall::Import::Http.new(nil, "example.com", "x.dhall", nil, nil)
		promise = source.resolve(resolver)
		resolver.finish!
		assert_raises Dhall::ImportBannedException do
			promise.sync
		end
	end

	def test_none_resolver_rejects_local
		resolver = Dhall::Resolvers::None.new
		source = Dhall::Import::AbsolutePath.new("dhall", "common", "x.dhall")
		promise = source.resolve(resolver)
		resolver.finish!
		assert_raises Dhall::ImportBannedException do
			promise.sync
		end
	end
end
