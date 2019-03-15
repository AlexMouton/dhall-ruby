# frozen_string_literal: true

require "uri"
require "value_semantics"

require "dhall/util"
require "dhall/visitor"

module Dhall
	class Expression
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
			case other
			when Natural
				other * self
			else
				Operator::Times.new(lhs: self, rhs: other)
			end
		end

		def <<(other)
			Operator::TextConcatenate.new(lhs: self, rhs: other)
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

		def as_json
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

		def call(*args)
			return super if args.length > 1

			body.substitute(
				Variable.new(name: var),
				args.first.shift(1, var, 0)
			).shift(-1, var, 0).normalize
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

		def as_json
			value
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

		def as_json
			if name == "_"
				index
			elsif index == 0
				name
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

		OPERATORS = [
			Or, And, Equal, NotEqual,
			Plus, Times,
			TextConcatenate, ListConcatenate,
			RecursiveRecordMerge, RightBiasedRecordMerge, RecursiveRecordTypeMerge,
			ImportFallback
		].freeze
	end

	class List < Expression
		include(ValueSemantics.for_attributes do
			elements ArrayOf(Expression)
		end)

		def self.of(*args)
			List.new(elements: args)
		end

		def as_json
			[4, nil, *elements.map(&:as_json)]
		end

		def type
			# TODO: inferred element type
		end

		def map(type: nil, &block)
			with(elements: elements.each_with_index.map(&block))
		end

		def each(&block)
			elements.each(&block)
			self
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

		def as_json
			[4, type.as_json]
		end

		def map(type: nil)
			type.nil? ? self : with(type: type)
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

		def reduce(_, &block)
			block[value]
		end

		def as_json
			[5, type&.as_json, value.as_json]
		end
	end

	class OptionalNone < Optional
		include(ValueSemantics.for_attributes do
			type Expression
		end)

		def reduce(z)
			z
		end

		def as_json
			[5, type.as_json]
		end
	end

	class Merge < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			input  Expression
			type   Either(Expression, nil)
		end)

		def as_json
			[6, record.as_json, input.as_json] +
				(type.nil? ? [] : [type.as_json])
		end
	end

	class RecordType < Expression
		include(ValueSemantics.for_attributes do
			record Util::HashOf.new(::String, Expression, min: 1)
		end)

		def deep_merge_type(other)
			return super unless other.is_a?(RecordType)

			with(record: Hash[record.merge(other.record) { |_, v1, v2|
				v1.deep_merge_type(v2)
			}.sort])
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

	class EmptyRecordType < Expression
		include(ValueSemantics.for_attributes {})

		def deep_merge_type(other)
			other
		end

		def as_json
			[7, {}]
		end
	end

	class Record < Expression
		include(ValueSemantics.for_attributes do
			record Util::HashOf.new(::String, Expression, min: 1)
		end)

		def fetch(k, default=nil, &block)
			record.fetch(k, *default, &block)
		end

		def slice(*keys)
			if record.respond_to?(:slice)
				with(record: record.slice(*keys))
			else
				with(record: record.select { |k, _| keys.include?(k) })
			end
		end

		def deep_merge(other)
			return super unless other.is_a?(Record)

			with(record: Hash[record.merge(other.record) { |_, v1, v2|
				v1.deep_merge(v2)
			}.sort])
		end

		def merge(other)
			return super unless other.is_a?(Record)

			with(record: Hash[record.merge(other.record).sort])
		end

		def ==(other)
			other.respond_to?(:record) && record.to_a == other.record.to_a
		end

		def eql?(other)
			self == other
		end

		def as_json
			[8, Hash[record.to_a.map { |k, v| [k, v.as_json] }.sort]]
		end
	end

	class EmptyRecord < Expression
		include(ValueSemantics.for_attributes {})

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

		def as_json
			[8, {}]
		end
	end

	class RecordSelection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			selector ::String
		end)

		def as_json
			[9, record.as_json, selector]
		end
	end

	class RecordProjection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
			selectors Util::ArrayOf.new(::String, min: 1)
		end)

		def as_json
			[10, record.as_json, *selectors]
		end
	end

	class EmptyRecordProjection < Expression
		include(ValueSemantics.for_attributes do
			record Expression
		end)

		def as_json
			[10, record.as_json]
		end
	end

	class UnionType < Expression
		include(ValueSemantics.for_attributes do
			alternatives Util::HashOf.new(::String, Expression)
		end)

		def ==(other)
			other.is_a?(UnionType) && alternatives.to_a == other.alternatives.to_a
		end

		def eql?(other)
			self == other
		end

		def fetch(k)
			remains = with(alternatives: alternatives.dup.tap { |r| r.delete(k) })
			Function.new(
				var:  k,
				type: alternatives.fetch(k),
				body: Union.new(
					tag:          k,
					value:        Variable.new(name: k),
					alternatives: remains
				)
			)
		end

		def as_json
			[11, Hash[alternatives.to_a.map { |k, v| [k, v.as_json] }.sort]]
		end
	end

	class Union < Expression
		include(ValueSemantics.for_attributes do
			tag          ::String
			value        Expression
			alternatives UnionType
		end)

		def as_json
			[12, tag, value.as_json, alternatives.as_json.last]
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
			return self if zero?
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

		def as_json
			[15, value]
		end
	end

	class Integer < Number
		include(ValueSemantics.for_attributes do
			value ::Integer
		end)

		def to_s
			"#{value >= 0 ? "+" : ""}#{value}"
		end

		def as_json
			[16, value]
		end
	end

	class Double < Number
		include(ValueSemantics.for_attributes do
			value ::Float
		end)

		def to_s
			value.to_s
		end

		def single?
			[value].pack("g").unpack("g").first == value
		end

		def as_json
			value
		end

		def as_cbor
			self
		end

		def to_cbor(packer=nil)
			if [0.0, Float::INFINITY, -Float::INFINITY].include?(value) ||
			   value.nan?
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
			value ::String
		end)

		def <<(other)
			if other.is_a?(Text)
				with(value: value + other.value)
			else
				super
			end
		end

		def to_s
			value
		end

		def as_json
			[18, value]
		end
	end

	class TextLiteral < Expression
		include(ValueSemantics.for_attributes do
			chunks ArrayOf(Expression)
		end)

		def as_json
			raise "TextLiteral must start with a Text" unless chunks.first.is_a?(Text)
			[18, *chunks.map { |chunk| chunk.is_a?(Text) ? chunk.value : chunk.as_json }]
		end
	end

	class Import < Expression
		def initialize(integrity_check, import_type, path)
			@integrity_check = integrity_check
			@import_type = import_type
			@path = path
		end

		def as_json
			[
				24,
				@integrity_check&.as_json,
				IMPORT_TYPES.index(@import_type),
				PATH_TYPES.index(@path.class),
				*@path.as_json
			]
		end

		class URI
			include(ValueSemantics.for_attributes do
				headers   Either(nil, Expression)
				authority ::String
				path      ArrayOf(::String)
				query     Either(nil, ::String)
				fragment  Either(nil, ::String)
			end)

			HeaderType = RecordType.new(record: {
				"header" => Variable["Text"],
				"value"  => Variable["Text"]
			})

			def initialize(headers, authority, *path, query, fragment)
				super(
					headers:   headers,
					authority: authority,
					path:      path,
					query:     query,
					fragment:  fragment
				)
			end

			def with(hash)
				self.class.new(
					hash.fetch(:headers),
					authority,
					*path,
					query,
					fragment
				)
			end

			def self.from_uri(uri)
				(uri.scheme == "https" ? Https : Http).new(
					nil,
					"#{uri.host}:#{uri.port}",
					*uri.path.split(/\//)[1..-1],
					uri.query,
					nil
				)
			end

			def headers
				super || EmptyList.new(type: HeaderType)
			end

			def uri
				URI("#{scheme}://#{authority}/#{path.join("/")}?#{query}")
			end

			def as_json
				[@headers.as_json, authority, *path, query, fragment]
			end
		end

		class Http < URI
			def resolve(resolver)
				resolver.resolve_http(self)
			end

			def scheme
				"http"
			end
		end

		class Https < URI
			def resolve(resolver)
				resolver.resolve_https(self)
			end

			def scheme
				"https"
			end
		end

		class Path
			include(ValueSemantics.for_attributes do
				path ArrayOf(::String)
			end)

			def initialize(*path)
				super(path: path)
			end

			def self.from_string(s)
				parts = s.split(/\//)
				if parts.first == ""
					AbsolutePath.new(*parts[1..-1])
				elsif parts.first == "~"
					RelativeToHomePath.new(*parts[1..-1])
				else
					RelativePath.new(*parts)
				end
			end

			def resolve(resolver)
				resolver.resolve_path(self)
			end

			def to_s
				pathname.to_s
			end

			def as_json
				path
			end
		end

		class AbsolutePath < Path
			def pathname
				Pathname.new("/").join(*path)
			end

			def to_uri(scheme, authority)
				scheme.new(nil, authority, *path, nil, nil)
			end
		end

		class RelativePath < Path
			def pathname
				Pathname.new(".").join(*path)
			end
		end

		class RelativeToParentPath < Path
			def pathname
				Pathname.new("..").join(*path)
			end
		end

		class RelativeToHomePath < Path
			def pathname
				Pathname.new("~").join(*@path)
			end
		end

		class EnvironmentVariable
			def initialize(var)
				@var = var
			end

			def value
				ENV.fetch(@var)
			end

			def resolve(resolver)
				val = ENV.fetch(@var)
				if val =~ /\Ahttps?:\/\//
					URI.from_uri(URI(value))
				else
					Path.from_string(val)
				end.resolve(resolver)
			end

			def as_json
				var
			end
		end

		class MissingImport
			def resolve(*)
				Promise.new.reject(ImportFailedException.new("missing"))
			end

			def as_json
				[]
			end
		end

		class IntegrityCheck
			def initialize(protocol, data)
				@protocol = protocol
				@data = data
			end
		end

		class Expression
			def self.call(import_value)
				Dhall.from_binary(import_value)
			end
		end

		class Text
			def self.call(import_value)
				Dhall::Text.new(value: import_value)
			end
		end

		IMPORT_TYPES = [
			Expression,
			Text
		].freeze

		PATH_TYPES = [
			Http, Https,
			AbsolutePath, RelativePath, RelativeToParentPath, RelativeToHomePath,
			EnvironmentVariable, MissingImport
		].freeze
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

	class LetBlock < Expression
		include(ValueSemantics.for_attributes do
			lets ArrayOf(Let)
			body Expression
		end)

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
end
