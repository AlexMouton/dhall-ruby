# frozen_string_literal: true

require "dhall/ast"

module Dhall
	module TypeChecker
		def self.for(expr)
			case expr
			when Dhall::Variable
				Variable.new(expr)
			when Dhall::Bool, Dhall::Natural, Dhall::Text
				Literal.new(expr)
			when Dhall::TextLiteral
				TextLiteral.new(expr)
			when Dhall::EmptyList
				EmptyList.new(expr)
			when Dhall::List
				List.new(expr)
			when Dhall::If
				If.new(expr)
			when Dhall::Application
				# TODO
				Variable.new(Dhall::Variable["Bool"])
			when Dhall::Operator::And, Dhall::Operator::Or,
			     Dhall::Operator::Equal, Dhall::Operator::NotEqual
				Operator.new(expr, Dhall::Variable["Bool"])
			when Dhall::Operator::Plus, Dhall::Operator::Times
				Operator.new(expr, Dhall::Variable["Natural"])
			when Dhall::Operator::TextConcatenate
				Operator.new(expr, Dhall::Variable["Text"])
			when Dhall::Operator::ListConcatenate
				OperatorListConcatenate.new(expr)
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

			def add(name, type)
				self.class.new(@bindings.merge(
					name => [type] + @bindings[name]
				))
			end
		end

		class Variable
			def initialize(var)
				@var = var
			end

			BUILTIN = {
				"Type"    => Dhall::Variable["Kind"],
				"Kind"    => Dhall::Variable["Sort"],
				"Bool"    => Dhall::Variable["Type"],
				"Natural" => Dhall::Variable["Type"],
				"Text"    => Dhall::Variable["Type"],
				"List"    => Dhall::Forall.of_arguments(
					Dhall::Variable["Type"],
					body: Dhall::Variable["Type"]
				)
			}.freeze

			def annotate(context)
				if @var.name == "Sort"
					raise TypeError, "Sort has no Type, Kind, or Sort"
				end

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
						type: annotated_then.type
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

				unless valid_types
					raise TypeError, "Operator arguments not List: #{types}"
				end

				unless annotated_lhs.type == annotated_rhs.type
					raise TypeError, "Operator arguments do not match: #{types}"
				end

				Dhall::TypeAnnotation.new(
					value: @expr.with(lhs: annotated_lhs, rhs: annotated_rhs),
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
						function:  Dhall::Variable["List"],
						arguments: [@expr.type]
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
						function:  Dhall::Variable["List"],
						arguments: [list.type]
					)
				)
			end
		end

		class Builtin
			def initialize(builtin)
				@expr = builtin
				@name = builtin.as_json
			end

			TYPES = {
				"Natural/build" => Dhall::Forall.of_arguments(
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
				"Natural/fold" => Dhall::Forall.of_arguments(
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
				"Natural/isZero" => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Bool"]
				),
				"Natural/even" => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Bool"]
				),
				"Natural/odd" => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Bool"]
				),
				"Natural/toInteger" => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Integer"]
				),
				"Natural/show" => Dhall::Forall.of_arguments(
					Dhall::Variable["Natural"],
					body: Dhall::Variable["Text"]
				),
				"Text/show" => Dhall::Forall.of_arguments(
					Dhall::Variable["Text"],
					body: Dhall::Variable["Text"]
				),
				"List/build" => Dhall::Forall.new(
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
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
						)
					)
				),
				"List/fold" => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
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
				"List/length" => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
						),
						body: Dhall::Variable["Natural"]
					)
				),
				"List/head" => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
						),
						body: Dhall::Application.new(
							function:  Dhall::Variable["Optional"],
							arguments: [Dhall::Variable["a"]]
						)
					)
				),
				"List/last" => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
						),
						body: Dhall::Application.new(
							function:  Dhall::Variable["Optional"],
							arguments: [Dhall::Variable["a"]]
						)
					)
				),
				"List/indexed" => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
						),
						body: Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::RecordType.new(record: {
								"index" => Dhall::Variable["Natural"],
								"value" => Dhall::Variable["a"]
							})]
						)
					)
				),
				"List/reverse" => Dhall::Forall.new(
					var:  "a",
					type: Dhall::Variable["Type"],
					body: Dhall::Forall.of_arguments(
						Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
						),
						body: Dhall::Application.new(
							function:  Dhall::Variable["List"],
							arguments: [Dhall::Variable["a"]]
						)
					)
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
