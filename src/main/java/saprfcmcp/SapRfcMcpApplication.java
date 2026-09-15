package saprfcmcp;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * 启动入口。因为和 {@link SapRfcMcpController} 同在 package saprfcmcp，
 * @SpringBootApplication 的组件扫描会自动发现该控制器。
 *
 * 启动后：GET/POST http://localhost:8080/sap-rfc-mcp
 */
@SpringBootApplication
public class SapRfcMcpApplication {
    public static void main(String[] args) {
        SpringApplication.run(SapRfcMcpApplication.class, args);
    }
}
