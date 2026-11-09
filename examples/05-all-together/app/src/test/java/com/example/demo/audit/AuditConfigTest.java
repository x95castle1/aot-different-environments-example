package com.example.demo.audit;

import org.junit.jupiter.api.Test;

import org.springframework.data.mongodb.core.MongoOperations;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalStateException;
import static org.mockito.Mockito.mock;

class AuditConfigTest {

    private final MongoOperations mongo = mock(MongoOperations.class);

    @Test
    void choosesImplementationFromPropertyAtStartup() {
        assertThat(AuditConfig.create("log", mongo)).isInstanceOf(LogAuditSink.class);
        assertThat(AuditConfig.create("MONGO", mongo)).isInstanceOf(MongoAuditSink.class);
        assertThat(AuditConfig.create(null, mongo)).isInstanceOf(LogAuditSink.class);
    }

    @Test
    void rejectsUnknownSink() {
        assertThatIllegalStateException().isThrownBy(() -> AuditConfig.create("kafka", mongo))
            .withMessageContaining("kafka");
    }
}
