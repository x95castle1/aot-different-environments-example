package com.example.common.env;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

import org.springframework.boot.EnvironmentPostProcessor;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.context.config.ConfigDataEnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.MapPropertySource;
import org.springframework.util.StringUtils;

/**
 * Derives the active profiles from the deployment's environment variables, at startup.
 * <p>
 * {@code APP_ENV=dev} and {@code APP_ENV_INDEX=2} activate the profiles {@code dev,dev2} (tier first,
 * so the numbered environment's settings win). Profiles from {@code SPRING_PROFILES_ACTIVE} are kept and end
 * up last, so an operator-added profile overrides both. It also publishes {@code app.env.name},
 * {@code app.env.index} and {@code app.env.id} for use in config and logs.
 * <p>
 * Runs just before {@link ConfigDataEnvironmentPostProcessor}, so the profiles decide which
 * {@code application-{profile}.yml} files load, what the Config Server returns, and which Vault
 * paths are read. Environment post-processors run on every startup, including with Spring AOT,
 * so none of this is fixed at build time.
 */
public class EnvironmentProfilesPostProcessor implements EnvironmentPostProcessor, Ordered {

    public static final int ORDER = ConfigDataEnvironmentPostProcessor.ORDER - 1;

    static final String PROPERTY_SOURCE_NAME = "appEnvironment";

    private static final Pattern NAME = Pattern.compile("[a-z][a-z0-9-]*");
    private static final Pattern INDEX = Pattern.compile("[0-9]+");

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
        String name = trimToNull(environment.getProperty("APP_ENV"));
        if (name == null) {
            return;
        }
        String index = trimToNull(environment.getProperty("APP_ENV_INDEX"));
        validate(name, NAME, "APP_ENV");
        if (index != null) {
            validate(index, INDEX, "APP_ENV_INDEX");
        }
        String id = (index != null) ? name + index : name;

        addProfile(environment, name);
        addProfile(environment, id);

        Map<String, Object> props = new LinkedHashMap<>();
        props.put("app.env.name", name);
        props.put("app.env.index", (index != null) ? index : "");
        props.put("app.env.id", id);
        environment.getPropertySources().addLast(new MapPropertySource(PROPERTY_SOURCE_NAME, props));
    }

    private static void addProfile(ConfigurableEnvironment environment, String profile) {
        if (!Arrays.asList(environment.getActiveProfiles()).contains(profile)) {
            environment.addActiveProfile(profile);
        }
    }

    private static void validate(String value, Pattern pattern, String variable) {
        if (!pattern.matcher(value).matches()) {
            throw new IllegalStateException(
                    variable + "='" + value + "' is invalid; expected to match " + pattern.pattern());
        }
    }

    private static String trimToNull(String value) {
        return StringUtils.hasText(value) ? value.trim() : null;
    }

    @Override
    public int getOrder() {
        return ORDER;
    }
}
