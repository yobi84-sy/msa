package com.example.ordersystem;
import org.junit.jupiter.api.*;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.*;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import com.example.ordersystem.ordering.service.OrderingService;
import com.example.ordersystem.ordering.dto.OrderCreateDto;
import com.example.ordersystem.ordering.repository.OrderingRepository;
import org.springframework.test.web.servlet.MockMvc;
import javax.sql.DataSource;import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
@SpringBootTest(properties={"order.alerts.enabled=true","order.alerts.dispatch-enabled=false"}) @AutoConfigureMockMvc @ActiveProfiles("test") @Import(OrdersystemApplicationTests.LocalDatabase.class)
class OrdersystemApplicationTests {
 @TestConfiguration static class LocalDatabase {
  @Bean DataSource dataSource(){String url=System.getenv("YOBI_TEST_MYSQL_URL");var ds=url==null?new DriverManagerDataSource("jdbc:h2:mem:ordering;MODE=MySQL;DB_CLOSE_DELAY=-1","sa",""):new DriverManagerDataSource(url,"root",System.getenv("YOBI_TEST_MYSQL_PASSWORD"));var j=new JdbcTemplate(ds);
   j.execute("create table member(id bigint auto_increment primary key, name varchar(255) not null, login_id varchar(255) not null unique, nickname varchar(255) not null, email varchar(255) not null unique, password varchar(255) not null, role enum('ADMIN','USER'), created_time datetime(6), updated_time datetime(6))");
   j.execute("insert into member(id,name,login_id,nickname,email,password,role) values(1,'Phase1','phase1-user','Phase1','phase1@example.com','phase1-password-hash','USER')");
   j.execute("create table product(id bigint auto_increment primary key, name varchar(255) not null, category varchar(255), description varchar(1000), image_url varchar(255), price integer not null, stock_quantity integer not null, member_id bigint not null, created_time datetime(6), updated_time datetime(6))");
   j.execute("create table ordering(id bigint auto_increment primary key, member_id bigint not null, product_id bigint not null, quantity integer not null, order_status enum('ORDERED','CANCELED') not null, created_time datetime(6), updated_time datetime(6))");
   j.execute("insert into ordering(member_id,product_id,quantity,order_status) values(1,99,1,'ORDERED')");return ds;
  }
 }
 @org.springframework.test.context.DynamicPropertySource static void dialect(org.springframework.test.context.DynamicPropertyRegistry r){if(System.getenv("YOBI_TEST_MYSQL_URL")!=null)r.add("spring.jpa.database-platform",()->"org.hibernate.dialect.MySQLDialect");}
 @Autowired JdbcTemplate jdbc;@Autowired OrderingService service;@org.springframework.boot.test.mock.mockito.SpyBean OrderingRepository repository;@Autowired MockMvc mvc;
 @BeforeEach void fixture(){jdbc.update("delete from order_notification_outbox");jdbc.update("delete from ordering where product_id<>99");jdbc.update("delete from product");jdbc.update("insert into product(id,name,price,stock_quantity,member_id) values(1,'Test Shoe',139000,3,1)");}
 @Test void migrationPreservesPriorDataAndAddsNullableFields()throws Exception{
  assertThat(jdbc.queryForObject("select password from member where id=1",String.class)).isEqualTo("phase1-password-hash");
  assertThat(jdbc.queryForObject("select count(*) from ordering where product_id=99",Integer.class)).isEqualTo(1);
  assertThat(jdbc.queryForObject("select gender from product where id=1",String.class)).isNull();
  assertThat(jdbc.queryForObject("select sport_style from product where id=1",String.class)).isNull();
  assertThat(jdbc.queryForObject("select unit_price from ordering where product_id=99",Integer.class)).isNull();
  try(var c=jdbc.getDataSource().getConnection()){String q=c.getMetaData().getIdentifierQuoteString();assertThat(jdbc.queryForObject("select count(*) from "+q+"flyway_schema_history"+q+" where "+q+"version"+q+"='2' and "+q+"success"+q+"=true",Integer.class)).isEqualTo(1);}
 }

 @Test void replayHasSameIdAndOneDeduction(){var d=new OrderCreateDto(1L,1);var a=service.create(d,1L,"request-key-00001");var b=service.create(d,1L,"request-key-00001");assertThat(b.getId()).isEqualTo(a.getId());assertThat(a.getUnitPrice()).isEqualTo(139000);assertThat(a.getProductName()).isEqualTo("Test Shoe");assertThat(jdbc.queryForObject("select stock_quantity from product where id=1",Integer.class)).isEqualTo(2);assertThatThrownBy(()->service.create(new OrderCreateDto(1L,2),1L,"request-key-00001")).hasMessageContaining("같은 요청 키");}
 @Test void twoBuyersCannotOversellLastUnit()throws Exception{jdbc.update("update product set stock_quantity=1 where id=1");var pool=Executors.newFixedThreadPool(2);var gate=new CountDownLatch(1);try{var a=pool.submit(()->{gate.await();try{service.create(new OrderCreateDto(1L,1),1L,"concurrent-key-001");return true;}catch(Exception e){return false;}});var b=pool.submit(()->{gate.await();try{service.create(new OrderCreateDto(1L,1),2L,"concurrent-key-002");return true;}catch(Exception e){return false;}});gate.countDown();assertThat((a.get(10,TimeUnit.SECONDS)?1:0)+(b.get(10,TimeUnit.SECONDS)?1:0)).isEqualTo(1);assertThat(jdbc.queryForObject("select stock_quantity from product where id=1",Integer.class)).isZero();}finally{pool.shutdownNow();}}
 @Test void anonymousAndSpoofedIdentityCannotReadOrders()throws Exception{mvc.perform(get("/ordering/mine").header("X-User-Id","1")).andExpect(status().isUnauthorized());}
 @Test void missingProductAndInvalidQuantityDoNotWrite(){assertThatThrownBy(()->service.create(new OrderCreateDto(88L,1),1L,"missing-product-01")).isInstanceOf(jakarta.persistence.EntityNotFoundException.class);assertThatThrownBy(()->service.create(new OrderCreateDto(1L,0),1L,"bad-quantity-0001")).isInstanceOf(IllegalArgumentException.class);assertThat(jdbc.queryForObject("select stock_quantity from product where id=1",Integer.class)).isEqualTo(3);}
 @Test void ownershipIsCheckedInService(){var order=service.create(new OrderCreateDto(1L,1),1L,"owned-request-001");assertThat(service.mine(2L)).isEmpty();assertThatThrownBy(()->service.detail(order.getId(),2L)).isInstanceOf(jakarta.persistence.EntityNotFoundException.class);}
 @Test void orderSaveFailureRollsBackStock(){
  org.mockito.Mockito.doThrow(new IllegalStateException("injected-test-failure")).when(repository).saveAndFlush(org.mockito.ArgumentMatchers.any());
  try{assertThatThrownBy(()->service.create(new OrderCreateDto(1L,1),1L,"rollback-request-01")).hasMessageContaining("injected-test-failure");}
  finally{org.mockito.Mockito.reset(repository);}
  assertThat(jdbc.queryForObject("select stock_quantity from product where id=1",Integer.class)).isEqualTo(3);
 }
 @Test void concurrentSameKeyReturnsSameOrder()throws Exception{
  var pool=Executors.newFixedThreadPool(2);var gate=new CountDownLatch(1);
  try{var a=pool.submit(()->{gate.await();return service.create(new OrderCreateDto(1L,1),1L,"same-request-0001").getId();});var b=pool.submit(()->{gate.await();return service.create(new OrderCreateDto(1L,1),1L,"same-request-0001").getId();});gate.countDown();assertThat(a.get(10,TimeUnit.SECONDS)).isEqualTo(b.get(10,TimeUnit.SECONDS));assertThat(jdbc.queryForObject("select stock_quantity from product where id=1",Integer.class)).isEqualTo(2);}
  finally{pool.shutdownNow();}
 }

 @Test void committedOrderQueuesOneEmailAndOneSmsButIdempotentReplayDoesNotDuplicate(){
  var dto=new OrderCreateDto(1L,1);var a=service.create(dto,1L,"notification-order-001");service.create(dto,1L,"notification-order-001");
  assertThat(jdbc.queryForObject("select count(*) from order_notification_outbox where order_id=?",Integer.class,a.getId())).isEqualTo(2);
 }
 @Test void notificationEnqueueFailureRollsBackOrderAndStock(){
  jdbc.execute("ALTER TABLE order_notification_outbox ADD CONSTRAINT reject_fixture CHECK(order_id<0)");
  try{assertThatThrownBy(()->service.create(new OrderCreateDto(1L,1),1L,"notification-failure-01")).isInstanceOf(RuntimeException.class);
   assertThat(jdbc.queryForObject("select stock_quantity from product where id=1",Integer.class)).isEqualTo(3);
   assertThat(jdbc.queryForObject("select count(*) from ordering where product_id=1",Integer.class)).isZero();
  }finally{jdbc.execute("ALTER TABLE order_notification_outbox DROP CONSTRAINT reject_fixture");}
 }
}
