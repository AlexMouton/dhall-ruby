# frozen_string_literal: true

module Dhall
	class Visitor
		def initialize(callbacks)
			@callbacks = callbacks
		end

		def visit(expr)
			expr.to_h.each_with_object({}) do |(attr, value), h|
				if (callback = callback_for(value))
					h[attr] = callback.call(value)
				end
			end
		end

		protected

		def callback_for(x)
			@callbacks.find { |k, _| k === x }&.last
		end
	end
end
