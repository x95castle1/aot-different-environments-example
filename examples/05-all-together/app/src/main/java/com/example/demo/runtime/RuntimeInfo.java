package com.example.demo.runtime;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.example.common.runtime.Fingerprints;
import com.example.common.runtime.JvmInfo;
import com.example.demo.audit.AuditSink;
import org.bson.Document;

import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.EnumerablePropertySource;
import org.springframework.core.env.PropertySource;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.stereotype.Component;

/**
 * Collects what this instance resolved at startup: profiles, where its config came from, which
 * secrets it holds (as fingerprints, never values), whether Mongo answers, and how the JVM was started.
 */
@Component
public class RuntimeInfo {

    private static final List<String> SECRETS = List.of("spring.mongodb.password", "app.api-key");

    private final ConfigurableEnvironment environment;
    private final MongoTemplate mongo;
    private final AuditSink auditSink;

    RuntimeInfo(ConfigurableEnvironment environment, MongoTemplate mongo, AuditSink auditSink) {
        this.environment = environment;
        this.mongo = mongo;
        this.auditSink = auditSink;
    }

    public Map<String, Object> collect() {
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("envId", environment.getProperty("app.env.id", "local"));
        info.put("activeProfiles", List.of(environment.getActiveProfiles()));
        info.put("configSources", configSources());
        info.put("secretFingerprints", secretFingerprints());
        info.put("mongo", mongo());
        info.put("auditSink", auditSink.getClass().getSimpleName());
        info.put("jvm", JvmInfo.collect());
        return info;
    }

    /** Config Server files and Vault paths this instance loaded, with how many keys each supplied. */
    private List<String> configSources() {
        List<String> names = new ArrayList<>();
        for (PropertySource<?> source : environment.getPropertySources()) {
            String name = source.getName();
            boolean configServer = name.startsWith("configserver:");
            boolean vault = source.getClass().getName().contains("Vault");
            if (configServer || vault) {
                int keys = (source instanceof EnumerablePropertySource<?> e) ? e.getPropertyNames().length : -1;
                names.add((vault ? "vault:" : "") + name + " (" + keys + " keys)");
            }
        }
        return names;
    }

    private Map<String, String> secretFingerprints() {
        Map<String, String> fingerprints = new LinkedHashMap<>();
        for (String key : SECRETS) {
            fingerprints.put(key, Fingerprints.of(environment.getProperty(key)));
        }
        return fingerprints;
    }

    private Map<String, Object> mongo() {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("host", environment.getProperty("spring.mongodb.host", "localhost") + ":"
                + environment.getProperty("spring.mongodb.port", "27017"));
        result.put("database", mongo.getDb().getName());
        result.put("username", environment.getProperty("spring.mongodb.username", "<none>"));
        try {
            Document pong = mongo.executeCommand(new Document("ping", 1));
            result.put("ping", pong.get("ok") != null ? "ok" : pong.toJson());
        }
        catch (RuntimeException ex) {
            result.put("ping", "FAILED: " + ex.getClass().getSimpleName() + ": " + ex.getMessage());
        }
        return result;
    }
}
