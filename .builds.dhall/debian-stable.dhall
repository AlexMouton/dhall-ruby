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
			wget https://github.com/dhall-lang/dhall-haskell/releases/download/1.21.0/dhall-1.21.0-x86_64-linux.tar.bz2
			tar -xvf dhall-1.21.0-x86_64-linux.tar.bz2
			export PATH="$(pwd)/bin:$PATH"
			test/normalization/gen
			rubocop
			bundle install --path="../.gems"
			bundle exec ruby -Ilib test/test_suite.rb
			''
		}
	]
}
