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
require "dhall/types"

module Dhall
	using Dhall::AsDhall

	def self.load(
		source,
		resolver: Resolvers::Default.new,
		timeout: 10
	)
		deadline = Util::Deadline.for_timeout(timeout)
		Promise.resolve(nil).then {
			load_raw(source.to_s, timeout: timeout).resolve(
				resolver: resolver.with_deadline(deadline)
			)
		}.then do |resolved|
			deadline.timeout_block do
				TypeChecker.for(resolved).annotate(TypeChecker::Context.new).normalize
			end
		end
	end

	def self.load_raw(source, timeout: 10)
		source = Util.text_or_binary(source)

		Util::Deadline.for_timeout(timeout).timeout_block do
			if source.encoding == Encoding::BINARY
				from_binary(source)
			else
				Parser.parse(source).value
			end
		end
	end

	def self.dump(o)
		CBOR.encode(o.as_dhall)
	end

	class TimeoutException < StandardError; end
end
