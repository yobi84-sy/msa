package com.example.ordersystem.product.service;

import com.example.ordersystem.product.domain.Product;
import com.example.ordersystem.product.dto.ProductRegisterDto;
import com.example.ordersystem.product.dto.ProductResDto;
import com.example.ordersystem.product.dto.ProductUpdateStockDto;
import com.example.ordersystem.product.repository.ProductRepository;
import jakarta.persistence.EntityNotFoundException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.IOException;
import java.util.List;

@Service
@Transactional
public class ProductService {
    private final ProductRepository productRepository;
    private final S3Service s3Service;

    public ProductService(ProductRepository productRepository, S3Service s3Service) {
        this.productRepository = productRepository;
        this.s3Service = s3Service;
    }

    public Product productCreate(ProductRegisterDto dto, String userId) throws IOException {
        if(productRepository.existsBySku(dto.getSku()))throw new IllegalArgumentException("이미 등록된 품번입니다.");
        if((dto.getImageFile()==null||dto.getImageFile().isEmpty()) && (dto.getImageUrl()==null||dto.getImageUrl().isBlank()))throw new IllegalArgumentException("상품 이미지가 필요합니다.");
        String finalImageUrl = dto.getImageUrl();
        if (dto.getImageFile() != null && !dto.getImageFile().isEmpty()) {
            finalImageUrl = s3Service.uploadFile(dto.getImageFile());
        }

        Long memberId = 1L;
        if (userId != null && !userId.isBlank()) {
            memberId = Long.parseLong(userId);
        }

        return productRepository.save(dto.toEntity(memberId, finalImageUrl));
    }

    @Transactional(readOnly = true)
    public ProductResDto productDetail(Long id){
        Product product = productRepository.findById(id)
                .orElseThrow(() -> new EntityNotFoundException("없는 상품입니다."));
        return toDto(product);
    }

    @Transactional(readOnly = true)
    public List<ProductResDto> productList(){
        return productRepository.findAllByOrderByIdDesc()
                .stream()
                .map(this::toDto)
                .toList();
    }

    public Product updateStockQuantity(ProductUpdateStockDto productUpdateStockDto){
        Product product = productRepository.findById(productUpdateStockDto.getProductId())
                .orElseThrow(() -> new EntityNotFoundException("없는 상품입니다."));
        if (productUpdateStockDto.getProductQuantity() == null) {
            throw new IllegalArgumentException("구매 수량이 없습니다.");
        }
        product.updateStockQuantity(productUpdateStockDto.getProductQuantity());
        return product;
    }

    public Product purchaseProduct(Long id){
        Product product = productRepository.findById(id)
                .orElseThrow(() -> new EntityNotFoundException("없는 상품입니다."));
        product.updateStockQuantity(1);
        return product;
    }

    public ProductResDto edit(Long id,com.example.ordersystem.product.dto.ProductEditDto dto){
        Product p=productRepository.lockById(id).orElseThrow(EntityNotFoundException::new);
        if(productRepository.existsBySkuAndIdNot(dto.sku(),id))throw new IllegalArgumentException("이미 등록된 품번입니다.");
        p.edit(dto.sku(),dto.name(),dto.category(),dto.gender(),dto.sportStyle(),dto.description(),dto.price());return toDto(p);
    }
    public ProductResDto restock(Long id,int quantity){Product p=productRepository.lockById(id).orElseThrow(EntityNotFoundException::new);p.restock(quantity);return toDto(p);}
    private ProductResDto toDto(Product product){
        return ProductResDto.builder()
                .id(product.getId())
                .name(product.getName()).sku(product.getSku())
                .category(product.getCategory()).gender(product.getGender()).sportStyle(product.getSportStyle())
                .description(product.getDescription())
                .imageUrl(product.getImageUrl())
                .price(product.getPrice())
                .stockQuantity(product.getStockQuantity())
                .build();
    }
}
