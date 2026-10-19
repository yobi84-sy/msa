package com.example.ordersystem;
import org.junit.jupiter.api.*;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MockMvc;
import com.example.ordersystem.member.repository.MemberRepository;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import static org.assertj.core.api.Assertions.*;
@SpringBootTest @AutoConfigureMockMvc @ActiveProfiles("test")
class OrdersystemApplicationTests {
 @Autowired MockMvc mvc;@Autowired MemberRepository members;
 @Test void validatesSignupAndDoesNotPersistWeakPassword()throws Exception{
  mvc.perform(post("/member/create").contentType("application/json").content("{\"name\":\"Test\",\"loginId\":\"weak1\",\"nickname\":\"Test\",\"email\":\"weak@example.com\",\"password\":\"weak\"}")).andExpect(status().isBadRequest());
  assertThat(members.findByLoginId("weak1")).isEmpty();
 }
 @Test void createsUserHashesPasswordAndRejectsDuplicate()throws Exception{
  String body="{\"name\":\"Test\",\"loginId\":\"valid1\",\"nickname\":\"Test\",\"email\":\"valid@example.com\",\"password\":\"Strong-Test-2026!\",\"passwordConfirm\":\"Strong-Test-2026!\",\"role\":\"ADMIN\"}";
  mvc.perform(post("/member/create").contentType("application/json").content(body)).andExpect(status().isCreated());
  var member=members.findByLoginId("valid1").orElseThrow();assertThat(member.getPassword()).isNotEqualTo("Strong-Test-2026!");assertThat(member.getRole().name()).isEqualTo("USER");
  mvc.perform(post("/member/create").contentType("application/json").content(body)).andExpect(status().isBadRequest());
  mvc.perform(post("/member/doLogin").contentType("application/json").content("{\"loginId\":\"valid1\",\"password\":\"Strong-Test-2026!\"}")).andExpect(status().isOk()).andExpect(jsonPath("$.token").isNotEmpty()).andExpect(jsonPath("$.password").doesNotExist());
 }
 @Test void ignoresSpoofedIdentity()throws Exception{mvc.perform(get("/member/me").header("X-User-Id","1").header("X-User-Role","ADMIN")).andExpect(status().isUnauthorized());}
}
