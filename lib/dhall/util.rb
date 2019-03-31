# frozen_string_literal: true

module Dhall
	module Util
		class AllOf
			def initialize(*validators)
				@validators = validators
			end

			def ===(other)
				@validators.all? { |v| v === other }
			end
		end

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

		module ArrayAllTheSame
			def self.===(other)
				Array === other && other.all? { |x| x == other.first }
			end
		end

		def self.match_results(xs=nil, ys=nil)
			Array(xs).each_with_index.map do |r, idx|
				yield r, ys[idx]
			end
		end

		def self.match_result_promises(xs=nil, ys=nil)
			match_results(yield(Array(xs)), ys) do |promise, promises|
				promises.each { |p| p.fulfill(promise) }
			end
		end

		def self.promise_all_hash(hash)
			keys, promises = hash.to_a.transpose

			return Promise.resolve(hash) unless keys

			Promise.all(promises).then do |values|
				Hash[Util.match_results(keys, values) do |k, v|
					[k, v]
				end]
			end
		end
	end
end
