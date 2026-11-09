package com.example.profiles.notify;

class EmailNotifier implements Notifier {

    @Override
    public String send(String message) {
        return "emailed the on-call list: " + message;
    }
}
