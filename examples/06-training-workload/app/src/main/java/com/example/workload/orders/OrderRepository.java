package com.example.workload.orders;

import java.util.List;

import org.springframework.data.domain.Pageable;
import org.springframework.data.mongodb.repository.MongoRepository;

public interface OrderRepository extends MongoRepository<Order, String> {

    List<Order> findByCustomerOrderByCreatedAtDesc(String customer, Pageable page);

    long countByStatus(Order.Status status);
}
