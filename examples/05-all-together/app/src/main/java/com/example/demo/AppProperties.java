package com.example.demo;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Application settings. Every value can differ per environment and is resolved at startup
 * (Config Server for {@code audit.sink}, Vault for {@code api-key}).
 *
 * @param apiKey key required on write requests ({@code X-Api-Key}); comes from Vault
 * @param audit  audit settings
 */
@ConfigurationProperties("app")
public record AppProperties(String apiKey, Audit audit) {

    public AppProperties {
        audit = (audit != null) ? audit : new Audit(null);
    }

    /** @param sink where audit events go: {@code log} or {@code mongo} */
    public record Audit(String sink) {
    }
}
