package com.example.ordersystem.ordering.controller;
import com.example.ordersystem.ordering.dto.OrderCreateDto;
import com.example.ordersystem.ordering.service.OrderingService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
@RestController @RequestMapping("/ordering")
public class OrderingController {
 private final OrderingService service;public OrderingController(OrderingService service){this.service=service;}
 @PostMapping("/create") public Object create(@Valid @RequestBody OrderCreateDto dto,@RequestAttribute("authenticatedMemberId") Long member,@RequestHeader(value="Idempotency-Key",required=false) String key){
  // Compatibility with the old frontend during rollout; new frontend always supplies its persistent key.
  if(key==null)key=java.util.UUID.randomUUID().toString();
  return ResponseEntity.status(201).body(service.create(dto,member,key));
 }
 @GetMapping("/mine") public Object mine(@RequestAttribute("authenticatedMemberId") Long member){return service.mine(member);}
 @GetMapping("/{id}") public Object detail(@PathVariable Long id,@RequestAttribute("authenticatedMemberId") Long member){return service.detail(id,member);}
}
