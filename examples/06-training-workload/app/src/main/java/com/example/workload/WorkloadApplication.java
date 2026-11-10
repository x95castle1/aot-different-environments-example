package com.example.workload;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Example 06: an app with real request-path code (validation, JSON, Mongo queries and aggregation,
 * error handling), so that warming it up matters, and so that training its AOT cache with a workload
 * pays off compared with training on startup alone.
 */
@SpringBootApplication
public class WorkloadApplication {

    public static void main(String[] args) {
        SpringApplication.run(WorkloadApplication.class, args);
    }
}
