package com.example.oneimage;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.example.common.runtime.JvmInfo;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.info.BuildProperties;
import org.springframework.core.env.Environment;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Example 04: one build promoted unchanged through dev, qa and prod. The image carries no environment
 * settings at all; each environment supplies env vars and a config directory mounted at /config.
 */
@SpringBootApplication
@RestController
public class OneImageApplication {

    private final Environment environment;
    private final ObjectProvider<BuildProperties> build;

    OneImageApplication(Environment environment, ObjectProvider<BuildProperties> build) {
        this.environment = environment;
        this.build = build;
    }

    public static void main(String[] args) {
        SpringApplication.run(OneImageApplication.class, args);
    }

    @GetMapping("/info")
    Map<String, Object> info() {
        Map<String, Object> info = new LinkedHashMap<>();
        BuildProperties b = build.getIfAvailable();
        info.put("build", (b != null) ? Map.of("version", b.getVersion(), "time", String.valueOf(b.getTime())) : "<none>");
        info.put("envId", environment.getProperty("app.env.id", "<none>"));
        info.put("activeProfiles", List.of(environment.getActiveProfiles()));
        Map<String, Object> values = new LinkedHashMap<>();
        for (String key : List.of("app.message", "app.region", "app.db-url", "app.support-email")) {
            values.put(key, environment.getProperty(key, "<unset>"));
        }
        info.put("values", values);
        info.put("jvm", JvmInfo.collect());
        return info;
    }
}
