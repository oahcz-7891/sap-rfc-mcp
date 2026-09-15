## sap-rfc-mcp — 单文件 SAP RFC MCP 服务 / Single-file SAP RFC MCP Server
`Spring Boot + SSE + JCo` · 1 个控制器 + 2 个 JSON 配置 / one controller + two JSON configs

```
sap-rfc-mcp/
├── pom.xml                                  # Spring Boot 2.7.3（已配 -Djava.library.path=lib）
├── src/main/java/saprfcmcp/
│   ├── SapRfcMcpApplication.java            # 启动入口 / entry point
│   └── SapRfcMcpController.java             # 唯一控制器 / the only controller（MCP + JCo + 白名单）
├── src/main/resources/application.properties
├── lib/                                     # sapjco3.jar + sapjco3.dll + 运行时依赖
├── config/                                  # sap.json / whitelist.json（附 *.example.json）
└── .mcp.json                                # PI(pi-mcp-adapter) 项目级接入配置
```

### 启动 / Run

```bash
mvn spring-boot:run
# 或 / or
mvn -DskipTests package && java -Djava.library.path=lib -jar target/sap-rfc-mcp-1.0.0.jar
```

IDEA：`pom.xml` → Add as Maven Project，Run `SapRfcMcpApplication`（`.idea/runConfigurations/` 已备好 VM options，工作目录=项目根）。

成功日志 / success log：`Tomcat started on port(s): 8080`。

### 端点 / Endpoints

```
GET  /sap-rfc-mcp    建立 SSE 长连接，先下发 endpoint 事件 / open SSE, emits endpoint first
POST /sap-rfc-mcp    发 JSON-RPC（带 ?sessionId=xxx 时响应经 SSE 推回）
```

客户端 URL / client URL：`http://localhost:8080/sap-rfc-mcp`，传输 **SSE**。

### 工具 / Tools

| 工具 Tool | 入参 Args | 说明 Description |
|---|---|---|
| `sap_ping` | — | RFC_PING 连通性 / connectivity |
| `sap_list` | `pattern?` | 列白名单放行的函数（读本地 `whitelist.json`，**不发 RFC**）；通配符条目不展开 / list allowed functions locally, no RFC |
| `sap_describe` | `funcname` | 函数签名（JCo 元数据，需在白名单内）/ signature from JCo metadata |
| `sap_call` | `funcname`, `params?` | 调用白名单内的函数模块，参数类型自动识别 / invoke whitelisted FM |

要查 **SAP 里真实存在**哪些函数模块（而不是白名单写了什么），用 `sap_call` 调 `ZRFC_AGENT_FM_LIST`。
To see which function modules **actually exist in SAP**, call `ZRFC_AGENT_FM_LIST` via `sap_call`.

### 接入 Agent / Agent Integration

**让 Agent 自己配置**：把仓库地址（或本目录）交给它即可，配置信息都在 `.mcp.json`。
必要提示：本服务是经典 HTTP+SSE，需显式 `httpTransport: "sse"`。改完 `.mcp.json` 需重启 PI 或 `/reload`。

**Let the agent configure it itself**: hand it the repo URL (or this directory) and it's done — everything lives in `.mcp.json`.
One hint it needs: this is classic HTTP+SSE, so `httpTransport: "sse"` is required. Restart PI (or `/reload`) after editing `.mcp.json`.

### 配置 / Configuration

`config/sap.json`：`destination` / `ashost` / `sysnr` / `client` / `user` / `passwd` / `lang`。
`passwd` 支持 `${ENV}` 与 `${ENV:-默认值}`，推荐只写 `${SAP_PASSWD}`。

`config/whitelist.json`：

```jsonc
{ "readonly": true,          // true = 只允许 readonly:true 的函数 / only readonly:true functions
  "defaultPolicy": "deny",   // 白名单外一律拒绝 / deny anything not listed
  "functions": [ { "name": "RFC_READ_TABLE", "readonly": true } ],
  "deny": [ "RFC_ABAP_*" ] } // 黑名单优先，`*` 任意位置生效 / deny wins, `*` anywhere
```

条目字段 / entry fields：`name`（支持 `*` 通配）、`readonly`（只读模式下必须为 true）。

配置查找顺序 / lookup order：`-Dsap.rfc.mcp.config.dir` → 环境变量 `SAP_RFC_MCP_CONFIG_DIR` → 工作目录 `config/` → classpath `saprfcmcp/<name>`。

### 嵌进已有 Spring 应用 / Embed in an Existing Spring App（可选 optional）

只拷 `SapRfcMcpController.java`（包名 `saprfcmcp`），保证组件扫描覆盖 `saprfcmcp`
（否则 `@ComponentScan` 或 `@Import(SapRfcMcpController.class)`），`config/` 放工作目录，启动加
`-Djava.library.path=<dll 目录>`。

### 实测与限制 / Verified & Limitations

已实测 / verified（Spring Boot 2.7.3 + JCo 3.0.6）：`initialize` / `tools/list`（4 工具）、`sap_ping`、
`sap_call RFC_READ_TABLE`（中文正确 / CJK OK）、白名单外调用返回 `POLICY_DENIED`（`isError:true`）。

- 只实现 `initialize / ping / tools/list / tools/call`。/ Only these four methods are implemented.
- 首次调用工具时才连 SAP（懒初始化），配置错误在首次调用时报出，不影响启动。
  Lazy SAP connection on first tool call; config errors surface then, startup is unaffected.
