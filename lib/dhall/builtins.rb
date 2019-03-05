# frozen_string_literal: true

require "dhall/ast"

module Dhall
	class Builtin < Expression
		def ==(other)
			self.class == other.class
		end

		def call(*args)
			# Do not auto-normalize builtins to avoid recursion loop
			args.reduce(self) do |f, arg|
				Application.new(function: f, arguments: [arg])
			end
		end
	end

	module Builtins
		# rubocop:disable Style/ClassAndModuleCamelCase

		class Natural_build < Builtin
			def fusion(arg, *bogus)
				if bogus.empty? &&
				   arg.is_a?(Application) &&
				   arg.function == Natural_fold.new &&
				   arg.arguments.length == 1
					arg.arguments.first
				else
					super
				end
			end

			def call(arg)
				arg.call(
					Variable.new(name: "Natural"),
					Function.new(
						"_",
						Variable.new(name: "Natural"),
						Operator::Plus.new(
							lhs: Variable.new(name: "_"),
							rhs: Natural.new(value: 1)
						)
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
			def initialize(nat=nil, type=nil, f=nil)
				@nat = nat
				@type = type
				@f = f
			end

			def call(arg)
				if @nat.nil? && arg.is_a?(Natural)
					Natural_fold.new(arg)
				elsif !@nat.nil? && @type.nil?
					Natural_fold.new(@nat, arg)
				elsif !@nat.nil? && !@type.nil? && @f.nil?
					Natural_fold.new(@nat, @type, arg)
				elsif !@nat.nil? && !@type.nil? && !@f.nil?
					if @nat.zero?
						arg.normalize
					else
						@f.call(Natural_fold.new(@nat.pred, @type, @f).call(arg))
					end
				else
					super
				end
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
			def fusion(*args)
				_, arg, = args
				if arg.is_a?(Application) &&
				   arg.function.is_a?(Application) &&
				   arg.function.function == List_fold.new &&
				   arg.arguments.length == 1
					arg.arguments.first
				else
					super
				end
			end
		end

		class List_fold < Builtin
			def initialize(ltype=nil, list=nil, ztype=nil, f=nil)
				@ltype = ltype
				@list = list
				@ztype = ztype
				@f = f
			end

			def call(arg)
				if @ltype.nil?
					List_fold.new(arg)
				elsif @list.nil?
					List_fold.new(@ltype, arg)
				elsif @ztype.nil?
					List_fold.new(@ltype, @list, arg)
				elsif @f.nil?
					List_fold.new(@ltype, @list, @ztype, arg)
				else
					@list.reduce(arg, &@f).normalize
				end
			end
		end

		class List_head < Builtin
			def call(arg)
				if arg.is_a?(List)
					arg.first
				else
					super
				end
			end
		end

		class List_indexed < Builtin
			def call(arg)
				if arg.is_a?(List)
					arg.map(type: RecordType.new(
						"index" => Variable.new(name: "Natural"),
						"value" => arg.type
					)) do |x, idx|
						Record.new(
							"index" => Natural.new(value: idx),
							"value" => x
						)
					end
				else
					super
				end
			end
		end

		class List_last < Builtin
			def call(arg)
				if arg.is_a?(List)
					arg.last
				else
					super
				end
			end
		end

		class List_length < Builtin
			def call(arg)
				if arg.is_a?(List)
					Natural.new(value: arg.length)
				else
					super
				end
			end
		end

		class List_reverse < Builtin
			def call(arg)
				if arg.is_a?(List)
					arg.reverse
				else
					super
				end
			end
		end

		class Optional_build < Builtin
			def fusion(*args)
				_, arg, = args
				if arg.is_a?(Application) &&
				   arg.function.is_a?(Application) &&
				   arg.function.function == Optional_fold.new &&
				   arg.arguments.length == 1
					arg.arguments.first
				else
					super
				end
			end
		end

		class Optional_fold < Builtin
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

		ALL = Hash[constants.map { |c| [c.to_s.tr("_", "/"), const_get(c)] }]
	end
end
