let map = https://cloudflare-ipfs.com/ipfs/Qmet1UAmpcY8iCWKNJy2SAk79LS88X7A1LyyFuREbs2zko
let Entry = { mapKey: Text, mapValue: Text }
let Map = List Entry
in
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
	tasks = map Map Map (map Entry Entry (\(sentry: Entry) ->
		sentry // { mapValue = "cd dhall-ruby\n" ++ sentry.mapValue }
	)) [
		[{ mapKey = "lint", mapValue = "make lint" }],
		[{ mapKey = "bundle", mapValue = "bundle install --path=\"../.gems\"" }],
		[{ mapKey = "test", mapValue = "make test" }],
		[{ mapKey = "compile_prelude", mapValue =
			''
			bundle exec ruby -E UTF-8 bin/dhall-compile -e -o /tmp/Prelude dhall-lang/Prelude
			tar -cJf Prelude.tar.xz /tmp/Prelude/
			curl -F'file=@Prelude.tar.xz' http://0x0.st
			''
		}],
		[{ mapKey = "cache_prelude", mapValue =
			''
			bundle exec ruby -E UTF-8 bin/dhall-compile -co /tmp/PreludeCache dhall-lang/Prelude
			tar -cJf PreludeCache.tar.xz /tmp/PreludeCache/
			curl -F'file=@PreludeCache.tar.xz' http://0x0.st
			''
		}]
	]
}
