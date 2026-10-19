package com.example.ordersystem.ordering.dto;

import jakarta.validation.constraints.*;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class OrderCreateDto {
    @NotNull @Min(1) private Long productId;
    @NotNull @Min(1) @Max(1000) private Integer productCount;
}
