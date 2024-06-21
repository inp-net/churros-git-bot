FROM ruby:3.0.0-alpine

RUN apk add git build-base

WORKDIR /app

COPY . .

RUN bundle install --deployment


ENTRYPOINT ["bundle", "exec", "churros_git_bot"]
