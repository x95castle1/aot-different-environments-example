package com.example.profiles.notify;

class LogNotifier implements Notifier {

    @Override
    public String send(String message) {
        return "logged: " + message;
    }
}
