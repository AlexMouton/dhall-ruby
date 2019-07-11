# frozen_string_literal: true

require "cbor"
require "digest/sha2"
require "multihashes"

require "dhall/ast"
require "dhall/builtins"

module Dhall
	def self.from_binary(cbor_binary)
		decode(CBOR.decode(cbor_binary))
	end

	def self.decode(expression)
		BINARY.each do |match, use|
			return use[expression] if expression.is_a?(match)
		end

		raise "Unknown expression: #{expression.inspect}"
	end

	class Expression
		def self.decode(*args)
			return new(value: args.first) if args.length == 1

			new(*args)
		end

		def to_cbor(packer=nil)
			if packer
				packer.write(as_json)
				packer
			else
				CBOR.encode(as_json)
			end
		end

		def to_binary
			CBOR.encode(::CBOR::Tagged.new(55799, self))
		end

		def digest(digest: Digest::SHA2.new(256))
			(digest << normalize.to_cbor).freeze
		end

		def cache_key
			"sha256:#{digest.hexdigest}"
		end
	end

	class Application
		def self.decode(function, *args)
			function = Dhall.decode(function)
			args.map(&Dhall.method(:decode)).reduce(function) do |f, arg|
				self.for(function: f, argument: arg)
			end
		end
	end

	class Function
		def self.decode(var_or_type, type_or_body, body_or_nil=nil)
			type_or_body = Dhall.decode(type_or_body)

			if body_or_nil.nil?
				of_arguments(Dhall.decode(var_or_type), body: type_or_body)
			else
				raise ArgumentError, "explicit var named _" if var_or_type == "_"

				body_or_nil = Dhall.decode(body_or_nil)
				new(var: var_or_type, type: type_or_body, body: body_or_nil)
			end
		end
	end

	class Operator
		def self.decode(opcode, lhs, rhs)
			OPERATORS[opcode].new(
				lhs: Dhall.decode(lhs),
				rhs: Dhall.decode(rhs)
			)
		end
	end

	class List
		def self.decode(type, *els)
			type = type.nil? ? nil : Dhall.decode(type)
			if els.empty?
				EmptyList.new(element_type: type)
			else
				List.new(elements: els.map(&Dhall.method(:decode)), element_type: type)
			end
		end
	end

	class Optional
		def self.decode(type, value=nil)
			if value.nil?
				OptionalNone.new(value_type: Dhall.decode(type))
			else
				Optional.new(
					value:      Dhall.decode(value),
					value_type: type.nil? ? type : Dhall.decode(type)
				)
			end
		end
	end

	class Merge
		def self.decode(record, input, type=nil)
			new(
				record: Dhall.decode(record),
				input:  Dhall.decode(input),
				type:   type.nil? ? nil : Dhall.decode(type)
			)
		end
	end

	class RecordType
		def self.decode(record)
			if record.empty?
				EmptyRecordType.new
			else
				new(record: Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
			end
		end
	end

	class Record
		def self.decode(record)
			if record.empty?
				EmptyRecord.new
			else
				new(record: Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
			end
		end
	end

	class RecordSelection
		def self.decode(record, selector)
			new(record: Dhall.decode(record), selector: selector)
		end
	end

	class RecordProjection
		def self.decode(record, *selectors)
			record = Dhall.decode(record)
			if selectors.length == 1 && selectors[0].is_a?(Array)
				RecordProjectionByExpression.new(
					record:   record,
					selector: Dhall.decode(selectors[0][0])
				)
			else
				self.for(record, selectors)
			end
		end
	end

	class UnionType
		def self.decode(record)
			new(alternatives: Hash[record.map do |k, v|
				[k, v.nil? ? v : Dhall.decode(v)]
			end])
		end
	end

	class Union
		def self.decode(tag, value, alternatives)
			new(
				tag:          tag,
				value:        Dhall.decode(value),
				alternatives: UnionType.decode(alternatives)
			)
		end
	end

	class If
		def self.decode(pred, thn, els)
			new(
				predicate: Dhall.decode(pred),
				then:      Dhall.decode(thn),
				else:      Dhall.decode(els)
			)
		end
	end

	class TextLiteral
		def self.decode(*chunks)
			lead_text, *pairs = chunks
			chunks =
				[Text.new(value: lead_text)] +
				pairs.each_slice(2).flat_map do |(e, t)|
					[Dhall.decode(e), Text.new(value: t)]
				end

			chunks.length == 1 ? chunks.first : TextLiteral.new(chunks: chunks)
		end
	end

	class Import
		class IntegrityCheck
			def self.decode(integrity_check)
				return unless integrity_check

				IntegrityCheck.new(
					Multihashes.decode(integrity_check).select { |k, _|
						[:code, :digest].include?(k)
					}
				)
			end
		end

		def self.decode(integrity_check, import_type, path_type, *parts)
			parts[0] = Dhall.decode(parts[0]) if path_type < 2 && !parts[0].nil?

			new(
				IntegrityCheck.decode(integrity_check),
				IMPORT_TYPES[import_type],
				PATH_TYPES[path_type].new(*parts)
			)
		end
	end

	class LetBlock
		def self.decode(*parts)
			body = Dhall.decode(parts.pop)
			lets = parts.each_slice(3).map do |(var, type, assign)|
				Let.new(
					var:    var,
					assign: Dhall.decode(assign),
					type:   type.nil? ? nil : Dhall.decode(type)
				)
			end

			self.for(lets: lets, body: body)
		end
	end

	class TypeAnnotation
		def self.decode(value, type)
			new(value: Dhall.decode(value), type: Dhall.decode(type))
		end
	end

	def self.handle_tag(e)
		return e unless e.is_a?(::CBOR::Tagged)
		return e.value if e.tag == 55799

		raise "Unknown tag: #{e.inspect}"
	end

	BINARY = {
		::TrueClass    => ->(e) { Bool.new(value: e) },
		::FalseClass   => ->(e) { Bool.new(value: e) },
		::Float        => ->(e) { Double.new(value: e) },
		::String       => ->(e) { Builtins[e.to_sym] || (raise "Unknown builtin") },
		::Integer      => ->(e) { Variable.new(index: e) },
		::Array        => lambda { |e|
			e = e.map(&method(:handle_tag))
			if e.length == 2 && e.first.is_a?(::String)
				Variable.new(name: e[0], index: e[1])
			else
				tag, *body = e
				BINARY_TAGS[tag]&.decode(*body) ||
					(raise "Unknown expression: #{e.inspect}")
			end
		},
		::CBOR::Tagged => ->(e) { Dhall.decode(handle_tag(e)) }
	}.freeze

	BINARY_TAGS = [
		Application,
		Function,
		Forall,
		Operator,
		List,
		Optional,
		Merge,
		RecordType,
		Record,
		RecordSelection,
		RecordProjection,
		UnionType,
		Union,
		nil,
		If,
		Natural,
		Integer,
		nil,
		TextLiteral,
		nil,
		nil,
		nil,
		nil,
		nil,
		Import,
		LetBlock,
		TypeAnnotation
	].freeze
end
