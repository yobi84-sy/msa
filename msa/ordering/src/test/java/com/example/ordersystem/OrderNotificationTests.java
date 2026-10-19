package com.example.ordersystem;
import com.example.ordersystem.ordering.service.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sns.model.*;
import static org.mockito.Mockito.*;
import static org.assertj.core.api.Assertions.*;
class OrderNotificationTests {
 JdbcTemplate jdbc;SnsClient sns;SimpleMeterRegistry meters;
 final String email="arn:aws:sns:ap-northeast-2:021158485482:fixture-email",sms="arn:aws:sns:ap-northeast-2:021158485482:fixture-sms";
 @BeforeEach void setup(){
  jdbc=new JdbcTemplate(new DriverManagerDataSource("jdbc:h2:mem:"+java.util.UUID.randomUUID()+";MODE=MySQL;DB_CLOSE_DELAY=-1","sa",""));
  jdbc.execute("CREATE TABLE order_notification_outbox(id BIGINT AUTO_INCREMENT PRIMARY KEY,order_id BIGINT,channel VARCHAR(8),message VARCHAR(500),status VARCHAR(16) DEFAULT 'PENDING',attempts INT DEFAULT 0,next_attempt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,lease_until TIMESTAMP,lease_token VARCHAR(36),sent_at TIMESTAMP,UNIQUE(order_id,channel))");
  jdbc.execute("CREATE TABLE order_notification_quota(quota_day DATE PRIMARY KEY,attempts INT DEFAULT 0)");sns=mock(SnsClient.class);meters=new SimpleMeterRegistry();
 }
 void queue(long id,String channel){jdbc.update("INSERT INTO order_notification_outbox(order_id,channel,message) VALUES(?,?,?)",id,channel,"Fixture order #"+id);}
 OrderNotificationDispatcher worker(String target,int cap){return new OrderNotificationDispatcher(jdbc,sns,meters,email,target,cap);}
 @Test void deliversBothChannelsAndDoesNotResendSentRows(){queue(1,"EMAIL");queue(1,"SMS");var w=worker(sms,10);w.dispatch();w.dispatch();w.dispatch();verify(sns,times(2)).publish(any(PublishRequest.class));assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM order_notification_outbox WHERE status='SENT'",Integer.class)).isEqualTo(2);}
 @Test void senderFailureRetriesAndStopsAfterFiveAttempts(){queue(1,"EMAIL");when(sns.publish(any(PublishRequest.class))).thenThrow(new RuntimeException("fixture failure"));var w=worker(sms,10);for(int i=0;i<5;i++){jdbc.update("UPDATE order_notification_outbox SET next_attempt=TIMESTAMP '2000-01-01 00:00:00'");w.dispatch();}assertThat(jdbc.queryForObject("SELECT status FROM order_notification_outbox",String.class)).isEqualTo("FAILED");verify(sns,times(5)).publish(any(PublishRequest.class));}
 @Test void smsQuotaPreventsExtraPaidAttemptsAndDefersRatherThanDrops(){queue(1,"SMS");queue(2,"SMS");var w=worker(sms,1);w.dispatch();w.dispatch();verify(sns,times(1)).publish(any(PublishRequest.class));assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM order_notification_outbox WHERE status='PENDING' AND next_attempt>CURRENT_TIMESTAMP",Integer.class)).isEqualTo(1);}
 @Test void absentSmsTargetNeverPublishes(){queue(1,"SMS");worker("",10).dispatch();verifyNoInteractions(sns);assertThat(jdbc.queryForObject("SELECT status FROM order_notification_outbox",String.class)).isEqualTo("SKIPPED");}
 @Test void unrelatedTopicIsRejected(){assertThatThrownBy(()->worker("arn:aws:sns:us-east-1:000000000000:wrong",10)).isInstanceOf(IllegalArgumentException.class);}
}
