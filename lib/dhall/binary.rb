# frozen_string_literal: true

require "cbor"

module Dhall
	def self.from_binary(cbor_binary)
		data = CBOR.decode(cbor_binary)
		if data.is_a?(Array) && data[0] == "5.0.0"
			decode(data[1])
		else
			decode(data)
		end
	end

	def self.decode(expression)
		return expression if expression.is_a?(Expression)

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
	end

	class Application
		def self.decode(f, *args)
			new(Dhall.decode(f), *args.map(&Dhall.method(:decode)))
		end
	end

	class Function
		def self.decode(var_or_type, type_or_body, body_or_nil=nil)
			if body_or_nil.nil?
				new("_", Dhall.decode(var_or_type), Dhall.decode(type_or_body))
			else
				unless var_or_type.is_a?(String)
					raise TypeError, "Function var must be a String"
				end

				raise ArgumentError, "explicit var named _" if var_or_type == "_"

				new(var_or_type, Dhall.decode(type_or_body), Dhall.decode(body_or_nil))
			end
		end
	end

	class Operator
		OPERATORS = [
			Or, And, Equal, NotEqual,
			Plus, Times,
			TextConcatenate, ListConcatenate,
			RecordMerge, RecordOverride, RecordTypeMerge,
			ImportFallback
		].freeze

		def self.decode(opcode, lhs, rhs)
			OPERATORS[opcode].new(
				lhs: Dhall.decode(lhs),
				rhs: Dhall.decode(rhs)
			)
		end
	end

	class List
		def self.decode(type, *els)
			if type.nil?
				List.new(elements: els.map(&Dhall.method(:decode)))
			else
				EmptyList.new(type: Dhall.decode(type))
			end
		end
	end

	class Optional
		def self.decode(type, value=nil)
			if value.nil?
				OptionalNone.new(Dhall.decode(type))
			else
				Optional.new(
					Dhall.decode(value),
					type.nil? ? type : Dhall.decode(type)
				)
			end
		end
	end

	class Merge
		def self.decode(record, input, type=nil)
			new(
				Dhall.decode(record),
				Dhall.decode(input),
				type.nil? ? nil : Dhall.decode(type)
			)
		end
	end

	class RecordType
		def self.decode(record)
			new(Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
		end
	end

	class Record
		def self.decode(record)
			new(Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
		end
	end

	class RecordFieldAccess
		def self.decode(record, field)
			new(Dhall.decode(record), field)
		end
	end

	class RecordProjection
		def self.decode(record, *fields)
			new(Dhall.decode(record), *fields)
		end
	end

	class UnionType
		def self.decode(record)
			new(Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
		end
	end

	class Union
		def self.decode(tag, value, rest_of_type)
			new(
				tag,
				Dhall.decode(value),
				Hash[rest_of_type.map { |k, v| [k, Dhall.decode(v)] }]
			)
		end
	end

	class If
		def self.decode(pred, thn, els)
			new(
				predicate: Dhall.decode(pred),
				then: Dhall.decode(thn),
				else: Dhall.decode(els)
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
		IMPORT_TYPES = [Expression, Text].freeze
		PATH_TYPES = [
			Http, Https,
			AbsolutePath, RelativePath, RelativeToParentPath, RelativeToHomePath,
			EnvironmentVariable, MissingImport
		].freeze

		def self.decode(integrity_check, import_type, path_type, *parts)
			parts[0] = Dhall.decode(parts[0]) if path_type
			new(
				integrity_check.nil? ? nil : IntegrityCheck.new(*integrity_check),
				IMPORT_TYPES[import_type],
				PATH_TYPES[path_type].new(*parts)
			)
		end
	end

	class LetBlock
		def self.decode(*parts)
			new(
				Dhall.decode(parts.pop),
				*parts.each_slice(3).map do |(var, type, assign)|
					Let.new(
						var,
						Dhall.decode(assign),
						type.nil? ? nil : Dhall.decode(type)
					)
				end
			)
		end
	end

	class TypeAnnotation
		def self.decode(value, type)
			new(Dhall.decode(value), Dhall.decode(type))
		end
	end

	BINARY = {
		::TrueClass  => ->(e) { Bool.new(value: e) },
		::FalseClass => ->(e) { Bool.new(value: e) },
		::Float      => ->(e) { Double.new(value: e) },
		::String     => ->(e) { Variable.new(name: e) },
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
		RecordFieldAccess,
		RecordProjection,
		UnionType,
		Union,
		Constructors,
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
