package com.example.demo.greeting;

import java.time.Instant;

import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.mapping.Document;

@Document("greetings")
public record Greeting(@Id String id, String message, String env, Instant createdAt) {
}
