# frozen_string_literal: true

require "value_semantics"

module Dhall
	class Expression
		def map_subexpressions(&_)
			# For expressions with no subexpressions
			self
		end
	end

	class Application < Expression
		def initialize(f, *args)
			if args.empty?
				raise ArgumentError, "Application requires at least one argument"
			end

			@f = f
			@args = args
		end

		def map_subexpressions(&block)
			self.class.new(block[@f], *@args.map(&block))
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
	end

	class EmptyList < List
		include(ValueSemantics.for_attributes do
			type Expression
		end)

		def map_subexpressions(&block)
			with(type: block[@type])
		end
	end

	class Optional < Expression
		def initialize(value, type=nil)
			raise TypeError, "value must not be nil" if value.nil?

			@value = value
			@type = type
		end

		def map_subexpressions(&block)
			self.class.new(block[@value], block[@type])
		end
	end

	class OptionalNone < Optional
		def initialize(type)
			raise TypeError, "type must not be nil" if type.nil?

			@type = type
		end

		def map_subexpressions(&block)
			self.class.new(block[@type])
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
	end

	class Record < Expression
		def initialize(record)
			@record = record
		end

		def map_subexpressions(&block)
			self.class.new(Hash[*@record.map { |k, v| [k, block[v]] }])
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
