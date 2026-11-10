package com.example.workload.runtime;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.example.common.runtime.Fingerprints;
import com.example.common.runtime.JvmInfo;
import org.bson.Document;

import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.EnumerablePropertySource;
import org.springframework.core.env.PropertySource;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * What this instance resolved at startup in its environment: profiles, which Config Server files and Vault
 * paths it loaded, its Mongo database, a per-tier setting, its secret (as a fingerprint) and its JVM flags.
 */
@RestController
class RuntimeInfoController {

    private final ConfigurableEnvironment environment;
    private final MongoTemplate mongo;

    RuntimeInfoController(ConfigurableEnvironment environment, MongoTemplate mongo) {
        this.environment = environment;
        this.mongo = mongo;
    }

    @GetMapping("/info/runtime")
    Map<String, Object> info() {
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("envId", environment.getProperty("app.env.id", "<none>"));
        info.put("activeProfiles", List.of(environment.getActiveProfiles()));
        info.put("configSources", configSources());
        info.put("maxPageSize", environment.getProperty("app.orders.max-page-size", "<default 100>"));
        info.put("mongoPasswordFingerprint", Fingerprints.of(environment.getProperty("spring.mongodb.password")));
        info.put("mongo", mongo());
        info.put("jvm", JvmInfo.collect());
        return info;
    }

    private List<String> configSources() {
        List<String> names = new ArrayList<>();
        for (PropertySource<?> source : environment.getPropertySources()) {
            boolean configServer = source.getName().startsWith("configserver:");
            boolean vault = source.getClass().getName().contains("Vault");
            if (configServer || vault) {
                int keys = (source instanceof EnumerablePropertySource<?> e) ? e.getPropertyNames().length : -1;
                names.add((vault ? "vault:" : "") + source.getName() + " (" + keys + " keys)");
            }
        }
        return names;
    }

    private Map<String, Object> mongo() {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("database", mongo.getDb().getName());
        result.put("username", environment.getProperty("spring.mongodb.username", "<none>"));
        try {
            result.put("ping", mongo.executeCommand(new Document("ping", 1)).get("ok") != null ? "ok" : "?");
        }
        catch (RuntimeException ex) {
            result.put("ping", "FAILED: " + ex.getClass().getSimpleName());
        }
        return result;
    }
}
