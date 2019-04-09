# frozen_string_literal: true

module Dhall
	def self.load_raw(source)
		begin
			return from_binary(source) if source.encoding == Encoding::BINARY
		rescue Exception # rubocop:disable Lint/RescueException
			# Parsing CBOR failed, so guess this is source text in standard UTF-8
			return load_raw(source.force_encoding("UTF-8"))
		end

		Parser.parse(source.encode("UTF-8")).value
	end
end

require "dhall/as_dhall"
require "dhall/ast"
require "dhall/binary"
require "dhall/builtins"
require "dhall/normalize"
require "dhall/parser"
require "dhall/resolve"
require "dhall/typecheck"
