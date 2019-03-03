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
		BINARY.each do |match, use|
			return use[expression] if expression.is_a?(match)
		end

		raise "Unknown expression: #{expression.inspect}"
	end

	BINARY = {
		::TrueClass => Bool.method(:decode),
		::FalseClass => Bool.method(:decode),
		::Float => Double.method(:decode),
		::String => ->(e) { Variable.decode(e, 0) },
		::Integer => ->(e) { Variable.decode("_", e) },
		::Array => lambda { |e|
			if e.length == 2 && e.first.is_a?(::String)
				Variable.decode(*expression)
			else
				tag, *body = expression
				BINARY_TAGS[tag]&.decode(*body) ||
					(raise "Unknown expression: #{expression.inspect}")
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

	class Expression
		def self.decode(*args)
			new(*args)
		end
	end

	class Application < Expression
		def self.decode(f, *args)
			new(Dhall.decode(f), *args.map(&Dhall.method(:decode)))
		end
	end

	class Function < Expression
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

	class Operator < Expression
		OPCODES = [
			:'||', :'&&', :==, :!=, :+, :*, :'++', :'#', :∧, :⫽, :⩓, :'?'
		].freeze

		def self.decode(opcode, lhs, rhs)
			new(
				OPCODES[opcode] || (raise "Unknown opcode: #{opcode}"),
				Dhall.decode(lhs),
				Dhall.decode(rhs)
			)
		end
	end

	class List < Expression
		def self.decode(type, *els)
			if type.nil?
				List.new(*els.map(&Dhall.method(:decode)))
			else
				EmptyList.new(Dhall.decode(type))
			end
		end
	end

	class Optional < Expression
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

	class Merge < Expression
		def self.decode(record, input, type=nil)
			new(
				Dhall.decode(record),
				Dhall.decode(input),
				type.nil? ? nil : Dhall.decode(type)
			)
		end
	end

	class RecordType < Expression
		def self.decode(record)
			new(Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
		end
	end

	class Record < Expression
		def self.decode(record)
			new(Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
		end
	end

	class RecordFieldAccess < Expression
		def self.decode(record, field)
			new(Dhall.decode(record), field)
		end
	end

	class RecordProjection < Expression
		def self.decode(record, *fields)
			new(Dhall.decode(record), *fields)
		end
	end

	class UnionType < Expression
		def self.decode(record)
			new(Hash[record.map { |k, v| [k, Dhall.decode(v)] }])
		end
	end

	class Union < Expression
		def self.decode(tag, value, rest_of_type)
			new(
				tag,
				Dhall.decode(value),
				Hash[rest_of_type.map { |k, v| [k, Dhall.decode(v)] }]
			)
		end
	end

	class If < Expression
		def self.decode(cond, thn, els)
			new(Dhall.decode(cond), Dhall.decode(thn), Dhall.decode(els))
		end
	end

	class TextLiteral < Text
		def self.decode(*chunks)
			if chunks.length == 1 && chunks.is_a?(String)
				Text.new(chunks.first)
			else
				TextLiteral.new(*chunks.map do |chunk|
					chunk.is_a?(String) ? Text.new(chunk) : Dhall.decode(chunk)
				end)
			end
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
			parts[0] = Dhall.decode(parts[0]) if path_type < 2 && !parts[0].nil?
			new(
				integrity_check.nil? ? nil : IntegrityCheck.new(*integrity_check),
				IMPORT_TYPES[import_type],
				PATH_TYPES[path_type].new(*parts)
			)
		end
	end

	class LetBlock < Expression
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

	class TypeAnnotation < Expression
		def self.decode(value, type)
			new(Dhall.decode(value), Dhall.decode(type))
		end
	end
end
