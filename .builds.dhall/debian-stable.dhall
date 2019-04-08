{
	image = "debian/stable",
	packages = [
		"bundler",
		"git-extras",
		"rubocop",
		"ruby"
	],
	repositories = {
		backports = "http://ftp.ca.debian.org/debian/ stretch-backports main"
	},
	sources = ["https://git.sr.ht/~singpolyma/dhall-ruby"],
	tasks = [
		{ build =
			''
			cd dhall-ruby
			make lint
			bundle install --path="../.gems"
			make test
			''
		}
	]
}
