package com.example.demo.runtime;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

/** Short SHA-256 prefix of a secret, so you can tell secrets apart in logs without printing them. */
public final class Fingerprints {

    private Fingerprints() {
    }

    public static String of(String value) {
        if (value == null || value.isEmpty()) {
            return "<missing>";
        }
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            return "sha256:" + HexFormat.of().formatHex(hash, 0, 6);
        }
        catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException(ex);
        }
    }
}
