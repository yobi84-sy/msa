package com.example.ordersystem.product.domain;

import com.example.ordersystem.common.domain.BaseTimeEntity;
import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;

@Entity
@NoArgsConstructor
@AllArgsConstructor
@Builder
@Getter
public class Product extends BaseTimeEntity {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false)
    private String name;

    @Column(length=64,unique=true)
    private String sku;

    private String category;
    private String gender;
    private String sportStyle;
    private Boolean hideWhenSoldOut;

    @Column(length = 1000)
    private String description;

    private String imageUrl;

    @Column(nullable = false)
    private Integer price;

    @Column(nullable = false)
    private Integer stockQuantity;

    @Column(nullable = false)
    private Long memberId;

    public void edit(String sku,String name,String category,String gender,String sportStyle,String description,Integer price){this.sku=sku;this.name=name;this.category=category;this.gender=gender;this.sportStyle=sportStyle;this.description=description;this.price=price;}
    public void setSoldOutVisibility(boolean hide){this.hideWhenSoldOut=hide;}
    public void restock(int quantity){if(quantity<=0 || quantity>Integer.MAX_VALUE-this.stockQuantity)throw new IllegalArgumentException("재입고 수량을 확인하세요.");this.stockQuantity+=quantity;}
    public void updateStockQuantity(int stockQuantity){
        if (stockQuantity <= 0) {
            throw new IllegalArgumentException("구매 수량은 1개 이상이어야 합니다.");
        }
        if (this.stockQuantity < stockQuantity) {
            throw new IllegalArgumentException("재고가 부족합니다.");
        }
        this.stockQuantity = this.stockQuantity - stockQuantity;
    }
}
