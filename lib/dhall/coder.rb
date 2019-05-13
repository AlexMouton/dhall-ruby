# frozen_string_literal: true

require "psych"

module Dhall
	class Coder
		JSON_LIKE = [
			::Array, ::Hash,
			::TrueClass, ::FalseClass, ::NilClass,
			::Integer, ::Float, ::String
		].freeze

		class Verifier
			def initialize(*classes)
				@classes = classes
				@matcher = ValueSemantics::Either.new(classes)
			end

			def verify_class(klass, op)
				if @classes.any? { |safe| klass <= safe }
					klass
				else
					raise ArgumentError, "#{op} does not match "\
					                     "#{@classes.inspect}: #{klass}"
				end
			end

			def verify(obj, op)
				if @matcher === obj
					obj
				else
					raise ArgumentError, "#{op} does not match "\
					                     "#{@classes.inspect}: #{obj.inspect}"
				end
			end
		end

		def self.load(source, transform_keys: :to_s)
			new.load(source, transform_keys: transform_keys)
		end

		def self.dump(obj)
			new.dump(obj)
		end

		def initialize(default: nil, safe: JSON_LIKE)
			@default = default
			@verifier = Verifier.new(*Array(safe))
			@verifier.verify(default, "default value")
		end

		def load_async(source, op="load_async", transform_keys: :to_s)
			return Promise.resolve(@default) if source.nil?
			return Promise.resolve(source) unless source.is_a?(String)

			Dhall.load(source).then do |expr|
				decode(expr, op, transform_keys: transform_keys)
			end
		end

		def load(source, transform_keys: :to_s)
			load_async(source, "load", transform_keys: transform_keys).sync
		end

		module ToRuby
			refine Expression do
				def to_ruby
					self
				end
			end

			refine Natural do
				alias_method :to_ruby, :to_i
			end

			refine Integer do
				alias_method :to_ruby, :to_i
			end

			refine Double do
				alias_method :to_ruby, :to_f
			end

			refine Text do
				alias_method :to_ruby, :to_s
			end

			refine Bool do
				def to_ruby
					self === true
				end
			end

			refine Record do
				def to_ruby(&decode)
					Hash[to_h.map { |k, v| [k, decode[v]] }]
				end
			end

			refine EmptyRecord do
				def to_ruby
					{}
				end
			end

			refine List do
				def to_ruby(&decode)
					to_a.map(&decode)
				end
			end

			refine Optional do
				def to_ruby(&decode)
					reduce(nil, &decode)
				end
			end

			refine Function do
				def to_ruby(&decode)
					->(*args) { decode[call(*args)] }
				end
			end

			refine Enum do
				def to_ruby
					extract == :None ? nil : extract
				end
			end

			refine Union do
				def to_ruby
					rtag = tag.sub(/_[0-9a-f]{64}\Z/, "")
					if tag.match(/\A\p{Upper}/) &&
					   Object.const_defined?(rtag) && !Dhall.const_defined?(rtag, false)
						yield extract, Object.const_get(rtag)
					else
						yield extract
					end
				end
			end

			refine TypeAnnotation do
				def to_ruby
					yield value
				end
			end
		end

		using ToRuby

		module InitWith
			refine Object do
				def init_with(coder)
					coder.map.each do |k, v|
						instance_variable_set(:"@#{k}", v)
					end
				end
			end
		end

		using InitWith

		def revive(klass, expr, op="revive", transform_keys: :to_s)
			@verifier.verify_class(klass, op)
			return klass.from_dhall(expr) if klass.respond_to?(:from_dhall)

			klass.allocate.tap do |o|
				o.init_with(Util.psych_coder_for(
					klass.name,
					decode(expr, op, transform_keys: transform_keys)
				))
			end
		end

		def decode(expr, op="decode", klass: nil, transform_keys: :to_s)
			return revive(klass, expr, op, transform_keys: transform_keys) if klass
			@verifier.verify(
				Util.transform_keys(
					expr.to_ruby { |dexpr, dklass|
						decode(dexpr, op, klass: dklass, transform_keys: transform_keys)
					},
					&transform_keys
				),
				op
			)
		end

		def dump(obj)
			return if obj.nil?

			Dhall.dump(@verifier.verify(obj, "dump"))
		end
	end
end
