# frozen_string_literal: true

require "dhall/builtins"
require "dhall/util"

module Dhall
	class ExpressionVisitor
		ExpressionHash = Util::HashOf.new(
			ValueSemantics::Anything,
			ValueSemantics::Either.new([Expression, nil])
		)

		ExpressionArray = Util::ArrayOf.new(Expression)

		def initialize(&block)
			@block = block
		end

		def visit(expr)
			expr.to_h.each_with_object({}) do |(attr, value), h|
				result = one_visit(value)
				h[attr] = result if result
			end
		end

		def one_visit(value)
			case value
			when Expression
				@block[value]
			when ExpressionArray
				value.map(&@block)
			when ExpressionHash
				Hash[value.map { |k, v| [k, v.nil? ? v : @block[v]] }.sort]
			end
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

			if normalized.function.is_a?(BuiltinFunction) ||
			   normalized.function.is_a?(Function) ||
			   normalized.function.is_a?(RecordSelection)
				return normalized.function.call(normalized.argument)
			end

			normalized
		end

		def fuse
			if function.is_a?(Application)
				@fuse ||= function.function.fusion(function.argument, argument)
				return @fuse if @fuse
			end

			@fuse ||= function.fusion(argument)
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

	class FunctionProxyRaw
		def shift(*)
			self
		end

		def substitute(*)
			raise "Cannot substitute #{self}"
		end

		def normalize
			self
		end
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
				TextLiteral.for(lhs, rhs).normalize
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

	class EmptyList
		def normalize
			super.with(type: type.normalize)
		end
	end

	class Optional
		def normalize
			with(
				value:      value.normalize,
				value_type: value_type&.normalize,
				normalized: true
			)
		end
	end

	class OptionalNone
		def normalize
			with(value_type: value_type.normalize)
		end
	end

	class ToMap
		def normalize
			normalized = super
			unless [Record, EmptyRecord].include?(normalized.record.class)
				return normalized
			end

			List.of(*normalized.record.to_h.to_a.map do |(k, v)|
				k = Text.new(value: k)
				Record.new(record: { "mapKey" => k, "mapValue" => v })
			end, type: normalized.type&.argument)
		end
	end

	class Merge
		def normalize
			normalized = super
			if normalized.record.is_a?(Record) && normalized.input.is_a?(Union)
				fetched = normalized.record.fetch(normalized.input.tag)
				value = normalized.input.value
				value.nil? ? fetched : fetched.call(value)
			else
				normalized
			end
		end
	end

	class Record
		def normalize
			with(record: Hash[
				record.map { |k, v| [k, v.nil? ? v : v.normalize] }.sort
			])
		end

		def shift(amount, name, min_index)
			with(record: Hash[
				record.map { |k, v|
					[k, v.nil? ? v : v.shift(amount, name, min_index)]
				}.sort
			])
		end

		def substitute(var, with_expr)
			with(record: Hash[
				record.map { |k, v|
					[k, v.nil? ? v : v.substitute(var, with_expr)]
				}.sort
			])
		end
	end

	class EmptyRecord
		def normalize
			self
		end
	end

	class RecordSelection
		def normalize
			record.normalize.fetch(selector)
		end
	end

	class RecordProjection
		def normalize
			record.normalize.slice(*selectors.sort)
		end
	end

	class RecordProjectionByExpression
		def normalize
			sel = selector.normalize

			if sel.is_a?(RecordType)
				RecordProjection.for(record, sel.keys).normalize
			else
				with(record: record.normalize, selector: sel)
			end
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
		def normalize
			val = if value.is_a?(TypeAnnotation)
				value.with(ExpressionVisitor.new(&:normalize).visit(value))
			else
				value&.normalize
			end

			with(value: val, alternatives: alternatives.normalize)
		end
	end

	class Enum
		def normalize
			with(alternatives: alternatives.normalize)
		end
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

	class TextLiteral
		def normalize
			lit = TextLiteral.for(*super.flatten.chunks)

			if lit.is_a?(TextLiteral) && lit.chunks.length == 3 &&
			   lit.start_empty? && lit.end_empty?
				lit.chunks[1]
			else
				lit
			end
		end

		def flatten
			with(chunks: chunks.flat_map do |chunk|
				chunk.is_a?(TextLiteral) ? chunk.chunks : chunk
			end)
		end
	end

	class LetIn
		def normalize
			desugar.normalize
		end

		def shift(amount, name, min_index)
			return super unless let.var == name

			with(
				let:  let.shift(amount, name, min_index),
				body: body.shift(amount, name, min_index + 1)
			)
		end

		def substitute(svar, with_expr)
			var = let.var
			with(
				let:  let.substitute(svar, with_expr),
				body: body.substitute(
					var == svar.name ? svar.with(index: svar.index + 1) : svar,
					with_expr.shift(1, var, 0)
				)
			)
		end
	end

	class TypeAnnotation
		def normalize
			value.normalize
		end
	end
end
