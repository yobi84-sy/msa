package db.migration;
import org.flywaydb.core.api.migration.*;
import java.sql.*;
public class V3__ProductTaxonomy extends BaseJavaMigration {
 @Override public Integer getChecksum(){return 2026101802;}
 @Override public boolean canExecuteInTransaction(){return false;}
 public void migrate(Context ctx)throws Exception{
  for(String name:new String[]{"gender","sport_style"}){
   Connection c=ctx.getConnection();boolean exists=false;
   try(ResultSet rs=c.getMetaData().getColumns(c.getCatalog(),null,null,null)){while(rs.next())if("product".equalsIgnoreCase(rs.getString("TABLE_NAME"))&&name.equalsIgnoreCase(rs.getString("COLUMN_NAME")))exists=true;}
   if(!exists)try(Statement s=c.createStatement()){s.executeUpdate("ALTER TABLE product ADD COLUMN "+name+" VARCHAR(255) NULL");}
  }
 }
}
