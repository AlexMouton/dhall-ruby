# frozen_string_literal: true

require "set"
require "promise.rb"

require "dhall/ast"
require "dhall/util"

module Dhall
	class ImportFailedException < StandardError; end
	class ImportBannedException < ImportFailedException; end
	class ImportLoopException < ImportBannedException; end

	module Resolvers
		ReadPathSources = lambda do |sources|
			sources.map do |source|
				Promise.resolve(nil).then { source.pathname.read }
			end
		end

		ReadHttpSources = lambda do |sources|
			sources.map do |source|
				Promise.resolve(nil).then do
					Net::HTTP.get(source.uri)
				end
			end
		end

		RejectSources = lambda do |sources|
			sources.map do |source|
				Promise.new.reject(ImportBannedException.new(source))
			end
		end

		class ResolutionSet
			attr_reader :reader

			def initialize(reader)
				@reader = reader
				@parents = Set.new
				@set = Hash.new { |h, k| h[k] = [] }
			end

			def register(source)
				p = Promise.new
				if @parents.include?(source)
					p.reject(ImportLoopException.new(source))
				else
					@set[source] << p
				end
				p
			end

			def resolutions
				sources, promises = @set.to_a.transpose
				[Array(sources), Array(promises)]
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

		class Default
			def initialize(
				path_reader: ReadPathSources,
				http_reader: ReadHttpSources,
				https_reader: http_reader
			)
				@path_resolutions = ResolutionSet.new(path_reader)
				@http_resolutions = ResolutionSet.new(http_reader)
				@https_resolutions = ResolutionSet.new(https_reader)
			end

			def resolve_path(path_source)
				@path_resolutions.register(path_source)
			end

			def resolve_http(http_source)
				@http_resolutions.register(http_source)
			end

			def resolve_https(https_source)
				@https_resolutions.register(https_source)
			end

			def finish!
				[
					@path_resolutions,
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
						@http_resolutions = @http_resolutions.child(parent_source)
						@https_resolutions = @https_resolutions.child(parent_source)
					end
				end
			end
		end

		class LocalOnly < Default
			def initialize(path_reader: ReadPathSources)
				super(
					path_reader:  path_reader,
					http_reader:  RejectSources,
					https_reader: RejectSources
				)
			end
		end

		class None < Default
			def initialize
				super(
					path_reader:  RejectSources,
					http_reader:  RejectSources,
					https_reader: RejectSources
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

		def resolve(resolver)
			Util.promise_all_hash(
				@expr.to_h.each_with_object({}) { |(attr, value), h|
					h[attr] = ExpressionResolver.for(value).resolve(resolver)
				}
			).then { |h| @expr.with(h) }
		end

		class ImportResolver < ExpressionResolver
			register_for Import

			def resolve(resolver)
				@expr.instance_eval do
					@path.resolve(resolver).then do |expr|
						@import_type.call(expr).resolve(resolver.child(@path))
					end
				end
			end
		end

		class FallbackResolver < ExpressionResolver
			register_for Operator::ImportFallback

			def resolve(resolver)
				ExpressionResolver.for(@expr.lhs).resolve(resolver).catch do
					ExpressionResolver.for(@expr.rhs).resolve(resolver)
				end
			end
		end

		class ArrayResolver < ExpressionResolver
			def resolve(resolver)
				Promise.all(
					@expr.map { |e| ExpressionResolver.for(e).resolve(resolver) }
				)
			end
		end

		class HashResolver < ExpressionResolver
			def resolve(resolver)
				Util.promise_all_hash(Hash[@expr.map do |k, v|
					[k, ExpressionResolver.for(v).resolve(resolver)]
				end])
			end
		end

		register_for Expression

		class IdentityResolver < ExpressionResolver
			register_for Object

			def resolve(*)
				@expr
			end
		end
	end

	class Expression
		def resolve(resolver=Resolvers::Default.new)
			p = ExpressionResolver.for(self).resolve(resolver)
			resolver.finish!
			p
		end
	end
end
