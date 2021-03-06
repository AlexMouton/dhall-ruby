# frozen_string_literal: true

require "ostruct"
require "psych"

module Dhall
	module AsDhall
		TAGS = {
			::Array      => "List",
			::FalseClass => "Bool",
			::Float      => "Double",
			::Hash       => "Record",
			::Integer    => "Integer",
			::Integer    => "Integer",
			::NilClass   => "None",
			::String     => "Text",
			::TrueClass  => "Bool"
		}.freeze

		def self.tag_for(o)
			return "Natural" if o.is_a?(::Integer) && !o.negative?

			TAGS.fetch(o.class) do
				o.class.name
			end
		end

		class AnnotatedExpressionList
			attr_reader :type
			attr_reader :exprs

			def self.from(type_annotation)
				if type_annotation.nil?
					new(nil, [nil])
				else
					new(type_annotation.type, [type_annotation.value])
				end
			end

			def initialize(type, exprs)
				@type = type
				@exprs = exprs
			end

			def +(other)
				raise "#{type} != #{other.type}" if type != other.type
				self.class.new(type, exprs + other.exprs)
			end
		end

		class UnionInferer
			def initialize(tagged={})
				@tagged = tagged
			end

			def union_type
				UnionType.new(alternatives: Hash[@tagged.map { |k, v| [k, v.type] }])
			end

			def union_for(expr)
				if expr.is_a?(Enum)
					tag = expr.tag
					expr = nil
				else
					tag = @tagged.keys.find { |k| @tagged[k].exprs.include?(expr) }
				end
				expr = expr.extract if expr.is_a?(Union)
				Union.from(union_type, tag, expr)
			end

			def with(tag, type_annotation)
				anno = AnnotatedExpressionList.from(type_annotation)
				if @tagged.key?(tag) && @tagged[tag].type != anno.type
					disambiguate_against(tag, anno)
				else
					self.class.new(@tagged.merge(tag => anno) { |_, x, y| x + y })
				end
			end

			def disambiguate_against(tag, anno)
				self.class.new(
					@tagged.reject { |k, _| k == tag }.merge(
						"#{tag}_#{@tagged[tag].type.digest.hexdigest}" => @tagged[tag],
						"#{tag}_#{anno.type.digest.hexdigest}"         => anno
					)
				)
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
				Dhall::Enum.new(
					tag:          to_s,
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
					@tags, @types = values.zip(types).map { |(value, type)|
						if type.is_a?(UnionType) && type.alternatives.length == 1
							type.alternatives.to_a.first
						else
							[AsDhall.tag_for(value), type]
						end
					}.transpose
					@exprs = exprs
					@inferer = UnionInferer.new
				end

				def list
					final_inferer =
						@tags
						.zip(@exprs, @types)
						.reduce(@inferer) do |inferer, (tag, expr, type)|
							inferer.with(
								tag,
								type.nil? ? nil : TypeAnnotation.new(value: expr, type: type)
							)
						end
					List.new(elements: @exprs.map(&final_inferer.method(:union_for)))
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

		refine ::Proc do
			def as_dhall
				FunctionProxy.new(self)
			end
		end

		refine ::Method do
			def as_dhall
				to_proc.as_dhall
			end
		end
	end
end
