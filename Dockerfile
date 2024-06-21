FROM ruby:3.0.0-alpine

RUN apk add git

WORKDIR /app

COPY . .

RUN bundle install --deployment


ENTRYPOINT ["bundle", "exec", "churros_git_bot"]
