package com.example.ordersystem.member.dto;

import com.example.ordersystem.member.domain.Member;
import jakarta.validation.constraints.*;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@NoArgsConstructor
@AllArgsConstructor
@Data
public class MemberSaveReqDto {
    @NotBlank @Size(max=100)
    private String name;
    @NotBlank @Pattern(regexp="[A-Za-z0-9_-]{4,30}")
    private String loginId;
    @NotBlank @Size(max=50)
    private String nickname;
    @NotBlank @Email @Size(max=254)
    private String email;
    @NotBlank @Size(min=12,max=72) @Pattern(regexp="(?s)^(?=.*[0-9])(?=.*\\p{Punct}).+$")
    private String password;

    @NotBlank private String passwordConfirm;
    @AssertTrue(message="비밀번호 확인이 일치하지 않습니다.")
    public boolean isPasswordConfirmed(){return password != null && password.equals(passwordConfirm);}

    public Member toEntity(String encodedPassword){
        return Member.builder()
                .name(this.name)
                .loginId(this.loginId)
                .nickname(this.nickname)
                .email(this.email)
                .password(encodedPassword)
                .build();
    }
}
