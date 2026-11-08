FROM dart:3.13 AS build
WORKDIR /src
COPY packages/yams_models/ packages/yams_models/
COPY gateway/pubspec.yaml gateway/pubspec.lock gateway/
RUN cd gateway && dart pub get
COPY gateway/ gateway/
RUN mkdir -p /out && cd gateway && dart pub get --offline && dart compile exe bin/server.dart -o /out/yams-hub

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /out/yams-hub /app/yams-hub
COPY app/build/web /srv/web
USER 64090:64090
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD ["/app/yams-hub", "healthcheck"]
ENTRYPOINT ["/app/yams-hub", "serve"]
