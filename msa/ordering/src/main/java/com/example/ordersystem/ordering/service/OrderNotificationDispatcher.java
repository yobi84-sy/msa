package com.example.ordersystem.ordering.service;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.*;
import org.springframework.scheduling.annotation.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sns.model.PublishRequest;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.core.retry.RetryPolicy;
import io.micrometer.core.instrument.MeterRegistry;
import java.time.*;import java.sql.Timestamp;import java.util.*;
@Configuration @EnableScheduling
@ConditionalOnProperty(name="order.alerts.dispatch-enabled",havingValue="true")
class OrderNotificationConfiguration {
 @Bean(destroyMethod="close") SnsClient orderSnsClient(){return SnsClient.builder().region(Region.AP_NORTHEAST_2).overrideConfiguration(ClientOverrideConfiguration.builder().apiCallTimeout(Duration.ofSeconds(10)).retryPolicy(RetryPolicy.none()).build()).build();}
}
@Component @ConditionalOnProperty(name="order.alerts.dispatch-enabled",havingValue="true")
public class OrderNotificationDispatcher {
 private final JdbcTemplate jdbc;private final SnsClient sns;private final MeterRegistry meters;private final String email,sms;private final int smsLimit;
 public OrderNotificationDispatcher(JdbcTemplate jdbc,SnsClient sns,MeterRegistry meters,@Value("${order.alerts.email-topic:}") String email,@Value("${order.alerts.sms-topic:}") String sms,@Value("${order.alerts.sms-daily-limit:10}") int limit){
  this.jdbc=jdbc;this.sns=sns;this.meters=meters;this.email=email;this.sms=sms;this.smsLimit=limit;
  if(!email.matches("arn:aws:sns:ap-northeast-2:021158485482:[A-Za-z0-9_-]+")||(!sms.isBlank()&&!sms.matches("arn:aws:sns:ap-northeast-2:021158485482:[A-Za-z0-9_-]+"))||limit<0||limit>100)throw new IllegalArgumentException("Invalid reviewed notification targets or SMS limit");
 }
 @Scheduled(fixedDelayString="${order.alerts.poll-ms:5000}")
 public void dispatch(){
  jdbc.update("UPDATE order_notification_outbox SET status='PENDING',lease_token=NULL WHERE status='SENDING' AND lease_until<CURRENT_TIMESTAMP");
  var rows=jdbc.queryForList("SELECT id,channel,message,attempts FROM order_notification_outbox WHERE status='PENDING' AND next_attempt<=CURRENT_TIMESTAMP ORDER BY id LIMIT 1");
  if(rows.isEmpty())return;var row=rows.get(0);long id=((Number)row.get("id")).longValue();String token=UUID.randomUUID().toString();
  if(jdbc.update("UPDATE order_notification_outbox SET status='SENDING',lease_token=?,lease_until=? WHERE id=? AND status='PENDING'",token,Timestamp.from(Instant.now().plusSeconds(60)),id)!=1)return;
  String channel=(String)row.get("channel");String target=channel.equals("SMS")?sms:email;
  if(target.isBlank()){finish(id,token,"SKIPPED");return;}
  if(channel.equals("SMS")&&!reserveSms()){jdbc.update("UPDATE order_notification_outbox SET status='PENDING',lease_token=NULL,next_attempt=? WHERE id=? AND lease_token=?",Timestamp.from(LocalDate.now(ZoneOffset.UTC).plusDays(1).atStartOfDay().toInstant(ZoneOffset.UTC)),id,token);return;}
  try{
   sns.publish(PublishRequest.builder().topicArn(target).message((String)row.get("message")).build());
   jdbc.update("UPDATE order_notification_outbox SET status='SENT',sent_at=CURRENT_TIMESTAMP,lease_token=NULL WHERE id=? AND lease_token=?",id,token);
   meters.counter("order_notification_events","channel",channel,"result","sent").increment();
  }catch(Exception e){
   int attempt=((Number)row.get("attempts")).intValue()+1;
   jdbc.update("UPDATE order_notification_outbox SET status=?,attempts=?,next_attempt=?,lease_token=NULL WHERE id=? AND lease_token=?",attempt>=5?"FAILED":"PENDING",attempt,Timestamp.from(Instant.now().plusSeconds(Math.min(900,30L*(1L<<attempt)))),id,token);
   meters.counter("order_notification_events","channel",channel,"result","failed").increment();
   // Do not log message bodies, recipients, credential errors or arbitrary SDK details.
  }
 }
 private void finish(long id,String token,String status){jdbc.update("UPDATE order_notification_outbox SET status=?,lease_token=NULL WHERE id=? AND lease_token=?",status,id,token);}
 private boolean reserveSms(){
  var day=java.sql.Date.valueOf(LocalDate.now(ZoneOffset.UTC));
  jdbc.update("INSERT INTO order_notification_quota(quota_day,attempts) VALUES(?,0) ON DUPLICATE KEY UPDATE quota_day=quota_day",day);
  return jdbc.update("UPDATE order_notification_quota SET attempts=attempts+1 WHERE quota_day=? AND attempts<?",day,smsLimit)==1;
 }
}
