package com.example.ordersystem.product.controller;
import com.example.ordersystem.product.dto.*;
import com.example.ordersystem.product.service.ProductService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import java.io.IOException;
@RestController @RequestMapping("/product")
public class ProductController {
 private final ProductService service;public ProductController(ProductService service){this.service=service;}
 @PostMapping(value="/create",consumes=MediaType.MULTIPART_FORM_DATA_VALUE)
 public ResponseEntity<?> create(@Valid @ModelAttribute ProductRegisterDto dto,@RequestAttribute("authenticatedMemberId") Long member) throws IOException{return ResponseEntity.status(201).body(service.productCreate(dto,member.toString()).getId());}
 @GetMapping("/admin/list") public Object adminList(){return service.adminList();}
 public record Visibility(@NotNull Boolean hideWhenSoldOut){}
 @PutMapping("/{id}/sold-out-visibility") public Object visibility(@PathVariable Long id,@Valid @RequestBody Visibility dto){return service.soldOutVisibility(id,dto.hideWhenSoldOut());}
 @GetMapping("/list") public Object list(){return service.productList();}
 @GetMapping("/{id}") public Object detail(@PathVariable Long id){return service.productDetail(id);}
 @PutMapping("/{id}") public Object edit(@PathVariable Long id,@Valid @RequestBody ProductEditDto dto){return service.edit(id,dto);}
 public record Restock(@NotNull @Min(1) Integer quantity){}
 @PostMapping("/{id}/restock") public Object restock(@PathVariable Long id,@Valid @RequestBody Restock dto){return service.restock(id,dto.quantity());}
 @PutMapping("/updatestock") public ResponseEntity<?> legacyStock(){return ResponseEntity.status(410).body(java.util.Map.of("message","주문 API를 사용해주세요."));}
 @PostMapping("/{id}/purchase") public ResponseEntity<?> legacyPurchase(){return ResponseEntity.status(410).body(java.util.Map.of("message","주문 API를 사용해주세요."));}
}
