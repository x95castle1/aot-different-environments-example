package com.example.connections;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** Example 03: everything environment-specific is fetched at startup from Config Server and Vault. */
@SpringBootApplication
public class ConnectionsApplication {

    public static void main(String[] args) {
        SpringApplication.run(ConnectionsApplication.class, args);
    }
}
