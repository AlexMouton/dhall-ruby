# frozen_string_literal: true

require "dhall/builtins"
require "dhall/visitor"
require "dhall/util"

module Dhall
	module ExpressionVisitor
		def self.new(&block)
			Visitor.new(
				Expression                                             => block,
				Util::ArrayOf.new(Expression)                          => lambda do |x|
					x.map(&block)
				end,
				Util::HashOf.new(ValueSemantics::Anything, Expression) => lambda do |x|
					Hash[x.map { |k, v| [k, block[v]] }]
				end
			)
		end
	end

	class Expression
		def normalize
			with(ExpressionVisitor.new(&:normalize).visit(self))
		end

		def shift(amount, name, min_index)
			with(ExpressionVisitor.new { |expr|
				expr.shift(amount, name, min_index)
			}.visit(self))
		end

		def substitute(var, with_expr)
			with(ExpressionVisitor.new { |expr|
				expr.substitute(var, with_expr)
			}.visit(self))
		end

		def fusion(*); end
	end

	class Application
		def normalize
			return fuse.normalize if fuse

			normalized = super
			return normalized.fuse if normalized.fuse

			if normalized.function.is_a?(Builtin) ||
			   normalized.function.is_a?(Function)
				return normalized.function.call(*normalized.arguments)
			end

			normalized
		end

		def fuse
			if function.is_a?(Application)
				@fuse ||= function.function.fusion(*function.arguments, *arguments)
				return @fuse if @fuse
			end

			@fuse ||= function.fusion(*arguments)
		end
	end

	class Function
		@@alpha_normalization = true

		def self.disable_alpha_normalization!
			@@alpha_normalization = false
		end

		def self.enable_alpha_normalization!
			@@alpha_normalization = true
		end

		def shift(amount, name, min_index)
			return super unless var == name

			with(
				type: type.shift(amount, name, min_index),
				body: body.shift(amount, name, min_index + 1)
			)
		end

		def substitute(svar, with_expr)
			with(
				type: type&.substitute(svar, with_expr),
				body: body.substitute(
					var == svar.name ? svar.with(index: svar.index + 1) : svar,
					with_expr.shift(1, var, 0)
				)
			)
		end

		def normalize
			return super unless alpha_normalize?
			with(
				var:  "_",
				type: type&.normalize,
				body: body
				      .shift(1, "_", 0)
				      .substitute(Variable[var], Variable["_"])
				      .shift(-1, var, 0)
				      .normalize
			)
		end

		protected

		def alpha_normalize?
			var != "_" && @@alpha_normalization
		end
	end

	class Forall; end

	class Bool
	end

	class Variable
		def shift(amount, name, min_index)
			return self if self.name != name || min_index > index

			with(index: index + amount)
		end

		def substitute(var, with_expr)
			self == var ? with_expr : self
		end
	end

	class Operator
		class Or
			def normalize
				lhs.normalize | rhs.normalize
			end
		end

		class And
			def normalize
				lhs.normalize & rhs.normalize
			end
		end

		class Equal
			def normalize
				lhs.normalize.dhall_eq(rhs.normalize)
			end
		end

		class NotEqual
			def normalize
				normalized = super
				if normalized.lhs == Bool.new(value: false)
					normalized.rhs
				elsif normalized.rhs == Bool.new(value: false)
					normalized.lhs
				elsif normalized.lhs == normalized.rhs
					Bool.new(value: false)
				else
					normalized
				end
			end
		end

		class Plus
			def normalize
				normalized = super
				if normalized.lhs == Natural.new(value: 0)
					normalized.rhs
				elsif normalized.rhs == Natural.new(value: 0)
					normalized.lhs
				else
					normalized.lhs + normalized.rhs
				end
			end
		end

		class Times
			def normalize
				normalized = super
				if normalized.lhs == Natural.new(value: 1)
					normalized.rhs
				elsif normalized.rhs == Natural.new(value: 1)
					normalized.lhs
				else
					normalized.lhs * normalized.rhs
				end
			end
		end

		class TextConcatenate
			def normalize
				normalized = super
				if normalized.lhs == Text.new(value: "")
					normalized.rhs
				elsif normalized.rhs == Text.new(value: "")
					normalized.lhs
				else
					normalized.lhs << normalized.rhs
				end
			end
		end

		class ListConcatenate
			def normalize
				normalized = super
				case normalized.rhs
				when EmptyList
					normalized.lhs
				else
					normalized.lhs.concat(normalized.rhs)
				end
			end
		end

		class RecursiveRecordMerge
			def normalize
				lhs.normalize.deep_merge(rhs.normalize)
			end
		end

		class RightBiasedRecordMerge
			def normalize
				lhs.normalize.merge(rhs.normalize)
			end
		end

		class RecursiveRecordTypeMerge
			def normalize
				lhs.normalize.deep_merge_type(rhs.normalize)
			end
		end
	end

	class List
			def normalize
				super.with(type: nil)
			end
	end

	class EmptyList
			def normalize
				super.with(type: type.normalize)
			end
	end

	class Optional
		def normalize
			with(value: value.normalize, type: nil)
		end
	end

	class OptionalNone
		def normalize
			with(type: type.normalize)
		end
	end

	class Merge
		def normalize
			normalized = super
			if normalized.record.is_a?(Record) && normalized.input.is_a?(Union)
				normalized.record.fetch(normalized.input.tag).call(
					normalized.input.value
				)
			else
				normalized
			end
		end
	end

	class RecordSelection
		def normalize
			record.normalize.fetch(selector)
		end
	end

	class RecordProjection
		def normalize
			record.normalize.slice(*selectors)
		end
	end

	class EmptyRecordProjection
		def normalize
			EmptyRecord.new
		end
	end

	class UnionType
		def normalize
			with(alternatives: Hash[super.alternatives.sort])
		end
	end

	class Union
	end

	class If
		def normalize
			normalized = super
			if normalized.predicate.is_a?(Bool)
				normalized.predicate.reduce(normalized.then, normalized.else)
			elsif normalized.trivial?
				normalized.predicate
			elsif normalized.then == normalized.else
				normalized.then
			else
				normalized
			end
		end

		def trivial?
			self.then == Bool.new(value: true) &&
				self.else == Bool.new(value: false)
		end
	end

	class Number
	end

	class Natural; end
	class Integer; end
	class Double; end

	class Text
	end

	class TextLiteral
		def normalize
			chunks =
				super
				.flatten.chunks.chunk { |x| x.is_a?(Text) }.flat_map do |(_, group)|
					if group.first.is_a?(Text)
						[Text.new(value: group.map(&:value).join)]
					else
						group
					end
				end

			chunks.length == 1 ? chunks.first : with(chunks: chunks)
		end

		def flatten
			with(chunks: chunks.flat_map do |chunk|
				chunk.is_a?(TextLiteral) ? chunk.chunks : chunk
			end)
		end
	end

	class Import
	end

	class LetBlock
		def normalize
			desugar.normalize
		end

		def shift(amount, name, min_index)
			return unflatten.shift(amount, name, min_index) if lets.length > 1
			return super unless lets.first.var == name

			with(
				lets: [let.first.shift(amount, name, min_index)],
				body: body.shift(amount, name, min_index + 1)
			)
		end
	end

	class TypeAnnotation
		def normalize
			value.normalize
		end
	end
end
