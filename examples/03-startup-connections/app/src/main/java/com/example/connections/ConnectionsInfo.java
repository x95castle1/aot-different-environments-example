package com.example.connections;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.example.common.runtime.Fingerprints;
import org.bson.Document;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.aot.AotDetector;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.EnumerablePropertySource;
import org.springframework.core.env.PropertySource;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Where this instance's config and secrets came from, and whether Mongo accepted them. Logged at startup too. */
@RestController
class ConnectionsInfo implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(ConnectionsInfo.class);

    private final ConfigurableEnvironment environment;
    private final MongoTemplate mongo;

    ConnectionsInfo(ConfigurableEnvironment environment, MongoTemplate mongo) {
        this.environment = environment;
        this.mongo = mongo;
    }

    @GetMapping("/info/connections")
    Map<String, Object> info() {
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("envId", environment.getProperty("app.env.id", "<none>"));
        info.put("activeProfiles", List.of(environment.getActiveProfiles()));
        info.put("springAotGeneratedCode", AotDetector.useGeneratedArtifacts());
        info.put("configSources", configSources());
        info.put("mongoPasswordFingerprint", Fingerprints.of(environment.getProperty("spring.mongodb.password")));
        info.put("mongo", mongo());
        return info;
    }

    @Override
    public void run(ApplicationArguments args) {
        Map<String, Object> info = info();
        log.info("Connected at startup: sources={} mongo={} password={}", info.get("configSources"), info.get("mongo"),
                info.get("mongoPasswordFingerprint"));
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
        result.put("host", environment.getProperty("spring.mongodb.host", "localhost"));
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
