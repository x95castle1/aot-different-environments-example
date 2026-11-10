# syntax=docker/dockerfile:1
#
# One Dockerfile for every example app. Build context = repo root.
#   docker build -f docker/app.Dockerfile --build-arg MODULE=examples/01-jvm-args/app --build-arg APP=jvm-args-app .
#
# Built here, once, with NO network:
#   - Spring AOT bean definitions (mvn package runs process-aot)
#   - JDK AOT cache (class loading/linking + method profiles), trained with the PROD JVM flags
# Decided by each environment at startup:
#   - profiles, config values, secrets, connections, JVM flags

ARG JDK_IMAGE=eclipse-temurin:25-jdk
ARG JRE_IMAGE=eclipse-temurin:25-jre

############################
# 1. Build the jar. Dependencies are downloaded first; the build itself runs offline.
############################
FROM ${JDK_IMAGE} AS build
ARG MODULE
ARG APP
WORKDIR /workspace
COPY . .
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -q -pl "${MODULE}" -am dependency:go-offline dependency:resolve-plugins
# Spring AOT processing happens in this step, with no network at all.
RUN --network=none --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -o -pl "${MODULE}" -am package -DskipTests
# Unpack into the layout the JDK AOT cache needs: app.jar + lib/ (a fixed classpath).
RUN java -Djarmode=tools -jar "${MODULE}/target/${APP}.jar" extract \
      --destination /extracted --application-filename app.jar

############################
# 2. Runtime image WITHOUT an AOT cache (target "untrained").
#    Example 06 trains this exact image with a real workload outside the build, then adds app.aot on top.
############################
FROM ${JRE_IMAGE} AS untrained
WORKDIR /app
RUN groupadd --system app && useradd --system --gid app --home /app app
COPY --from=build /extracted/ /app/

# The PROD JVM flags, the one place they're defined. The AOT cache is trained with exactly these, and
# prod runs with them by not overriding JDK_JAVA_OPTIONS. Other environments override it; if their
# flags are incompatible with the cache (e.g. ZGC on JDK 25) the JVM warns and starts without it.
ENV JDK_JAVA_OPTIONS="-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

USER app
EXPOSE 8080
# -XX:AOTCache points at the cache the next stage (or example 06's Dockerfile.trained) adds. In this
# stage the file doesn't exist yet: the JVM warns and runs without a cache.
ENTRYPOINT ["java", "-XX:AOTCache=/app/app.aot", "-Dspring.aot.enabled=true", "-jar", "/app/app.jar"]

############################
# 3. Runtime image + AOT cache trained in the build by only STARTING the app
#    (target "context-trained", the default; examples 01-05 use this).
############################
FROM untrained AS context-trained
USER root

# Training run, step by step:
#   - The JVM runs with the prod flags (JDK_JAVA_OPTIONS from the untrained stage), so the cache is
#     recorded under prod settings. -XX:AOTCacheOutput records which classes get loaded and linked,
#     plus method profiles.
#   - -Dspring.aot.enabled=true: Spring runs its build-time (Spring AOT) code, as in every environment.
#   - build-time.yml (only apps that import remote config have one) points Config Server and Vault at
#     unreachable .invalid hosts with fail-fast off, so those imports are skipped. --network=none proves
#     nothing here needs Config Server, Vault or Mongo.
#   - Every bean is created (the Mongo client doesn't connect until first use).
#   - -Dspring.context.exit=onRefresh: Spring exits as soon as the application context is ready, before
#     the web server takes any request.
#   - The JVM exits normally and JDK 25 assembles what it recorded into /app/app.aot.
# Result: a cache of what runs during STARTUP only. Request-path code (validation, JSON, DB queries, error
# handling) was never run, so it isn't in it; example 06 shows training with a real workload for that.
RUN --network=none java \
      -XX:AOTCacheOutput=/app/app.aot \
      -Dspring.aot.enabled=true \
      -Dspring.config.additional-location=optional:classpath:/build-time.yml \
      -Dspring.context.exit=onRefresh \
      -jar /app/app.jar \
 && ls -lh /app/app.aot

USER app

# Traceability for promotion (example 04). Last, so they don't invalidate the layers above.
ARG REVISION=unknown
ARG CREATED=unknown
ARG APP
LABEL org.opencontainers.image.title="${APP}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"
