# frozen_string_literal: true

require "cbor"
require "digest/sha2"

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

		def to_cbor(io=nil)
			CBOR.encode(as_cbor, io)
		end
		alias to_binary to_cbor

		def as_cbor
			as_json
		end

		def digest(digest: Digest::SHA2.new(256))
			(digest << normalize.to_binary).freeze
		end

		def cache_key
			"sha256:#{digest.hexdigest}"
		end
	end

	class Application
		def self.decode(f, *args)
			args.map(&Dhall.method(:decode)).reduce(Dhall.decode(f)) { |f, arg|
				new(function: f, argument: arg)
			}
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
			if els.empty?
				EmptyList.new(type: type.nil? ? nil : Dhall.decode(type))
			else
				List.new(elements: els.map(&Dhall.method(:decode)))
			end
		end
	end

	class Optional
		def self.decode(type, value=nil)
			if value.nil?
				OptionalNone.new(type: Dhall.decode(type))
			else
				Optional.new(
					value: Dhall.decode(value),
					type:  type.nil? ? type : Dhall.decode(type)
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
			if selectors.empty?
				EmptyRecordProjection.new(record: Dhall.decode(record))
			else
				new(record: Dhall.decode(record), selectors: selectors)
			end
		end
	end

	class UnionType
		def self.decode(record)
			new(alternatives: Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
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
		def self.decode(integrity_check, import_type, path_type, *parts)
			parts[0] = Dhall.decode(parts[0]) if path_type < 2 && !parts[0].nil?

			new(
				IntegrityCheck.new(*integrity_check),
				IMPORT_TYPES[import_type],
				PATH_TYPES[path_type].new(*parts)
			)
		end
	end

	class LetBlock
		def self.decode(*parts)
			new(
				body: Dhall.decode(parts.pop),
				lets: parts.each_slice(3).map do |(var, type, assign)|
					Let.new(
						var:    var,
						assign: Dhall.decode(assign),
						type:   type.nil? ? nil : Dhall.decode(type)
					)
				end
			)
		end
	end

	class TypeAnnotation
		def self.decode(value, type)
			new(value: Dhall.decode(value), type: Dhall.decode(type))
		end
	end

	BINARY = {
		::TrueClass  => ->(e) { Bool.new(value: e) },
		::FalseClass => ->(e) { Bool.new(value: e) },
		::Float      => ->(e) { Double.new(value: e) },
		::String     => ->(e) { Builtins::ALL[e]&.new || Variable.new(name: e) },
		::Integer    => ->(e) { Variable.new(index: e) },
		::Array      => lambda { |e|
			if e.length == 2 && e.first.is_a?(::String)
				Variable.new(name: e[0], index: e[1])
			else
				tag, *body = e
				BINARY_TAGS[tag]&.decode(*body) ||
					(raise "Unknown expression: #{e.inspect}")
			end
		}
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
