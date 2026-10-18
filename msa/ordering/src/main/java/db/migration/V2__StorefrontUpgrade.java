package db.migration;
import org.flywaydb.core.api.migration.*;
import java.sql.*;
import java.util.*;
public class V2__StorefrontUpgrade extends BaseJavaMigration {
 @Override public Integer getChecksum(){return 2026101801;}
 @Override public boolean canExecuteInTransaction(){return false;}
 public void migrate(Context ctx)throws Exception{
  Connection c=ctx.getConnection();
  add(c,"product","sku","VARCHAR(64)");
  add(c,"ordering","request_key","VARCHAR(64)");add(c,"ordering","product_name","VARCHAR(255)");add(c,"ordering","unit_price","INTEGER");
  index(c,"product","uq_product_sku","sku");index(c,"ordering","uq_order_member_request","member_id,request_key");
 }
 private void add(Connection c,String table,String name,String type)throws SQLException{
  try(ResultSet rs=c.getMetaData().getColumns(c.getCatalog(),null,null,null)){while(rs.next())if(table.equalsIgnoreCase(rs.getString("TABLE_NAME"))&&name.equalsIgnoreCase(rs.getString("COLUMN_NAME")))return;}
  try(Statement s=c.createStatement()){s.executeUpdate("ALTER TABLE "+table+" ADD COLUMN "+name+" "+type+" NULL");}
 }
 private void index(Connection c,String table,String name,String columns)throws SQLException{
  String actual=table;try(ResultSet rs=c.getMetaData().getTables(c.getCatalog(),null,null,new String[]{"TABLE"})){while(rs.next())if(table.equalsIgnoreCase(rs.getString("TABLE_NAME")))actual=rs.getString("TABLE_NAME");}
  try(ResultSet rs=c.getMetaData().getIndexInfo(c.getCatalog(),null,actual,true,false)){while(rs.next())if(name.equalsIgnoreCase(rs.getString("INDEX_NAME")))return;}
  try(Statement s=c.createStatement()){s.executeUpdate("CREATE UNIQUE INDEX "+name+" ON "+table+" ("+columns+")");}
 }
}
