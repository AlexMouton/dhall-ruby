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
	secrets = ["253ed950-242c-4d53-ba56-5cf1175e7d29"],
	tasks = map Map Map (map Entry Entry (\(sentry: Entry) ->
		sentry // { mapValue = "cd dhall-ruby\n" ++ sentry.mapValue }
	)) [
		[{ mapKey = "lint", mapValue = "make lint" }],
		[{ mapKey = "bundle", mapValue = "bundle install --path=\"../.gems\"" }],
		[{ mapKey = "test", mapValue = "make test" }],
		[{ mapKey = "compile_prelude", mapValue =
			''
			bundle exec ruby -E UTF-8 bin/dhall-compile -e -o /tmp/Prelude dhall-lang/Prelude
			cd /tmp
			. ~/.pinata
			curl -H "pinata_api_key: $PINATA_API_KEY" -H "pinata_secret_api_key: $PINATA_SECRET_API_KEY" https://api.pinata.cloud/pinning/pinFileToIPFS $(find Prelude -type f -printf "-F'file=@%h/%f' ")
			''
		}],
		[{ mapKey = "cache_prelude", mapValue =
			''
			bundle exec ruby -E UTF-8 bin/dhall-compile -co /tmp/PreludeCache dhall-lang/Prelude
			cd /tmp
			. ~/.pinata
			curl -H "pinata_api_key: $PINATA_API_KEY" -H "pinata_secret_api_key: $PINATA_SECRET_API_KEY" https://api.pinata.cloud/pinning/pinFileToIPFS $(find PreludeCache -type f -printf "-F'file=@%h/%f' ")
			''
		}]
	]
}
