# frozen_string_literal: true

require "uri"
require "value_semantics"

require "dhall/util"

module Dhall
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
			argument Expression
		end)

		def self.for(function:, argument:)
			if function == Variable["Some"]
				Optional.new(value: argument)
			elsif function == Variable["None"]
				OptionalNone.new(value_type: argument)
			else
				new(function: function, argument: argument)
			end
		end

		def flatten
			f, args = if function.is_a?(Application)
				function.flatten
			elsif function.is_a?(Builtin) &&
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
			var  Util::AllOf.new(::String, Util::Not.new(Util::BuiltinName))
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
			if other.is_a?(Bool)
				reduce(other, with(value: self == other))
			else
				reduce(other, super)
			end
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

		def to_s
			"#{name}@#{index}"
		end

		def as_json
			if name == "_"
				index
			elsif index.zero?
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
		include Enumerable

		include(ValueSemantics.for_attributes do
			elements     Util::ArrayOf.new(Expression, min: 1)
			element_type Either(nil, Expression), default: nil
		end)

		def self.of(*args, type: nil)
			if args.empty?
				EmptyList.new(element_type: type)
			else
				List.new(elements: args, element_type: type)
			end
		end

		def type
			Dhall::Application.new(
				function: Dhall::Variable["List"],
				argument: element_type
			)
		end

		def as_json
			[4, nil, *elements.map(&:as_json)]
		end

		def map(type: nil, &block)
			with(elements: elements.each_with_index.map(&block), element_type: type)
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
			Optional.for(elements.first, type: element_type)
		end

		def last
			Optional.for(elements.last, type: element_type)
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
			element_type Either(nil, Expression)
		end)

		def as_json
			[4, element_type.as_json]
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

		def first
			OptionalNone.new(value_type: element_type)
		end

		def last
			OptionalNone.new(value_type: element_type)
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

		def type
			return unless value_type

			Dhall::Application.new(
				function: Dhall::Variable["Optional"],
				argument: value_type
			)
		end

		def map(type: nil, &block)
			with(value: block[value], value_type: value_type)
		end

		def reduce(_, &block)
			block[value]
		end

		def as_json
			[5, value_type&.as_json, value.as_json]
		end
	end

	class OptionalNone < Optional
		include(ValueSemantics.for_attributes do
			value_type Expression
		end)

		def map(type: nil)
			type.nil? ? self : with(value_type: value_type)
		end

		def reduce(z)
			z
		end

		def as_json
			[0, Variable["None"].as_json, value_type.as_json]
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
		include(ValueSemantics.for_attributes do
			record Util::HashOf.new(::String, Expression, min: 1)
		end)

		def keys
			record.keys
		end

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

		def map(&block)
			with(record: Hash[record.map(&block)])
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
				type = record.alternatives.fetch(selector)
				body = Union.from(record, selector, Variable[selector])
				Function.new(var: selector, type: type, body: body).call(value)
			else
				super
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

		def as_json
			[10, record.as_json, *selectors]
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
			alternatives Util::HashOf.new(::String, Either(Expression, nil))
		end)

		def record
			alternatives
		end

		def ==(other)
			other.is_a?(UnionType) && alternatives.to_a == other.alternatives.to_a
		end

		def eql?(other)
			self == other
		end

		def merge(other)
			with(alternatives: alternatives.merge(other.alternatives))
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

		def constructor_types
			alternatives.each_with_object({}) do |(k, type), ctypes|
				ctypes[k] = Forall.new(var: k, type: type, body: self)
			end
		end

		def as_json
			[11, Hash[alternatives.to_a.map { |k, v| [k, v&.as_json] }.sort]]
		end
	end

	class Union < Expression
		include(ValueSemantics.for_attributes do
			tag          ::String
			value        Either(Expression, nil)
			alternatives UnionType
		end)

		def self.from(alts, tag, value)
			new(
				tag:          tag,
				value:        value && TypeAnnotation.new(
					value: value,
					type:  alts.alternatives[tag]
				),
				alternatives: alts.with(
					alternatives: alts.alternatives.reject { |alt, _| alt == tag }
				)
			)
		end

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

	class Natural < Expression
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

	class Integer < Expression
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

	class Double < Expression
		include(ValueSemantics.for_attributes do
			value ::Float
		end)

		def to_s
			value.to_s
		end

		def to_f
			value
		end

		def coerce(other)
			return [other, self] if other.is_a?(Double)
			[Double.new(value: other.to_f), self]
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

		def as_json
			[18, *chunks.map { |chunk| chunk.is_a?(Text) ? chunk.value : chunk.as_json }]
		end
	end

	class Import < Expression
		class IntegrityCheck
			include(ValueSemantics.for_attributes do
				protocol Either("sha256", :nocheck)
				data     Either(::String, nil)
			end)

			class FailureException < StandardError; end

			def initialize(protocol=:nocheck, data=nil)
				super(
					protocol: protocol,
					data:     data
				)
			end

			def to_s
				"#{@protocol}:#{@data}"
			end

			def check(expr)
				if @protocol != :nocheck && expr.cache_key != to_s
					raise FailureException, "#{expr} does not match #{self}"
				end

				expr
			end

			def as_json
				@protocol == :nocheck ? nil : [@protocol, @data]
			end
		end

		class URI
			include(ValueSemantics.for_attributes do
				headers   Either(nil, Expression)
				authority ::String
				path      ArrayOf(::String)
				query     Either(nil, ::String)
			end)

			HeaderType = RecordType.new(
				record: {
					"header" => Variable["Text"],
					"value"  => Variable["Text"]
				}
			)

			def initialize(headers, authority, *path, query)
				super(
					headers:   headers,
					authority: authority,
					path:      path,
					query:     query,
				)
			end

			def with(hash)
				self.class.new(
					hash.fetch(:headers),
					authority,
					*path,
					query
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
				super || EmptyList.new(element_type: HeaderType)
			end

			def uri
				URI("#{scheme}://#{authority}/#{path.join("/")}?#{query}")
			end

			def as_json
				[@headers&.as_json, authority, *path, query]
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
				scheme.new(nil, authority, *path, nil)
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
			ESCAPES = {
				"\"" => "\"",
				"\\" => "\\",
				"a"  => "\a",
				"b"  => "\b",
				"f"  => "\f",
				"n"  => "\n",
				"r"  => "\r",
				"t"  => "\t",
				"v"  => "\v"
			}.freeze

			def self.decode(var)
				var.gsub(/\\[\"\\abfnrtv]/) do |escape|
					ESCAPES.fetch(escape[1])
				end
			end

			def initialize(var)
				@var = var
			end

			def value
				ENV.fetch(@var)
			end

			def resolve(resolver)
				Promise.resolve(nil).then do
					val = ENV.fetch(@var) do
						raise ImportFailedException, "No ENV #{@var}"
					end
					if val =~ /\Ahttps?:\/\//
						URI.from_uri(URI(value))
					else
						Path.from_string(val)
					end.resolve(resolver)
				end
			end

			def as_json
				@var.gsub(/[\"\\\a\b\f\n\r\t\v]/) do |c|
					"\\" + ESCAPES.find { |(_, v)| v == c }.first
				end
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

		class Expression
			def self.call(import_value)
				Dhall.load_raw(import_value)
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

		include(ValueSemantics.for_attributes do
			integrity_check IntegrityCheck, default: IntegrityCheck.new
			import_type     Class
			path            Either(*PATH_TYPES)
		end)

		def initialize(integrity_check, import_type, path)
			super(
				integrity_check: integrity_check || IntegrityCheck.new,
				import_type:     import_type,
				path:            path
			)
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
			var    Util::AllOf.new(::String, Util::Not.new(Util::BuiltinName))
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
			[25, *let.as_json, body.as_json]
		end
	end

	class LetBlock < Expression
		include(ValueSemantics.for_attributes do
			lets Util::ArrayOf.new(Let, min: 2)
			body Expression
		end)

		def self.for(lets:, body:)
			if lets.length == 1
				LetIn.new(let: lets.first, body: body)
			else
				new(lets: lets, body: body)
			end
		end

		def unflatten
			lets.reverse.reduce(body) do |inside, let|
				letin = LetIn.new(let: let, body: inside)
				block_given? ? (yield letin) : letin
			end
		end

		def desugar
			unflatten(&:desugar)
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
end
