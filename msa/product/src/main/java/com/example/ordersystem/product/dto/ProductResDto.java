package com.example.ordersystem.product.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

@AllArgsConstructor
@NoArgsConstructor
@Data
@Builder
public class ProductResDto {
    private Long id;
    private String sku;
    private String name;
    private String category;
    private String gender;
    private String sportStyle;
    private boolean hideWhenSoldOut;
    private String description;
    private String imageUrl;
    private int price;
    private int stockQuantity;
}
