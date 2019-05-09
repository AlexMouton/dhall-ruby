{
	image = "debian/stable",
	packages = [
		"bundler",
		"curl",
		"git-extras",
		"rubocop",
		"ruby"
	],
	repositories = {
		backports = "http://ftp.ca.debian.org/debian/ stretch-backports main"
	},
	sources = ["https://git.sr.ht/~singpolyma/dhall-ruby"],
	environment = { CI = 1 },
	tasks = [
		{ build =
			''
			cd dhall-ruby
			make lint
			bundle install --path="../.gems"
			make test
			bundle exec ruby -E UTF-8 bin/dhall-compile -e -o /tmp/Prelude dhall-lang/Prelude
			tar -cJf Prelude.tar.xz /tmp/Prelude/
			curl -F'file=@Prelude.tar.xz' http://0x0.st
			''
		}
	]
}
