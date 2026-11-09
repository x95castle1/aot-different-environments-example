package com.example.profiles.notify;

/** Sends alerts. Which implementation is used differs per environment and is decided at startup. */
public interface Notifier {

    String send(String message);
}
