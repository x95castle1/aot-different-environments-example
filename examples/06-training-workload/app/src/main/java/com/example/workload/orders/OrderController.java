package com.example.workload.orders;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import jakarta.validation.Valid;
import org.bson.Document;

import org.springframework.data.domain.PageRequest;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.aggregation.Aggregation;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import static org.springframework.data.mongodb.core.aggregation.Aggregation.group;
import static org.springframework.data.mongodb.core.aggregation.Aggregation.sort;

/** The request paths the training workload exercises (and the demo measures). */
@RestController
@RequestMapping("/orders")
class OrderController {

    private final OrderRepository orders;
    private final MongoTemplate mongo;

    OrderController(OrderRepository orders, MongoTemplate mongo) {
        this.orders = orders;
        this.mongo = mongo;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    Order create(@Valid @RequestBody NewOrder request) {
        List<Order.Item> items = request.items().stream().map(l -> new Order.Item(l.sku(), l.quantity())).toList();
        return orders.save(new Order(null, request.customer(), items, request.amount(), Order.Status.NEW, Instant.now()));
    }

    @GetMapping("/{id}")
    Order get(@PathVariable String id) {
        return orders.findById(id).orElseThrow(() -> new OrderNotFoundException(id));
    }

    @GetMapping
    List<Order> byCustomer(@RequestParam String customer, @RequestParam(defaultValue = "20") int limit) {
        return orders.findByCustomerOrderByCreatedAtDesc(customer, PageRequest.of(0, Math.min(limit, 100)));
    }

    @PutMapping("/{id}/status")
    Order updateStatus(@PathVariable String id, @RequestBody Map<String, Order.Status> body) {
        Order.Status status = body.get("status");
        if (status == null) {
            throw new IllegalArgumentException("status is required");
        }
        Order order = get(id);
        return orders.save(order.withStatus(status));
    }

    /** Count and revenue per status: a Mongo aggregation pipeline on every call. */
    @GetMapping("/stats")
    List<Document> stats() {
        Aggregation pipeline = Aggregation.newAggregation(
                group("status").count().as("orders").sum("amount").as("revenue"),
                sort(org.springframework.data.domain.Sort.Direction.DESC, "orders"));
        return mongo.aggregate(pipeline, "orders", Document.class).getMappedResults();
    }
}
