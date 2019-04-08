# frozen_string_literal: true

require "dhall/ast"
require "dhall/normalize"

module Dhall
	module TypeChecker
		def self.assert(type, assertion, message)
			raise TypeError, message unless assertion === type
			type
		end

		def self.assert_type(expr, assertion, message, context:)
			aexpr = self.for(expr).annotate(context)
			type = aexpr.type
			raise TypeError, "#{message}: #{type}" unless assertion === type
			aexpr
		end

		def self.assert_types_match(a, b, message, context:)
			atype = self.for(a).annotate(context).type
			btype = self.for(b).annotate(context).type
			raise TypeError, "#{message}: #{atype}, #{btype}" unless atype == btype
			atype
		end

		def self.for(expr)
			@typecheckers.each do |node_matcher, (typechecker, extras)|
				if node_matcher === expr
					msg = [:call, :for, :new].find { |m| typechecker.respond_to?(m) }
					return typechecker.public_send(msg, expr, *extras)
				end
			end

			raise TypeError, "Unknown expression: #{expr.inspect}"
		end

		def self.register(typechecker, node_type, *extras)
			@typecheckers ||= {}
			@typecheckers[node_type] ||= [typechecker, extras]
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
			TypeChecker.register self, Dhall::Variable

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
			TypeChecker.register self, Dhall::Bool
			TypeChecker.register self, Dhall::Natural
			TypeChecker.register self, Dhall::Text
			TypeChecker.register self, Dhall::Integer
			TypeChecker.register self, Dhall::Double

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
			TypeChecker.register self, Dhall::TextLiteral

			def initialize(lit)
				@lit = lit
			end

			class Chunks
				def initialize(chunks)
					@chunks = chunks
				end

				def map
					self.class.new(@chunks.map { |c|
						if c.is_a?(Dhall::Text)
							c
						else
							yield c
						end
					})
				end

				def to_a
					@chunks
				end
			end

			def annotate(context)
				chunks = Chunks.new(@lit.chunks).map { |c|
					TypeChecker.for(c).annotate(context).tap do |annotated|
						TypeChecker.assert annotated.type, Dhall::Variable["Text"],
						                   "Cannot interpolate #{annotated.type}"
					end
				}.to_a

				Dhall::TypeAnnotation.new(
					value: @lit.with(chunks: chunks),
					type:  Dhall::Variable["Text"]
				)
			end
		end

		class If
			TypeChecker.register self, Dhall::If

			def initialize(expr)
				@expr = expr
				@predicate = TypeChecker.for(expr.predicate)
				@then = TypeChecker.for(expr.then)
				@else = TypeChecker.for(expr.else)
			end

			class AnnotatedIf
				def initialize(expr, apred, athen, aelse, context:)
					TypeChecker.assert apred.type, Dhall::Variable["Bool"],
					                   "If must have a predicate of type Bool"
					TypeChecker.assert_type athen.type, Dhall::Variable["Type"],
					                        "If branches must have types of type Type",
					                        context: context
					TypeChecker.assert aelse.type, athen.type,
					                   "If branches have mismatched types"
					@expr = expr.with(predicate: apred, then: athen, else: aelse)
				end

				def annotation
					Dhall::TypeAnnotation.new(
						value: @expr,
						type:  @expr.then.type
					)
				end
			end

			def annotate(context)
				AnnotatedIf.new(
					@expr,
					@predicate.annotate(context),
					@then.annotate(context),
					@else.annotate(context),
					context: context
				).annotation
			end
		end

		class Operator
			{
				Dhall::Operator::And             => Dhall::Variable["Bool"],
				Dhall::Operator::Or              => Dhall::Variable["Bool"],
				Dhall::Operator::Equal           => Dhall::Variable["Bool"],
				Dhall::Operator::NotEqual        => Dhall::Variable["Bool"],
				Dhall::Operator::Plus            => Dhall::Variable["Natural"],
				Dhall::Operator::Times           => Dhall::Variable["Natural"],
				Dhall::Operator::TextConcatenate => Dhall::Variable["Text"]
			}.each do |node_type, type|
				TypeChecker.register self, node_type, type
			end

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
			TypeChecker.register self, Dhall::Operator::ListConcatenate

			def initialize(expr)
				@expr = expr
				@lhs = TypeChecker.for(expr.lhs)
				@rhs = TypeChecker.for(expr.rhs)
			end

			module IsList
				def self.===(other)
					other.is_a?(Dhall::Application) &&
						other.function == Dhall::Variable["List"]
				end
			end

			def annotate(context)
				annotated_lhs = @lhs.annotate(context)
				annotated_rhs = @rhs.annotate(context)

				types = [annotated_lhs.type, annotated_rhs.type]
				assertion = Util::ArrayOf.new(Util::AllOf.new(IsList, types.first))
				TypeChecker.assert types, assertion,
				                   "Operator arguments wrong: #{types}"

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
					type:  types.first
				)
			end
		end

		class OperatorRecursiveRecordMerge
			TypeChecker.register self, Dhall::Operator::RecursiveRecordMerge

			def initialize(expr)
				@expr = expr
				@lhs = TypeChecker.for(expr.lhs)
				@rhs = TypeChecker.for(expr.rhs)
			end

			def annotate(context)
				annotated_lhs = @lhs.annotate(context)
				annotated_rhs = @rhs.annotate(context)

				type = annotated_lhs.type.deep_merge_type(annotated_rhs.type)

				TypeChecker.assert type, Dhall::RecordType,
				                   "RecursiveRecordMerge got #{type}"

				# Annotate to sanity check
				TypeChecker.for(type).annotate(context)

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
					type:  type
				)
			end
		end

		class OperatorRightBiasedRecordMerge
			TypeChecker.register self, Dhall::Operator::RightBiasedRecordMerge

			def initialize(expr)
				@expr = expr
			end

			def check(context)
				annotated_lhs = TypeChecker.assert_type @expr.lhs, Dhall::RecordType,
				                                        "RecursiveRecordMerge got",
				                                        context: context

				annotated_rhs = TypeChecker.assert_type @expr.rhs, Dhall::RecordType,
				                                        "RecursiveRecordMerge got",
				                                        context: context

				TypeChecker.assert_types_match annotated_lhs.type, annotated_rhs.type,
				                               "RecursiveRecordMerge got mixed kinds",
				                               context: context

				[annotated_lhs, annotated_rhs]
			end

			def annotate(context)
				annotated_lhs, annotated_rhs = check(context)

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
					type:  TypeChecker.for(
						annotated_lhs.type.merge_type(annotated_rhs.type)
					).annotate(context).value
				)
			end
		end

		class OperatorRecursiveRecordTypeMerge
			TypeChecker.register self, Dhall::Operator::RecursiveRecordTypeMerge

			def initialize(expr)
				@expr = expr
			end

			def annotate(context)
				kind = TypeChecker.assert_types_match(
					@expr.lhs, @expr.rhs,
					"RecursiveRecordTypeMerge mixed kinds",
					context: context
				)

				type = @expr.lhs.deep_merge_type(@expr.rhs)

				TypeChecker.assert type, Dhall::RecordType,
				                   "RecursiveRecordMerge got #{type}"

				# Annotate to sanity check
				TypeChecker.for(type).annotate(context)

				Dhall::TypeAnnotation.new(value: @expr, type: kind)
			end
		end

		class EmptyList
			TypeChecker.register self, Dhall::EmptyList

			def initialize(expr)
				@expr = expr
			end

			def annotate(context)
				TypeChecker.assert_type @expr.element_type, Dhall::Variable["Type"],
				                        "EmptyList element type not of type Type",
				                        context: context

				Dhall::TypeAnnotation.new(type: @expr.type, value: @expr)
			end
		end

		class List
			TypeChecker.register self, Dhall::List

			def initialize(list)
				@list = list
			end

			class AnnotatedList
				def initialize(alist)
					@alist = alist
				end

				def annotation
					list = @alist.with(element_type: element_type)
					Dhall::TypeAnnotation.new(type: list.type, value: list)
				end

				def element_type
					@alist.first.value&.type || @alist.element_type
				end

				def element_types
					@alist.to_a.map(&:type)
				end
			end

			def annotate(context)
				alist = AnnotatedList.new(@list.map(type: @list.element_type) { |el|
					TypeChecker.for(el).annotate(context)
				})

				TypeChecker.assert alist.element_types,
				                   Util::ArrayOf.new(alist.element_type),
				                   "Non-homogenous List"

				TypeChecker.assert_type alist.element_type, Dhall::Variable["Type"],
				                        "List type not of type Type", context: context

				alist.annotation
			end
		end

		class OptionalNone
			TypeChecker.register self, Dhall::OptionalNone

			def initialize(expr)
				@expr = expr
			end

			def annotate(context)
				TypeChecker.assert(
					TypeChecker.for(@expr.value_type).annotate(context).type,
					Dhall::Variable["Type"],
					"OptionalNone element type not of type Type"
				)

				Dhall::TypeAnnotation.new(type: @expr.type, value: @expr)
			end
		end

		class Optional
			TypeChecker.register self, Dhall::Optional

			def initialize(some)
				@some = some
			end

			def annotate(context)
				asome = @some.map do |el|
					TypeChecker.for(el).annotate(context)
				end
				some = asome.with(value_type: asome.value.type)

				type_type = TypeChecker.for(some.value_type).annotate(context).type
				TypeChecker.assert type_type, Dhall::Variable["Type"],
				                   "Some type not of type Type, was: #{type_type}"

				Dhall::TypeAnnotation.new(type: some.type, value: some)
			end
		end

		class EmptyAnonymousType
			TypeChecker.register self, Dhall::EmptyRecordType

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
			TypeChecker.register self, Dhall::RecordType
			TypeChecker.register self, Dhall::UnionType

			def initialize(type)
				@type = type
			end

			def annotate(context)
				kinds = @type.record.values.compact.map do |mtype|
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
			TypeChecker.register self, Dhall::EmptyRecord

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
			TypeChecker.register self, Dhall::Record

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
			TypeChecker.register self, Dhall::RecordSelection

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
			TypeChecker.register self, Dhall::EmptyRecordProjection
			TypeChecker.register self, Dhall::RecordProjection

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
			TypeChecker.register self, Dhall::Union

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
			TypeChecker.register self, Dhall::Merge

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
				end

				def output_type(output_annotation=nil)
					@type.record.values.reduce(output_annotation) do |type_acc, htype|
						htype = htype.body.shift(-1, htype.var, 0) if htype.is_a?(Dhall::Forall)

						if type_acc && htype.normalize != type_acc.normalize
							raise TypeError, "Handler output types must all match"
						end

						htype
					end
				end

				def keys
					@type.record.keys
				end

				def fetch_input_type(k)
					type = @type.record.fetch(k) do
						raise TypeError, "No merge handler for alternative: #{k}"
					end

					TypeChecker.assert type, Dhall::Forall, "Handler is not a function"

					type.type
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
						atype.nil? || TypeChecker.assert(
							@handlers.fetch_input_type(k),
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
			TypeChecker.register self, Dhall::Forall

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
			TypeChecker.register self, Dhall::Function

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
			TypeChecker.register self, Dhall::Application

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

		TypeChecker.register ->(blk) { LetIn.for(blk.unflatten) }, Dhall::LetBlock

		class LetIn
			TypeChecker.register self, Dhall::LetIn

			def self.for(letin)
				if letin.let.type
					LetInAnnotated.new(letin)
				else
					LetIn.new(letin)
				end
			end

			def initialize(letin)
				@letin = letin
				@let = @letin.let
			end

			def annotate(context)
				alet = @let.with(type: assign_type(context))
				type = TypeChecker.for(@letin.eliminate).annotate(context).type
				abody = Dhall::TypeAnnotation.new(value: @letin.body, type: type)
				Dhall::TypeAnnotation.new(
					value: @letin.with(let: alet, body: abody),
					type:  type
				)
			end

			protected

			def assign_type(context)
				TypeChecker.for(@let.assign).annotate(context).type
			end
		end

		class LetInAnnotated < LetIn
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
			TypeChecker.register self, Dhall::TypeAnnotation

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

		BUILTIN_TYPES = {
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

		class Builtin
			TypeChecker.register self, Dhall::Builtin

			def initialize(builtin)
				@expr = builtin
				@name = builtin.as_json
			end

			def annotate(*)
				Dhall::TypeAnnotation.new(
					value: @expr,
					type:  BUILTIN_TYPES.fetch(@name) do
						raise TypeError, "Unknown Builtin #{@name}"
					end
				)
			end
		end
	end
end
