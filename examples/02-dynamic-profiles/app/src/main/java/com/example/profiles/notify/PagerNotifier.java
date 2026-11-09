package com.example.profiles.notify;

class PagerNotifier implements Notifier {

    @Override
    public String send(String message) {
        return "paged the on-call engineer: " + message;
    }
}
