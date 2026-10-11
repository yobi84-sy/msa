package com.example.ordersystem.member.service;

import com.example.ordersystem.member.domain.Member;
import com.example.ordersystem.member.domain.Role;
import com.example.ordersystem.member.repository.MemberRepository;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.CommandLineRunner;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;

@Component
public class InitialDataLoader implements CommandLineRunner {

    private final MemberRepository memberRepository;
    private final PasswordEncoder passwordEncoder;

    // 관리자 초기 비밀번호를 환경변수에서 가져오기
    @Value("${ADMIN_BOOTSTRAP_PASSWORD:}")
    private String adminBootstrapPassword;

    public InitialDataLoader(MemberRepository memberRepository, PasswordEncoder passwordEncoder) {
        this.memberRepository = memberRepository;
        this.passwordEncoder = passwordEncoder;
    }

    @Override
    public void run(String... args) {

        // 비밀번호가 설정되지 않았다면 관리자 자동 생성 생략
        if (adminBootstrapPassword.isBlank()) {
            return;
        }

        // 기존 관리자 계정 중복 확인
        if (memberRepository.findByLoginId("admin").isPresent()
                || memberRepository.findByEmail("admin@naver.com").isPresent()) {
            return;
        }

        Member member = Member.builder()
                .name("관리자")
                .loginId("admin")
                .nickname("관리자")
                .email("admin@naver.com")
                .password(passwordEncoder.encode(adminBootstrapPassword))
                .role(Role.ADMIN)
                .build();

        memberRepository.save(member);
    }
}
