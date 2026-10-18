package com.example.ordersystem.common.config;
import io.jsonwebtoken.*;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;
@Component
public class ApiSecurityFilter extends OncePerRequestFilter {
 @Value("${jwt.secretKey}") private String key;
 @Override protected void doFilterInternal(HttpServletRequest request,HttpServletResponse response,FilterChain chain) throws ServletException,IOException {
  String path=request.getRequestURI();
  if(path.equals("/health") || path.startsWith("/actuator/") || ("GET".equals(request.getMethod()) && (path.equals("/product/list") || path.matches("/product/\\d+")))){chain.doFilter(request,response);return;}
  String auth=request.getHeader("Authorization");
  try {
   if(auth==null || !auth.startsWith("Bearer "))throw new IllegalArgumentException();
   Claims claims=Jwts.parserBuilder().setSigningKey(key).build().parseClaimsJws(auth.substring(7)).getBody();
   String role=claims.get("role",String.class);long id=Long.parseLong(claims.getSubject());
   if(id<=0 || !("USER".equals(role)||"ADMIN".equals(role)))throw new IllegalArgumentException();
   request.setAttribute("authenticatedMemberId",id);request.setAttribute("authenticatedRole",role);
   if(!"GET".equals(request.getMethod()) && !"ADMIN".equals(role)){response.sendError(403,"관리자 권한이 필요합니다.");return;}
  } catch(JwtException|IllegalArgumentException e){response.sendError(401,"로그인이 필요합니다.");return;}
  chain.doFilter(request,response);
 }
}
