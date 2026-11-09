# syntax=docker/dockerfile:1
# Local stand-in for the Config Server. Not AOT-optimised; it's infrastructure for the demo.
FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace
COPY mvnw pom.xml ./
COPY .mvn .mvn
COPY demo-app/pom.xml demo-app/pom.xml
COPY config-server/pom.xml config-server/pom.xml
COPY config-server/src config-server/src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -pl config-server -am package -DskipTests

FROM eclipse-temurin:25-jre
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/config-server/target/config-server.jar /app/config-server.jar
ENV CONFIG_REPO=file:/config-repo
EXPOSE 8888
ENTRYPOINT ["java", "-jar", "/app/config-server.jar"]
