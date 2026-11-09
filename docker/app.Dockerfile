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
# 2. Runtime image + AOT cache training run
############################
FROM ${JRE_IMAGE}
WORKDIR /app
RUN groupadd --system app && useradd --system --gid app --home /app app
COPY --from=build /extracted/ /app/

# The PROD JVM flags, the one place they're defined. The AOT cache below is trained with exactly
# these, and prod runs with them by not overriding JDK_JAVA_OPTIONS. Other environments override it;
# if their flags are incompatible with the cache (e.g. ZGC on JDK 25) the JVM warns and starts without it.
ENV JDK_JAVA_OPTIONS="-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

# Training run. --network=none proves it needs no Config Server, Vault or Mongo.
# spring.context.exit=onRefresh creates every bean, then exits before serving traffic.
# build-time.yml (only in apps that import remote config) turns off fail-fast for those imports.
RUN --network=none java \
      -XX:AOTCacheOutput=/app/app.aot \
      -Dspring.aot.enabled=true \
      -Dspring.config.additional-location=optional:classpath:/build-time.yml \
      -Dspring.context.exit=onRefresh \
      -jar /app/app.jar \
 && ls -lh /app/app.aot

USER app
EXPOSE 8080
ENTRYPOINT ["java", "-XX:AOTCache=/app/app.aot", "-Dspring.aot.enabled=true", "-jar", "/app/app.jar"]

# Traceability for promotion (example 04). Last, so they don't invalidate the layers above.
ARG REVISION=unknown
ARG CREATED=unknown
ARG APP
LABEL org.opencontainers.image.title="${APP}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"
