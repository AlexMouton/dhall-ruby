require "abnf"

require "dhall/parser"
require "dhall/util"

class RegexpTree::CharClass
	def encode_elt(e)
		case e
		when 0x09; '\t'
		when 0x0a; '\n'
		when 0x0d; '\r'
		when 0x0c; '\f'
		when 0x0b; '\v'
		when 0x07; '\a'
		when 0x1b; '\e'
		when 0x21, 0x22, 0x25, 0x26, 0x27, 0x2c, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x2f, 0x30..0x39, 0x40, 0x41..0x5a, 0x5f, 0x60, 0x61..0x7a, 0x7e
			sprintf("%c", e)
		else
			sprintf("\\u{%02x}", e)
		end
	end
end

class Sequence
	attr_reader :seq

	def initialize(*seq)
		@seq = seq
	end

	def +(other)
		if other.is_a?(Sequence)
			self.class.new(*seq, *other.seq)
		else
			self.class.new(*seq, other)
		end
	end

	def to_s
		@seq.join(' ')
	end
end

class Terminal
	SAFE = /\A[\w_:']+\Z/

	def initialize(regex)
		@regex = regex
	end

	def +(other)
		if options == other.options
			self.class.new(Regexp.compile("#{source}#{other.source}", options))
		else
			Sequence.new(self, other)
		end
	end

	def options
		@regex.options
	end

	def source
		if SAFE =~ @regex.source
			@regex.source
		else
			"(?:#{@regex.source})"
		end
	end

	def to_s
		if SAFE =~ @regex.source
			if @regex.casefold?
				"`#{@regex.source}`"
			else
				@regex.source.inspect
			end
		else
			@regex.inspect
		end
	end
end

class RuleFormatter
	def initialize(abnf)
		@abnf = abnf
		@bogus = 0
	end

	def bogus_name
		"____#{@bogus += 1}".intern
	end

	def format_anon_rule(rule)
		name = bogus_name
		@abnf[name] = rule
		formatted = format_rule(name, rule)
		formatted.is_a?(Terminal) ? formatted : "(#{formatted})"
	end

	def format_rule(name, rule)
		if name == :"simple-label"
			return "keyword simple_label_next_char+ | !keyword (simple_label_first_char simple_label_next_char*)"
		end

		if name == :"nonreserved-label"
			return "reserved_identifier simple_label_next_char+ | !reserved_identifier label"
		end

		case rule
		when ABNF::Term
			Terminal.new(@abnf.regexp(name))
		when ABNF::Var
			rule.name.to_s.gsub(/-/, '_')
		when ABNF::Seq
			if rule.elts.empty?
				'""'
			else
				rule.elts.map(&method(:format_anon_rule)).chunk { |x| x.is_a?(Terminal) }.flat_map { |(terminal, chunk)|
					terminal ? chunk.reduce(:+) : Sequence.new(chunk)
				}.join(' ')
			end
		when ABNF::Alt
			rule.elts.map(&method(:format_anon_rule)).join(' | ')
		when ABNF::Rep
			base = format_anon_rule(rule.elt)
			if rule.min == 0 && rule.max.nil?
				"#{base}*"
			elsif rule.min == 1 && rule.max.nil?
				"#{base}+"
			elsif rule.min == 0 && rule.max == 1
				"#{base}?"
			else
				"#{base} #{rule.min}*#{rule.max}"
			end
		else
			raise "Unknown rule type: #{rule.inspect}"
		end

	end
end

puts "grammar Dhall::Parser::CitrusParser"
puts "\troot complete_expression"

abnf = ABNF.parse(STDIN.read)
formatter = RuleFormatter.new(abnf)
abnf.each do |name, rule|
	next if name.to_s.start_with?("____")
	puts "rule #{name.to_s.gsub(/-/, '_')}"
	print "\t(#{formatter.format_rule(name, rule)})"
	extension = name.to_s.split(/-/).map(&:capitalize).join
	if Dhall::Parser.const_defined?(extension)
		puts " <Dhall::Parser::#{extension}>"
	else
		puts
	end
	puts "end"
end

puts "rule reserved_identifier"
print "\t"
puts Dhall::Util::BuiltinName::NAMES.map { |name| "\"#{name}\"" }.join(" |\n\t")
puts "end"

puts "end"
