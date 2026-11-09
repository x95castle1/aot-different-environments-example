package com.example.demo.audit;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Writes audit events to the log. Used in dev. */
public class LogAuditSink implements AuditSink {

    private static final Logger log = LoggerFactory.getLogger(LogAuditSink.class);

    @Override
    public void record(String action, String detail) {
        log.info("AUDIT {} {}", action, detail);
    }
}
