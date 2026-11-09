package com.example.profiles.pitfall;

import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

/**
 * PITFALL, kept on purpose for the demo. Don't copy this.
 * <p>
 * Without AOT this bean exists whenever the "prod" profile is active. With Spring AOT, {@code @Profile}
 * is evaluated once, at build time, when no profile was active, so the bean is missing in prod too.
 */
@Component
@Profile("prod")
public class ProdOnlyAuditor {
}
