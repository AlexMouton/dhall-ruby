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

		class Not
			def initialize(validator)
				@validator = validator
			end

			def ===(other)
				!(@validator === other)
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

		def self.psych_coder_for(tag, v)
			c = Psych::Coder.new(tag)
			case v
			when Hash
				c.map = v
			when Array
				c.seq = v
			else
				c.scalar = v
			end
		end

		def self.psych_coder_from(tag, o)
			coder = Psych::Coder.new(tag)

			if o.respond_to?(:encode_with)
				o.encode_with(coder)
			else
				o.instance_variables.each do |ivar|
					coder[ivar.to_s[1..-1]] = o.instance_variable_get(ivar)
				end
			end

			coder
		end

		def self.transform_keys(hash_or_not)
			return hash_or_not unless hash_or_not.is_a?(Hash)

			Hash[hash_or_not.map { |k, v| [(yield k), v] }]
		end
	end
end
