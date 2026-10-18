package com.example.ordersystem.product.service;

import com.amazonaws.services.s3.AmazonS3;
import com.amazonaws.services.s3.model.ObjectMetadata;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class S3Service {

    private final AmazonS3 amazonS3;

    @Value("${cloud.aws.s3.bucket}")
    private String bucket;

    public String uploadFile(MultipartFile file) throws IOException {
        String type=file.getContentType();
        if(type==null || !java.util.Set.of("image/jpeg","image/png","image/webp").contains(type))throw new IllegalArgumentException("JPG, PNG, WEBP 이미지만 등록할 수 있습니다.");
        String extension=type.equals("image/jpeg")?"jpg":type.equals("image/png")?"png":"webp";
        String fileName = "products/" + UUID.randomUUID() + "." + extension;

        ObjectMetadata metadata = new ObjectMetadata();
        metadata.setContentLength(file.getSize());
        metadata.setContentType(file.getContentType());

        try(java.io.InputStream input=file.getInputStream()){amazonS3.putObject(bucket, fileName, input, metadata);}

        return amazonS3.getUrl(bucket, fileName).toString();
    }
}
