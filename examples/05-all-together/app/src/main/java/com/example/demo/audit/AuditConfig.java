package com.example.demo.audit;

import com.example.demo.AppProperties;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.mongodb.core.MongoOperations;

/**
 * The AOT-safe way to vary behaviour per environment.
 * <p>
 * Don't write {@code @Profile("dev") LogAuditSink} / {@code @Profile("prod") MongoAuditSink}: Spring AOT
 * evaluates {@code @Profile} at build time, so whichever profile was active during the build would win
 * everywhere. Instead there is exactly one bean definition (fixed at build time), and this method body,
 * which still runs at startup, picks the implementation from a property the Config Server supplies.
 */
@Configuration(proxyBeanMethods = false)
public class AuditConfig {

    @Bean
    AuditSink auditSink(AppProperties properties, MongoOperations mongo) {
        return create(properties.audit().sink(), mongo);
    }

    static AuditSink create(String sink, MongoOperations mongo) {
        String mode = (sink != null) ? sink.trim().toLowerCase() : "log";
        return switch (mode) {
            case "log" -> new LogAuditSink();
            case "mongo" -> new MongoAuditSink(mongo);
            default -> throw new IllegalStateException("Unknown app.audit.sink '" + sink + "' (expected log or mongo)");
        };
    }
}
