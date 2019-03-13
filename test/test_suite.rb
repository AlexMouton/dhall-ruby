# frozen_string_literal: true

require "pathname"

DIRPATH = Pathname.new(File.dirname(__FILE__))
Pathname.glob(DIRPATH + "test_*.rb").each do |path|
	require_relative path.basename
end
