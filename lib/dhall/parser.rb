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
				return list if string =~ /\A\[\s*\]/

				key =
					[:let_binding, :lambda, :forall, :arrow, :if, :merge, :tomap]
					.find { |k| captures.key?(k) }

				key ? public_send(key) : super
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

			def list
				EmptyList.new(type: capture(:application_expression).value)
			end

			def tomap
				ToMap.new(
					record: capture(:import_expression).value,
					type:   capture(:application_expression).value
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
					Optional.new(value: capture(:import_expression).value)
				elsif captures.key?(:tomap)
					ToMap.new(record: capture(:import_expression).value)
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
				captures(:selector).map(&:value).reduce(record) do |rec, sels|
					if sels.is_a?(Array)
						RecordProjection.for(rec, sels)
					elsif sels.is_a?(Dhall::Expression)
						RecordProjectionByExpression.new(record: rec, selector: sels)
					else
						RecordSelection.new(record: rec, selector: sels)
					end
				end
			end
		end

		module Selector
			def value
				if captures.key?(:type_selector)
					capture(:expression).value
				elsif captures.key?(:labels)
					captures(:any_label).map(&:value)
				else
					string
				end
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
						strs ? group.join : group
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
					[string.sub(/\Au\{?([A-F0-9]+)\}?/, "\\1").to_i(16)].pack("U*")
				end
			end
		end

		module SingleQuoteLiteral
			def value
				chunks = capture(:single_quote_continue).value
				indent = Util.indent_size(chunks.join)

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

		module EndOfLine
			def value
				"\n"
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
				elsif captures.key?(:location)
					Dhall::Import::AsLocation
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
				Dhall::Import::IntegrityCheck.new(
					code:   Multihashes::TABLE.key(
						protocol.sub(/\Asha(\d{3})/, "sha2-\\1")
					),
					digest: [data].pack("H*")
				)
			end
		end

		module Scheme
			def value
				::URI.scheme_list[string.upcase]
			end
		end

		module Authority
			def value
				{
					userinfo: capture(:userinfo)&.value,
					host:     capture(:host).value,
					port:     capture(:port)&.value
				}
			end
		end

		module Http
			SCHEME = {
				"http"  => Dhall::Import::Http,
				"https" => Dhall::Import::Https
			}.freeze

			def http(key)
				@http ||= capture(:http_raw)
				@http.capture(key)&.value
			end

			def value
				uri = http(:scheme).build(
					http(:authority).merge(
						path: http(:url_path) || "/"
					)
				)

				uri.instance_variable_set(:@query, http(:query))

				SCHEME.fetch(uri.scheme).new(
					headers: capture(:import_expression)&.value,
					uri:     uri
				)
			end
		end

		module Env
			def value
				Dhall::Import::EnvironmentVariable.new(
					if captures.key?(:bash_environment_variable)
						capture(:bash_environment_variable).value
					else
						capture(:posix_environment_variable).value
					end
				)
			end
		end

		module PosixEnvironmentVariable
			def value
				matches.map(&:value).join.encode(Encoding::UTF_8)
			end
		end

		module PosixEnvironmentVariableCharacter
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
			def value(escaper=:itself.to_proc)
				if captures.key?(:quoted_path_component)
					escaper.call(capture(:quoted_path_component).value)
				else
					capture(:unquoted_path_component).value
				end
			end
		end

		module UrlPath
			def value
				"/" + matches.map { |pc|
					if pc.captures.key?(:path_component)
						# We escape here because ruby stdlib URI just stores path unparsed
						pc.value(Util.method(:uri_escape))
					else
						pc.string[1..-1]
					end
				}.join("/")
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
