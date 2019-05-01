# frozen_string_literal: true

require "dhall/ast"
require "dhall/builtins"

module Dhall
	module Parser
		def self.parse(*args)
			CitrusParser.parse(*args)
		end

		def self.parse_file(*args)
			CitrusParser.parse_file(*args)
		end

		module CompleteExpression
			def value
				capture(:expression).value
			end
		end

		module Expression
			def value
				key =
					[:let_binding, :lambda, :forall, :arrow, :if, :merge]
					.find { |k| captures.key?(k) }

				return public_send(key) if key

				key =
					[:empty_collection, :non_empty_optional]
					.find { |k| captures.key?(k) }
				key ? capture(key).value : super
			end

			def let_binding
				LetBlock.for(
					lets: captures(:let_binding).map(&:value),
					body: capture(:expression).value
				)
			end

			def lambda
				Function.new(
					var:  capture(:nonreserved_label).value,
					type: captures(:expression)[0].value,
					body: captures(:expression)[1].value
				)
			end

			def forall
				Forall.new(
					var:  capture(:nonreserved_label).value,
					type: captures(:expression)[0].value,
					body: captures(:expression)[1].value
				)
			end

			def arrow
				Forall.of_arguments(
					capture(:operator_expression).value,
					body: capture(:expression).value
				)
			end

			def if
				If.new(
					predicate: captures(:expression)[0].value,
					then:      captures(:expression)[1].value,
					else:      captures(:expression)[2].value
				)
			end

			def merge
				Merge.new(
					record: captures(:import_expression)[0].value,
					input:  captures(:import_expression)[1].value,
					type:   capture(:application_expression)&.value
				)
			end
		end

		OPERATORS = {
			import_alt_expression:    :ImportFallback,
			or_expression:            :Or,
			plus_expression:          :Plus,
			text_append_expression:   :TextConcatenate,
			list_append_expression:   :ListConcatenate,
			and_expression:           :And,
			combine_expression:       :RecursiveRecordMerge,
			prefer_expression:        :RightBiasedRecordMerge,
			combine_types_expression: :RecursiveRecordTypeMerge,
			times_expression:         :Times,
			equal_expression:         :Equal,
			not_equal_expression:     :NotEqual
		}.freeze

		OPERATORS.to_a.zip(
			OPERATORS.to_a[1..-1] + [[:application_expression]]
		).each do |((rule, ast_class), (next_rule, _))|
			const_set(rule.to_s.split(/_/).map(&:capitalize).join, Module.new do
				define_method(:value) do
					captures(next_rule).map(&:value).reduce do |lhs, rhs|
						Operator.const_get(ast_class).new(lhs: lhs, rhs: rhs)
					end
				end
			end)
		end

		module ApplicationExpression
			def value
				first_expr = [capture(:first_application_expression).value]
				els = first_expr + captures(:import_expression).map(&:value)
				els.reduce do |f, arg|
					Application.for(function: f, argument: arg)
				end
			end
		end

		module FirstApplicationExpression
			def value
				if captures.key?(:merge)
					merge
				elsif captures.key?(:some)
					Optional.new(
						value: capture(:import_expression).value
					)
				else
					super
				end
			end

			def merge
				Merge.new(
					record: captures(:import_expression)[0].value,
					input:  captures(:import_expression)[1].value,
					type:   nil
				)
			end
		end

		module SelectorExpression
			def value
				record = capture(:primitive_expression).value
				selectors = captures(:selector).map(&:value)
				selectors.reduce(record) do |rec, sels|
					if sels.is_a?(Array)
						return EmptyRecordProjection.new(record: rec) if sels.empty?
						RecordProjection.new(record: rec, selectors: sels)
					else
						RecordSelection.new(record: rec, selector: sels)
					end
				end
			end
		end

		module Labels
			def value
				captures(:any_label).map(&:value)
			end
		end

		module Label
			module Quoted
				def quoted?
					true
				end
			end

			module Unquoted
				def quoted?
					false
				end
			end

			def value
				if first.string == "`"
					matches[1].string.extend(Quoted)
				else
					string.extend(Unquoted)
				end
			end
		end

		module NonreservedLabel
			def value
				if captures.key?(:label)
					capture(:label).value
				else
					string
				end
			end
		end

		module NaturalLiteral
			def value
				Natural.new(value: string.to_i)
			end
		end

		module IntegerLiteral
			def value
				Integer.new(value: string.to_i)
			end
		end

		module NumericDoubleLiteral
			def value
				float = string.to_f
				raise Citrus::ParseError, input if float.nan? || float.infinite?
				Double.new(value: float)
			end
		end

		module MinusInfinityLiteral
			def value
				Double.new(value: -Float::INFINITY)
			end
		end

		module PlusInfinityLiteral
			def value
				Double.new(value: Float::INFINITY)
			end
		end

		module Nan
			def value
				Double.new(value: Float::NAN)
			end
		end

		module DoubleQuoteLiteral
			def value
				TextLiteral.for(
					*captures(:double_quote_chunk)
					.map(&:value)
					.chunk { |s| s.is_a?(String) }
					.flat_map do |(strs, group)|
						strs ? group.map { |s| s.encode("UTF-16BE") }.join : group
					end
				)
			end
		end

		module DoubleQuoteChunk
			def value
				if captures.key?(:double_quote_escaped)
					capture(:double_quote_escaped).value
				else
					super
				end
			end
		end

		module DoubleQuoteEscaped
			ESCAPES = {
				"\"" => "\"",
				"$"  => "$",
				"\\" => "\\",
				"/"  => "/",
				"b"  => "\b",
				"f"  => "\f",
				"n"  => "\n",
				"r"  => "\r",
				"t"  => "\t"
			}.freeze

			def value
				ESCAPES.fetch(string) do
					[string[1..-1]].pack("H*").force_encoding("UTF-16BE")
				end
			end
		end

		module SingleQuoteLiteral
			def value
				chunks = capture(:single_quote_continue).value
				raw = chunks.join + "\n"
				indent = raw.scan(/^[ \t]*(?=[^ \t\r\n])/).map(&:length).min
				indent = 0 if raw.end_with?("\n\n")

				TextLiteral.for(
					*chunks
					.chunk { |c| c != "\n" }
					.flat_map { |(line, chunk)| line ? chunk[indent..-1] : chunk }
				)
			end
		end

		module SingleQuoteContinue
			def value
				([first].compact + captures(:single_quote_continue)).flat_map(&:value)
			end
		end

		module Interpolation
			def value
				capture(:complete_expression).value
			end
		end

		module EscapedQuotePair
			def value
				"''"
			end
		end

		module EscapedInterpolation
			def value
				"${"
			end
		end

		module NonEmptyListLiteral
			def value
				List.new(elements: captures(:expression).map(&:value))
			end
		end

		module Variable
			def value
				Dhall::Variable.new(
					name:  capture(:nonreserved_label).value,
					index: capture(:natural_literal)&.string.to_i
				)
			end
		end

		module Builtin
			def value
				return Dhall::Bool.new(value: true) if string == "True"
				return Dhall::Bool.new(value: false) if string == "False"

				Dhall::Builtins[string.to_sym]
			end
		end

		module PrimitiveExpression
			def value
				key = [
					:complete_expression,
					:record_type_or_literal,
					:union_type_or_literal
				].find { |k| captures.key?(k) }
				key ? capture(key).value : super
			end
		end

		module EmptyUnionType
			def value
				UnionType.new(alternatives: {})
			end
		end

		module UnionTypeOrLiteralVariantType
			def value(label)
				rest = capture(:non_empty_union_type_or_literal)&.value
				type = UnionType.new(
					alternatives: { label => capture(:expression)&.value }
				)
				if rest.is_a?(Union)
					rest.with(alternatives: type.merge(rest.alternatives))
				else
					rest ? type.merge(rest) : type
				end
			end
		end

		module UnionLiteralVariantValue
			def value(label)
				Union.new(
					tag:          label,
					value:        capture(:expression).value,
					alternatives: captures(:union_type_entry).map(&:value)
					              .reduce(UnionType.new(alternatives: {}), &:merge)
				)
			end
		end

		module UnionTypeEntry
			def value
				UnionType.new(
					alternatives: {
						capture(:any_label).value => capture(:expression)&.value
					}
				)
			end
		end

		module NonEmptyUnionTypeOrLiteral
			def value
				key = [
					:union_literal_variant_value,
					:union_type_or_literal_variant_type
				].find { |k| captures.key?(k) }

				if key
					capture(key).value(capture(:any_label).value)
				else
					no_alts = UnionType.new(alternatives: {})
					Union.from(no_alts, capture(:any_label).value, nil)
				end
			end
		end

		module EmptyRecordLiteral
			def value
				EmptyRecord.new
			end
		end

		module EmptyRecordType
			def value
				Dhall::EmptyRecordType.new
			end
		end

		module NonEmptyRecordTypeOrLiteral
			def value
				key = [
					:non_empty_record_literal,
					:non_empty_record_type
				].find { |k| captures.key?(k) }

				capture(key).value(capture(:any_label).value)
			end
		end

		module NonEmptyRecordLiteral
			def value(first_key)
				Record.new(
					record: captures(:record_literal_entry).map(&:value).reduce(
						first_key => capture(:expression).value
					) do |final, rec|
						final.merge(rec) { raise TypeError, "duplicate field" }
					end
				)
			end
		end

		module RecordLiteralEntry
			def value
				{ capture(:any_label).value => capture(:expression).value }
			end
		end

		module NonEmptyRecordType
			def value(first_key)
				RecordType.new(
					record: captures(:record_type_entry).map(&:value).reduce(
						{ first_key => capture(:expression).value },
						&:merge
					)
				)
			end
		end

		RecordTypeEntry = RecordLiteralEntry

		module EmptyCollection
			def value
				if captures.key?(:list)
					EmptyList.new(element_type: capture(:import_expression).value)
				else
					OptionalNone.new(value_type: capture(:import_expression).value)
				end
			end
		end

		module NonEmptyOptional
			def value
				Optional.new(
					value:      capture(:expression).value,
					value_type: capture(:import_expression).value
				)
			end
		end

		module AnnotatedExpression
			def value
				if matches[1].string.empty?
					first.value
				else
					TypeAnnotation.new(
						value: first.value,
						type:  capture(:expression).value
					)
				end
			end
		end

		module LetBinding
			def value
				exprs = captures(:expression)
				Let.new(
					var:    capture(:nonreserved_label).value,
					assign: exprs.last.value,
					type:   exprs.length > 1 ? exprs.first.value : nil
				)
			end
		end

		module Import
			def value
				import_type = if captures.key?(:text)
					Dhall::Import::Text
				else
					Dhall::Import::Expression
				end

				capture(:import_hashed).value(import_type)
			end
		end

		module ImportHashed
			def value(import_type)
				integrity_check = capture(:hash)&.value
				path = capture(:import_type).value
				Dhall::Import.new(integrity_check, import_type, path)
			end
		end

		module Hash
			def value
				protocol, data = string.split(/:/, 2)
				Dhall::Import::IntegrityCheck.new(protocol, data)
			end
		end

		module Http
			SCHEME = {
				"http"  => Dhall::Import::Http,
				"https" => Dhall::Import::Https
			}.freeze

			def value
				http = capture(:http_raw)
				SCHEME.fetch(http.capture(:scheme).value).new(
					capture(:import_hashed)&.value(Dhall::Import::Expression),
					http.capture(:authority).value,
					*unescaped_components,
					http.capture(:query)&.value
				)
			end

			def unescaped_components
				capture(:http_raw)
					.capture(:path)
					.captures(:path_component)
					.map do |pc|
						pc.value(URI.method(:unescape))
					end
			end
		end

		module Env
			def value
				Dhall::Import::EnvironmentVariable.new(
					if captures.key?(:bash_environment_variable)
						capture(:bash_environment_variable).string
					else
						capture(:posix_environment_variable).value.encode("utf-8")
					end
				)
			end
		end

		module PosixEnvironmentVariable
			def value
				matches.map(&:value).join
			end
		end

		module PosixEnvironmentVariableCharacter
			ESCAPES = Dhall::Import::EnvironmentVariable::ESCAPES

			def value
				if first&.string == "\\"
					ESCAPES.fetch(matches[1].string) {
						raise "Invalid escape: #{string}"
					}.encode("UTF-16BE")
				else
					string
				end
			end
		end

		module AbsolutePath
			def value
				Dhall::Import::AbsolutePath.new(*super)
			end
		end

		module HerePath
			def value
				Dhall::Import::RelativePath.new(*capture(:path).value)
			end
		end

		module ParentPath
			def value
				Dhall::Import::RelativeToParentPath.new(*capture(:path).value)
			end
		end

		module HomePath
			def value
				Dhall::Import::RelativeToHomePath.new(*capture(:path).value)
			end
		end

		module Path
			def value
				captures(:path_component).map(&:value)
			end
		end

		module PathComponent
			def value(unescaper=:itself.to_proc)
				if captures.key?(:quoted_path_component)
					capture(:quoted_path_component).value
				else
					unescaper.call(capture(:unquoted_path_component).value)
				end
			end
		end

		module Missing
			def value
				Dhall::Import::MissingImport.new
			end
		end
	end
end

require "citrus"
Citrus.require "dhall/parser"
