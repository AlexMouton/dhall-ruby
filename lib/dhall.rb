# frozen_string_literal: true

require "dhall/as_dhall"
require "dhall/ast"
require "dhall/binary"
require "dhall/builtins"
require "dhall/normalize"
require "dhall/parser"
require "dhall/resolve"
require "dhall/typecheck"

module Dhall
	using Dhall::AsDhall

	def self.load(source, resolver: Resolvers::Default.new)
		Promise.resolve(nil).then {
			load_raw(source).resolve(resolver: resolver)
		}.then do |resolved|
			TypeChecker.for(resolved).annotate(TypeChecker::Context.new).normalize
		end
	end

	def self.load_raw(source)
		unless source.valid_encoding?
			raise ArgumentError, "invalid byte sequence in #{source.encoding}"
		end

		begin
			return from_binary(source) if source.encoding == Encoding::BINARY
		rescue Exception # rubocop:disable Lint/RescueException
			# Parsing CBOR failed, so guess this is source text in standard UTF-8
			return load_raw(source.force_encoding("UTF-8"))
		end

		Parser.parse(source.encode("UTF-8")).value
	end

	def self.dump(o)
		CBOR.encode(o.as_dhall)
	end
end
