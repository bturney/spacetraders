FROM hexpm/elixir:1.18.4-erlang-27.3.4-alpine-3.21.3 AS build

RUN apk add --no-cache build-base git npm

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets
COPY .formatter.exs .

RUN mix compile && mix assets.deploy
RUN mix release

FROM alpine:3.21 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs sqlite-libs

WORKDIR /app
ENV PHX_SERVER=true
COPY --from=build /app/_build/prod/rel/spacetraders ./

EXPOSE 4000
CMD ["bin/spacetraders", "start"]
