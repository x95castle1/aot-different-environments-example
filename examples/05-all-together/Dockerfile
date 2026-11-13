# syntax=docker/dockerfile:1
#
# Example 05's image. Build context = this folder (it holds the whole Maven build):
#   docker build -t demo-app:1.0.0 .
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
ARG MODULE=app
ARG APP=demo-app
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
# 2. Runtime image + AOT cache trained in the build by only STARTING the app.
#    (Example 06 splits this into an untrained stage, which it trains with a real workload, and this
#    startup-only training for comparison.)
############################
FROM ${JRE_IMAGE}
WORKDIR /app
RUN groupadd --system app && useradd --system --gid app --home /app app
COPY --from=build /extracted/ /app/

# The PROD JVM flags, the one place they're defined. The AOT cache below is trained with exactly these, and
# prod runs with them by not overriding JDK_JAVA_OPTIONS. Other environments override it; if their flags are
# incompatible with the cache (e.g. ZGC on JDK 25) the JVM warns and starts without it.
ENV JDK_JAVA_OPTIONS="-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

# Training run, step by step:
#   - The JVM runs with the prod flags (JDK_JAVA_OPTIONS above), so the cache is
#     recorded under prod settings. -XX:AOTCacheOutput records which classes get loaded and linked,
#     plus method profiles.
#   - -Xmx1g: docker build has no memory limit, so MaxRAMPercentage=75 would size the heap from the BUILD
#     machine's RAM. Above ~43 GB that is a heap over 32 GB, which switches compressed oops off, and a cache
#     recorded without them is rejected by every JVM that has them (any heap under ~32 GB). An explicit heap
#     keeps the cache independent of where the image is built. Its size doesn't matter to the cache: an app
#     that needs more to start can raise it (here and in the check below), staying under ~32 GB.
#   - -Dspring.aot.enabled=true: Spring runs its build-time (Spring AOT) code, as in every environment.
#   - build-time.yml (app/src/main/resources) points Config Server and Vault at
#     unreachable .invalid hosts with fail-fast off, so those imports are skipped. --network=none proves
#     nothing here needs Config Server, Vault or Mongo.
#   - Every bean is created (the Mongo client doesn't connect until first use).
#   - -Dspring.context.exit=onRefresh: Spring exits as soon as the application context is ready, before
#     the web server takes any request.
#   - The JVM exits normally and JDK 25 assembles what it recorded into /app/app.aot.
# Result: a cache of what runs during STARTUP only. Request-path code (validation, JSON, DB queries, error
# handling) was never run, so it isn't in it; example 06 shows training with a real workload for that.
RUN --network=none java \
      -XX:AOTCacheOutput=/app/app.aot -Xmx1g \
      -Dspring.aot.enabled=true \
      -Dspring.config.additional-location=optional:classpath:/build-time.yml \
      -Dspring.context.exit=onRefresh \
      -jar /app/app.jar \
 && ls -lh /app/app.aot

# Check the cache: start once more with -XX:AOTMode=on, which turns an unusable cache into an error. A cache the
# environments couldn't use fails the build here, instead of being shipped and silently ignored. The heap is
# explicit again, and the same as in training: any heap under ~32 GB tests the same thing (compressed oops on),
# and one the app has just started in can't make this step fail for lack of memory.
RUN --network=none java \
      -XX:AOTCache=/app/app.aot -XX:AOTMode=on -Xmx1g \
      -Dspring.aot.enabled=true \
      -Dspring.config.additional-location=optional:classpath:/build-time.yml \
      -Dspring.context.exit=onRefresh \
      -jar /app/app.jar

USER app
EXPOSE 8080
ENTRYPOINT ["java", "-XX:AOTCache=/app/app.aot", "-Dspring.aot.enabled=true", "-jar", "/app/app.jar"]

# Traceability. Last, so they don't invalidate the layers above.
ARG REVISION=unknown
ARG CREATED=unknown
ARG APP=demo-app
LABEL org.opencontainers.image.title="${APP}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"
