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

		def fetch(k)
			RecordSelection.new(record: self, selector: k)
		end

		def slice(*keys)
			RecordProjection.new(record: self, selectors: keys)
		end

		def +(other)
			Operator::Plus.new(lhs: self, rhs: other)
		end

		def *(other)
			Operator::Times.new(lhs: self, rhs: other)
		end

		def <<(other)
			Operator::TextConcatenate.new(lhs: self, rhs: other)
		end

		def concat(other)
			case other
			when EmptyList
				self
			else
				Operator::ListConcatenate.new(lhs: self, rhs: other)
			end
		end

		def &(other)
			if self == other
				self
			elsif other.is_a?(Bool)
				other & self
			else
				Operator::And.new(lhs: self, rhs: other)
			end
		end

		def |(other)
			if self == other
				self
			elsif other.is_a?(Bool)
				other | self
			else
				Operator::Or.new(lhs: self, rhs: other)
			end
		end

		def dhall_eq(other)
			if self == other
				Bool.new(value: true)
			elsif other.is_a?(Bool)
				other.dhall_eq(self)
			else
				Operator::Equal.new(lhs: self, rhs: other)
			end
		end

		def deep_merge(other)
			case other
			when EmptyRecord
				other.deep_merge(self)
			else
				Operator::RecursiveRecordMerge.new(lhs: self, rhs: other)
			end
		end

		def merge(other)
			case other
			when EmptyRecord
				other.merge(self)
			else
				Operator::RightBiasedRecordMerge.new(lhs: self, rhs: other)
			end
		end

		def deep_merge_type(other)
			case other
			when EmptyRecordType
				other.deep_merge_type(self)
			else
				Operator::RecursiveRecordTypeMerge.new(lhs: self, rhs: other)
			end
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
		include(ValueSemantics.for_attributes do
			var  ::String
			type Either(nil, Expression) # nil is not allowed in proper Dhall
			body Expression
		end)

		def map_subexpressions(&block)
			with(var: var, type: type.nil? ? nil : block[type], body: block[body])
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

		def &(other)
			reduce(other, with(value: false))
		end

		def |(other)
			reduce(with(value: true), other)
		end

		def dhall_eq(other)
			reduce(other, super)
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
		class RecursiveRecordMerge < Operator; end
		class RightBiasedRecordMerge < Operator; end
		class RecursiveRecordTypeMerge < Operator; end
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

		def concat(other)
			if other.is_a?(List) && !other.is_a?(EmptyList)
				with(elements: elements + other.elements)
			else
				super
			end
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

		def concat(other)
			other
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
		include(ValueSemantics.for_attributes do
			record Expression
			input  Expression
			type  Either(Expression, nil)
		end)

		def map_subexpressions(&block)
			with(
				record: block[record],
				input: block[input],
				type: type.nil? ? nil : block[type]
			)
		end
	end

	class RecordType < Expression
		attr_reader :record

		def initialize(record)
			raise ArgumentError, "You meant EmptyRecordType?" if record.empty?
			@record = record
		end

		def map_subexpressions(&block)
			self.class.new(Hash[*@record.map { |k, v| [k, block[v]] }])
		end

		def deep_merge_type(other)
			return super unless other.is_a?(RecordType)
			self.class.new(Hash[record.merge(other.record) { |_, v1, v2|
				v1.deep_merge_type(v2)
			}.sort])
		end

		def ==(other)
			other.respond_to?(:record) && record.to_a == other.record.to_a
		end

		def eql?(other)
			self == other
		end
	end

	class EmptyRecordType < Expression
		include ValueSemantics.for_attributes { }

		def map_subexpressions
			self
		end

		def deep_merge_type(other)
			other
		end
	end

	class Record < Expression
		attr_reader :record

		def initialize(record)
			raise ArgumentError, "You meant EmptyRecord?" if record.empty?
			@record = record
		end

		def map_subexpressions(&block)
			self.class.new(Hash[*@record.map { |k, v| [k, block[v]] }])
		end

		def fetch(k, default=nil, &block)
			record.fetch(k, *default, &block)
		end

		def slice(*keys)
			if record.respond_to?(:slice)
				self.class.new(record.slice(*keys))
			else
				self.class.new(record.select { |k, _| keys.include?(k) })
			end
		end

		def deep_merge(other)
			return super unless other.is_a?(Record)
			self.class.new(Hash[record.merge(other.record) { |_, v1, v2|
				v1.deep_merge(v2)
			}.sort])
		end

		def merge(other)
			return super unless other.is_a?(Record)
			self.class.new(Hash[record.merge(other.record).sort])
		end

		def ==(other)
			other.respond_to?(:record) && record.to_a == other.record.to_a
		end

		def eql?(other)
			self == other
		end
	end

	class EmptyRecord < Expression
		include ValueSemantics.for_attributes { }

		def map_subexpressions
			self
		end

		def fetch(k, default=nil, &block)
			{}.fetch(k, *default, &block)
		end

		def slice(*)
			self
		end

		def deep_merge(other)
			other
		end

		def merge(other)
			other
		end
	end

	class RecordSelection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			selector ::String
		end)

		def map_subexpressions(&block)
			with(record: block[record], selector: selector)
		end
	end

	class RecordProjection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			selectors Util::ArrayOf.new(::String, min: 1)
		end)

		def map_subexpressions(&block)
			with(record: block[record], selectors: selectors)
		end
	end

	class EmptyRecordProjection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
		end)

		def map_subexpressions(&block)
			with(record: block[record])
		end
	end

	class UnionType < Expression
		attr_reader :record

		def initialize(record)
			@record = record
		end

		def map_subexpressions(&block)
			self.class.new(Hash[@record.map { |k, v| [k, block[v]] }])
		end

		def ==(other)
			other.respond_to?(:record) && record.to_a == other.record.to_a
		end

		def eql?(other)
			self == other
		end

		def fetch(k)
			Function.new(
				var:  k,
				type: record.fetch(k),
				body: Union.new(
					tag: k,
					value: Variable.new(name: k),
					alternatives: self.class.new(record.dup.tap { |r| r.delete(k) })
				)
			)
		end
	end

	class Union < Expression
		include(ValueSemantics.for_attributes do
			tag          ::String
			value        Expression
			alternatives UnionType
		end)

		def map_subexpressions(&block)
			with(
				tag:          tag,
				value:        block[value],
				alternatives: block[alternatives]
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

		def +(other)
			if other.is_a?(Natural)
				with(value: value + other.value)
			else
				super
			end
		end

		def *(other)
			if other.is_a?(Natural)
				with(value: value * other.value)
			else
				super
			end
		end

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

		def to_s
			"#{value >= 0 ? "+" : ""}#{value.to_s}"
		end
	end

	class Double < Number
		include(ValueSemantics.for_attributes do
			value ::Float
		end)

		def to_s
			value.to_s
		end
	end

	class Text < Expression
		include(ValueSemantics.for_attributes do
			value ::String
		end)

		def <<(other)
			if other.is_a?(Text)
				with(value: value + other.value)
			else
				super
			end
		end
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
		include(ValueSemantics.for_attributes do
			var    ::String
			assign Expression
			type   Either(nil, Expression)
		end)

		def map_subexpressions(&block)
			with(
				var: var,
				assign: block[assign],
				type: type.nil? ? nil : block[type]
			)
		end
	end

	class LetBlock < Expression
		include(ValueSemantics.for_attributes do
			lets ArrayOf(Let)
			body Expression
		end)

		def map_subexpressions(&block)
			with(
				body: block[body],
				lets: lets.map { |let| let.map_subexpressions(&block) }
			)
		end
	end

	class TypeAnnotation < Expression
		include(ValueSemantics.for_attributes do
			value Expression
			type  Expression
		end)

		def map_subexpressions(&block)
			with(
				value: block[value],
				type: block[type]
			)
		end
	end
end
