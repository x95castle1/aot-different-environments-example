package com.example.jvmargs;

import java.util.Map;

import com.example.common.runtime.JvmInfo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Example 01: a plain web app. The point isn't the code but how the same image starts under different JVM flags. */
@SpringBootApplication
@RestController
public class JvmArgsApplication {

    public static void main(String[] args) {
        SpringApplication.run(JvmArgsApplication.class, args);
    }

    /** The flags, GC, heap and CPU count this JVM actually got. */
    @GetMapping("/info/jvm")
    Map<String, Object> jvm() {
        return JvmInfo.collect();
    }
}
