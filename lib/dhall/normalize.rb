# frozen_string_literal: true

require "dhall/builtins"

module Dhall
	class Expression
		def normalize
			map_subexpressions(&:normalize)
		end

		def shift(amount, name, min_index)
			map_subexpressions { |expr| expr.shift(amount, name, min_index) }
		end

		def substitute(var, with_expr)
			map_subexpressions { |expr| expr.substitute(var, with_expr) }
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
				@fused ||= function.function.fusion(*function.arguments, *arguments)
				return @fused if @fused
			end

			@fused ||= function.fusion(*arguments)
		end
	end

	class Function
		def shift(amount, name, min_index)
			return super unless var == name
			with(
				type: type.shift(amount, name, min_index),
				body: body.shift(amount, name, min_index + 1)
			)
		end

		def substitute(svar, with_expr)
			with(
				type: type.substitute(svar, with_expr),
				body: body.substitute(
					var == svar.name ? svar.with(index: svar.index + 1) : svar,
					with_expr.shift(1, var, 0)
				)
			)
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
				if [normalized.lhs, normalized.rhs]
				      .any? { |x| x == Natural.new(value: 0) }
					Natural.new(value: 0)
				elsif normalized.lhs == Natural.new(value: 1)
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
				lhs.normalize.concat(rhs.normalize)
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
	end

	class EmptyList
	end

	class Optional
	end

	class OptionalNone
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

	class RecordType
		def normalize
			self.class.new(Hash[record.sort.map { |(k, v)| [k, v.normalize] }])
		end
	end

	class Record
		def normalize
			self.class.new(Hash[record.sort.map { |(k, v)| [k, v.normalize] }])
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
			self.class.new(Hash[super.record.sort])
		end
	end

	class Union
	end

	class If
		def normalize
			if (pred = predicate.normalize).is_a?(Bool)
				return pred.reduce(self.then, self.else)
			end

			normalized = with(
				predicate: pred,
				then: self.then.normalize,
				else: self.else.normalize
			)

			if normalized.trivial?
				pred
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
			chunks = super.chunks.flat_map { |chunk|
				chunk.is_a?(TextLiteral) ? chunk.chunks : chunk
			}.chunk { |x| x.is_a?(Text) }.flat_map do |(_, group)|
				if group.first.is_a?(Text)
					[Text.new(value: group.map(&:value).join)]
				else
					group
				end
			end

			chunks.length == 1 ? chunks.first : with(chunks: chunks)
		end
	end

	class Import
	end

	class LetBlock
		def normalize
			desugar.normalize
		end

		def desugar
			lets.reverse.reduce(body) { |inside, let|
				Application.new(
					function: Function.new(
						var: let.var,
						type: let.type,
						body: inside
					),
					arguments: [let.assign]
				)
			}
		end

		def shift(amount, name, min_index)
			desugar.shift(amont, name, min_index)
		end
	end

	class TypeAnnotation
		def normalize
			value.normalize
		end
	end
end
