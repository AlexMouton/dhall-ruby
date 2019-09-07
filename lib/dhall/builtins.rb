# frozen_string_literal: true

require "dhall/ast"

module Dhall
	class Builtin < Expression
		include(ValueSemantics.for_attributes {})

		def as_json
			self.class.name&.split(/::/)&.last&.tr("_", "/").to_s
		end
	end

	class BuiltinFunction < Builtin
		include(ValueSemantics.for_attributes do
			partial_application ArrayOf(Expression), default: []
		end)

		def unfill(*args)
			(args.empty? ? partial_application : args).reduce(self.class.new) do |f, arg|
				Application.new(function: f, argument: arg)
			end
		end

		def call(*new_args)
			args = partial_application + new_args
			if args.length == method(:uncurried_call).arity
				uncurried_call(*args)
			else
				with(partial_application: args)
			end
		end

		def as_json
			if (unfilled = unfill) != self
				unfilled.as_json
			else
				super
			end
		end
	end

	module Builtins
		# rubocop:disable Style/ClassAndModuleCamelCase

		class Double_show < BuiltinFunction
			protected

			def uncurried_call(arg)
				return unfill(arg) unless arg.is_a?(Dhall::Double)

				Dhall::Text.new(value: arg.to_s)
			end
		end

		class Integer_show < BuiltinFunction
			protected

			def uncurried_call(arg)
				return unfill(arg) unless arg.is_a?(Dhall::Integer)

				Dhall::Text.new(value: arg.to_s)
			end
		end

		class Integer_toDouble < BuiltinFunction
			protected

			def uncurried_call(arg)
				return unfill(arg) unless arg.is_a?(Dhall::Integer)

				Dhall::Double.new(value: arg.value.to_f)
			end
		end

		class Natural_build < BuiltinFunction
			def fusion(arg, *bogus)
				if bogus.empty? &&
				   arg.is_a?(Application) &&
				   arg.function == Natural_fold.new
					arg.argument
				else
					super
				end
			end

			protected

			def uncurried_call(arg)
				arg.call(
					Natural.new,
					Function.of_arguments(
						Natural.new,
						body: Variable["_"] + Dhall::Natural.new(value: 1)
					),
					Dhall::Natural.new(value: 0)
				)
			end
		end

		class Natural_subtract < BuiltinFunction
			protected

			def uncurried_call(x, y)
				if Natural_isZero.new.call(x) === true ||
				   Natural_isZero.new.call(y) === true
					return y
				end

				unless x.is_a?(Dhall::Natural) && y.is_a?(Dhall::Natural)
					return unfill(x, y)
				end

				Dhall::Natural.new(value: [y.to_i - x.to_i, 0].max)
			end
		end

		class Natural_even < BuiltinFunction
			protected

			def uncurried_call(nat)
				return unfill(nat) unless nat.is_a?(Dhall::Natural)

				Dhall::Bool.new(value: nat.even?)
			end
		end

		class Natural_fold < BuiltinFunction
			protected

			def uncurried_call(nat, type, f, z)
				return unfill(nat, type, f, z) unless nat.is_a?(Dhall::Natural)

				if nat.zero?
					z.normalize
				else
					f.call(Natural_fold.new.call(nat.pred, type, f, z))
				end
			end
		end

		class Natural_isZero < BuiltinFunction
			protected

			def uncurried_call(nat)
				return unfill(nat) unless nat.is_a?(Dhall::Natural)

				Dhall::Bool.new(value: nat.zero?)
			end
		end

		class Natural_odd < BuiltinFunction
			protected

			def uncurried_call(nat)
				return unfill(nat) unless nat.is_a?(Dhall::Natural)

				Dhall::Bool.new(value: nat.odd?)
			end
		end

		class Natural_show < BuiltinFunction
			protected

			def uncurried_call(nat)
				return unfill(nat) unless nat.is_a?(Dhall::Natural)

				Dhall::Text.new(value: nat.to_s)
			end
		end

		class Natural_toInteger < BuiltinFunction
			protected

			def uncurried_call(nat)
				return unfill(nat) unless nat.is_a?(Dhall::Natural)

				Dhall::Integer.new(value: nat.value)
			end
		end

		class List_build < BuiltinFunction
			def fusion(*args)
				_, arg, = args
				if arg.is_a?(Application) &&
				   arg.function.is_a?(Application) &&
				   arg.function.function == List_fold.new
					arg.argument
				else
					super
				end
			end

			protected

			def uncurried_call(type, arg)
				arg.call(
					List.new.call(type),
					cons(type),
					EmptyList.new(element_type: type)
				)
			end

			def cons(type)
				Function.of_arguments(
					type,
					List.new.call(type.shift(1, "_", 0)),
					body: Dhall::List.of(Variable["_", 1]).concat(Variable["_"])
				)
			end
		end

		class List_fold < BuiltinFunction
			protected

			def uncurried_call(ltype, list, ztype, f, z)
				return unfill(ltype, list, ztype, f, z) unless list.is_a?(Dhall::List)

				list.reduce(z, &f).normalize
			end
		end

		class List_head < BuiltinFunction
			protected

			def uncurried_call(type, list)
				return unfill(type, list) unless list.is_a?(Dhall::List)

				list.first
			end
		end

		class List_indexed < BuiltinFunction
			protected

			def uncurried_call(type, list)
				return unfill(type, list) unless list.is_a?(Dhall::List)

				list.map(type: indexed_type(type)) { |x, idx|
					Record.new(
						record: {
							"index" => Dhall::Natural.new(value: idx),
							"value" => x
						}
					)
				}.normalize
			end

			def indexed_type(value_type)
				RecordType.new(
					record: {
						"index" => Natural.new,
						"value" => value_type
					}
				)
			end
		end

		class List_last < BuiltinFunction
			protected

			def uncurried_call(type, list)
				return unfill(type, list) unless list.is_a?(Dhall::List)

				list.last
			end
		end

		class List_length < BuiltinFunction
			protected

			def uncurried_call(type, list)
				return unfill(type, list) unless list.is_a?(Dhall::List)

				Dhall::Natural.new(value: list.length)
			end
		end

		class List_reverse < BuiltinFunction
			protected

			def uncurried_call(type, list)
				return unfill(type, list) unless list.is_a?(Dhall::List)

				list.reverse
			end
		end

		class Optional_build < BuiltinFunction
			def fusion(*args)
				_, arg, = args
				if arg.is_a?(Application) &&
				   arg.function.is_a?(Application) &&
				   arg.function.function == Optional_fold.new
					arg.argument
				else
					super
				end
			end

			protected

			def uncurried_call(type, f)
				f.call(
					Optional.new.call(type),
					some(type),
					OptionalNone.new(value_type: type)
				)
			end

			def some(type)
				Function.of_arguments(
					type,
					body: Dhall::Optional.new(
						value:      Variable["_"],
						value_type: type
					)
				)
			end
		end

		class Optional_fold < BuiltinFunction
			protected

			def uncurried_call(type, optional, ztype, f, z)
				unless optional.is_a?(Dhall::Optional)
					return unfill(type, optional, ztype, f, z)
				end

				optional.reduce(z, &f)
			end
		end

		class Text_show < BuiltinFunction
			ENCODE = (Hash.new { |_, x| "\\u%04x" % x.ord }).merge(
				"\"" => "\\\"",
				"\\" => "\\\\",
				"\b" => "\\b",
				"\f" => "\\f",
				"\n" => "\\n",
				"\r" => "\\r",
				"\t" => "\\t"
			)

			protected

			def uncurried_call(text)
				return unfill(text) unless text.is_a?(Dhall::Text)

				Dhall::Text.new(
					value: "\"#{text.to_s.gsub(
						/["\$\\\b\f\n\r\t\u0000-\u001F]/,
						&ENCODE
					)}\""
				)
			end
		end

		class Bool < Builtin
		end

		class Optional < Builtin
		end

		class Natural < Builtin
		end

		class Integer < Builtin
		end

		class Double < Builtin
		end

		class Text < Builtin
		end

		class List < Builtin
		end

		class None < Builtin
			def call(arg)
				OptionalNone.new(value_type: arg)
			end
		end

		class Type < Builtin
		end

		class Kind < Builtin
		end

		class Sort < Builtin
		end

		# rubocop:enable Style/ClassAndModuleCamelCase

		def self.[](k)
			const = constants.find { |c| c.to_s.tr("_", "/").to_sym == k }
			const && const_get(const).new
		end
	end
end
