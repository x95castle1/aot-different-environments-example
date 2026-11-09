package com.example.profiles.notify;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * THE RIGHT WAY to vary behaviour per environment with Spring AOT.
 * <p>
 * One bean definition, fixed at build time. The method body still runs at every startup, so it can
 * read the environment's profile-specific value ({@code app.notifier} from application-{profile}.yml).
 * Compare with the {@code pitfall} package, which uses {@code @Profile} and {@code @ConditionalOnProperty}.
 */
@Configuration(proxyBeanMethods = false)
public class NotifierConfig {

    @Bean
    Notifier notifier(@Value("${app.notifier:log}") String kind) {
        return create(kind);
    }

    static Notifier create(String kind) {
        return switch (kind.trim().toLowerCase()) {
            case "log" -> new LogNotifier();
            case "email" -> new EmailNotifier();
            case "pager" -> new PagerNotifier();
            default -> throw new IllegalStateException("Unknown app.notifier '" + kind + "' (expected log, email or pager)");
        };
    }
}
