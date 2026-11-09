package com.example.common.runtime;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.aot.AotDetector;

/** How this JVM was started: flags, GC, heap, and whether Spring AOT code and the JDK AOT cache are in play. */
public final class JvmInfo {

    private JvmInfo() {
    }

    public static Map<String, Object> collect() {
        List<String> args = ManagementFactory.getRuntimeMXBean().getInputArguments();
        Map<String, Object> info = new LinkedHashMap<>();
        info.put("springAotGeneratedCode", AotDetector.useGeneratedArtifacts());
        info.put("jvmAotCacheFlag", args.stream().filter(a -> a.startsWith("-XX:AOTCache")).findFirst().orElse("<none>"));
        info.put("version", Runtime.version().toString());
        info.put("inputArguments", args);
        info.put("garbageCollectors",
                ManagementFactory.getGarbageCollectorMXBeans().stream().map(GarbageCollectorMXBean::getName).toList());
        info.put("maxHeapMb", Runtime.getRuntime().maxMemory() / (1024 * 1024));
        info.put("availableProcessors", Runtime.getRuntime().availableProcessors());
        info.put("uptimeMs", ManagementFactory.getRuntimeMXBean().getUptime());
        return info;
    }
}
