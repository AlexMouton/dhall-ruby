# frozen_string_literal: true

require "pathname"

DIRPATH = Pathname.new(File.dirname(__FILE__))
Pathname.glob(DIRPATH + "test_*.rb").each do |path|
	next if path.basename.to_s == "test_suite.rb"
	require_relative path.basename
end
