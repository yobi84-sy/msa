package com.example.ordersystem.product.dto;

import com.example.ordersystem.product.domain.Product;
import jakarta.validation.constraints.*;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.springframework.web.multipart.MultipartFile;

@NoArgsConstructor
@AllArgsConstructor
@Data
public class ProductRegisterDto {
    @NotBlank @Size(max=255) private String name;
    @NotBlank @Pattern(regexp="[A-Za-z0-9][A-Za-z0-9_-]{0,63}") private String sku;
    @NotBlank @Pattern(regexp="신발|의류|용품") private String category;
    @NotBlank @Pattern(regexp="MEN|WOMEN|KIDS|UNISEX") private String gender;
    @NotBlank @Pattern(regexp="러닝|트레이닝|오리지널스|축구|스포츠웨어") private String sportStyle;
    @Size(max=1000) private String description;
    private String imageUrl;
    private MultipartFile imageFile;
    @NotNull @Min(0) private Integer price;
    @NotNull @Min(0) private Integer stockQuantity;

    public Product toEntity(Long userId, String finalImageUrl){
        return Product.builder()
                .name(this.name).sku(this.sku)
                .category(this.category).gender(this.gender).sportStyle(this.sportStyle)
                .description(this.description)
                .imageUrl(finalImageUrl)
                .price(this.price)
                .stockQuantity(this.stockQuantity)
                .memberId(userId)
                .build();
    }
}
