package com.example.demo.runtime;

import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

/** Logs what this instance resolved at startup, so each environment's log shows its own wiring. */
@Component
class StartupReport implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(StartupReport.class);

    private final RuntimeInfo runtimeInfo;

    StartupReport(RuntimeInfo runtimeInfo) {
        this.runtimeInfo = runtimeInfo;
    }

    @Override
    public void run(ApplicationArguments args) {
        StringBuilder report = new StringBuilder("\n===== startup report =====\n");
        runtimeInfo.collect().forEach((key, value) -> append(report, key, value, "  "));
        log.info(report.append("==========================").toString());
    }

    private static void append(StringBuilder out, String key, Object value, String indent) {
        if (value instanceof Map<?, ?> map) {
            out.append(indent).append(key).append(":\n");
            map.forEach((k, v) -> append(out, String.valueOf(k), v, indent + "  "));
        }
        else {
            out.append(indent).append(key).append(": ").append(value).append('\n');
        }
    }
}
