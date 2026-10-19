package com.example.ordersystem.ordering.service;
import com.example.ordersystem.ordering.domain.Ordering;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
@Component
public class OrderNotificationOutbox {
 private final JdbcTemplate jdbc;private final boolean enabled;
 public OrderNotificationOutbox(JdbcTemplate jdbc,@Value("${order.alerts.enabled:false}") boolean enabled){this.jdbc=jdbc;this.enabled=enabled;}
 /** Caller is the order transaction. A rollback also removes both notifications. */
 public void enqueue(Ordering order){
  if(!enabled)return;
  long amount=(long)order.getUnitPrice()*order.getQuantity();
  String text="[adidas mall] New order #"+order.getId()+" / quantity "+order.getQuantity()+" / KRW "+amount;
  for(String channel:new String[]{"EMAIL","SMS"})jdbc.update("INSERT INTO order_notification_outbox(order_id,channel,message) VALUES(?,?,?)",order.getId(),channel,text);
 }
}
