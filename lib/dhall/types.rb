# frozen_string_literal: true

require "dhall/builtins"

module Dhall
	module Types
		MAP_ENTRY = RecordType.new(
			record: {
				"mapKey" => Builtins[:Text], "mapValue" => Builtins[:Text]
			}
		)

		MAP = Builtins[:List].call(MAP_ENTRY)
	end
end
