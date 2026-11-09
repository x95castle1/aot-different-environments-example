package com.example.profiles.pitfall;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * PITFALL, kept on purpose for the demo. Don't copy this.
 * <p>
 * application-prod.yml sets {@code app.fancy-feature=true}. Without AOT the bean exists in prod. With Spring
 * AOT the condition was evaluated at build time (property false), so it never exists, whatever the environment says.
 */
@Component
@ConditionalOnProperty(name = "app.fancy-feature", havingValue = "true")
public class FancyFeature {
}
