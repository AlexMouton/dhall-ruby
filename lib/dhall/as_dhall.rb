# frozen_string_literal: true

require "ostruct"
require "psych"

module Dhall
	module AsDhall
		TAGS = {
			::Integer    => "Integer",
			::FalseClass => "Bool",
			::Integer    => "Integer",
			::Float      => "Double",
			::NilClass   => "None",
			::String     => "Text",
			::TrueClass  => "Bool"
		}.freeze

		def self.tag_for(o, type)
			return "Natural" if o.is_a?(::Integer) && !o.negative?

			TAGS.fetch(o.class) do
				"#{o.class.name}_#{type.digest.hexdigest}"
			end
		end

		def self.union_of(values_and_types)
			z = [UnionType.new(alternatives: {}), []]
			values_and_types.reduce(z) do |(ut, tags), (v, t)|
				tag = tag_for(v, t)
				[
					ut.merge(UnionType.new(alternatives: { tag => t })),
					tags + [tag]
				]
			end
		end

		refine ::String do
			def as_dhall
				if encoding == Encoding::BINARY
					bytes.as_dhall
				else
					Text.new(value: self)
				end
			end
		end

		refine ::Symbol do
			def as_dhall
				Dhall::Union.new(
					tag:          to_s,
					value:        nil,
					alternatives: Dhall::UnionType.new(alternatives: {})
				)
			end
		end

		refine ::Integer do
			def as_dhall
				if negative?
					Integer.new(value: self)
				else
					Natural.new(value: self)
				end
			end
		end

		refine ::Float do
			def as_dhall
				Double.new(value: self)
			end
		end

		refine ::TrueClass do
			def as_dhall
				Bool.new(value: true)
			end
		end

		refine ::FalseClass do
			def as_dhall
				Bool.new(value: false)
			end
		end

		refine ::NilClass do
			def as_dhall
				raise(
					"Cannot call NilClass#as_dhall directly, " \
					"you probably want to create a Dhall::OptionalNone yourself."
				)
			end
		end

		module ExpressionList
			def self.for(values, exprs)
				types = exprs.map(&TypeChecker.method(:type_of))

				if types.empty?
					Empty
				elsif types.include?(nil) && types.uniq.length <= 2
					Optional
				elsif types.uniq.length == 1
					Mono
				else
					Union
				end.new(values, exprs, types)
			end

			class Empty
				def initialize(*); end

				def list
					EmptyList.new(element_type: UnionType.new(alternatives: {}))
				end
			end

			class Optional
				def initialize(_, exprs, types)
					@type = types.compact.first
					@exprs = exprs
				end

				def list
					List.new(elements: @exprs.map do |x|
						if x.nil?
							Dhall::OptionalNone.new(value_type: @type)
						else
							Dhall::Optional.new(value: x)
						end
					end)
				end
			end

			class Mono
				def initialize(_, exprs, _)
					@exprs = exprs
				end

				def list
					List.new(elements: @exprs)
				end
			end

			class Union
				def initialize(values, exprs, types)
					@values = values
					@exprs = exprs
					@types = types
				end

				def list
					ut, tags = AsDhall.union_of(@values.zip(@types))

					List.new(elements: @exprs.zip(tags).map do |(expr, tag)|
						Dhall::Union.from(ut, tag, expr)
					end)
				end
			end
		end

		refine ::Array do
			def as_dhall
				ExpressionList.for(self, map { |x| x&.as_dhall }).list
			end
		end

		refine ::Hash do
			def as_dhall
				if empty?
					EmptyRecord.new
				else
					Record.new(record: Hash[
						reject { |_, v| v.nil? }
						.map { |k, v| [k.to_s, v.as_dhall] }
						.sort
					])
				end
			end
		end

		refine ::OpenStruct do
			def as_dhall
				expr = to_h.as_dhall
				type = TypeChecker.for(expr).annotate(TypeChecker::Context.new).type
				Union.from(
					UnionType.new(alternatives: { "OpenStruct" => type }),
					"OpenStruct",
					expr
				)
			end
		end

		refine ::Psych::Coder do
			def as_dhall
				case type
				when :seq
					seq
				when :map
					map
				else
					scalar
				end.as_dhall
			end
		end

		refine ::Object do
			def as_dhall
				tag = self.class.name
				expr = Util.psych_coder_from(tag, self).as_dhall
				type = TypeChecker.for(expr).annotate(TypeChecker::Context.new).type
				Union.from(
					UnionType.new(alternatives: { tag => type }),
					tag,
					expr
				)
			end
		end
	end
end
