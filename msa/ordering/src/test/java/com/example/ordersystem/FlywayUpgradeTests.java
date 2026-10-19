package com.example.ordersystem;
import org.junit.jupiter.api.Test;
import org.flywaydb.core.Flyway;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import static org.assertj.core.api.Assertions.*;
class FlywayUpgradeTests {
 @Test void appliesOnlyVisibilityAfterTaxonomyAndPreservesExistingData(){
  var ds=new DriverManagerDataSource("jdbc:h2:mem:incremental;MODE=MySQL;DB_CLOSE_DELAY=-1","sa","");var j=new JdbcTemplate(ds);
  j.execute("create table product(id bigint primary key, name varchar(255), stock_quantity integer)");
  j.execute("create table ordering(id bigint primary key, member_id bigint)");
  j.execute("insert into product values(1,'Existing product',7)");
  var prior=Flyway.configure().dataSource(ds).locations("classpath:db/migration").target("3.1").load();prior.baseline();prior.migrate();
  j.execute("update product set gender='MEN',sport_style='러닝',sku='UNCHANGED01' where id=1");
  var upgrade=Flyway.configure().dataSource(ds).locations("classpath:db/migration").load();assertThat(upgrade.migrate().migrationsExecuted).isEqualTo(1);
  assertThat(j.queryForObject("select stock_quantity from product where id=1",Integer.class)).isEqualTo(7);
  assertThat(j.queryForObject("select sku from product where id=1",String.class)).isEqualTo("UNCHANGED01");
  assertThat(j.queryForObject("select hide_when_sold_out from product where id=1",Boolean.class)).isNull();
  assertThat(upgrade.migrate().migrationsExecuted).isZero();
 }
}
