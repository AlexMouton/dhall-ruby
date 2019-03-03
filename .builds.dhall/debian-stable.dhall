{
	image = "debian/stable",
	packages = [
		"ruby",
		"bundler",
		"rubocop"
	],
	sources = ["https://git.sr.ht/~singpolyma/dhall-ruby"],
	tasks = [
		{ build =
			''
			cd dhall-ruby
			rubocop
			bundle install --path="../.gems"
			bundle exec ruby -Ilib test/test_binary.rb
			''
		}
	]
}
