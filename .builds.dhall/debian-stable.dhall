{
	image = "debian/stable",
	packages = [
		"ruby",
		"bundler",
		"rubocop"
	],
	repositories = {
		backports = "http://ftp.ca.debian.org/debian/ stretch-backports main"
	},
	sources = ["https://git.sr.ht/~singpolyma/dhall-ruby"],
	tasks = [
		{ build =
			''
			cd dhall-ruby
			rubocop
			bundle install --path="../.gems"
			test/normalization/gen
			bundle exec ruby -Ilib test/test_binary.rb
			''
		}
	]
}
