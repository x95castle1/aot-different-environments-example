package com.example.demo.audit;

/** Records audit events. Which implementation is used is decided per environment at startup. */
public interface AuditSink {

    void record(String action, String detail);
}
