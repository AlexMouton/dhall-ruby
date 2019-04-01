# frozen_string_literal: true

require "dhall/ast"

module Dhall
	class Builtin < Expression
		include(ValueSemantics.for_attributes {})

		def call(*args)
			# Do not auto-normalize builtins to avoid recursion loop
			args.reduce(self) do |f, arg|
				Application.new(function: f, argument: arg)
			end
		end

		def unfill
			attributes.reduce(self.class.new) do |f, attr|
				if send(attr.name).nil?
					f
				else
					Application.new(function: f, argument: send(attr.name))
				end
			end
		end

		def as_json
			if (unfilled = unfill).class != self.class
				unfilled.as_json
			else
				self.class.name.split(/::/).last.tr("_", "/")
			end
		end

		protected

		def attributes
			self.class.value_semantics.attributes
		end

		def fill_next_if_valid(value)
			with(attributes.each_with_object({}) do |attr, h|
				if !send(attr.name).nil?
					h[attr.name] = send(attr.name)
				elsif attr.validate?(value)
					h[attr.name] = value
					value = nil
				else
					return nil
				end
			end)
		end

		def full?
			attributes.all? { |attr| !send(attr.name).nil? }
		end

		def fill_or_call(arg, &block)
			full? ? block[arg] : fill_next_if_valid(arg)
		end
	end

	module Builtins
		# rubocop:disable Style/ClassAndModuleCamelCase

		class Double_show < Builtin
			def call(arg)
				if arg.is_a?(Double)
					Text.new(value: arg.to_s)
				else
					super
				end
			end
		end

		class Integer_show < Builtin
			def call(arg)
				if arg.is_a?(Integer)
					Text.new(value: arg.to_s)
				else
					super
				end
			end
		end

		class Integer_toDouble < Builtin
			def call(arg)
				if arg.is_a?(Integer)
					Double.new(value: arg.value.to_f)
				else
					super
				end
			end
		end

		class Natural_build < Builtin
			def fusion(arg, *bogus)
				if bogus.empty? &&
				   arg.is_a?(Application) &&
				   arg.function == Natural_fold.new
					arg.argument
				else
					super
				end
			end

			def call(arg)
				arg.call(
					Variable.new(name: "Natural"),
					Function.of_arguments(
						Variable.new(name: "Natural"),
						body: Variable["_"] + Natural.new(value: 1)
					),
					Natural.new(value: 0)
				)
			end
		end

		class Natural_even < Builtin
			def call(nat)
				if nat.is_a?(Natural)
					Bool.new(value: nat.even?)
				else
					super
				end
			end
		end

		class Natural_fold < Builtin
			include(ValueSemantics.for_attributes do
				nat  Either(nil, Natural),    default: nil
				type Either(nil, Expression), default: nil
				f    Either(nil, Expression), default: nil
			end)

			def call(arg)
				fill_or_call(arg) do
					if @nat.zero?
						arg.normalize
					else
						@f.call(with(nat: nat.pred).call(arg))
					end
				end || super
			end
		end

		class Natural_isZero < Builtin
			def call(nat)
				if nat.is_a?(Natural)
					Bool.new(value: nat.zero?)
				else
					super
				end
			end
		end

		class Natural_odd < Builtin
			def call(nat)
				if nat.is_a?(Natural)
					Bool.new(value: nat.odd?)
				else
					super
				end
			end
		end

		class Natural_show < Builtin
			def call(nat)
				if nat.is_a?(Natural)
					Text.new(value: nat.to_s)
				else
					super
				end
			end
		end

		class Natural_toInteger < Builtin
			def call(nat)
				if nat.is_a?(Natural)
					Integer.new(value: nat.value)
				else
					super
				end
			end
		end

		class List_build < Builtin
			include(ValueSemantics.for_attributes do
				type Either(nil, Expression), default: nil
			end)

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

			def call(arg)
				fill_or_call(arg) do
					arg.call(
						Variable["List"].call(type),
						cons,
						EmptyList.new(element_type: type)
					)
				end
			end

			protected

			def cons
				Function.of_arguments(
					type,
					Variable["List"].call(type.shift(1, "_", 0)),
					body: List.of(Variable["_", 1]).concat(Variable["_"])
				)
			end
		end

		class List_fold < Builtin
			include(ValueSemantics.for_attributes do
				ltype Either(nil, Expression), default: nil
				list  Either(nil, List),       default: nil
				ztype Either(nil, Expression), default: nil
				f     Either(nil, Expression), default: nil
			end)

			def call(arg)
				fill_or_call(arg) do
					list.reduce(arg, &f).normalize
				end || super
			end
		end

		class List_head < Builtin
			include(ValueSemantics.for_attributes do
				type Either(nil, Expression), default: nil
			end)

			def call(arg)
				fill_or_call(arg) do
					if arg.is_a?(List)
						arg.first
					else
						super
					end
				end
			end
		end

		class List_indexed < Builtin
			include(ValueSemantics.for_attributes do
				type Either(nil, Expression), default: nil
			end)

			def call(arg)
				fill_or_call(arg) do
					if arg.is_a?(List)
						_call(arg)
					else
						super
					end
				end
			end

			protected

			def _call(arg)
				arg.map(type: indexed_type(type)) { |x, idx|
					Record.new(
						record: {
							"index" => Natural.new(value: idx),
							"value" => x
						}
					)
				}.normalize
			end

			def indexed_type(value_type)
				RecordType.new(
					record: {
						"index" => Variable.new(name: "Natural"),
						"value" => value_type
					}
				)
			end
		end

		class List_last < Builtin
			include(ValueSemantics.for_attributes do
				type Either(nil, Expression), default: nil
			end)

			def call(arg)
				fill_or_call(arg) do
					if arg.is_a?(List)
						arg.last
					else
						super
					end
				end
			end
		end

		class List_length < Builtin
			include(ValueSemantics.for_attributes do
				type Either(nil, Expression), default: nil
			end)

			def call(arg)
				fill_or_call(arg) do
					if arg.is_a?(List)
						Natural.new(value: arg.length)
					else
						super
					end
				end
			end
		end

		class List_reverse < Builtin
			include(ValueSemantics.for_attributes do
				type Either(nil, Expression), default: nil
			end)

			def call(arg)
				fill_or_call(arg) do
					if arg.is_a?(List)
						arg.reverse
					else
						super
					end
				end
			end
		end

		class Optional_build < Builtin
			include(ValueSemantics.for_attributes do
				type Either(nil, Expression), default: nil
			end)

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

			def call(arg)
				fill_or_call(arg) do
					arg.call(
						Variable["Optional"].call(type),
						some,
						OptionalNone.new(value_type: type)
					)
				end
			end

			protected

			def some
				Function.of_arguments(
					type,
					body: Optional.new(
						value:      Variable["_"],
						value_type: type
					)
				)
			end
		end

		class Optional_fold < Builtin
			include(ValueSemantics.for_attributes do
				type     Either(nil, Expression), default: nil
				optional Either(nil, Optional),   default: nil
				ztype    Either(nil, Expression), default: nil
				f        Either(nil, Expression), default: nil
			end)

			def call(*args)
				args.reduce(self) do |fold, arg|
					fold.fill_or_call(arg) do
						fold.optional.reduce(arg, &fold.f)
					end || super
				end
			end
		end

		class Text_show < Builtin
			ENCODE = (Hash.new { |_, x| "\\u%04x" % x.ord }).merge(
				"\"" => "\\\"",
				"\\" => "\\\\",
				"\b" => "\\b",
				"\f" => "\\f",
				"\n" => "\\n",
				"\r" => "\\r",
				"\t" => "\\t"
			)

			def call(arg)
				if arg.is_a?(Text)
					Text.new(
						value: "\"#{arg.value.gsub(
							/["\$\\\b\f\n\r\t\u0000-\u001F]/,
							&ENCODE
						)}\""
					)
				else
					super
				end
			end
		end

		# rubocop:enable Style/ClassAndModuleCamelCase

		ALL = Hash[constants.map { |c| [c.to_s.tr("_", "/"), const_get(c)] }]
	end
end
