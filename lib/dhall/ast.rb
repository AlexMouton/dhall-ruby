# frozen_string_literal: true

require "base32"
require "lazy_object"
require "multihashes"
require "uri"
require "value_semantics"

require "dhall/as_dhall"
require "dhall/util"

module Dhall
	using AsDhall

	class Expression
		def call(*args)
			args.reduce(self) { |f, arg|
				Application.new(function: f, argument: arg)
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
			if other.is_a?(Natural) && other.zero?
				other * self
			else
				Operator::Times.new(lhs: self, rhs: other)
			end
		end

		def concat(other)
			Operator::ListConcatenate.new(lhs: self, rhs: other)
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
			elsif other == Bool.new(value: true)
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

		def annotate(type)
			TypeAnnotation.new(value: self, type: type)
		end

		def to_s
			inspect
		end

		def as_dhall
			self
		end
	end

	class Application < Expression
		include(ValueSemantics.for_attributes do
			function Expression
			argument Expression
		end)

		def self.for(function:, argument:)
			if function == Builtins[:None]
				OptionalNone.new(value_type: argument)
			else
				new(function: function, argument: argument)
			end
		end

		def flatten
			f, args = if function.is_a?(Application)
				function.flatten
			elsif function.is_a?(BuiltinFunction) &&
			      (unfilled = function.unfill).is_a?(Application)
				unfilled.flatten
			else
				[function, []]
			end

			[f, args + [argument]]
		end

		def as_json
			function, arguments = flatten
			[0, function.as_json, *arguments.map(&:as_json)]
		end
	end

	class Function < Expression
		include(ValueSemantics.for_attributes do
			var  ::String
			type Either(nil, Expression) # nil is not allowed in proper Dhall
			body Expression
		end)

		def self.of_arguments(*types, body:)
			types.reverse.reduce(body) do |inner, type|
				new(
					var:  "_",
					type: type,
					body: inner
				)
			end
		end

		def call(*args, &block)
			args += [block] if block
			args.map! { |arg| arg&.as_dhall }
			return super if args.length > 1

			body.substitute(
				Variable.new(name: var),
				args.first.shift(1, var, 0)
			).shift(-1, var, 0).normalize
		end

		alias [] call
		alias === call

		def <<(other)
			FunctionProxy.new(
				->(*args, &block) { call(other.call(*args, &block)) },
				curry: false
			)
		end

		def >>(other)
			FunctionProxy.new(
				->(*args, &block) { other.call(call(*args, &block)) },
				curry: false
			)
		end

		def binding
			to_proc.binding
		end

		def curry
			self
		end

		def as_json
			if var == "_"
				[1, type.as_json, body.as_json]
			else
				[1, var, type.as_json, body.as_json]
			end
		end
	end

	class Forall < Function
		def as_json
			if var == "_"
				[2, type.as_json, body.as_json]
			else
				[2, var, type.as_json, body.as_json]
			end
		end
	end

	class RubyObjectRaw < Expression
		def initialize(object)
			@object = object
		end

		def unwrap
			@object
		end

		def respond_to_missing?(m)
			super || @object.respond_to?(m)
		end

		def method_missing(m, *args, &block)
			if @object.respond_to?(m)
				@object.public_send(m, *args, &block)
			else
				super
			end
		end
	end

	class FunctionProxyRaw < Function
		def initialize(callable, curry: true)
			@callable = if !curry
				callable
			elsif callable.respond_to?(:curry)
				callable.curry
			elsif callable.respond_to?(:to_proc)
				callable.to_proc.curry
			else
				callable.method(:call).to_proc.curry
			end
		end

		def call(*args, &block)
			RubyObjectRaw.new(@callable.call(*args.map { |arg| arg&.as_dhall }, &block))
		end

		def as_json
			raise "Cannot serialize #{self}"
		end
	end

	class FunctionProxy < FunctionProxyRaw
		def call(*args, &block)
			super.unwrap.as_dhall
		end
	end

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
			if other.is_a?(Bool)
				reduce(other, with(value: self == other))
			else
				reduce(other, super)
			end
		end

		def !@
			with(value: !value)
		end

		def ===(other)
			self == other || value === other
		end

		def to_s
			reduce("True", "False")
		end

		def as_json
			value
		end

		def self.as_dhall
			Builtins[:Bool]
		end
	end

	class Variable < Expression
		include(ValueSemantics.for_attributes do
			name String, default: "_"
			index (0..Float::INFINITY), default: 0
		end)

		def self.[](name, index=0)
			new(name: name, index: index)
		end

		def to_s
			"#{name}@#{index}"
		end

		def as_json
			if name == "_"
				index
			else
				[name, index]
			end
		end
	end

	class Operator < Expression
		include(ValueSemantics.for_attributes do
			lhs Expression
			rhs Expression
		end)

		def as_json
			[3, OPERATORS.index(self.class), lhs.as_json, rhs.as_json]
		end

		module FetchFromMerge
			def fetch_second_record(first, second, selector)
				rec = self.class.new(
					self.class::FETCH2K => second.slice(selector),
					self.class::FETCH1K => first
				).normalize

				if rec.class == self.class
					RecordSelection.new(record: rec, selector: selector)
				else
					rec.fetch(selector)
				end
			end

			def fetch(selector)
				first = public_send(self.class::FETCH1K)
				second = public_send(self.class::FETCH2K)
				if first.is_a?(Record)
					first.fetch(selector) { second.fetch(selector) }
				elsif second.is_a?(Record)
					fetch_second_record(first, second, selector)
				else
					super
				end
			end
		end

		class Or < Operator; end
		class And < Operator; end
		class Equal < Operator; end
		class NotEqual < Operator; end
		class Plus < Operator; end
		class Times < Operator; end
		class TextConcatenate < Operator; end
		class ListConcatenate < Operator; end
		class RecursiveRecordMerge < Operator
			FETCH1K = :lhs
			FETCH2K = :rhs
			include FetchFromMerge
		end
		class RightBiasedRecordMerge < Operator
			FETCH1K = :rhs
			FETCH2K = :lhs
			include FetchFromMerge
		end
		class RecursiveRecordTypeMerge < Operator; end
		class ImportFallback < Operator; end
		class Equivalent < Operator; end

		OPERATORS = [
			Or, And, Equal, NotEqual,
			Plus, Times,
			TextConcatenate, ListConcatenate,
			RecursiveRecordMerge, RightBiasedRecordMerge, RecursiveRecordTypeMerge,
			ImportFallback,
			Equivalent
		].freeze
	end

	class List < Expression
		include Enumerable

		include(ValueSemantics.for_attributes do
			elements     Util::ArrayOf.new(Expression, min: 1)
			type         Either(nil, Expression), default: nil
		end)

		def initialize(attrs)
			if attrs.key?(:element_type)
				et = attrs.delete(:element_type)
				attrs[:type] = self.class.as_dhall.call(et) if et
			end

			super
		end

		def self.of(*args, type: nil)
			if args.empty?
				EmptyList.new(element_type: type)
			else
				List.new(elements: args, element_type: type)
			end
		end

		def self.as_dhall
			Builtins[:List]
		end

		def element_type
			if type.nil?
			elsif type.is_a?(Application) && type.function == Builtins[:List]
				type.argument
			else
				raise "Cannot get element_type of: #{type.inspect}"
			end
		end

		def as_json
			[4, nil, *elements.map(&:as_json)]
		end

		def map(type: nil, &block)
			type = type.nil? ? nil : Builtins[:List].call(type.as_dhall)
			with(
				elements: elements.each_with_index.map(&block),
				type:     type
			)
		end

		def each(&block)
			elements.each(&block)
			self
		end

		def reduce(*z)
			elements.reverse.reduce(*z) { |acc, x| yield x, acc }
		end

		def length
			elements.length
		end

		def [](idx)
			Optional.for(elements[idx.to_i], type: element_type)
		end

		def first
			Optional.for(elements.first, type: element_type)
		end

		def last
			Optional.for(elements.last, type: element_type)
		end

		def reverse
			with(elements: elements.reverse)
		end

		def join(sep=$,)
			elements.map(&:to_s).join(sep)
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
			type Either(nil, Expression)
		end)

		def initialize(attrs)
			if attrs.key?(:element_type)
				et = attrs.delete(:element_type)
				attrs[:type] = self.class.as_dhall.call(et) if et
			end

			super
		end

		def as_json
			[4, element_type.as_json]
		rescue
			[28, type.as_json]
		end

		def map(type: nil)
			type.nil? ? self : with(element_type: type)
		end

		def each
			self
		end

		def reduce(z)
			z
		end

		def length
			0
		end

		def [](_)
			OptionalNone.new(value_type: element_type)
		end

		def first
			OptionalNone.new(value_type: element_type)
		end

		def last
			OptionalNone.new(value_type: element_type)
		end

		def reverse
			self
		end

		def join(*)
			""
		end

		def concat(other)
			other
		end
	end

	class Optional < Expression
		include(ValueSemantics.for_attributes do
			value      Expression
			value_type Either(nil, Expression), default: nil
		end)

		def self.for(value, type: nil)
			if value.nil?
				OptionalNone.new(value_type: type)
			else
				Optional.new(value: value, value_type: type)
			end
		end

		def self.as_dhall
			Builtins[:Natural]
		end

		def initialize(normalized: false, **attrs)
			@normalized = normalized
			super(**attrs)
		end

		def type
			return unless value_type

			Dhall::Application.new(
				function: Builtins[:Optional],
				argument: value_type
			)
		end

		def map(type: nil, &block)
			with(value: block[value], value_type: type)
		end

		def reduce(_, &block)
			block[value]
		end

		def to_s
			value.to_s
		end

		def as_json
			[5, @normalized ? nil : value_type&.as_json, value.as_json]
		end
	end

	class OptionalNone < Optional
		include(ValueSemantics.for_attributes do
			value_type Expression
		end)

		def self.as_dhall
			Builtins[:None]
		end

		def map(type: nil)
			type.nil? ? self : with(value_type: type)
		end

		def reduce(z)
			z
		end

		def to_s
			""
		end

		def as_json
			Application.new(
				function: self.class.as_dhall,
				argument: value_type
			).as_json
		end
	end

	class Merge < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			input  Expression
			type   Either(Expression, nil), default: nil
		end)

		def as_json
			[6, record.as_json, input.as_json] +
				(type.nil? ? [] : [type.as_json])
		end
	end

	class ToMap < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			type   Either(Expression, nil), default: nil
		end)

		def as_json
			[27, record.as_json] +
				(type.nil? ? [] : [type.as_json])
		end
	end

	class RecordType < Expression
		include(ValueSemantics.for_attributes do
			record Util::HashOf.new(::String, Expression, min: 1)
		end)

		def self.for(types)
			if types.empty?
				EmptyRecordType.new
			else
				RecordType.new(record: types)
			end
		end

		def merge_type(other)
			return self if other.is_a?(EmptyRecordType)

			with(record: record.merge(other.record))
		end

		def deep_merge_type(other)
			return super unless other.class == RecordType

			with(record: Hash[record.merge(other.record) { |_, v1, v2|
				v1.deep_merge_type(v2)
			}.sort])
		end

		def keys
			record.keys
		end

		def slice(keys)
			RecordType.for(record.select { |k, _| keys.include?(k) })
		end

		def ==(other)
			other.respond_to?(:record) && record.to_a == other.record.to_a
		end

		def eql?(other)
			self == other
		end

		def as_json
			[7, Hash[record.to_a.map { |k, v| [k, v.as_json] }.sort]]
		end
	end

	class EmptyRecordType < RecordType
		include(ValueSemantics.for_attributes {})

		def slice(*)
			self
		end

		def record
			{}
		end

		def merge_type(other)
			other
		end

		def deep_merge_type(other)
			other
		end

		def as_json
			[7, {}]
		end
	end

	class Record < Expression
		include Enumerable

		include(ValueSemantics.for_attributes do
			record Util::HashOf.new(::String, Expression, min: 1)
		end)

		def self.for(record)
			if record.empty?
				EmptyRecord.new
			else
				new(record: record)
			end
		end

		def each(&block)
			record.each(&block)
			self
		end

		def to_h
			record
		end

		def keys
			record.keys
		end

		def values
			record.values
		end

		def [](k)
			record[k.to_s]
		end

		def fetch(k, default=nil, &block)
			record.fetch(k.to_s, *default, &block)
		end

		def slice(*keys)
			keys = keys.map(&:to_s)
			if record.respond_to?(:slice)
				self.class.for(record.slice(*keys))
			else
				self.class.for(record.select { |k, _| keys.include?(k) })
			end
		end

		def dig(*keys)
			if keys.empty?
				raise ArgumentError, "wrong number of arguments (given 0, expected 1+)"
			end

			key, *rest = keys.map(&:to_s)
			v = record.fetch(key) { return nil }
			return v if rest.empty?

			v.dig(*rest)
		end

		def deep_merge(other)
			other = other.as_dhall
			return super unless other.is_a?(Record)

			with(record: Hash[record.merge(other.record) { |_, v1, v2|
				v1.deep_merge(v2)
			}.sort])
		end

		def merge(other)
			other = other.as_dhall
			return super unless other.is_a?(Record)

			with(record: Hash[record.merge(other.record).sort])
		end

		def map(&block)
			with(record: Hash[record.map(&block)])
		end

		def ==(other)
			other.respond_to?(:record) && record.to_a == other.record.to_a
		end

		def eql?(other)
			self == other
		end

		def with(attrs)
			self.class.new({ record: record }.merge(attrs))
		end

		def as_json
			[8, Hash[record.to_a.map { |k, v| [k, v.as_json] }.sort]]
		end
	end

	class EmptyRecord < Expression
		include Enumerable

		include(ValueSemantics.for_attributes {})

		def each
			self
		end

		def to_h
			{}
		end

		def keys
			[]
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

		def map
			self
		end

		def as_json
			[8, {}]
		end
	end

	class RecordSelection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			selector ::String
		end)

		def call(value)
			if record.is_a?(UnionType)
				record.get_constructor(selector).call(value)
			else
				Application.new(function: self, argument: value)
			end
		end

		def as_json
			[9, record.as_json, selector]
		end
	end

	class RecordProjection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			selectors Util::ArrayOf.new(::String, min: 1)
		end)

		def self.for(record, selectors)
			if selectors.empty?
				EmptyRecordProjection.new(record: record)
			else
				new(record: record, selectors: selectors)
			end
		end

		def fetch(selector)
			record.fetch(selector)
		end

		def as_json
			[10, record.as_json, *selectors]
		end
	end

	class RecordProjectionByExpression < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			selector Expression
		end)

		def fetch(selector)
			record.fetch(selector)
		end

		def as_json
			[10, record.as_json, [selector.as_json]]
		end
	end

	class EmptyRecordProjection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
		end)

		def selectors
			[]
		end

		def as_json
			[10, record.as_json]
		end
	end

	class UnionType < Expression
		include(ValueSemantics.for_attributes do
			alternatives Util::HashOf.new(::String, Either(Expression, nil)), default: {}
		end)

		def empty?
			alternatives.empty?
		end

		def [](k)
			alternatives.fetch(k)
		end

		def without(*keys)
			keys.map!(&:to_s)
			with(alternatives: alternatives.reject { |k, _| keys.include?(k) })
		end

		def record
			alternatives
		end

		def ==(other)
			other.is_a?(UnionType) && alternatives.to_a == other.alternatives.to_a
		end

		def eql?(other)
			self == other
		end

		def merge(other, &block)
			with(alternatives: alternatives.merge(other.alternatives, &block))
		end

		def fetch(k, default=nil)
			if alternatives.fetch(k)
				super(k)
			else
				Union.from(self, k, nil)
			end
		rescue KeyError
			block_given? ? yield : (default || raise)
		end

		def get_constructor(selector)
			type = alternatives.fetch(selector)
			body = Union.from(self, selector, Variable[selector])
			Function.new(var: selector, type: type, body: body)
		end

		def constructor_types
			alternatives.each_with_object({}) do |(k, type), ctypes|
				ctypes[k] = if type.nil?
					self
				else
					Forall.new(var: k, type: type, body: self)
				end
			end
		end

		def as_json
			[11, Hash[alternatives.to_a.map { |k, v| [k, v&.as_json] }.sort]]
		end
	end

	class Union < Expression
		include(ValueSemantics.for_attributes do
			tag          ::String
			value        Expression
			alternatives UnionType
		end)

		def self.from(alts, tag, value)
			if value.nil?
				Enum.new(tag: tag, alternatives: alts.without(tag))
			else
				new(
					tag:          tag,
					value:        TypeAnnotation.new(value: value, type: alts[tag]),
					alternatives: alts.without(tag)
				)
			end
		end

		def to_s
			extract.to_s
		end

		def extract
			if value.is_a?(TypeAnnotation)
				value.value
			else
				value
			end
		end

		def reduce(handlers)
			handlers = handlers.to_h
			handler = handlers.fetch(tag.to_sym) { handlers.fetch(tag) }
			(handler.respond_to?(:to_proc) ? handler.to_proc : handler)
				.call(extract)
		end

		def selection_syntax
			RecordSelection.new(
				record:   alternatives.merge(
					UnionType.new(alternatives: { tag => value&.type })
				),
				selector: tag
			)
		end

		def syntax
			Application.new(
				function: selection_syntax,
				argument: value.is_a?(TypeAnnotation) ? value.value : value
			)
		end

		def as_json
			if value.respond_to?(:type)
				syntax.as_json
			else
				[12, tag, value&.as_json, alternatives.as_json.last]
			end
		end
	end

	class Enum < Union
		include(ValueSemantics.for_attributes do
			tag          ::String
			alternatives UnionType
		end)

		def reduce(handlers)
			handlers = handlers.to_h
			handler = handlers.fetch(tag.to_sym) { handlers.fetch(tag) }
			handler
		end

		def to_s
			tag
		end

		def extract
			tag.to_sym
		end

		def as_json
			selection_syntax.as_json
		end
	end

	class If < Expression
		include(ValueSemantics.for_attributes do
			predicate Expression
			self.then Expression
			self.else Expression
		end)

		def as_json
			[14, predicate.as_json, self.then.as_json, self.else.as_json]
		end
	end

	class Natural < Expression
		include(ValueSemantics.for_attributes do
			value (0..Float::INFINITY)
		end)

		def self.as_dhall
			Builtins[:Natural]
		end

		def coerce(other)
			[other.as_dhall, self]
		end

		def +(other)
			other = other.as_dhall
			if other.is_a?(Natural)
				with(value: value + other.value)
			else
				super
			end
		end

		def *(other)
			other = other.as_dhall
			return self if zero?
			if other.is_a?(Natural)
				with(value: value * other.value)
			else
				super
			end
		end

		def to_i
			value
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

		def ===(other)
			self == other || value === other
		end

		def as_json
			[15, value]
		end
	end

	class Integer < Expression
		include(ValueSemantics.for_attributes do
			value ::Integer
		end)

		def self.as_dhall
			Builtins[:Integer]
		end

		def to_s
			"#{value >= 0 ? "+" : ""}#{value}"
		end

		def to_i
			value
		end

		def ===(other)
			self == other || value === other
		end

		def as_json
			[16, value]
		end
	end

	class Double < Expression
		include(ValueSemantics.for_attributes do
			value ::Float
		end)

		def self.as_dhall
			Builtins[:Double]
		end

		def to_s
			value.to_s
		end

		def to_f
			value
		end

		def ===(other)
			self == other || value === other
		end

		def coerce(other)
			return [other, self] if other.is_a?(Double)
			[Double.new(value: other.to_f), self]
		end

		def eql?(other)
			other.is_a?(Double) && to_cbor == other.to_cbor
		end

		def single?
			[value].pack("g").unpack("g").first == value
		end

		def as_json
			self
		end

		def to_json
			value.to_json
		end

		def to_cbor(packer=nil)
			if [0, Float::INFINITY, -Float::INFINITY].include?(value) || value.nan?
				return value.to_cbor(packer)
			end

			# Dhall spec requires *not* using half-precision CBOR floats
			bytes = single? ? [0xFA, value].pack("Cg") : [0xFB, value].pack("CG")
			if packer
				packer.buffer.write(bytes)
				packer
			else
				bytes
			end
		end
	end

	class Text < Expression
		include(ValueSemantics.for_attributes do
			value ::String, coerce: ->(s) { s.encode("UTF-8") }
		end)

		def self.as_dhall
			Builtins[:Text]
		end

		def empty?
			value.empty?
		end

		def <<(other)
			with(value: value + other.value)
		end

		def to_s
			value
		end

		def ===(other)
			self == other || value === other
		end

		def as_json
			[18, value]
		end
	end

	class TextLiteral < Expression
		include(ValueSemantics.for_attributes do
			chunks Util::ArrayOf.new(Expression, min: 3)
		end)

		def self.for(*chunks)
			fixed =
				([""] + chunks)
				.flat_map { |c| ["", c, ""] }
				.map { |c| c.is_a?(Expression) ? c : Text.new(value: c.to_s) }
				.chunk { |x| x.is_a?(Text) }.flat_map do |(is_text, group)|
					is_text ? group.reduce(&:<<) : group
				end

			fixed.length == 1 ? fixed.first : new(chunks: fixed)
		end

		def start_empty?
			chunks.first.empty?
		end

		def end_empty?
			chunks.last.empty?
		end

		def as_json
			[18, *chunks.map { |chunk| chunk.is_a?(Text) ? chunk.value : chunk.as_json }]
		end
	end

	class Import < Expression
		class IntegrityCheck
			include(ValueSemantics.for_attributes do
				code   ::Integer
				digest ::String
			end)

			class FailureException < StandardError; end

			def to_s
				"#{Multihashes::TABLE[code].sub(/\Asha2-/, "sha")}:#{hexdigest}"
			end

			def hexdigest
				digest.unpack("H*").first.encode(Encoding::UTF_8)
			end

			def ipfs
				"/ipfs/b#{Base32.encode("\x01\x55" + as_json).downcase.sub(/=*$/, "")}"
			end

			def check(expr)
				expr = expr.normalize
				return expr if expr.cache_key == to_s

				raise FailureException, "#{expr} hash #{expr.cache_key}" \
				                        " does not match #{self}"
			end

			def as_json
				Multihashes.encode(digest, Multihashes::TABLE[code])
			end
		end

		class NoIntegrityCheck < IntegrityCheck
			def initialize; end

			def to_s
				""
			end

			def hexdigest; end

			def check(expr)
				expr.normalize
			end

			def as_json
				nil
			end
		end

		Location = LazyObject.new do
			UnionType.new(
				alternatives: {
					"Local"       => Builtins[:Text],
					"Remote"      => Builtins[:Text],
					"Environment" => Builtins[:Text],
					"Missing"     => nil
				}
			)
		end

		class URI
			include(ValueSemantics.for_attributes do
				uri       ::URI
				headers   Either(nil, Expression), default: nil
			end)

			def with(attrs)
				if attrs.key?(:path)
					attrs[:uri] =
						uri + Util.path_components_to_uri(*attrs.delete(:path))
				end

				super
			end

			def headers
				header_type = RecordType.new(
					record: {
						"mapKey"   => Builtins[:Text],
						"mapValue" => Builtins[:Text]
					}
				)

				super || EmptyList.new(element_type: header_type)
			end

			def chain_onto(relative_to)
				if headers.is_a?(Import)
					with(headers: headers.with(path: headers.real_path(relative_to)))
				else
					self
				end
			end

			def canonical
				with(
					path: (path[1..-1] + [""]).reduce([[], path.first]) { |(pth, prev), c|
						c == ".." ? [pth, prev] : [pth + [prev], c]
					}.first.reject { |c| c == "." }
				)
			end

			def port
				uri.port && uri.port != uri.default_port ? uri.port : nil
			end

			def authority
				[
					uri.userinfo,
					[uri.host, port].compact.join(":")
				].compact.join("@")
			end

			def origin
				"#{uri.scheme}://#{authority}"
			end

			def to_s
				uri.to_s
			end

			def location
				Union.from(Location, "Remote", to_s.as_dhall)
			end

			def path
				path = uri.path.split(/\//, -1)
				path = path[1..-1] if path.length > 1 && path.first.empty?
				path
			end

			def as_json
				[@headers&.as_json, authority, *path, uri.query]
			end
		end

		class Http < URI
			def resolve(resolver)
				resolver.resolve_http(self)
			end
		end

		class Https < URI
			def resolve(resolver)
				resolver.resolve_https(self)
			end
		end

		class Path
			include(ValueSemantics.for_attributes do
				path ArrayOf(::String)
			end)

			def initialize(*path)
				super(path: path)
			end

			def with(path:)
				self.class.new(*path)
			end

			def self.from_string(s)
				prefix, *suffix = s.to_s.split(/\//)
				if prefix == ""
					AbsolutePath.new(*suffix)
				elsif prefix == "~"
					RelativeToHomePath.new(*suffix)
				elsif prefix == ".."
					RelativeToParentPath.new(*suffix)
				else
					RelativePath.new(prefix, *suffix)
				end
			end

			def canonical
				self.class.from_string(pathname.cleanpath)
			end

			def resolve(resolver)
				resolver.resolve_path(self)
			end

			def origin
				"localhost"
			end

			def to_s
				pathname.to_s
			end

			def location
				Union.from(Location, "Local", to_s.as_dhall)
			end

			def as_json
				path
			end
		end

		class AbsolutePath < Path
			def pathname
				Pathname.new("/").join(*path)
			end

			def to_uri(scheme, base_uri)
				scheme.new(uri: base_uri + Util.path_components_to_uri(*path))
			end

			def chain_onto(relative_to)
				if relative_to.is_a?(URI)
					raise ImportBannedException, "remote import cannot import #{self}"
				end

				self
			end
		end

		class RelativePath < Path
			def pathname
				Pathname.new(".").join(*path)
			end

			def to_s
				"./#{pathname}"
			end

			def chain_onto(relative_to)
				relative_to.with(
					path: relative_to.path[0..-2] + path
				)
			end
		end

		class RelativeToParentPath < Path
			def pathname
				Pathname.new("..").join(*path)
			end

			def chain_onto(relative_to)
				relative_to.with(
					path: relative_to.path[0..-2] + [".."] + path
				)
			end
		end

		class RelativeToHomePath < Path
			def pathname
				Pathname.new("~").join(*@path)
			end

			def chain_onto(relative_to)
				if relative_to.is_a?(URI)
					raise ImportBannedException, "remote import cannot import #{self}"
				end

				self
			end
		end

		class EnvironmentVariable
			attr_reader :var

			def initialize(var)
				@var = var
			end

			def chain_onto(relative_to)
				if relative_to.is_a?(URI)
					raise ImportBannedException, "remote import cannot import #{self}"
				end

				self
			end

			def path
				[]
			end

			def with(path:)
				Path.from_string(path.join("/"))
			end

			def canonical
				self
			end

			def real_path
				self
			end

			def resolve(resolver)
				resolver.resolve_environment(self)
			end

			def origin
				"localhost"
			end

			def to_s
				escapes = Parser::PosixEnvironmentVariableCharacter::ESCAPES
				"env:#{@var.gsub(/[\"\\\a\b\f\n\r\t\v]/) do |c|
					"\\" + escapes.find { |(_, v)| v == c }.first
				end}"
			end

			def location
				Union.from(Location, "Environment", to_s.as_dhall)
			end

			def hash
				@var.hash
			end

			def eql?(other)
				other.is_a?(self.class) && other.var == var
			end
			alias == eql?

			def as_json
				@var
			end
		end

		class MissingImport
			def chain_onto(*)
				self
			end

			def canonical
				self
			end

			def resolve(*)
				Promise.new.reject(ImportFailedException.new("missing"))
			end

			def origin; end

			def to_s
				"missing"
			end

			def location
				Union.from(Location, "Missing", nil)
			end

			def eql?(other)
				other.class == self.class
			end
			alias == eql?

			def as_json
				[]
			end
		end

		class Expression
			def self.call(import_value, deadline: Util::NoDeadline.new)
				return import_value if import_value.is_a?(Dhall::Expression)

				Dhall.load_raw(import_value, timeout: deadline.timeout)
			end
		end

		class Text
			def self.call(import_value, deadline: Util::NoDeadline.new)
				Dhall::Text.new(value: import_value)
			end
		end

		class AsLocation
			def self.call(*)
				raise "AsLocation is only a marker, you don't actually call it"
			end
		end

		IMPORT_TYPES = [
			Expression,
			Text,
			AsLocation
		].freeze

		PATH_TYPES = [
			Http, Https,
			AbsolutePath, RelativePath, RelativeToParentPath, RelativeToHomePath,
			EnvironmentVariable, MissingImport
		].freeze

		include(ValueSemantics.for_attributes do
			integrity_check IntegrityCheck, default: NoIntegrityCheck.new
			import_type     Class
			path            Either(*PATH_TYPES)
		end)

		def initialize(integrity_check, import_type, path)
			super(
				integrity_check: integrity_check || NoIntegrityCheck.new,
				import_type:     import_type,
				path:            path
			)
		end

		def with(options)
			self.class.new(
				options.fetch(:integrity_check, integrity_check),
				options.fetch(:import_type, import_type),
				options.fetch(:path, path)
			)
		end

		def real_path(relative_to)
			path.chain_onto(relative_to).canonical
		end

		def parse_resolve_check(raw, deadline: Util::NoDeadline.new, **kwargs)
			import_type.call(raw, deadline: deadline).resolve(**kwargs).then do |e|
				integrity_check.check(TypeChecker.annotate(e))
			end
		end

		def cache_key(relative_to)
			key = integrity_check.to_s
			if key.empty?
				real_path(relative_to)
			else
				key
			end
		end

		def as_json
			[
				24,
				integrity_check&.as_json,
				IMPORT_TYPES.index(import_type),
				PATH_TYPES.index(path.class),
				*path.as_json
			]
		end
	end

	class Let < Expression
		include(ValueSemantics.for_attributes do
			var    ::String
			assign Expression
			type   Either(nil, Expression)
		end)

		def as_json
			[var, type&.as_json, assign.as_json]
		end
	end

	class LetIn < Expression
		include(ValueSemantics.for_attributes do
			let  Let
			body Expression
		end)

		def lets
			[let]
		end

		def flatten
			flattened = body.is_a?(LetIn) ? body.flatten : body
			if flattened.is_a?(LetBlock)
				LetBlock.new(lets: lets + flattened.lets, body: flattened.body)
			else
				LetBlock.new(lets: lets, body: body)
			end
		end

		def desugar
			Application.new(
				function: Function.new(
					var:  let.var,
					type: let.type,
					body: body
				),
				argument: let.assign
			)
		end

		def eliminate
			body.substitute(
				Dhall::Variable[let.var],
				let.assign.shift(1, let.var, 0)
			).shift(-1, let.var, 0)
		end

		def as_json
			flatten.as_json
		end
	end

	class LetBlock
		include(ValueSemantics.for_attributes do
			lets Util::ArrayOf.new(Let)
			body Expression
		end)

		def unflatten
			lets.reverse.reduce(body) do |inside, let|
				letin = LetIn.new(let: let, body: inside)
				block_given? ? (yield letin) : letin
			end
		end

		def as_json
			[25, *lets.flat_map(&:as_json), body.as_json]
		end
	end

	class TypeAnnotation < Expression
		include(ValueSemantics.for_attributes do
			value Expression
			type  Expression
		end)

		def as_json
			[26, value.as_json, type.as_json]
		end
	end

	class Assertion < Expression
		include(ValueSemantics.for_attributes do
			type Expression
		end)

		def as_json
			[19, type.as_json]
		end
	end
end
