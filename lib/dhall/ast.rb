# frozen_string_literal: true

require "value_semantics"

require "dhall/util"

module Dhall
	class Expression
		def map_subexpressions(&_)
			# For expressions with no subexpressions
			self
		end

		def call(*args)
			args.reduce(self) { |f, arg|
				Application.new(function: f, arguments: [arg])
			}.normalize
		end

		def to_proc
			method(:call).to_proc
		end
	end

	class Application < Expression
		include(ValueSemantics.for_attributes do
			function Expression
			arguments Util::ArrayOf.new(Expression, min: 1)
		end)

		def map_subexpressions(&block)
			with(function: block[function], arguments: arguments.map(&block))
		end
	end

	class Function < Expression
		def initialize(var, type, body)
			@var = var
			@type = type
			@body = body
		end

		def map_subexpressions(&block)
			self.class.new(@var, block[@type], block[@body])
		end
	end

	class Forall < Function; end

	class Bool < Expression
		include(ValueSemantics.for_attributes do
			value Bool()
		end)

		def reduce(when_true, when_false)
			value ? when_true : when_false
		end
	end

	class Variable < Expression
		include(ValueSemantics.for_attributes do
			name String, default: "_"
			index (0..Float::INFINITY), default: 0
		end)
	end

	class Operator < Expression
		include(ValueSemantics.for_attributes do
			lhs Expression
			rhs Expression
		end)

		def map_subexpressions(&block)
			with(lhs: block[@lhs], rhs: block[@rhs])
		end

		class Or < Operator; end
		class And < Operator; end
		class Equal < Operator; end
		class NotEqual < Operator; end
		class Plus < Operator; end
		class Times < Operator; end
		class TextConcatenate < Operator; end
		class ListConcatenate < Operator; end
		class RecordMerge < Operator; end
		class RecordOverride < Operator; end
		class RecordTypeMerge < Operator; end
		class ImportFallback < Operator; end
	end

	class List < Expression
		include(ValueSemantics.for_attributes do
			elements ArrayOf(Expression)
		end)

		def map_subexpressions(&block)
			with(elements: elements.map(&block))
		end

		def type
			# TODO: inferred element type
		end

		def map(type: nil, &block)
			with(elements: elements.each_with_index.map(&block))
		end

		def reduce(z)
			elements.reverse.reduce(z) { |acc, x| yield x, acc }
		end

		def length
			elements.length
		end

		def first
			Optional.new(value: elements.first, type: type)
		end

		def last
			Optional.new(value: elements.last, type: type)
		end

		def reverse
			with(elements: elements.reverse)
		end
	end

	class EmptyList < List
		include(ValueSemantics.for_attributes do
			type Expression
		end)

		def map_subexpressions(&block)
			with(type: block[@type])
		end

		def map(type: nil)
			type.nil? ? self : with(type: type)
		end

		def reduce(z)
			z
		end

		def length
			0
		end

		def first
			OptionalNone.new(type: type)
		end

		def last
			OptionalNone.new(type: type)
		end

		def reverse
			self
		end
	end

	class Optional < Expression
		include(ValueSemantics.for_attributes do
			value Expression
			type Either(nil, Expression), default: nil
		end)

		def map_subexpressions(&block)
			with(value: block[value], type: type.nil? ? type : block[type])
		end
	end

	class OptionalNone < Optional
		include(ValueSemantics.for_attributes do
			type Expression
		end)

		def map_subexpressions(&block)
			with(type: block[@type])
		end
	end

	class Merge < Expression
		def initialize(record, input, type)
			@record = record
			@input = input
			@type = type
		end

		def map_subexpressions(&block)
			self.class.new(block[@record], block[@input], block[@type])
		end
	end

	class RecordType < Expression
		attr_reader :record

		def initialize(record)
			@record = record
		end

		def map_subexpressions(&block)
			self.class.new(
				Hash[*@record.map { |k, v| [k, block[v]] }],
				block[@input],
				block[@type]
			)
		end

		def eql?(other)
			record == other.record
		end
	end

	class Record < Expression
		attr_reader :record

		def initialize(record)
			@record = record
		end

		def map_subexpressions(&block)
			self.class.new(Hash[*@record.map { |k, v| [k, block[v]] }])
		end

		def eql?(other)
			record == other.record
		end
	end

	class RecordFieldAccess < Expression
		def initialize(record, field)
			raise TypeError, "field must be a String" unless field.is_a?(String)

			@record = record
			@field = field
		end

		def map_subexpressions(&block)
			self.class.new(Hash[*@record.map { |k, v| [k, block[v]] }], @field)
		end
	end

	class RecordProjection < Expression
		def initialize(record, *fields)
			unless fields.all? { |x| x.is_a?(String) }
				raise TypeError, "fields must be String"
			end

			@record = record
			@fields = fields
		end

		def map_subexpressions(&block)
			self.class.new(Hash[*@record.map { |k, v| [k, block[v]] }], @fields)
		end
	end

	class UnionType < Expression
		def initialize(record)
			@record = record
		end

		def map_subexpressions(&block)
			self.class.new(Hash[*@record.map { |k, v| [k, block[v]] }])
		end
	end

	class Union < Expression
		def initialize(tag, value, rest_of_type)
			raise TypeError, "tag must be a string" unless tag.is_a?(String)

			@tag = tag
			@value = value
			@rest_of_type = rest_of_type
		end

		def map_subexpressions(&block)
			self.class.new(
				@tag,
				block[@value],
				Hash[*@rest_of_type.map { |k, v| [k, block[v]] }]
			)
		end
	end

	class Constructors < Expression
		extend Gem::Deprecate

		def initialize(arg)
			@arg = arg
		end
		DEPRECATION_WIKI = "https://github.com/dhall-lang/dhall-lang/wiki/" \
		                   "Migration:-Deprecation-of-constructors-keyword"
		deprecate :initialize, DEPRECATION_WIKI, 2019, 4
	end

	class If < Expression
		include(ValueSemantics.for_attributes do
			predicate Expression
			self.then Expression
			self.else Expression
		end)

		def map_subexpressions(&block)
			with(
				predicate: block[predicate],
				then: block[self.then],
				else: block[self.else]
			)
		end
	end

	class Number < Expression
	end

	class Natural < Number
		include(ValueSemantics.for_attributes do
			value (0..Float::INFINITY)
		end)

		def to_s
			value.to_s
		end

		def even?
			value.even?
		end

		def odd?
			value.odd?
		end

		def zero?
			value.zero?
		end

		def pred
			with(value: [0, value - 1].max)
		end
	end

	class Integer < Number
		include(ValueSemantics.for_attributes do
			value ::Integer
		end)
	end

	class Double < Number
		include(ValueSemantics.for_attributes do
			value ::Float
		end)
	end

	class Text < Expression
		include(ValueSemantics.for_attributes do
			value ::String
		end)
	end

	class TextLiteral < Expression
		include(ValueSemantics.for_attributes do
			chunks ArrayOf(Expression)
		end)

		def map_subexpressions(&block)
			with(chunks: chunks.map(&block))
		end
	end

	class Import < Expression
		def initialize(integrity_check, import_type, path)
			@integrity_check = integrity_check
			@import_type = import_type
			@path = path
		end

		class URI
			def initialize(headers, authority, *path, query, fragment)
				@headers = headers
				@authority = authority
				@path = path
				@query = query
				@fragment = fragment
			end
		end

		class Http < URI; end
		class Https < URI; end

		class Path
			def initialize(*path)
				@path = path
			end
		end

		class AbsolutePath < Path; end
		class RelativePath < Path; end
		class RelativeToParentPath < Path; end
		class RelativeToHomePath < Path; end

		class EnvironmentVariable
			def initialize(var)
				@var = var
			end
		end

		class MissingImport; end

		class IntegrityCheck
			def initialize(protocol, data)
				@protocol = protocol
				@data = data
			end
		end
	end

	class Let
		def initialize(var, assign, type=nil)
			@var = var
			@assign = assign
			@type = type
		end

		def map_subexpressions(&block)
			self.class.new(@var, block[@assign], block[@type])
		end
	end

	class LetBlock < Expression
		def initialize(body, *lets)
			unless lets.all? { |x| x.is_a?(Let) }
				raise TypeError, "LetBlock only contains Let"
			end

			@lets = lets
			@body = body
		end

		def map_subexpressions(&block)
			self.class.new(
				block[@body],
				*@lets.map { |let| let.map_subexpressions(&block) }
			)
		end
	end

	class TypeAnnotation < Expression
		def initialize(value, type)
			@value = value
			@type = type
		end

		def map_subexpressions(&block)
			self.class.new(block[@value], block[@type])
		end
	end
end
