# frozen_string_literal: true

require "pathname"
require "promise.rb"
require "set"

require "dhall/ast"
require "dhall/binary"
require "dhall/util"

module Dhall
	class ImportFailedException < StandardError; end
	class ImportBannedException < ImportFailedException; end
	class ImportLoopException < ImportBannedException; end

	module Resolvers
		ReadPathSources = lambda do |sources|
			sources.map do |source|
				Util::LazyPromise.new { source.pathname.binread }
			end
		end

		ReadEnvironmentSources = lambda do |sources|
			sources.map do |source|
				Util::LazyPromise.new do
					ENV.fetch(source.var) do
						raise ImportFailedException, "No #{source}"
					end
				end
			end
		end

		PreflightCORS = lambda do |source, parent_origin|
			timeout = source.deadline.timeout
			uri = source.uri
			if parent_origin != "localhost" && parent_origin != source.origin
				req = Net::HTTP::Options.new(uri)
				req["Origin"] = parent_origin
				req["Access-Control-Request-Method"] = "GET"
				req["Access-Control-Request-Headers"] =
					source.headers.to_a.map { |h|
						(h.fetch("header") { h.fetch("mapKey") }).to_s
					}.join(",")
				r = Util.net_http_req_with_timeout(uri, req, timeout: timeout)

				raise ImportFailedException, source if r.code != "200"
				unless r["Access-Control-Allow-Origin"] == parent_origin ||
				       r["Access-Control-Allow-Origin"] == "*"
					raise ImportBannedException, source
				end
			end
		end

		ReadHttpSources = lambda do |sources, parent_origin|
			sources.map do |source|
				Util::LazyPromise.new do
					PreflightCORS.call(source, parent_origin)
					timeout = source.deadline.timeout
					uri = source.uri
					r = loop do
						req = Net::HTTP::Get.new(uri)
						source.headers.each do |header|
							req[(header.fetch("header") { header.fetch("mapKey") }).to_s] =
								(header.fetch("value") { header.fetch("mapValue") }).to_s
						end
						r = Util.net_http_req_with_timeout(uri, req, timeout: timeout)

						break r unless ["301", "302", "303", "307", "308"].include?(r.code)
						uri = URI(r["Location"])
					end

					raise ImportFailedException, source if r.code != "200"
					r.body
				end
			end
		end

		StandardReadHttpSources = lambda do |sources, parent_origin|
			ReadHttpSources.call(sources, parent_origin).map do |source_promise|
				source_promise.then do |s|
					s = s.dup.force_encoding("UTF-8")
					unless s.valid_encoding?
						raise ImportFailedException, "#{s.inspect} is not valid UTF-8"
					end
					s
				end
			end
		end

		RejectSources = lambda do |sources|
			sources.map do |source|
				Promise.new.reject(ImportBannedException.new(source))
			end
		end

		class ReadPathAndIPFSSources
			def initialize(
				path_reader: ReadPathSources,
				http_reader: ReadHttpSources,
				https_reader: http_reader,
				public_gateway: URI("https://cloudflare-ipfs.com")
			)
				@path_reader = path_reader
				@http_reader = http_reader
				@https_reader = https_reader
				@public_gateway = public_gateway
			end

			def arity
				1
			end

			def call(sources)
				@path_reader.call(sources).map.with_index do |promise, idx|
					source = sources[idx]
					if source.canonical.is_a?(Import::AbsolutePath) &&
					   ["ipfs", "ipns"].include?(source.path.first)
						gateway_fallback(source, promise)
					else
						promise
					end
				end
			end

			def to_proc
				method(:call).to_proc
			end

			protected

			def gateway_fallback(source, promise)
				promise.catch {
					@http_reader.call([
						source.to_uri(Import::Http, URI("http://localhost:8000"))
					], "localhost").first
				}.catch do
					@https_reader.call([
						source.to_uri(Import::Https, @public_gateway)
					], "localhost").first
				end
			end
		end

		module NoCache
			def self.fetch(*)
				yield
			end
		end

		class RamCache
			def initialize
				@cache = {}
			end

			def fetch(key, &block)
				return @cache[key] if @cache.key?(key)

				Promise.resolve(nil).then(&block).then do |result|
					@cache[key] = result
				end
			end
		end

		class StandardFileCache
			def initialize(
				dir=Pathname.new(ENV.fetch(
					"XDG_CACHE_HOME", ENV.fetch("HOME") + "/.cache/"
				)) + "dhall/"
			)
				dir.mkpath
				@dir = dir
				@ram = RamCache.new
			end

			def fetch(key, &block)
				if key.is_a?(String) && key.start_with?("sha256:")
					file = @dir + key.sub(/^sha256:/, "1220")
					return Dhall.from_binary(file.binread) if file.exist?

					Promise.resolve(nil).then(&block).then do |result|
						file.open("wb") { |fh| fh.write(result.to_cbor) }
						result
					end
				else
					@ram.fetch(key, &block)
				end
			end
		end

		class ResolutionSet
			def initialize(reader, max_depth:)
				@reader = reader
				@max_depth = max_depth
				@parents = []
				@set = Hash.new { |h, k| h[k] = [] }
			end

			def register(source)
				p = Promise.new
				if @parents.include?(source.canonical)
					p.reject(ImportLoopException.new(source))
				elsif @parents.length + 1 > @max_depth
					msg = "Max import depth of #{@max_depth} exceeded"
					p.reject(ImportFailedException.new(msg))
				else
					@set[source] << p
				end
				p
			end

			def resolutions
				sources, promises = @set.to_a.transpose
				[Array(sources), Array(promises)]
			end

			def reader
				lambda do |sources|
					raise TimeoutException if sources.any? { |s| s.deadline.exceeded? }

					if @reader.arity == 2
						@reader.call(sources, @parents.last&.origin || "localhost")
					else
						@reader.call(sources)
					end
				end
			end

			def child(parent_source)
				dup.tap do |c|
					c.instance_eval do
						@parents = @parents.dup + [parent_source]
						@set = Hash.new { |h, k| h[k] = [] }
					end
				end
			end
		end

		class SourceWithDeadline < SimpleDelegator
			attr_reader :deadline

			def initialize(source, deadline)
				@source = source
				@deadline = deadline

				super(source)
			end

			def to_uri(*args)
				self.class.new(super, deadline)
			end
		end

		class Standard
			attr_reader :deadline

			def initialize(
				path_reader: ReadPathSources,
				http_reader: StandardReadHttpSources,
				https_reader: http_reader,
				environment_reader: ReadEnvironmentSources,
				cache: StandardFileCache.new,
				max_depth: Float::INFINITY
			)
				@path_resolutions = ResolutionSet.new(path_reader, max_depth: max_depth)
				@http_resolutions = ResolutionSet.new(http_reader, max_depth: max_depth)
				@https_resolutions = ResolutionSet.new(https_reader, max_depth: max_depth)
				@env_resolutions = ResolutionSet.new(
					environment_reader, max_depth: max_depth
				)
				@deadline = Util::NoDeadline.new
				@cache = cache
			end

			def with_deadline(deadline)
				dup.tap do |c|
					c.instance_eval do
						@deadline = deadline
					end
				end
			end

			def cache_fetch(key, &fallback)
				@cache.fetch(key) do
					Promise.resolve(nil).then(&fallback)
				end
			end

			def resolve_path(path_source)
				@path_resolutions.register(
					SourceWithDeadline.new(path_source, @deadline)
				)
			end

			def resolve_environment(env_source)
				@env_resolutions.register(
					SourceWithDeadline.new(env_source, @deadline)
				)
			end

			def resolve_http(http_source)
				http_source.headers.resolve(
					resolver:    self,
					relative_to: Dhall::Import::RelativePath.new
				).then do |headers|
					source = http_source.with(headers: headers.normalize)
					@http_resolutions.register(
						SourceWithDeadline.new(source, @deadline)
					)
				end
			end

			def resolve_https(https_source)
				https_source.headers.resolve(
					resolver:    self,
					relative_to: Dhall::Import::RelativePath.new
				).then do |headers|
					source = https_source.with(headers: headers.normalize)
					@https_resolutions.register(
						SourceWithDeadline.new(source, @deadline)
					)
				end
			end

			def finish!
				[
					@path_resolutions,
					@env_resolutions,
					@http_resolutions,
					@https_resolutions
				].each do |rset|
					Util.match_result_promises(*rset.resolutions, &rset.reader)
				end
				freeze
			end

			def child(parent_source)
				dup.tap do |c|
					c.instance_eval do
						@path_resolutions = @path_resolutions.child(parent_source)
						@env_resolutions = @env_resolutions.child(parent_source)
						@http_resolutions = @http_resolutions.child(parent_source)
						@https_resolutions = @https_resolutions.child(parent_source)
					end
				end
			end
		end

		class Default < Standard
			def initialize(
				path_reader: ReadPathSources,
				http_reader: ReadHttpSources,
				https_reader: http_reader,
				environment_reader: ReadEnvironmentSources,
				ipfs_public_gateway: URI("https://cloudflare-ipfs.com"),
				cache: RamCache.new,
				max_depth: 50
			)
				super(
					path_reader: ReadPathAndIPFSSources.new(
						path_reader:    path_reader,
						http_reader:    http_reader,
						https_reader:   https_reader,
						public_gateway: ipfs_public_gateway
					),
					http_reader: http_reader, https_reader: https_reader, cache: cache,
					environment_reader: environment_reader, max_depth: max_depth
				)
			end
		end

		class LocalOnly < Standard
			def initialize(
				path_reader: ReadPathSources,
				environment_reader: ReadEnvironmentSources,
				max_depth: 50
			)
				super(
					path_reader:        path_reader,
					environment_reader: environment_reader,
					http_reader:        RejectSources,
					https_reader:       RejectSources,
					max_depth:          max_depth
				)
			end
		end

		class None < Default
			def initialize
				super(
					path_reader:        RejectSources,
					environment_reader: RejectSources,
					http_reader:        RejectSources,
					https_reader:       RejectSources
				)
			end
		end
	end

	class ExpressionResolver
		@@registry = {}

		def self.for(expr)
			@@registry.find { |k, _| k === expr }.last.new(expr)
		end

		def self.register_for(kase)
			@@registry[kase] = self
		end

		def initialize(expr)
			@expr = expr
		end

		def resolve(**kwargs)
			Util.promise_all_hash(
				@expr.to_h.each_with_object({}) { |(attr, value), h|
					h[attr] = ExpressionResolver.for(value).resolve(**kwargs)
				}
			).then { |h| @expr.with(h) }
		end

		class ImportAsLocationResolver < ExpressionResolver
			def resolve(resolver:, relative_to:)
				Promise.resolve(nil).then do
					@expr.real_path(relative_to).location
				end
			end
		end

		class ImportResolver < ExpressionResolver
			register_for Import

			def self.new(expr)
				if expr.import_type == Import::AsLocation
					ImportAsLocationResolver.new(expr)
				else
					super
				end
			end

			def resolve(resolver:, relative_to:)
				Promise.resolve(nil).then do
					resolver.cache_fetch(@expr.cache_key(relative_to)) do
						resolve_raw(resolver: resolver, relative_to: relative_to)
					end
				end
			end

			def resolve_raw(resolver:, relative_to:)
				real_path = @expr.real_path(relative_to)
				real_path.resolve(resolver).then do |result|
					@expr.parse_resolve_check(
						result,
						deadline:    resolver.deadline,
						resolver:    resolver.child(real_path),
						relative_to: real_path
					)
				end
			end
		end

		class FallbackResolver < ExpressionResolver
			register_for Operator::ImportFallback

			def resolve(resolver:, relative_to:)
				ExpressionResolver.for(@expr.lhs).resolve(
					resolver:    resolver,
					relative_to: relative_to
				).catch do
					@expr.rhs.resolve(
						resolver:    resolver.child(Import::MissingImport.new),
						relative_to: relative_to
					)
				end
			end
		end

		class ArrayResolver < ExpressionResolver
			register_for Util::ArrayOf.new(Expression)

			def resolve(**kwargs)
				Promise.all(
					@expr.map { |e| ExpressionResolver.for(e).resolve(**kwargs) }
				)
			end
		end

		class HashResolver < ExpressionResolver
			register_for Util::HashOf.new(
				ValueSemantics::Anything,
				ValueSemantics::Either.new([Expression, nil])
			)

			def resolve(**kwargs)
				Util.promise_all_hash(Hash[@expr.map do |k, v|
					[k, ExpressionResolver.for(v).resolve(**kwargs)]
				end])
			end
		end

		class RecordResolver < ExpressionResolver
			register_for Record

			def resolve(**kwargs)
				ExpressionResolver.for(@expr.record).resolve(**kwargs).then do |h|
					@expr.with(record: h)
				end
			end
		end

		register_for Expression

		class IdentityResolver < ExpressionResolver
			register_for Object

			def resolve(*)
				Promise.resolve(@expr)
			end
		end
	end

	class Expression
		def resolve(
			resolver: Resolvers::Default.new,
			relative_to: Import::Path.from_string(Pathname.pwd + "file")
		)
			p = ExpressionResolver.for(self).resolve(
				resolver:    resolver,
				relative_to: relative_to
			)
			resolver.finish!
			p
		end
	end
end
