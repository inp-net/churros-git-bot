FROM ruby:3.0.0-alpine

RUN apk add git build-base

WORKDIR /app

COPY Gemfile Gemfile
COPY Gemfile.lock Gemfile.lock
COPY churros_git_bot.gemspec churros_git_bot.gemspec
COPY lib/churros_git_bot/version.rb lib/churros_git_bot/version.rb

RUN bundle install --deployment

COPY . .

RUN bundle install --deployment

ENTRYPOINT ["bundle", "exec", "churros_git_bot"]
