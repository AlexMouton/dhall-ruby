# frozen_string_literal: true

require "dhall/ast"
require "dhall/normalize"

module Dhall
	module TypeChecker
		def self.assert(type, assertion, message)
			unless assertion === type
				raise TypeError, message
			end
		end

		def self.for(expr)
			case expr
			when Dhall::Variable
				Variable.new(expr)
			when Dhall::Bool, Dhall::Natural, Dhall::Text, Dhall::Integer,
			     Dhall::Double
				Literal.new(expr)
			when Dhall::TextLiteral
				TextLiteral.new(expr)
			when Dhall::EmptyList
				EmptyList.new(expr)
			when Dhall::List
				List.new(expr)
			when Dhall::OptionalNone
				OptionalNone.new(expr)
			when Dhall::Optional
				Optional.new(expr)
			when Dhall::If
				If.new(expr)
			when Dhall::Application
				Application.new(expr)
			when Dhall::Operator::And, Dhall::Operator::Or,
			     Dhall::Operator::Equal, Dhall::Operator::NotEqual
				Operator.new(expr, Dhall::Variable["Bool"])
			when Dhall::Operator::Plus, Dhall::Operator::Times
				Operator.new(expr, Dhall::Variable["Natural"])
			when Dhall::Operator::TextConcatenate
				Operator.new(expr, Dhall::Variable["Text"])
			when Dhall::Operator::ListConcatenate
				OperatorListConcatenate.new(expr)
			when Dhall::Operator::RecursiveRecordMerge
				OperatorRecursiveRecordMerge.new(expr)
			when Dhall::Operator::RightBiasedRecordMerge
				OperatorRightBiasedRecordMerge.new(expr)
			when Dhall::Operator::RecursiveRecordTypeMerge
				OperatorRecursiveRecordTypeMerge.new(expr)
			when Dhall::EmptyRecordType
				EmptyAnonymousType.new(expr)
			when Dhall::RecordType, Dhall::UnionType
				AnonymousType.new(expr)
			when Dhall::EmptyRecord
				EmptyRecord.new(expr)
			when Dhall::Record
				Record.new(expr)
			when Dhall::RecordSelection
				RecordSelection.new(expr)
			when Dhall::RecordProjection, Dhall::EmptyRecordProjection
				RecordProjection.new(expr)
			when Dhall::Union
				Union.new(expr)
			when Dhall::Merge
				Merge.new(expr)
			when Dhall::Forall
				Forall.new(expr)
			when Dhall::Function
				Function.new(expr)
			when Dhall::LetBlock
				LetBlock.for(expr)
			when Dhall::TypeAnnotation
				TypeAnnotation.new(expr)
			when Dhall::Builtin
				Builtin.new(expr)
			else
				raise TypeError, "Unknown expression: #{expr}"
			end
		end

		class Context
			def initialize(bindings=Hash.new([]))
				@bindings = bindings.freeze
				freeze
			end

			def fetch(var)
				@bindings[var.name][var.index] ||
					(raise TypeError, "Free variable: #{var}")
			end

			def add(ftype)
				self.class.new(@bindings.merge(
					ftype.var => [ftype.type] + @bindings[ftype.var]
				)).shift(1, ftype.var, 0)
			end

			def shift(amount, name, min_index)
				self.class.new(@bindings.merge(
					Hash[@bindings.map do |var, bindings|
						[var, bindings.map { |b| b.shift(amount, name, min_index) }]
					end]
				))
			end
		end

		KINDS = [
			Dhall::Variable["Type"],
			Dhall::Variable["Kind"],
			Dhall::Variable["Sort"]
		].freeze

		class Variable
			def initialize(var)
				@var = var
			end

			BUILTIN = {
				"Type"     => Dhall::Variable["Kind"],
				"Kind"     => Dhall::Variable["Sort"],
				"Bool"     => Dhall::Variable["Type"],
				"Natural"  => Dhall::Variable["Type"],
				"Integer"  => Dhall::Variable["Type"],
				"Double"   => Dhall::Variable["Type"],
				"Text"     => Dhall::Variable["Type"],
				"List"     => Dhall::Forall.of_arguments(
					Dhall::Variable["Type"],
					body: Dhall::Variable["Type"]
				),
				"Optional" => Dhall::Forall.of_arguments(
					Dhall::Variable["Type"],
					body: Dhall::Variable["Type"]
				),
				"None"     => Dhall::Forall.new(
					var:  "A",
					type: Dhall::Variable["Type"],
					body: Dhall::Application.new(
						function: Dhall::Variable["Optional"],
						argument: Dhall::Variable["A"]
					)
				)
			}.freeze

			def annotate(context)
				raise TypeError, "Sort has no Type, Kind, or Sort" if @var.name == "Sort"

				Dhall::TypeAnnotation.new(
					value: @var,
					type:  BUILTIN.fetch(@var.name) { context.fetch(@var) }
				)
			end
		end

		class Literal
			def initialize(lit)
				@lit = lit
				@type = Dhall::Variable[lit.class.name.split(/::/).last]
			end

			def annotate(*)
				Dhall::TypeAnnotation.new(
					value: @lit,
					type:  @type
				)
			end
		end

		class TextLiteral
			def initialize(lit)
				@lit = lit
			end

			def annotate(context)
				chunks = @lit.chunks.map do |c|
					if c.is_a?(Dhall::Text)
						c
					else
						annotated = TypeChecker.for(c).annotate(context)
						if annotated.type != Dhall::Variable["Text"]
							raise TypeError, "Cannot interpolate non-Text: " \
							                 "#{annotated.type}"
						end
						annotated
					end
				end

				Dhall::TypeAnnotation.new(
					value: @lit.with(chunks: chunks),
					type:  Dhall::Variable["Text"]
				)
			end
		end

		class If
			def initialize(expr)
				@expr = expr
				@predicate = TypeChecker.for(expr.predicate)
				@then = TypeChecker.for(expr.then)
				@else = TypeChecker.for(expr.else)
			end

			def annotate(context)
				annotated_predicate = @predicate.annotate(context)
				if annotated_predicate.type != Dhall::Variable["Bool"]
					raise TypeError, "If must have a predicate of type Bool"
				end

				annotated_then = @then.annotate(context)
				then_type_type = TypeChecker.for(annotated_then.type)
				                            .annotate(context).type
				if then_type_type != Dhall::Variable["Type"]
					raise TypeError, "If branches must have types of type Type"
				end

				annotated_else = @else.annotate(context)
				if annotated_then.type == annotated_else.type
					Dhall::TypeAnnotation.new(
						value: @expr.with(
							predicate: annotated_predicate,
							then:      annotated_then,
							else:      annotated_else
						),
						type:  annotated_then.type
					)
				else
					raise TypeError, "If branches have mismatched types: " \
					                 "#{annotated_then.type}, #{annotated_else.type}"
				end
			end
		end

		class Operator
			def initialize(expr, type)
				@expr = expr
				@lhs = TypeChecker.for(expr.lhs)
				@rhs = TypeChecker.for(expr.rhs)
				@type = type
			end

			def annotate(context)
				annotated_lhs = @lhs.annotate(context)
				annotated_rhs = @rhs.annotate(context)
				types = [annotated_lhs.type, annotated_rhs.type]
				if types.any? { |t| t != @type }
					raise TypeError, "Operator arguments not #{@type}: #{types}"
				end

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
					type:  @type
				)
			end
		end

		class OperatorListConcatenate
			def initialize(expr)
				@expr = expr
				@lhs = TypeChecker.for(expr.lhs)
				@rhs = TypeChecker.for(expr.rhs)
			end

			def annotate(context)
				annotated_lhs = @lhs.annotate(context)
				annotated_rhs = @rhs.annotate(context)
				types = [annotated_lhs.type, annotated_rhs.type]
				valid_types = types.all? do |t|
					t.is_a?(Dhall::Application) &&
						t.function == Dhall::Variable["List"]
				end

				raise TypeError, "Operator arguments not List: #{types}" unless valid_types

				unless annotated_lhs.type == annotated_rhs.type
					raise TypeError, "Operator arguments do not match: #{types}"
				end

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
					type:  annotated_lhs.type
				)
			end
		end

		class OperatorRecursiveRecordMerge
			def initialize(expr)
				@expr = expr
				@lhs = TypeChecker.for(expr.lhs)
				@rhs = TypeChecker.for(expr.rhs)
			end

			def annotate(context)
				annotated_lhs = @lhs.annotate(context)
				annotated_rhs = @rhs.annotate(context)

				type = annotated_lhs.type.deep_merge_type(annotated_rhs.type)

				unless type.is_a?(Dhall::RecordType)
					raise TypeError, "RecursiveRecordMerge got #{type}"
				end

				# Annotate to sanity check
				TypeChecker.for(type).annotate(context)

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
					type:  type
				)
			end
		end

		class OperatorRightBiasedRecordMerge
			def initialize(expr)
				@expr = expr
				@lhs = TypeChecker.for(expr.lhs)
				@rhs = TypeChecker.for(expr.rhs)
			end

			def annotate(context)
				annotated_lhs = @lhs.annotate(context)
				annotated_rhs = @rhs.annotate(context)

				unless annotated_lhs.type.is_a?(Dhall::RecordType)
					raise TypeError, "RecursiveRecordMerge got #{annotated_lhs.type}"
				end

				unless annotated_rhs.type.is_a?(Dhall::RecordType)
					raise TypeError, "RecursiveRecordMerge got #{annotated_rhs.type}"
				end

				lkind = TypeChecker.for(annotated_lhs.type).annotate(context).type
				rkind = TypeChecker.for(annotated_rhs.type).annotate(context).type

				if lkind != rkind
					raise TypeError, "RecursiveRecordMerge got mixed kinds: " \
										  "#{lkind}, #{rkind}"
				end

				type = annotated_lhs.type.merge_type(annotated_rhs.type)

				# Annotate to sanity check
				TypeChecker.for(type).annotate(context)

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
					type:  type
				)
			end
		end

		class OperatorRecursiveRecordTypeMerge
			def initialize(expr)
				@expr = expr
				@lhs = TypeChecker.for(expr.lhs)
				@rhs = TypeChecker.for(expr.rhs)
			end

			def annotate(context)
				annotated_lhs = @lhs.annotate(context)
				annotated_rhs = @rhs.annotate(context)

				if annotated_lhs.type != annotated_rhs.type
					raise TypeError, "RecursiveRecordTypeMerge mixed kinds: " \
					                 "#{annotated_lhs.type}, #{annotated_rhs.type}"
				end

				type = @expr.lhs.deep_merge_type(@expr.rhs)

				unless type.is_a?(Dhall::RecordType)
					raise TypeError, "RecursiveRecordMerge got #{type}"
				end

				# Annotate to sanity check
				TypeChecker.for(type).annotate(context)

				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  annotated_lhs.type
				)
			end
		end

		class EmptyList
			def initialize(expr)
				@expr = expr
			end

			def annotate(context)
				type_type = TypeChecker.for(@expr.type).annotate(context).type
				if type_type != Dhall::Variable["Type"]
					raise TypeError, "EmptyList element type not of type Type"
				end

				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  Dhall::Application.new(
						function: Dhall::Variable["List"],
						argument: @expr.type
					)
				)
			end
		end

		class List
			def initialize(list)
				@list = list
			end

			def annotate(context)
				alist = @list.map(type: @list.type) do |el|
					TypeChecker.for(el).annotate(context)
				end
				list = alist.with(type: alist.first.value.type)

				if (bad = alist.find { |x| x.type != list.type })
					raise TypeError, "List #{list.type} with element #{bad}"
				end

				type_type = TypeChecker.for(list.type).annotate(context).type
				if type_type != Dhall::Variable["Type"]
					raise TypeError, "List type no of type Type, was: #{type_type}"
				end

				Dhall::TypeAnnotation.new(
					value: list,
					type:  Dhall::Application.new(
						function: Dhall::Variable["List"],
						argument: list.type
					)
				)
			end
		end

		class OptionalNone
			def initialize(expr)
				@expr = expr
			end

			def annotate(context)
				type_type = TypeChecker.for(@expr.type).annotate(context).type
				if type_type != Dhall::Variable["Type"]
					raise TypeError, "OptionalNone element type not of type Type"
				end

				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  Dhall::Application.new(
						function: Dhall::Variable["Optional"],
						argument: @expr.type
					)
				)
			end
		end

		class Optional
			def initialize(some)
				@some = some
			end

			def annotate(context)
				asome = @some.map(type: @some.type) do |el|
					TypeChecker.for(el).annotate(context)
				end
				some = asome.with(type: asome.value.type)

				type_type = TypeChecker.for(some.type).annotate(context).type
				if type_type != Dhall::Variable["Type"]
					raise TypeError, "Some type no of type Type, was: #{type_type}"
				end

				Dhall::TypeAnnotation.new(
					value: some,
					type:  Dhall::Application.new(
						function: Dhall::Variable["Optional"],
						argument: some.type
					)
				)
			end
		end

		class EmptyAnonymousType
			def initialize(expr)
				@expr = expr
			end

			def annotate(*)
				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  Dhall::Variable["Type"]
				)
			end
		end

		class AnonymousType
			def initialize(type)
				@type = type
			end

			def annotate(context)
				kinds = @type.record.values.map do |mtype|
					TypeChecker.for(mtype).annotate(context).type
				end

				TypeChecker.assert (kinds - KINDS), [],
				                   "AnonymousType field kind not one of #{KINDS}"

				TypeChecker.assert kinds, Util::ArrayAllTheSame,
				                   "AnonymousType field kinds not all the same"

				type = kinds.first || KINDS.first
				Dhall::TypeAnnotation.new(value: @type, type: type)
			end
		end

		class EmptyRecord
			def initialize(expr)
				@expr = expr
			end

			def annotate(*)
				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  Dhall::EmptyRecordType.new
				)
			end
		end

		class Record
			def initialize(record)
				@record = record
			end

			def annotate(context)
				arecord = @record.map do |k, v|
					[k, TypeChecker.for(v).annotate(context)]
				end

				Dhall::TypeAnnotation.new(
					value: arecord,
					type:  TypeChecker.for(Dhall::RecordType.for(Hash[
						arecord.record.map { |k, v| [k, v.type] }
					])).annotate(context).value
				)
			end
		end

		class RecordSelection
			def initialize(selection)
				@selection = selection
				@record = selection.record
				@selector = selection.selector
			end

			class Selector
				def self.for(annotated_record)
					if annotated_record.type == Dhall::Variable["Type"]
						TypeSelector.new(annotated_record.value)
					elsif annotated_record.type.class == Dhall::RecordType
						new(annotated_record.type)
					else
						raise TypeError, "RecordSelection on #{annotated_record.type}"
					end
				end

				def initialize(type)
					@fetch_from = type.record
				end

				def select(selector)
					@fetch_from.fetch(selector) do
						raise TypeError, "#{@fetch_from} has no field #{@selector}"
					end
				end
			end

			class TypeSelector < Selector
				def initialize(union)
					normalized = union.normalize
					TypeChecker.assert normalized, Dhall::UnionType,
					                   "RecordSelection on #{normalized}"
					@fetch_from = normalized.constructor_types
				end
			end

			def annotate(context)
				arecord = TypeChecker.for(@record).annotate(context)
				selector = Selector.for(arecord)

				Dhall::TypeAnnotation.new(
					value: @selection.with(record: arecord),
					type:  selector.select(@selector)
				)
			end
		end

		class RecordProjection
			def initialize(projection)
				@projection = projection
				@record = TypeChecker.for(projection.record)
				@selectors = projection.selectors
			end

			def annotate(context)
				arecord = @record.annotate(context)

				TypeChecker.assert arecord.type.class.name, "Dhall::RecordType",
				                   "RecordProjection on #{arecord.type}"

				slice = arecord.type.slice(@selectors)
				TypeChecker.assert slice.keys, @selectors,
				                   "#{arecord.type} missing one of: #{@selectors}"

				Dhall::TypeAnnotation.new(
					value: @projection.with(record: arecord),
					type:  slice
				)
			end
		end

		class Union
			def initialize(union)
				@union = union
				@value = TypeChecker.for(union.value)
			end

			def annotate(context)
				annotated_value = @value.annotate(context)

				type = Dhall::UnionType.new(
					alternatives: { @union.tag => annotated_value.type }
				).merge(@union.alternatives)

				# Annotate to sanity check
				TypeChecker.for(type).annotate(context)

				Dhall::TypeAnnotation.new(
					value: @union.with(value: annotated_value),
					type:  type
				)
			end
		end

		class Merge
			def initialize(merge)
				@merge = merge
				@record = TypeChecker.for(merge.record)
				@union = TypeChecker.for(merge.input)
			end

			class Handlers
				def initialize(annotation)
					@type = annotation.type

					TypeChecker.assert @type, Dhall::RecordType,
					                   "Merge expected Record got: #{@type}"

					@type.record.values.each do |htype|
						TypeChecker.assert htype, Dhall::Forall,
						                   "Merge handlers must all be functions"
					end
				end

				def output_type(output_annotation=nil)
					@type.record.values.reduce(output_annotation) do |type_acc, htype|
						if type_acc && htype.body.normalize != type_acc.normalize
							raise TypeError, "Handler output types must all match"
						end

						htype.body.shift(-1, htype.var, 0)
					end
				end

				def keys
					@type.record.keys
				end

				def fetch(k)
					@type.record.fetch(k) do
						raise TypeError, "No merge handler for alternative: #{k}"
					end
				end
			end

			class AnnotatedMerge
				def initialize(merge:, record:, input:)
					@merge = merge.with(record: record, input: input)
					@handlers = Handlers.new(record)
					@record = record
					@union = input

					TypeChecker.assert @union.type, Dhall::UnionType,
					                   "Merge expected Union got: #{@union.type}"

					assert_union_and_handlers_match
				end

				def annotation
					Dhall::TypeAnnotation.new(
						value: @merge,
						type:  type
					)
				end

				def type
					@type ||= @handlers.output_type(@merge.type)
				end

				def assert_kind(context)
					kind = TypeChecker.for(type).annotate(context).type

					TypeChecker.assert(
						kind,
						Dhall::Variable["Type"],
						"Merge must have kind Type"
					)

					kind
				end

				def assert_union_and_handlers_match
					extras = @handlers.keys - @union.type.alternatives.keys
					TypeChecker.assert extras, [],
					                   "Merge handlers unknown alternatives: #{extras}"

					@union.type.alternatives.each do |k, atype|
						TypeChecker.assert(
							@handlers.fetch(k).type,
							atype,
							"Handler argument does not match alternative type: #{atype}"
						)
					end
				end
			end

			def annotate(context)
				amerge = AnnotatedMerge.new(
					merge:  @merge,
					record: @record.annotate(context),
					input:  @union.annotate(context)
				)
				amerge.assert_kind(context)
				amerge.annotation
			end
		end

		class Forall
			def initialize(expr)
				@expr = expr
				@var = expr.var
				@var_type = expr.type
				@input = TypeChecker.for(expr.type)
				@output = TypeChecker.for(expr.body)
			end

			module FunctionKind
				def self.for(inkind, outkind)
					if inkind.nil? || outkind.nil?
						raise TypeError, "FunctionType part of this is a term"
					end

					raise TypeError, "Dependent types are not allowed" if outkind > inkind

					if outkind.zero?
						Term.new
					else
						Polymorphic.new(inkind, outkind)
					end
				end

				class Term
					def kind
						KINDS.first
					end
				end

				class Polymorphic
					def initialize(inkind, outkind)
						@inkind = inkind
						@outkind = outkind
					end

					def kind
						KINDS[[@outkind, @inkind].max]
					end
				end
			end

			def annotate(context)
				inkind = KINDS.index(@input.annotate(context).type)
				outkind = KINDS.index(@output.annotate(context.add(@expr)).type)

				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  FunctionKind.for(inkind, outkind).kind
				)
			end
		end

		class Function
			def initialize(func)
				@func = func
				@type = Dhall::Forall.new(
					var:  func.var,
					type: func.type,
					body: Dhall::Variable["UNKNOWN"]
				)
				@output = TypeChecker.for(func.body)
			end

			def annotate(context)
				abody = @output.annotate(context.add(@type))

				Dhall::TypeAnnotation.new(
					value: @func.with(body: abody),
					type:  TypeChecker.for(
						@type.with(body: abody.type)
					).annotate(context).value
				)
			end
		end

		class Application
			def initialize(app)
				@app = app
				@func = TypeChecker.for(app.function)
				@arg = app.argument
			end

			def annotate(context)
				afunc = @func.annotate(context)

				TypeChecker.assert afunc.type, Dhall::Forall,
				                   "Application LHS is not a function"

				aarg = TypeChecker.for(
					Dhall::TypeAnnotation.new(value: @arg, type: afunc.type.type)
				).annotate(context)

				Dhall::TypeAnnotation.new(
					value: @app.with(function: afunc, argument: aarg),
					type:  afunc.type.call(aarg.value)
				)
			end
		end

		class LetBlock
			def self.for(letblock)
				if letblock.lets.first.type
					LetBlockAnnotated.new(letblock)
				else
					LetBlock.new(letblock)
				end
			end

			def initialize(letblock)
				@letblock = letblock.unflatten
				@let = @letblock.lets.first
			end

			def annotate(context)
				alet = @let.with(type: assign_type(context))
				type = TypeChecker.for(@letblock.eliminate).annotate(context).type
				abody = Dhall::TypeAnnotation.new(value: @letblock.body, type: type)
				Dhall::TypeAnnotation.new(
					value: @letblock.with(lets: [alet], body: abody),
					type:  type
				)
			end

			protected

			def assign_type(context)
				TypeChecker.for(@let.assign).annotate(context).type
			end
		end

		class LetBlockAnnotated < LetBlock
			protected

			def assign_type(context)
				TypeChecker.for(
					Dhall::TypeAnnotation.new(
						value: @let.assign,
						type:  @let.type
					)
				).annotate(context).type
			end
		end

		class TypeAnnotation
			def initialize(expr)
				@expr = expr
			end

			def annotate(context)
				redo_annotation = TypeChecker.for(@expr.value).annotate(context)

				if redo_annotation.type.normalize == @expr.type.normalize
					redo_annotation
				else
					raise TypeError, "TypeAnnotation does not match: " \
					                 "#{@expr.type}, #{redo_annotation.type}"
				end
			end
		end

		class Builtin
			def initialize(builtin)
				@expr = builtin
				@name = builtin.as_json
			end

			TYPES = {
				"Natural/build"     => Dhall::Forall.of_arguments(
					Dhall::Forall.new(
						var:  "natural",
						type: Dhall::Variable["Type"],
						body: Dhall::Forall.new(
							var:  "succ",
							type: Dhall::Forall.of_arguments(
								Dhall::Variable["natural"],
								body: Dhall::Variable["natural"]
							),
							body: Dhall::Forall.new(
								var:  "zero",
								type: Dhall::Variable["natural"],
								body: Dhall::Variable["natural"]
							)
						)
					),
					body: Dhall::Variable["Natural"]
				),
				"Natural/fold"      => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Forall.new(
						var:  "natural",
						type: Dhall::Variable["Type"],
						body: Dhall::Forall.new(
							var:  "succ",
							type: Dhall::Forall.of_arguments(
								Dhall::Variable["natural"],
								body: Dhall::Variable["natural"]
							),
							body: Dhall::Forall.new(
								var:  "zero",
								type: Dhall::Variable["natural"],
								body: Dhall::Variable["natural"]
							)
						)
					)
				),
				"Natural/isZero"    => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Bool"]
				),
				"Natural/even"      => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Bool"]
				),
				"Natural/odd"       => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Bool"]
				),
				"Natural/toInteger" => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Integer"]
				),
				"Natural/show"      => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Text"]
				),
				"Text/show"         => Dhall::Forall.of_arguments(
					Dhall::Variable["Text"],
					body: Dhall::Variable["Text"]
				),
				"List/build"        => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Forall.new(
							var:  "list",
							type: Dhall::Variable["Type"],
							body: Dhall::Forall.new(
								var:  "cons",
								type: Dhall::Forall.of_arguments(
									Dhall::Variable["a"],
									Dhall::Variable["list"],
									body: Dhall::Variable["list"]
								),
								body: Dhall::Forall.new(
									var:  "nil",
									type: Dhall::Variable["list"],
									body: Dhall::Variable["list"]
								)
							)
						),
						body: Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						)
					)
				),
				"List/fold"         => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						),
						body: Dhall::Forall.new(
							var:  "list",
							type: Dhall::Variable["Type"],
							body: Dhall::Forall.new(
								var:  "cons",
								type: Dhall::Forall.of_arguments(
									Dhall::Variable["a"],
									Dhall::Variable["list"],
									body: Dhall::Variable["list"]
								),
								body: Dhall::Forall.new(
									var:  "nil",
									type: Dhall::Variable["list"],
									body: Dhall::Variable["list"]
								)
							)
						)
					)
				),
				"List/length"       => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						),
						body: Dhall::Variable["Natural"]
					)
				),
				"List/head"         => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						),
						body: Dhall::Application.new(
							function: Dhall::Variable["Optional"],
							argument: Dhall::Variable["a"]
						)
					)
				),
				"List/last"         => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						),
						body: Dhall::Application.new(
							function: Dhall::Variable["Optional"],
							argument: Dhall::Variable["a"]
						)
					)
				),
				"List/indexed"      => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						),
						body: Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::RecordType.new(
								record: {
									"index" => Dhall::Variable["Natural"],
									"value" => Dhall::Variable["a"]
								}
							)
						)
					)
				),
				"List/reverse"      => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						),
						body: Dhall::Application.new(
							function: Dhall::Variable["List"],
							argument: Dhall::Variable["a"]
						)
					)
				),
				"Optional/fold"     => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function: Dhall::Variable["Optional"],
							argument: Dhall::Variable["a"]
						),
						body: Dhall::Forall.new(
							var:  "optional",
							type: Dhall::Variable["Type"],
							body: Dhall::Forall.new(
								var:  "just",
								type: Dhall::Forall.of_arguments(
									Dhall::Variable["a"],
									body: Dhall::Variable["optional"]
								),
								body: Dhall::Forall.new(
									var:  "nothing",
									type: Dhall::Variable["optional"],
									body: Dhall::Variable["optional"]
								)
							)
						)
					)
				),
				"Optional/build"    => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Forall.new(
							var:  "optional",
							type: Dhall::Variable["Type"],
							body: Dhall::Forall.new(
								var:  "just",
								type: Dhall::Forall.of_arguments(
									Dhall::Variable["a"],
									body: Dhall::Variable["optional"]
								),
								body: Dhall::Forall.new(
									var:  "nothing",
									type: Dhall::Variable["optional"],
									body: Dhall::Variable["optional"]
								)
							)
						),
						body: Dhall::Application.new(
							function: Dhall::Variable["Optional"],
							argument: Dhall::Variable["a"]
						)
					)
				),
				"Integer/show"      => Dhall::Forall.of_arguments(
					Dhall::Variable["Integer"],
					body: Dhall::Variable["Text"]
				),
				"Integer/toDouble"  => Dhall::Forall.of_arguments(
					Dhall::Variable["Integer"],
					body: Dhall::Variable["Double"]
				),
				"Double/show"       => Dhall::Forall.of_arguments(
					Dhall::Variable["Double"],
					body: Dhall::Variable["Text"]
				)
			}.freeze

			def annotate(*)
				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  TYPES.fetch(@name) do
						raise TypeError, "Unknown Builtin #{@name}"
					end
				)
			end
		end
	end
end
