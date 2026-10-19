package com.example.ordersystem.common.service;
import jakarta.persistence.EntityNotFoundException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
import java.util.Map;
@RestControllerAdvice
public class CommonExceptionHandler {
 @ExceptionHandler(IllegalArgumentException.class) public ResponseEntity<?> bad(IllegalArgumentException e){return ResponseEntity.badRequest().body(Map.of("message",e.getMessage()==null?"입력값을 확인하세요.":e.getMessage()));}
 @ExceptionHandler(MethodArgumentNotValidException.class) public ResponseEntity<?> invalid(MethodArgumentNotValidException e){return ResponseEntity.badRequest().body(Map.of("message","입력값을 확인하세요.","fields",e.getBindingResult().getFieldErrors().stream().map(f->f.getField()).distinct().toList()));}
 @ExceptionHandler(EntityNotFoundException.class) public ResponseEntity<?> missing(EntityNotFoundException e){return ResponseEntity.status(404).body(Map.of("message","요청한 항목이 없습니다."));}
 @ExceptionHandler(DataIntegrityViolationException.class) public ResponseEntity<?> duplicate(DataIntegrityViolationException e){return ResponseEntity.status(409).body(Map.of("message","중복된 항목이거나 다른 요청과 충돌했습니다. 다시 조회해주세요."));}
 @ExceptionHandler(ResponseStatusException.class) public ResponseEntity<?> status(ResponseStatusException e){return ResponseEntity.status(e.getStatusCode()).body(Map.of("message",e.getReason()==null?"요청을 처리할 수 없습니다.":e.getReason()));}
}
