package com.example.ordersystem.common.config;
import org.springframework.context.annotation.*;
import org.springframework.boot.autoconfigure.flyway.FlywayMigrationStrategy;
import java.sql.*;
import java.util.*;
@Configuration
public class MigrationConfiguration {
 @Bean FlywayMigrationStrategy checkedMigration(){return flyway->{
  try(Connection c=flyway.getConfiguration().getDataSource().getConnection()){
   if(!hasTable(c,"flyway_schema_history")){
    requireColumns(c,"member",Set.of("id","login_id","password","role"));
    requireColumns(c,"product",Set.of("id","name","price","stock_quantity","member_id","created_time","updated_time"));
    requireColumns(c,"ordering",Set.of("id","member_id","product_id","quantity","order_status","created_time","updated_time"));
    // Explicit baseline only after the known phase1 schema has been inspected. Never clean/drop/reset.
    flyway.baseline();
   }
  }catch(SQLException e){throw new IllegalStateException("기준 DB 스키마를 확인할 수 없습니다.",e);}
  flyway.migrate();
 };}
 public static boolean hasTable(Connection c,String table)throws SQLException {try(ResultSet rs=c.getMetaData().getTables(c.getCatalog(),null,null,new String[]{"TABLE"})){while(rs.next())if(table.equalsIgnoreCase(rs.getString("TABLE_NAME")))return true;}return false;}
 public static void requireColumns(Connection c,String table,Set<String> required)throws SQLException{
  Set<String> actual=new HashSet<>();try(ResultSet rs=c.getMetaData().getColumns(c.getCatalog(),null,null,null)){while(rs.next())if(table.equalsIgnoreCase(rs.getString("TABLE_NAME")))actual.add(rs.getString("COLUMN_NAME").toLowerCase(Locale.ROOT));}
  if(!actual.containsAll(required))throw new IllegalStateException("알 수 없는 1차 DB 구조: "+table);
 }
}
