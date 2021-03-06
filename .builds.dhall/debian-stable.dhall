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
	secrets = ["c2675a05-0d2f-4f45-af27-0af04a1fb9fe"],
	tasks = map Map Map (map Entry Entry (\(sentry: Entry) ->
		sentry // { mapValue = "cd dhall-ruby\n" ++ sentry.mapValue }
	)) [
		[{ mapKey = "lint", mapValue = "make lint" }],
		[{ mapKey = "bundle", mapValue = "bundle install --path=\"../.gems\"" }],
		[{ mapKey = "test", mapValue = "make test" }],
		[{ mapKey = "compile_prelude", mapValue =
			''
			cd dhall-lang
			VERSION="$(git describe --tags)"
			cd ..
			bundle exec ruby -E UTF-8 bin/dhall-compile -e -o /tmp/Prelude dhall-lang/Prelude
			cd /tmp
			curl -H @$HOME/.pinata https://api.pinata.cloud/pinning/pinFileToIPFS -FpinataOptions="{\"cidVersion\": 1}" -FpinataMetadata="{\"name\": \"Prelude $VERSION $(date -I)\"}" $(find Prelude -type f -printf "-Ffile=@%h/%f;filename=%h/%f ")
			''
		}],
		[{ mapKey = "cache_prelude", mapValue =
			''
			cd dhall-lang
			VERSION="$(git describe --tags)"
			cd ..
			bundle exec ruby -E UTF-8 bin/dhall-compile -co /tmp/PreludeCache dhall-lang/Prelude
			cd /tmp
			curl -H @$HOME/.pinata https://api.pinata.cloud/pinning/pinFileToIPFS -FpinataOptions="{\"cidVersion\": 1}" -FpinataMetadata="{\"name\": \"Prelude Cache $VERSION $(date -I)\"}" $(find PreludeCache -type f -printf "-Ffile=@%h/%f;filename=%h/%f ")
			''
		}]
	]
}
