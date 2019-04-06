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

		def self.operator_expression(capture, ast_class)
			Module.new do
				define_method(:value) do
					captures(capture).map(&:value).reduce do |lhs, rhs|
						Operator.const_get(ast_class).new(lhs: lhs, rhs: rhs)
					end
				end
			end
		end

		ImportAltExpression = operator_expression(:or_expression, :ImportFallback)
		OrExpression = operator_expression(:plus_expression, :Or)
		PlusExpression = operator_expression(:text_append_expression, :Plus)
		TextAppendExpression = operator_expression(:list_append_expression, :TextConcatenate)
		ListAppendExpression = operator_expression(:and_expression, :ListConcatenate)
		AndExpression = operator_expression(:combine_expression, :And)
		CombineExpression = operator_expression(:prefer_expression, :RecursiveRecordMerge)
		PreferExpression = operator_expression(:combine_types_expression, :RightBiasedRecordMerge)
		CombineTypesExpression = operator_expression(:times_expression, :RecursiveRecordTypeMerge)
		TimesExpression = operator_expression(:equal_expression, :Times)
		EqualExpression = operator_expression(:not_equal_expression, :Equal)
		NotEqualExpression = operator_expression(:application_expression, :NotEqual)

		module ApplicationExpression
			def value
				some = capture(:some) ? [Variable["Some"]] : []
				els = some + captures(:import_expression).map(&:value)
				els.reduce do |f, arg|
					Application.for(function: f, argument: arg)
				end
			end
		end

		module SelectorExpression
			def value
				record = first.value
				selectors = matches[1].matches
				selectors.reduce(record) do |rec, sel|
					if sel.captures.key?(:labels)
						sels = sel.capture(:labels).captures(:any_label).map(&:value)
						return EmptyRecordProjection.new(record: rec) if sels.empty?
						RecordProjection.new(record: rec, selectors: sels)
					else
						RecordSelection.new(
							record:   rec,
							selector: sel.capture(:any_label).value
						)
					end
				end
			end
		end

		module Label
			def value
				if first.string == "`"
					matches[1].string
				else
					string
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

		module DoubleLiteral
			def value
				key = captures.keys.select { |k| k.is_a?(Symbol) }.first
				Double.new(value: case key
					when :infinity
						string == "-Infinity" ? -Float::INFINITY : Float::INFINITY
					when :nan
						Float::NAN
					else
						float = string.to_f
						raise Citrus::ParseError, input if float.nan? || float.infinite?
						float
					end)
			end
		end

		module DoubleQuoteLiteral
			def value
				TextLiteral.for(
					*captures(:double_quote_chunk)
					.map(&:value)
					.chunk { |s| s.is_a?(String) }
					.flat_map do |(is_string, group)|
						is_string ? group.join : group
					end
				)
			end
		end

		module DoubleQuoteChunk
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
				if first&.string == "\\" && matches[1].string =~ /\Au\h+\Z/i
					[matches[1].string[1..-1]].pack("H*").force_encoding("UTF-16BE")
				elsif first&.string == "\\"
					ESCAPES.fetch(matches[1].string) {
						raise "Invalid escape: #{string}"
					}.encode("UTF-16BE")
				elsif first&.string == "${"
					matches[1].value
				else
					string.encode("UTF-16BE")
				end
			end
		end

		module SingleQuoteLiteral
			def value
				chunks = capture(:single_quote_continue).value.flatten
				indent = chunks.join.split(/\n/, -1).map { |line|
					line.match(/^( *|\t*)/).to_s.length
				}.min

				TextLiteral.for(
					*chunks
					.chunk { |c| c != "\n" }
					.flat_map { |(line, chunk)| line ? chunk[indent..-1] : chunk }
				)
			end
		end

		module SingleQuoteContinue
			ESCAPES = {
				"'''"  => "''",
				"''${" => "${"
			}.freeze

			def value
				if matches.length == 2
					[ESCAPES.fetch(first.string, first.string), matches[1].value]
				elsif matches.empty?
					[]
				else
					[
						capture(:complete_expression).value,
						capture(:single_quote_continue).value
					]
				end
			end
		end

		module NonEmptyListLiteral
			def value
				List.new(elements: captures(:expression).map(&:value))
			end
		end

		module Identifier
			def value
				name = capture(:any_label).value

				return Dhall::Bool.new(value: true) if name == "True"
				return Dhall::Bool.new(value: false) if name == "False"

				Dhall::Builtins::ALL[name]&.new ||
					Variable.new(
						name:  name,
						index: capture(:natural_literal)&.string.to_i
					)
			end
		end

		module PrimitiveExpression
			def value
				if first&.string == "("
					capture(:expression).value
				elsif first&.string == "{"
					capture(:record_type_or_literal).value
				elsif first&.string == "<"
					capture(:union_type_or_literal).value
				else
					super
				end
			end
		end

		module UnionTypeOrLiteral
			def value
				if captures[0].string == ""
					UnionType.new(alternatives: {})
				else
					super
				end
			end
		end

		module NonEmptyUnionTypeOrLiteral
			def value
				cont = matches[1].first

				if cont && cont.matches[1].first.string == "="
					Union.new(
						tag:          captures(:any_label).first.value,
						value:        captures(:expression).first.value,
						alternatives: UnionType.new(alternatives: ::Hash[
							captures(:any_label)[1..-1].map(&:value).zip(
								captures(:expression)[1..-1].map(&:value)
							)
						])
					)
				else
					type = UnionType.new(alternatives: ::Hash[
						captures(:any_label).map(&:value).zip(
							captures(:expression).map(&:value)
						)
					])
					rest = cont && cont.matches[1].capture(:non_empty_union_type_or_literal)&.value
					if rest.is_a?(Union)
						rest.with(alternatives: type.merge(rest.alternatives))
					elsif rest
						type.merge(rest)
					else
						type
					end
				end
			end
		end

		module RecordTypeOrLiteral
			def value
				if captures[0].string == "="
					EmptyRecord.new
				elsif captures[0].string == ""
					EmptyRecordType.new
				else
					super
				end
			end
		end

		module NonEmptyRecordTypeOrLiteral
			def value
				if captures.key?(:non_empty_record_literal)
					capture(:non_empty_record_literal).value(
						capture(:any_label).value
					)
				else
					capture(:non_empty_record_type).value(
						capture(:any_label).value
					)
				end
			end
		end

		module NonEmptyRecordLiteral
			def value(first_key)
				keys = [first_key] + captures(:any_label).map(&:value)
				values = captures(:expression).map(&:value)
				Record.new(record: ::Hash[keys.zip(values)])
			end
		end

		module NonEmptyRecordType
			def value(first_key)
				keys = [first_key] + captures(:any_label).map(&:value)
				values = captures(:expression).map(&:value)
				RecordType.new(record: ::Hash[keys.zip(values)])
			end
		end

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
				if captures.key?(:empty_collection)
					capture(:empty_collection).value
				elsif captures.key?(:non_empty_optional)
					capture(:non_empty_optional).value
				elsif matches.length == 2
					TypeAnnotation.new(
						value: first.value,
						type:  matches[1].capture(:expression).value
					)
				else
					super
				end
			end
		end

		module Expression
			def value
				keys = captures.keys.select { |k| k.is_a?(Symbol) }
				if keys.length == 1
					capture(keys.first).value
				elsif captures.key?(:let)
					lets = first.matches.map do |let_match|
						exprs = let_match.captures(:expression)
						Let.new(
							var:    let_match.capture(:nonreserved_label).value,
							assign: exprs.last.value,
							type:   exprs.length > 1 ? exprs.first.value : nil
						)
					end

					if lets.length == 1
						LetIn.new(let: lets.first, body: matches.last.value)
					else
						LetBlock.new(lets: lets, body: matches.last.value)
					end
				elsif captures.key?(:lambda)
					Function.new(
						var:  capture(:nonreserved_label).value,
						type: captures(:expression)[0].value,
						body: captures(:expression)[1].value
					)
				elsif captures.key?(:forall)
					Forall.new(
						var:  capture(:nonreserved_label).value,
						type: captures(:expression)[0].value,
						body: captures(:expression)[1].value
					)
				elsif captures.key?(:arrow)
					Forall.of_arguments(
						capture(:operator_expression).value,
						body: capture(:expression).value
					)
				elsif captures.key?(:if)
					If.new(
						predicate: captures(:expression)[0].value,
						then:      captures(:expression)[1].value,
						else:      captures(:expression)[2].value
					)
				elsif captures.key?(:merge)
					Merge.new(
						record: captures(:import_expression)[0].value,
						input:  captures(:import_expression)[1].value,
						type:   capture(:application_expression)&.value
					)
				else
					super
				end
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

			def self.escape(s)
				URI.encode_www_form_component(s).gsub("+", "%20")
			end

			def value
				http = capture(:http_raw)
				SCHEME.fetch(http.capture(:scheme).value).new(
					if captures.key?(:import_hashed)
						capture(:import_hashed).value(Dhall::Import::Expression)
					end,
					http.capture(:authority).value,
					*http.capture(:path).captures(:path_component).map(&:value),
					http.capture(:query)&.value
				)
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

		module Local
			KLASS = {
				"/"  => Dhall::Import::AbsolutePath,
				"."  => Dhall::Import::RelativePath,
				".." => Dhall::Import::RelativeToParentPath,
				"~"  => Dhall::Import::RelativeToHomePath
			}.freeze

			def value
				path = capture(:path).captures(:path_component).map(&:value)
				klass = KLASS.find { |prefix, _| string.start_with?(prefix) }.last
				klass.new(*path)
			end
		end

		module PathComponent
			def value(escaper=:itself.to_proc)
				if captures.key?(:quoted_path_character)
					escaper.call(matches[1].matches[1].value)
				else
					matches[1].value
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
