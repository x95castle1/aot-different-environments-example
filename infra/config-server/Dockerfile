# syntax=docker/dockerfile:1
# Local stand-in for each environment's Config Server. Not AOT-optimised; it's demo infrastructure.
# Build context = repo root.
FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace
COPY . .
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q -pl infra/config-server -am package -DskipTests

FROM eclipse-temurin:25-jre
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/infra/config-server/target/config-server.jar /app/config-server.jar
ENV CONFIG_REPO=file:/config-repo
EXPOSE 8888
ENTRYPOINT ["java", "-jar", "/app/config-server.jar"]
