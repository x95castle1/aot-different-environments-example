package com.example.demo.greeting;

import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;

import com.example.demo.AppProperties;
import com.example.demo.audit.AuditSink;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

/** Reads and writes greetings in this environment's own MongoDB database. */
@RestController
@RequestMapping("/api/greetings")
class GreetingController {

    private final GreetingRepository repository;
    private final AuditSink audit;
    private final AppProperties properties;
    private final String envId;

    GreetingController(GreetingRepository repository, AuditSink audit, AppProperties properties,
            @Value("${app.env.id:local}") String envId) {
        this.repository = repository;
        this.audit = audit;
        this.properties = properties;
        this.envId = envId;
    }

    @GetMapping
    List<Greeting> list() {
        return repository.findAll();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    Greeting create(@RequestHeader(name = "X-Api-Key", required = false) String apiKey,
            @RequestBody NewGreeting request) {
        requireApiKey(apiKey);
        Greeting saved = repository.save(new Greeting(null, request.message(), envId, Instant.now()));
        audit.record("greeting.created", saved.id());
        return saved;
    }

    private void requireApiKey(String provided) {
        String expected = properties.apiKey();
        if (expected == null || expected.isBlank()) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "app.api-key is not configured");
        }
        if (provided == null || !MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8),
                provided.getBytes(StandardCharsets.UTF_8))) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "missing or wrong X-Api-Key");
        }
    }

    record NewGreeting(String message) {
    }
}
