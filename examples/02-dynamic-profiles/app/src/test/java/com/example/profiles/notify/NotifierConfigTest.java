package com.example.profiles.notify;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalStateException;

class NotifierConfigTest {

    @Test
    void choosesImplementationFromPropertyAtStartup() {
        assertThat(NotifierConfig.create("log")).isInstanceOf(LogNotifier.class);
        assertThat(NotifierConfig.create("email")).isInstanceOf(EmailNotifier.class);
        assertThat(NotifierConfig.create(" PAGER ")).isInstanceOf(PagerNotifier.class);
    }

    @Test
    void rejectsUnknownNotifier() {
        assertThatIllegalStateException().isThrownBy(() -> NotifierConfig.create("sms")).withMessageContaining("sms");
    }
}
