# Churros' git bot

Automates some stuff around Churros' git repositories.

Currently:

- Comments on MRs for Houdini migration progress

## Setup

1. Create a new bot user in your Gitlab instance
2. Create a personal access token for the bot user, with the `api` scope
3. Set the token as the value of an environment variable named `GITLAB_PRIVATE_TOKEN` (for example, in `docker-compose.yml`)

## Usage

```
docker compose up
```

This will spin up a webserver on port `3000` that listens for Gitlab merge request webhooks, on `/mr`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://git.inpt.fr/inp-net/churros-ecosystem/git-bot. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://git.inpt.fr/inp-net/churros-ecosystem/git-bot/-/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the ChurrosGitBot project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://git.inpt.fr/inp-net/churros-ecosystem/git-bot/-/blob/main/CODE_OF_CONDUCT.md).
