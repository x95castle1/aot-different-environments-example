# syntax=docker/dockerfile:1
#
# Example 06's Dockerfile: everything needed to build workload-app, self-contained so it can be copied as a
# template. (The build stage mirrors the shared docker/app.Dockerfile used by examples 01-05; keep them in step.)
#
#   eclipse-temurin:25-jre
#   └─ untrained         (--target untrained)  the app, prod JVM flags, entrypoint; NO AOT cache.
#      │                                       training-pipeline.sh trains this exact image with a real workload,
#      │                                       then Dockerfile.trained adds the cache on top -> workload-trained.
#      └─ context-trained (default target)     + a cache recorded right here, in docker build, by only STARTING
#                                              the app: what examples 01-05 do. Kept for comparison.
#
# Build context = repo root (the Maven reactor and the shared common module live there):
#   docker build -f examples/06-training-workload/Dockerfile --target untrained -t workload-app:untrained .
#   docker build -f examples/06-training-workload/Dockerfile                    -t workload-app:context-trained .

ARG JDK_IMAGE=eclipse-temurin:25-jdk
ARG JRE_IMAGE=eclipse-temurin:25-jre

############################
# 1. Build the jar. Dependencies are downloaded first; the build itself runs offline.
############################
FROM ${JDK_IMAGE} AS build
ARG MODULE=examples/06-training-workload/app
ARG APP=workload-app
WORKDIR /workspace
COPY . .
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -q -pl "${MODULE}" -am dependency:go-offline dependency:resolve-plugins
# Spring AOT processing (bean definitions generated at build time) happens in this step, with no network at all.
RUN --network=none --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -o -pl "${MODULE}" -am package -DskipTests
# Unpack into the layout the JDK AOT cache needs: app.jar + lib/ (a fixed classpath).
RUN java -Djarmode=tools -jar "${MODULE}/target/${APP}.jar" extract \
      --destination /extracted --application-filename app.jar

############################
# 2. "untrained": the runtime image WITHOUT an AOT cache.
#    This is the image training-pipeline.sh runs with -XX:AOTCacheOutput while it serves the workload, and the
#    BASE that Dockerfile.trained adds app.aot to. The cache is only valid for these exact layers (same JDK build,
#    same /app files down to their sizes and timestamps), so the final image must be built on top of this one.
############################
FROM ${JRE_IMAGE} AS untrained
WORKDIR /app
RUN groupadd --system app && useradd --system --gid app --home /app app
COPY --from=build /extracted/ /app/

# The PROD JVM flags. Every training run (here and in training-pipeline.sh) records the cache with exactly these,
# and prod runs with them by not overriding JDK_JAVA_OPTIONS. Other environments override it; if their flags are
# incompatible with the cache (e.g. ZGC on JDK 25) the JVM warns and starts without it.
ENV JDK_JAVA_OPTIONS="-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

USER app
EXPOSE 8080
# -XX:AOTCache points at the cache a later layer adds (stage 3 below, or Dockerfile.trained). In this stage the
# file doesn't exist yet: the JVM warns and runs without a cache.
ENTRYPOINT ["java", "-XX:AOTCache=/app/app.aot", "-Dspring.aot.enabled=true", "-jar", "/app/app.jar"]

############################
# 3. "context-trained" (default target): + a cache recorded in docker build by only STARTING the app.
############################
FROM untrained AS context-trained
USER root

# Training run, step by step:
#   - The JVM runs with the prod flags (JDK_JAVA_OPTIONS above), so the cache is recorded under prod settings.
#     -XX:AOTCacheOutput records which classes get loaded and linked, plus method profiles.
#   - -Dspring.aot.enabled=true: Spring runs its build-time (Spring AOT) code, as in every environment.
#   - build-time.yml points Config Server and Vault at unreachable .invalid hosts with fail-fast off, so those
#     imports are skipped. --network=none proves nothing here needs Config Server, Vault or Mongo.
#   - Every bean is created (the Mongo client doesn't connect until first use).
#   - -Dspring.context.exit=onRefresh: Spring exits as soon as the application context is ready, before the web
#     server takes any request.
#   - The JVM exits normally and JDK 25 assembles what it recorded into /app/app.aot (~76 MB).
# Result: a cache of what runs during STARTUP only. Request-path code (validation, JSON, Mongo queries, error
# handling) never ran, so ~2,150 of its classes are still loaded from the jars on the first requests. Training
# with a real workload (training-pipeline.sh) covers that.
RUN --network=none java \
      -XX:AOTCacheOutput=/app/app.aot \
      -Dspring.aot.enabled=true \
      -Dspring.config.additional-location=optional:classpath:/build-time.yml \
      -Dspring.context.exit=onRefresh \
      -jar /app/app.jar \
 && ls -lh /app/app.aot

USER app

ARG REVISION=unknown
ARG CREATED=unknown
LABEL org.opencontainers.image.title="workload-app" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      com.example.aot.training="startup only (docker build, -Dspring.context.exit=onRefresh)"
