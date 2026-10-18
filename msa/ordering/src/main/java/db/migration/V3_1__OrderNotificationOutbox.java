package db.migration;
import org.flywaydb.core.api.migration.*;
import java.sql.Statement;
/** Additive: old orders are never queued or resent. Runs before scenario V4. */
public class V3_1__OrderNotificationOutbox extends BaseJavaMigration {
 public Integer getChecksum(){return 2026101803;}
 public void migrate(Context c)throws Exception{try(Statement s=c.getConnection().createStatement()){
  s.execute("CREATE TABLE order_notification_outbox (id BIGINT AUTO_INCREMENT PRIMARY KEY, order_id BIGINT NOT NULL, channel VARCHAR(8) NOT NULL, message VARCHAR(500) NOT NULL, status VARCHAR(16) NOT NULL DEFAULT 'PENDING', attempts INT NOT NULL DEFAULT 0, next_attempt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, lease_until TIMESTAMP NULL, lease_token VARCHAR(36) NULL, sent_at TIMESTAMP NULL, CONSTRAINT uq_order_notification UNIQUE(order_id,channel))");
  s.execute("CREATE TABLE order_notification_quota (quota_day DATE PRIMARY KEY, attempts INT NOT NULL DEFAULT 0)");
 }}
}
