package com.example.workload.orders;

import java.util.Optional;

import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

// build-time.yml: like the build, the test never reaches Config Server or Vault.
@WebMvcTest(controllers = OrderController.class,
        properties = "spring.config.additional-location=optional:classpath:/build-time.yml")
class OrderControllerTest {

    @Autowired
    MockMvc mvc;

    @MockitoBean
    OrderRepository orders;

    @MockitoBean
    MongoTemplate mongo;

    @Test
    void createsValidOrder() throws Exception {
        given(orders.save(any())).willAnswer(inv -> inv.getArgument(0));
        mvc.perform(post("/orders").contentType(MediaType.APPLICATION_JSON)
                .content("{\"customer\":\"acme\",\"items\":[{\"sku\":\"A-1\",\"quantity\":2}],\"amount\":12.50}"))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.status").value("NEW"));
    }

    @Test
    void rejectsInvalidOrderWithFieldErrors() throws Exception {
        mvc.perform(post("/orders").contentType(MediaType.APPLICATION_JSON)
                .content("{\"customer\":\"\",\"items\":[],\"amount\":-1}"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.fields.customer").exists())
            .andExpect(jsonPath("$.fields.amount").exists());
    }

    @Test
    void unknownOrderIsNotFound() throws Exception {
        given(orders.findById("nope")).willReturn(Optional.empty());
        mvc.perform(get("/orders/nope")).andExpect(status().isNotFound());
    }
}
