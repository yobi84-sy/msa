package com.example.ordersystem.common.config;
import org.junit.jupiter.api.*;
import org.flywaydb.core.Flyway;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import com.example.ordersystem.common.config.MigrationConfiguration;
import static org.assertj.core.api.Assertions.*;
class CatalogCompatibilityTests {
 @Test void upgradesFirstInstallCatalogWithoutResettingStockOrPrices(){
  String url=System.getenv("YOBI_CATALOG_MYSQL_URL");Assumptions.assumeTrue(url!=null,"Supplemental test requires the owned local MySQL catalog fixture");
  var ds=new DriverManagerDataSource(url,"root",System.getenv("YOBI_TEST_MYSQL_PASSWORD"));var j=new JdbcTemplate(ds);
  var flyway=Flyway.configure().dataSource(ds).locations("classpath:db/migration").load();new MigrationConfiguration().checkedMigration().migrate(flyway);
  assertThat(j.queryForObject("select count(*) from product",Integer.class)).isEqualTo(40);
  assertThat(j.queryForObject("select count(*) from product where gender='UNISEX'",Integer.class)).isEqualTo(12);
  assertThat(j.queryForObject("select stock_quantity from product where sku='JR1094'",Integer.class)).isEqualTo(3);
  assertThat(j.queryForObject("select price from product where sku='JR1094'",Integer.class)).isEqualTo(1);
  assertThat(j.queryForObject("select name from product where sku='JR1094'",String.class)).isEqualTo("Edited fixture");
  assertThat(flyway.migrate().migrationsExecuted).isZero();
 }
}
