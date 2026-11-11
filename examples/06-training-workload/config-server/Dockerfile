# syntax=docker/dockerfile:1
# Example 06's local stand-in for each environment's Config Server (native backend: serves the files mounted at
# /config-repo). Not AOT-optimised; it's demo infrastructure. Built by compose.yml.
# Build context = the example folder (the Maven build lives there):
#   docker build -f config-server/Dockerfile .
FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace
# Only what the config-server build needs (the app's pom too: Maven reads every module of the build), so changing the
# app's code doesn't rebuild this image.
COPY mvnw pom.xml ./
COPY .mvn .mvn
COPY app/pom.xml app/pom.xml
COPY config-server config-server
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q -pl config-server -am package -DskipTests

FROM eclipse-temurin:25-jre
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/config-server/target/config-server.jar /app/config-server.jar
ENV CONFIG_REPO=file:/config-repo
EXPOSE 8888
ENTRYPOINT ["java", "-jar", "/app/config-server.jar"]
