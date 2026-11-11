package com.example.workload.env;

import org.junit.jupiter.api.Test;

import org.springframework.boot.SpringApplication;
import org.springframework.mock.env.MockEnvironment;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalStateException;

class EnvironmentProfilesPostProcessorTest {

    private final EnvironmentProfilesPostProcessor processor = new EnvironmentProfilesPostProcessor();

    @Test
    void numberedEnvironmentActivatesTierThenEnvironmentProfile() {
        MockEnvironment env = new MockEnvironment().withProperty("APP_ENV", "dev").withProperty("APP_ENV_INDEX", "2");

        processor.postProcessEnvironment(env, new SpringApplication());

        assertThat(env.getActiveProfiles()).containsExactly("dev", "dev2");
        assertThat(env.getProperty("app.env.name")).isEqualTo("dev");
        assertThat(env.getProperty("app.env.index")).isEqualTo("2");
        assertThat(env.getProperty("app.env.id")).isEqualTo("dev2");
    }

    @Test
    void environmentWithoutIndexActivatesTierOnly() {
        MockEnvironment env = new MockEnvironment().withProperty("APP_ENV", "qa");

        processor.postProcessEnvironment(env, new SpringApplication());

        assertThat(env.getActiveProfiles()).containsExactly("qa");
        assertThat(env.getProperty("app.env.id")).isEqualTo("qa");
    }

    @Test
    void keepsProfilesAlreadyRequestedThroughSpringProfilesActive() {
        MockEnvironment env = new MockEnvironment().withProperty("spring.profiles.active", "debug-logging")
            .withProperty("APP_ENV", "prod")
            .withProperty("APP_ENV_INDEX", "1");

        processor.postProcessEnvironment(env, new SpringApplication());

        // Final ordering is up to Spring Boot's config-data processing (at runtime extra profiles end up
        // last, so they override). This post-processor only has to keep them.
        assertThat(env.getActiveProfiles()).containsExactlyInAnyOrder("debug-logging", "prod", "prod1");
    }

    @Test
    void doesNothingWhenAppEnvIsNotSet() {
        MockEnvironment env = new MockEnvironment();

        processor.postProcessEnvironment(env, new SpringApplication());

        assertThat(env.getActiveProfiles()).isEmpty();
        assertThat(env.getPropertySources().contains(EnvironmentProfilesPostProcessor.PROPERTY_SOURCE_NAME)).isFalse();
    }

    @Test
    void rejectsMalformedValues() {
        assertThatIllegalStateException().isThrownBy(() -> processor
            .postProcessEnvironment(new MockEnvironment().withProperty("APP_ENV", "Prod!"), new SpringApplication()))
            .withMessageContaining("APP_ENV");
        assertThatIllegalStateException().isThrownBy(() -> processor.postProcessEnvironment(
                new MockEnvironment().withProperty("APP_ENV", "dev").withProperty("APP_ENV_INDEX", "two"),
                new SpringApplication()))
            .withMessageContaining("APP_ENV_INDEX");
    }

    @Test
    void runsBeforeConfigDataProcessing() {
        assertThat(processor.getOrder())
            .isLessThan(org.springframework.boot.context.config.ConfigDataEnvironmentPostProcessor.ORDER);
    }
}
