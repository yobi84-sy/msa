package com.example.ordersystem;
import org.junit.jupiter.api.*;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.web.servlet.MockMvc;
import com.example.ordersystem.product.repository.ProductRepository;
import com.example.ordersystem.product.domain.Product;
import com.example.ordersystem.product.service.S3Service;
import com.amazonaws.services.s3.AmazonS3;
import io.jsonwebtoken.Jwts;import io.jsonwebtoken.SignatureAlgorithm;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import static org.assertj.core.api.Assertions.*;
@SpringBootTest @AutoConfigureMockMvc @ActiveProfiles("test")
class OrdersystemApplicationTests {
 @Autowired MockMvc mvc;@Autowired ProductRepository products;@MockBean AmazonS3 s3;@MockBean S3Service files;
 static String token(String role){return "Bearer "+Jwts.builder().setSubject("1").claim("role",role).signWith(SignatureAlgorithm.HS512,"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==").compact();}
 @BeforeEach void clean(){products.deleteAll();}
 @Test void publicReadAndHealthButAdminWrites()throws Exception{
  mvc.perform(get("/product/list")).andExpect(status().isOk());mvc.perform(get("/health")).andExpect(status().isOk());
  mvc.perform(post("/product/create").header("X-User-Role","ADMIN")).andExpect(status().isUnauthorized());
  mvc.perform(post("/product/create").header("Authorization",token("USER"))).andExpect(status().isForbidden());
 }
 @Test void editPreservesStockAndRestockAdds()throws Exception{
  var p=products.save(Product.builder().sku("SKU01").name("Old").category("Shoes").price(100).stockQuantity(3).memberId(1L).build());
  mvc.perform(put("/product/"+p.getId()).header("Authorization",token("ADMIN")).contentType("application/json").content("{\"sku\":\"SKU01\",\"name\":\"New\",\"category\":\"신발\",\"gender\":\"MEN\",\"sportStyle\":\"러닝\",\"description\":\"Updated\",\"price\":200}")).andExpect(status().isOk());
  assertThat(products.findById(p.getId()).orElseThrow().getStockQuantity()).isEqualTo(3);
  mvc.perform(get("/product/"+p.getId())).andExpect(jsonPath("$.gender").value("MEN")).andExpect(jsonPath("$.category").value("신발")).andExpect(jsonPath("$.sportStyle").value("러닝"));
  mvc.perform(post("/product/"+p.getId()+"/restock").header("Authorization",token("ADMIN")).contentType("application/json").content("{\"quantity\":2}")).andExpect(status().isOk()).andExpect(jsonPath("$.stockQuantity").value(5));
  mvc.perform(post("/product/"+p.getId()+"/restock").header("Authorization",token("ADMIN")).contentType("application/json").content("{\"quantity\":-1}")).andExpect(status().isBadRequest());
 }
 @Test void rejectsDuplicateSkuWithoutResettingInventory()throws Exception{
  products.save(Product.builder().sku("SKU01").name("Old").category("Shoes").price(100).stockQuantity(3).memberId(1L).build());
  var p=products.save(Product.builder().sku("SKU02").name("Other").category("Shoes").price(100).stockQuantity(7).memberId(1L).build());
  mvc.perform(put("/product/"+p.getId()).header("Authorization",token("ADMIN")).contentType("application/json").content("{\"sku\":\"SKU01\",\"name\":\"Other\",\"category\":\"신발\",\"gender\":\"MEN\",\"sportStyle\":\"러닝\",\"price\":100}")).andExpect(status().isBadRequest());
  assertThat(products.findById(p.getId()).orElseThrow().getStockQuantity()).isEqualTo(7);
 }
 @Test void rejectsUnknownTaxonomyWithoutChangingProduct()throws Exception{
  var p=products.save(Product.builder().sku("SKU03").name("Legacy").category("Old category").price(100).stockQuantity(7).memberId(1L).build());
  mvc.perform(put("/product/"+p.getId()).header("Authorization",token("ADMIN")).contentType("application/json").content("{\"sku\":\"SKU03\",\"name\":\"Changed\",\"category\":\"신발\",\"gender\":\"UNKNOWN\",\"sportStyle\":\"러닝\",\"price\":100}")).andExpect(status().isBadRequest());
  assertThat(products.findById(p.getId()).orElseThrow().getName()).isEqualTo("Legacy");
  assertThat(products.findById(p.getId()).orElseThrow().getGender()).isNull();
 }
 @Test void acceptsUnisexAndAdditionalSportsWithoutChangingCatalogRules()throws Exception{
  mvc.perform(multipart("/product/create").header("Authorization",token("ADMIN")).param("sku","UNISEX01").param("name","Shared product").param("category","용품").param("gender","UNISEX").param("sportStyle","스포츠웨어").param("price","100").param("stockQuantity","0").param("imageUrl","https://fixture.example/image.png")).andExpect(status().isCreated());
  var p=products.findAll().get(0);
  mvc.perform(put("/product/"+p.getId()).header("Authorization",token("ADMIN")).contentType("application/json").content("{\"sku\":\"UNISEX01\",\"name\":\"Shared product\",\"category\":\"용품\",\"gender\":\"UNISEX\",\"sportStyle\":\"축구\",\"price\":100}")).andExpect(status().isOk()).andExpect(jsonPath("$.gender").value("UNISEX")).andExpect(jsonPath("$.sportStyle").value("축구"));
  assertThat(products.findById(p.getId()).orElseThrow().getStockQuantity()).isZero();
 }
}
