package com.example.ordersystem.product.dto;
import jakarta.validation.constraints.*;
public record ProductEditDto(@NotBlank @Pattern(regexp="[A-Za-z0-9][A-Za-z0-9_-]{0,63}") String sku,@NotBlank @Size(max=255) String name,@NotBlank @Pattern(regexp="신발|의류|용품") String category,@NotBlank @Pattern(regexp="MEN|WOMEN|KIDS|UNISEX") String gender,@NotBlank @Pattern(regexp="러닝|트레이닝|오리지널스|축구|스포츠웨어") String sportStyle,@Size(max=1000) String description,@NotNull @Min(0) Integer price) {}
