package com.example.ordersystem;
import io.jsonwebtoken.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.*;
import org.springframework.core.Ordered;
import org.springframework.http.*;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;
@Component
public class JwtAuthFilter implements GlobalFilter,Ordered {
 @Value("${jwt.secretKey}") private String secretKey;
 public int getOrder(){return -100;}
 public Mono<Void> filter(ServerWebExchange exchange,GatewayFilterChain chain){
  String path=exchange.getRequest().getURI().getPath();HttpMethod method=exchange.getRequest().getMethod();
  ServerWebExchange clean=exchange.mutate().request(b->b.headers(h->{h.remove("X-User-Id");h.remove("X-User-Role");})).build();
  boolean publicPath=java.util.Set.of("/health","/actuator/health","/actuator/prometheus").contains(path)||(HttpMethod.POST.equals(method)&&java.util.Set.of("/member-service/member/create","/member-service/member/doLogin","/member-service/member/refresh-token").contains(path))
    ||(HttpMethod.GET.equals(method)&&(path.equals("/product-service/product/list")||path.matches("/product-service/product/\\d+")));
  if(publicPath)return chain.filter(clean);
  try {
   String auth=clean.getRequest().getHeaders().getFirst(HttpHeaders.AUTHORIZATION);
   if(auth==null||!auth.startsWith("Bearer "))throw new IllegalArgumentException();
   Claims c=Jwts.parserBuilder().setSigningKey(secretKey).build().parseClaimsJws(auth.substring(7)).getBody();
   String role=c.get("role",String.class);long id=Long.parseLong(c.getSubject());
   if(id<=0||!("USER".equals(role)||"ADMIN".equals(role)))throw new IllegalArgumentException();
   if(path.startsWith("/product-service/product/")&&!HttpMethod.GET.equals(method)&&!"ADMIN".equals(role)){
    clean.getResponse().setStatusCode(HttpStatus.FORBIDDEN);return clean.getResponse().setComplete();
   }
   return chain.filter(clean.mutate().request(b->b.headers(h->{h.set("X-User-Id",Long.toString(id));h.set("X-User-Role",role);})).build());
  }catch(JwtException|IllegalArgumentException e){clean.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);return clean.getResponse().setComplete();}
 }
}
