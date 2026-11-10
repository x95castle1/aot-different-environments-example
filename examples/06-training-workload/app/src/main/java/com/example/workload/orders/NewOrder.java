package com.example.workload.orders;

import java.math.BigDecimal;
import java.util.List;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

/** Request body for POST /orders, validated on every request. */
public record NewOrder(@NotBlank @Size(max = 64) String customer,
        @NotNull @Size(min = 1, max = 20) List<@Valid Line> items,
        @NotNull @Positive BigDecimal amount) {

    public record Line(@NotBlank String sku, @Min(1) int quantity) {
    }
}
