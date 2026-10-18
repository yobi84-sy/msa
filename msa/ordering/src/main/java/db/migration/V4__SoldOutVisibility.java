package db.migration;
import org.flywaydb.core.api.migration.*;
import java.sql.*;
public class V4__SoldOutVisibility extends BaseJavaMigration {
 @Override public Integer getChecksum(){return 2026101803;}
 @Override public boolean canExecuteInTransaction(){return false;}
 public void migrate(Context ctx)throws Exception{
  Connection c=ctx.getConnection();
  try(ResultSet rs=c.getMetaData().getColumns(c.getCatalog(),null,null,null)){while(rs.next())if("product".equalsIgnoreCase(rs.getString("TABLE_NAME"))&&"hide_when_sold_out".equalsIgnoreCase(rs.getString("COLUMN_NAME")))return;}
  try(Statement s=c.createStatement()){s.executeUpdate("ALTER TABLE product ADD COLUMN hide_when_sold_out BOOLEAN NULL");}
 }
}
