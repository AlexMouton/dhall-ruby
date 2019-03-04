# frozen_string_literal: true

module Dhall
	class Expression
		def normalize
			map_subexpressions(&:normalize)
		end
	end

	class Application
	end

	class Function
	end

	class Forall; end

	class Bool
	end

	class Variable
	end

	class Operator
		class Or
			def normalize
				normalized = super
				if normalized.lhs.is_a?(Bool)
					normalized.lhs.reduce(Bool.new(value: true), normalized.rhs)
				elsif normalized.rhs.is_a?(Bool)
					normalized.rhs.reduce(Bool.new(value: true), normalized.lhs)
				elsif normalized.lhs == normalized.rhs
					normalized.lhs
				else
					normalized
				end
			end
		end

		class And
			def normalize
				normalized = super
				if normalized.lhs.is_a?(Bool)
					normalized.lhs.reduce(normalized.rhs, Bool.new(value: false))
				elsif normalized.rhs.is_a?(Bool)
					normalized.rhs.reduce(normalized.lhs, Bool.new(value: false))
				elsif normalized.lhs == normalized.rhs
					normalized.lhs
				else
					normalized
				end
			end
		end

		class Equal
			def normalize
				normalized = super
				if normalized.lhs == Bool.new(value: true)
					normalized.rhs
				elsif normalized.rhs == Bool.new(value: true)
					normalized.lhs
				elsif normalized.lhs == normalized.rhs
					Bool.new(value: true)
				else
					normalized
				end
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
				if [normalized.lhs, normalized.rhs].all? { |x| x.is_a?(Natural) }
					Natural.new(value: normalized.lhs.value + normalized.rhs.value)
				elsif normalized.lhs == Natural.new(value: 0)
					normalized.rhs
				elsif normalized.rhs == Natural.new(value: 0)
					normalized.lhs
				else
					normalized
				end
			end
		end

		class Times
			def normalize
				normalized = super
				if [normalized.lhs, normalized.rhs].all? { |x| x.is_a?(Natural) }
					Natural.new(value: normalized.lhs.value * normalized.rhs.value)
				elsif [normalized.lhs, normalized.rhs]
				      .any? { |x| x == Natural.new(value: 0) }
					Natural.new(value: 0)
				elsif normalized.lhs == Natural.new(value: 1)
					normalized.rhs
				elsif normalized.rhs == Natural.new(value: 1)
					normalized.lhs
				else
					normalized
				end
			end
		end

		class TextConcatenate
			def normalize
				normalized = super
				if [normalized.lhs, normalized.rhs].all? { |x| x.is_a?(Text) }
					Text.new(value: normalized.lhs.value + normalized.rhs.value)
				elsif normalized.lhs == Text.new(value: "")
					normalized.rhs
				elsif normalized.rhs == Text.new(value: "")
					normalized.lhs
				else
					normalized
				end
			end
		end

		class ListConcatenate
			def normalize
				normalized = super
				if [normalized.lhs, normalized.rhs].all? { |x| x.is_a?(List) }
					List.new(
						elements: normalized.lhs.elements + normalized.rhs.elements
					)
				elsif normalized.lhs.is_a?(EmptyList)
					normalized.rhs
				elsif normalized.rhs.is_a?(EmptyList)
					normalized.lhs
				else
					normalized
				end
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
	end

	class RecordType
	end

	class Record
	end

	class RecordFieldAccess
	end

	class RecordProjection
	end

	class UnionType
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
	end

	class TypeAnnotation
	end
end
