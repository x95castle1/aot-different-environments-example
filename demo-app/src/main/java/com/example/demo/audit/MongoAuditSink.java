package com.example.demo.audit;

import java.time.Instant;

import org.bson.Document;
import org.springframework.data.mongodb.core.MongoOperations;

/** Writes audit events to the {@code audit} collection. Used in qa and prod. */
public class MongoAuditSink implements AuditSink {

    private final MongoOperations mongo;

    public MongoAuditSink(MongoOperations mongo) {
        this.mongo = mongo;
    }

    @Override
    public void record(String action, String detail) {
        mongo.insert(new Document("action", action).append("detail", detail).append("at", Instant.now()), "audit");
    }
}
