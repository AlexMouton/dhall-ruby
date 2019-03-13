# frozen_string_literal: true

module Dhall
	module Util
		class ArrayOf < ValueSemantics::ArrayOf
			def initialize(element_validator, min: 0, max: Float::INFINITY)
				@min = min
				@max = max
				super(element_validator)
			end

			def ===(other)
				super && other.length >= @min && other.length <= @max
			end
		end

		class HashOf
			def initialize(
				key_validator,
				element_validator,
				min: 0,
				max: Float::INFINITY
			)
				@min = min
				@max = max
				@key_validator = key_validator
				@element_validator = element_validator
			end

			def ===(other)
				Hash === other &&
					other.keys.all? { |x| @key_validator === x } &&
					other.values.all? { |x| @element_validator === x } &&
					other.size >= @min && other.size <= @max
			end
		end
	end
end
