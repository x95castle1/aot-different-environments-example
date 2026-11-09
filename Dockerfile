# syntax=docker/dockerfile:1
#
# demo-app: ONE image deployed unchanged to every environment.
#
# Built here, once:
#   - Spring AOT bean definitions (mvn package runs process-aot)
#   - JDK AOT cache (class loading/linking + method profiles), trained with the PROD JVM flags
# Decided by each environment at startup:
#   - profiles (APP_ENV / APP_ENV_INDEX), Config Server + Vault values, Mongo, JVM flags

############################
# 1. Build the jar (includes Spring AOT processing)
############################
FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace
COPY mvnw pom.xml ./
COPY .mvn .mvn
COPY demo-app/pom.xml demo-app/pom.xml
COPY config-server/pom.xml config-server/pom.xml
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q -pl demo-app -am dependency:go-offline
COPY demo-app/src demo-app/src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -pl demo-app -am package -DskipTests
# Unpack into the layout the JDK AOT cache needs: demo-app.jar + lib/ (fixed classpath).
RUN java -Djarmode=tools -jar demo-app/target/demo-app.jar extract --destination /extracted

############################
# 2. Runtime image + AOT cache training run
############################
FROM eclipse-temurin:25-jre
WORKDIR /app
RUN groupadd --system app && useradd --system --gid app --home /app app
COPY --from=build /extracted/ /app/

# The PROD JVM flags. This is the one place they're defined. The AOT cache below is trained with
# exactly these, and prod runs with them by not overriding JDK_JAVA_OPTIONS. Other environments
# override JDK_JAVA_OPTIONS. If their flags are incompatible with the cache (e.g. ZGC on JDK 25),
# the JVM logs a warning and starts without it.
ENV JDK_JAVA_OPTIONS="-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

# Training run. --network=none proves it needs no Config Server, Vault or Mongo.
# spring.context.exit=onRefresh starts the context (all beans created) and exits before serving.
# build-time.yml turns off fail-fast so the unreachable imports are skipped.
RUN --network=none java \
      -XX:AOTCacheOutput=/app/app.aot \
      -Dspring.aot.enabled=true \
      -Dspring.config.additional-location=classpath:/build-time.yml \
      -Dspring.context.exit=onRefresh \
      -jar /app/demo-app.jar \
 && ls -lh /app/app.aot

USER app
EXPOSE 8080
ENTRYPOINT ["java", "-XX:AOTCache=/app/app.aot", "-Dspring.aot.enabled=true", "-jar", "/app/demo-app.jar"]
