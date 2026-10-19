package com.example.ordersystem.ordering.service;
import com.example.ordersystem.ordering.domain.Ordering;
import com.example.ordersystem.ordering.dto.OrderCreateDto;
import com.example.ordersystem.ordering.repository.OrderingRepository;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.http.HttpStatus;
import java.util.*;
@Service @Transactional(isolation=org.springframework.transaction.annotation.Isolation.READ_COMMITTED)
public class OrderingService {
 private final OrderingRepository orders;private final JdbcTemplate jdbc;private final OrderNotificationOutbox notifications;
 public OrderingService(OrderingRepository orders,JdbcTemplate jdbc,OrderNotificationOutbox notifications){this.orders=orders;this.jdbc=jdbc;this.notifications=notifications;}
 public Ordering create(OrderCreateDto dto,Long member,String key){
  if(dto.getProductId()==null||dto.getProductId()<=0||dto.getProductCount()==null||dto.getProductCount()<=0)throw new IllegalArgumentException("구매 수량은 1 이상이어야 합니다.");
  if(key==null||!key.matches("[A-Za-z0-9_-]{16,64}"))throw new IllegalArgumentException("올바른 주문 요청 키가 필요합니다.");
  var existing=orders.findByMemberIdAndRequestKey(member,key);if(existing.isPresent())return replay(existing.get(),dto);
  var products=jdbc.queryForList("select id,name,price,stock_quantity from product where id=? for update",dto.getProductId());
  if(products.isEmpty())throw new jakarta.persistence.EntityNotFoundException();
  // A concurrent identical request may have committed while this one waited for the product lock.
  existing=orders.findByMemberIdAndRequestKey(member,key);if(existing.isPresent())return replay(existing.get(),dto);
  var p=products.get(0);int changed=jdbc.update("update product set stock_quantity=stock_quantity-?, updated_time=CURRENT_TIMESTAMP where id=? and stock_quantity>=?",dto.getProductCount(),dto.getProductId(),dto.getProductCount());
  if(changed!=1)throw new ResponseStatusException(HttpStatus.CONFLICT,"재고가 부족합니다.");
  Ordering created=orders.saveAndFlush(Ordering.builder().memberId(member).productId(dto.getProductId()).quantity(dto.getProductCount()).requestKey(key).productName((String)p.get("name")).unitPrice(((Number)p.get("price")).intValue()).build());
  notifications.enqueue(created);return created;
 }
 private Ordering replay(Ordering o,OrderCreateDto dto){if(!o.getProductId().equals(dto.getProductId())||!o.getQuantity().equals(dto.getProductCount()))throw new ResponseStatusException(HttpStatus.CONFLICT,"같은 요청 키로 다른 주문을 만들 수 없습니다.");return o;}
 @Transactional(readOnly=true) public List<Ordering> mine(Long member){return orders.findByMemberIdOrderByIdDesc(member);}
 @Transactional(readOnly=true) public Ordering detail(Long id,Long member){return orders.findById(id).filter(o->o.getMemberId().equals(member)).orElseThrow(jakarta.persistence.EntityNotFoundException::new);}
}
