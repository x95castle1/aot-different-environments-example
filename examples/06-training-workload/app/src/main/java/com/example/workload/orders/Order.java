package com.example.workload.orders;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.index.Indexed;
import org.springframework.data.mongodb.core.mapping.Document;

@Document("orders")
public record Order(@Id String id, @Indexed String customer, List<Item> items, BigDecimal amount, Status status,
        Instant createdAt) {

    public enum Status { NEW, PAID, SHIPPED, CANCELLED }

    public record Item(String sku, int quantity) {
    }

    Order withStatus(Status newStatus) {
        return new Order(id, customer, items, amount, newStatus, createdAt);
    }
}
