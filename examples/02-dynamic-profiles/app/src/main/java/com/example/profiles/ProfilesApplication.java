package com.example.profiles;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Example 02: active profiles decided at startup ({@code APP_ENV} + {@code APP_ENV_INDEX}, see
 * {@link com.example.profiles.env.EnvironmentProfilesPostProcessor}), with Spring AOT on.
 */
@SpringBootApplication
public class ProfilesApplication {

    public static void main(String[] args) {
        SpringApplication.run(ProfilesApplication.class, args);
    }
}
