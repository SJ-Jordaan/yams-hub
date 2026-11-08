# yams-hub-updater (ARCHITECTURE §5.17). Build context = updater/:
#   docker build -f updater/Dockerfile -t yams-hub-updater:latest updater
FROM dart:3.13 AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN mkdir -p /out && dart pub get --offline && dart compile exe bin/updater.dart -o /out/updater

# Static docker CLI + compose plugin (Docker 29.4.3 / API 1.54 on Zenith).
FROM docker:29-cli AS docker-cli

# Not :nonroot: the updater needs the read-write Docker socket.
FROM gcr.io/distroless/cc-debian12
COPY --from=build /out/updater /app/updater
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
USER 0:0
ENV UPDATER_TOKEN_FILE=/run/secrets/updater.env
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s CMD ["/app/updater", "healthcheck"]
ENTRYPOINT ["/app/updater"]
CMD ["serve"]
