package com.example.profiles;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.example.profiles.notify.Notifier;
import com.example.profiles.pitfall.FancyFeature;
import com.example.profiles.pitfall.ProdOnlyAuditor;

import org.springframework.aot.AotDetector;
import org.springframework.context.ApplicationContext;
import org.springframework.core.env.Environment;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** What this instance decided at startup: profiles, values, the chosen notifier, and which pitfall beans exist. */
@RestController
class ProfilesInfoController {

    private final Environment environment;
    private final ApplicationContext context;
    private final Notifier notifier;

    ProfilesInfoController(Environment environment, ApplicationContext context, Notifier notifier) {
        this.environment = environment;
        this.context = context;
        this.notifier = notifier;
    }

    @GetMapping("/info/profiles")
    Map<String, Object> info() {
        Map<String, Object> values = new LinkedHashMap<>();
        for (String key : List.of("app.message", "app.db-name", "app.notifier", "app.fancy-feature", "app.extra")) {
            values.put(key, environment.getProperty(key, "<unset>"));
        }
        Map<String, Object> pitfall = new LinkedHashMap<>();
        pitfall.put("profileProdBeanExists", context.getBeanNamesForType(ProdOnlyAuditor.class).length > 0);
        pitfall.put("conditionalOnPropertyBeanExists", context.getBeanNamesForType(FancyFeature.class).length > 0);

        Map<String, Object> info = new LinkedHashMap<>();
        info.put("envId", environment.getProperty("app.env.id", "<none>"));
        info.put("activeProfiles", List.of(environment.getActiveProfiles()));
        info.put("springAotGeneratedCode", AotDetector.useGeneratedArtifacts());
        info.put("values", values);
        info.put("notifier", notifier.getClass().getSimpleName());
        info.put("notifierSays", notifier.send("disk 90% full"));
        info.put("pitfall", pitfall);
        return info;
    }
}
