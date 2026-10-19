package com.example.ordersystem.ordering.repository;

import com.example.ordersystem.ordering.domain.Ordering;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface OrderingRepository extends JpaRepository<Ordering, Long> {
    java.util.Optional<Ordering> findByMemberIdAndRequestKey(Long memberId,String requestKey);
    java.util.List<Ordering> findByMemberIdOrderByIdDesc(Long memberId);
}
