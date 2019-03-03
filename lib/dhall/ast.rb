# frozen_string_literal: true

module Dhall
	class Expression; end

	class Application < Expression
		def initialize(f, *args)
			if args.empty?
				raise ArgumentError, "Application requires at least one argument"
			end

			@f = f
			@args = args
		end
	end

	class Function < Expression
		def initialize(var, type, body)
			@var = var
			@type = type
			@body = body
		end
	end

	class Forall < Function; end

	class Bool < Expression
		def initialize(value)
			@value = value
		end
	end

	class Variable < Expression
		def initialize(var, index=0)
			@var = var
			@index = index
		end
	end

	class Operator < Expression
		def initialize(op, lhs, rhs)
			@op = op
			@lhs = lhs
			@rhs = rhs
		end
	end

	class List < Expression
		def initialize(*els)
			@els = els
		end
	end

	class EmptyList < List
		def initialize(type)
			@type = type
		end
	end

	class Optional < Expression
		def initialize(value, type=nil)
			raise TypeError, "value must not be nil" if value.nil?

			@value = value
			@type = type
		end
	end

	class OptionalNone < Optional
		def initialize(type)
			raise TypeError, "type must not be nil" if type.nil?

			@type = type
		end
	end

	class Merge < Expression
		def initialize(record, input, type)
			@record = record
			@input = input
			@type = type
		end
	end

	class RecordType < Expression
		def initialize(record)
			@record = record
		end
	end

	class Record < Expression
		def initialize(record)
			@record = record
		end
	end

	class RecordFieldAccess < Expression
		def initialize(record, field)
			raise TypeError, "field must be a String" unless field.is_a?(String)

			@record = record
			@field = field
		end
	end

	class RecordProjection < Expression
		def initialize(record, *fields)
			unless fields.all? { |x| x.is_a?(String) }
				raise TypeError, "fields must be String"
			end

			@record = record
			@fields = fields
		end
	end

	class UnionType < Expression
		def initialize(record)
			@record = record
		end
	end

	class Union < Expression
		def initialize(tag, value, rest_of_type)
			raise TypeError, "tag must be a string" unless tag.is_a?(String)

			@tag = tag
			@value = value
			@rest_of_type = rest_of_type
		end
	end

	class Constructors < Expression
		extend Gem::Deprecate

		def initialize(arg)
			@arg = arg
		end
		DEPRECATION_WIKI = "https://github.com/dhall-lang/dhall-lang/wiki/" \
		                   "Migration:-Deprecation-of-constructors-keyword"
		deprecate :initialize, DEPRECATION_WIKI, 2019, 4
	end

	class If < Expression
		def initialize(cond, thn, els)
			@cond = cond
			@thn = thn
			@els = els
		end
	end

	class Number < Expression
		def initialize(n)
			@n = n
		end
	end

	class Natural < Number; end
	class Integer < Number; end
	class Double < Number; end

	class Text < Expression
		def initialize(string)
			raise TypeError, "must be a String" unless string.is_a?(String)

			@string = string
		end
	end

	class TextLiteral < Text
		def initialize(*chunks)
			@chunks = chunks
		end
	end

	class Import < Expression
		def initialize(integrity_check, import_type, path)
			@integrity_check = integrity_check
			@import_type = import_type
			@path = path
		end

		class URI
			def initialize(headers, authority, *path, query, fragment)
				@headers = headers
				@authority = authority
				@path = path
				@query = query
				@fragment = fragment
			end
		end

		class Http < URI; end
		class Https < URI; end

		class Path
			def initialize(*path)
				@path = path
			end
		end

		class AbsolutePath < Path; end
		class RelativePath < Path; end
		class RelativeToParentPath < Path; end
		class RelativeToHomePath < Path; end

		class EnvironmentVariable
			def initialize(var)
				@var = var
			end
		end

		class MissingImport; end

		class IntegrityCheck
			def initialize(protocol, data)
				@protocol = protocol
				@data = data
			end
		end
	end

	class Let
		def initialize(var, assign, type=nil)
			@var = var
			@assign = assign
			@type = type
		end
	end

	class LetBlock < Expression
		def initialize(body, *lets)
			unless lets.all? { |x| x.is_a?(Let) }
				raise TypeError, "LetBlock only contains Let"
			end

			@lets = lets
			@body = body
		end
	end

	class TypeAnnotation < Expression
		def initialize(value, type)
			@value = value
			@type = type
		end
	end
end
