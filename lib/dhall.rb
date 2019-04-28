# frozen_string_literal: true

require "dhall/as_dhall"
require "dhall/ast"
require "dhall/binary"
require "dhall/builtins"
require "dhall/coder"
require "dhall/normalize"
require "dhall/parser"
require "dhall/resolve"
require "dhall/typecheck"

module Dhall
	using Dhall::AsDhall

	def self.load(source, resolver: Resolvers::Default.new)
		Promise.resolve(nil).then {
			load_raw(source.to_s).resolve(resolver: resolver)
		}.then do |resolved|
			TypeChecker.for(resolved).annotate(TypeChecker::Context.new).normalize
		end
	end

	def self.load_raw(source)
		source = Util.text_or_binary(source)

		if source.encoding == Encoding::BINARY
			from_binary(source)
		else
			Parser.parse(source).value
		end
	end

	def self.dump(o)
		CBOR.encode(o.as_dhall)
	end
end
