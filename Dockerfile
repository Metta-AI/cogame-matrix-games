# Matrix Games game + player image. One image, two entrypoints:
#   /bin/matrix-games         the game server (default)
#   /bin/matrix-games-player  the thin prompt-carrying player
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/matrix_games
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# A committed nim.cfg would pin the author's machine package paths; rebuild it
# from this container's synced package tree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/matrix-games-nimcache --out:matrix-games \
    src/matrix_games.nim && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/matrix-games-player-nimcache --out:matrix-games-player \
    src/matrix_games_player.nim

# Run image.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/matrix_games
COPY --from=build /workspace/matrix_games/matrix-games /bin/matrix-games
COPY --from=build /workspace/matrix_games/matrix-games-player \
  /bin/matrix-games-player
COPY --from=build /workspace/matrix_games/data ./data
COPY --from=build /workspace/matrix_games/client ./client

CMD ["/bin/matrix-games"]
