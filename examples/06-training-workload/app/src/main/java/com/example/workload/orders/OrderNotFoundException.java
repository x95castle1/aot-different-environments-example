package com.example.workload.orders;

class OrderNotFoundException extends RuntimeException {

    OrderNotFoundException(String id) {
        super("No order " + id);
    }
}
