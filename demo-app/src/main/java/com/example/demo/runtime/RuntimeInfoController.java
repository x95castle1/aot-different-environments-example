package com.example.demo.runtime;

import java.util.Map;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
class RuntimeInfoController {

    private final RuntimeInfo runtimeInfo;

    RuntimeInfoController(RuntimeInfo runtimeInfo) {
        this.runtimeInfo = runtimeInfo;
    }

    @GetMapping("/info/runtime")
    Map<String, Object> runtime() {
        return runtimeInfo.collect();
    }
}
