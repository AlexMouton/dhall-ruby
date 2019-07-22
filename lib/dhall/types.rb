# frozen_string_literal: true

require "dhall/builtins"

module Dhall
	module Types
		def self.MAP_ENTRY(k: Builtins[:Text], v: Builtins[:Text])
			RecordType.new(
				record: {
					"mapKey" => k, "mapValue" => v
				}
			)
		end

		def self.MAP(k: Builtins[:Text], v: Builtins[:Text])
			Builtins[:List].call(MAP_ENTRY(k: k, v: v))
		end
	end
end
