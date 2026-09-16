# sap-rfc-mcp

把 SAP RFC 暴露成 MCP 工具：Spring Boot + SSE + JCo。

Expose SAP RFC as MCP tools: Spring Boot + SSE + JCo.

---

## 目录结构 / Layout

服务端只有 1 个启动类和 1 个控制器，其余是配置与 JCo 运行库。`sap/` 存放的是要装到 SAP 里的 ABAP 函数，属于可选部分。

The server is just one bootstrap class and one controller; the rest is configuration and the JCo runtime. `sap/` holds optional ABAP function modules that live on the SAP side.

```
sap-rfc-mcp/
├── src/main/java/saprfcmcp/
│   ├── SapRfcMcpApplication.java     # 启动入口 / entry point
│   └── SapRfcMcpController.java      # 唯一控制器：MCP + JCo + 白名单 / the only controller
├── src/main/resources/application.properties
├── config/                           # sap.json + whitelist.json（附示例 / with examples）
├── lib/                              # sapjco3.jar + sapjco3.dll（JCo 运行库 / JCo runtime）
├── sap/                              # SAP 侧 ABAP 函数 / ABAP-side FMs（见 sap/README-安装说明.md）
├── ts/                               # 验证脚本 / helper scripts（非服务代码 / not server code）
└── abap/                             # ABAP 样例与改动记录 / ABAP samples and diffs
```

---

## 运行 / Run

命令行两种方式：开发时直接 `spring-boot:run`，部署时先打包再用 `java -jar` 启动，注意必须把 `lib` 加进 `java.library.path`，否则 JCo 的 DLL 加载会失败。IDEA 里以 Maven 项目导入 `pom.xml`，直接 Run `SapRfcMcpApplication` 即可。

Two ways from the CLI: use `spring-boot:run` while developing, or package and start with `java -jar` when deploying. Either way `lib` must be on `java.library.path`, otherwise the JCo DLL fails to load. In IntelliJ, import `pom.xml` as a Maven project and run `SapRfcMcpApplication`.

```bash
mvn spring-boot:run
# 或 / or
mvn -DskipTests package && java -Djava.library.path=lib -jar target/sap-rfc-mcp-1.0.0.jar
```

启动成功时日志会打印 `Tomcat started on port(s): 8080`。

On success the log prints `Tomcat started on port(s): 8080`.

---

## 接入 / Integration

客户端 URL 是 `http://localhost:8080/sap-rfc-mcp`，传输方式是经典的 HTTP + SSE，不是 Streamable HTTP。仓库里的 `.mcp.json` 已经配好（显式写了 `httpTransport: "sse"`），修改后需要重启 PI 或执行 `/reload` 才会生效。

The client URL is `http://localhost:8080/sap-rfc-mcp`, and the transport is classic HTTP + SSE rather than Streamable HTTP. `.mcp.json` in this repo is already configured (it sets `httpTransport: "sse"` explicitly); restart PI or run `/reload` after editing it.

```
GET  /sap-rfc-mcp    建立 SSE，先下发 endpoint 事件 / open SSE, emits endpoint first
POST /sap-rfc-mcp    发 JSON-RPC / send JSON-RPC
                    带 ?sessionId=xxx 时响应走 SSE / with ?sessionId the reply goes over SSE
```

---

## 工具 / Tools

一共 4 个工具。`sap_list` 只读本地白名单文件、不产生 RFC 调用；`sap_describe` 和 `sap_call` 走 JCo，且目标函数必须出现在白名单里，否则直接拒绝。如果想知道 SAP 里真实存在哪些函数模块（而不是白名单写了什么），用 `sap_call` 去调 `ZRFC_AGENT_FM_LIST`。

There are four tools. `sap_list` only reads the local whitelist file and issues no RFC; `sap_describe` and `sap_call` go through JCo, and the target function must be on the whitelist or the call is refused outright. To see which function modules actually exist in SAP (rather than what the whitelist says), call `ZRFC_AGENT_FM_LIST` via `sap_call`.

| Tool | Args | Description |
|---|---|---|
| `sap_ping` | — | RFC_PING 连通性检查 / connectivity check |
| `sap_list` | `pattern?` | 列白名单内的函数，读本地文件、不发 RFC / list allowed FMs from the local file, no RFC |
| `sap_describe` | `funcname` | 函数签名，取 JCo 元数据 / signature from JCo metadata |
| `sap_call` | `funcname`, `params?` | 调用函数模块，参数类型自动识别 / invoke the FM, parameter types auto-detected |

---

## 配置 / Configuration

`config/sap.json` 放连接参数。`passwd` 支持 `${ENV}` 和 `${ENV:-默认值}` 两种写法，但不建议把密码明文写进文件，推荐只写 `${SAP_PASSWD}`，运行时从环境变量取。

`config/sap.json` holds the connection settings. `passwd` accepts both `${ENV}` and `${ENV:-default}`, but do not put a plaintext password in the file — write `${SAP_PASSWD}` and let it come from the environment at runtime.

| Field | Description |
|---|---|
| `destination`、`ashost`、`sysnr` | 目标系统 / target system |
| `client`、`user`、`passwd`、`lang` | 登录信息 / credentials |

`config/whitelist.json` 控制允许调用哪些函数。`readonly: true` 时只放行标记了 `readonly: true` 的条目；`defaultPolicy: "deny"` 表示白名单外一律拒绝；`deny` 黑名单优先于白名单，且 `*` 通配符在任意位置都生效。

`config/whitelist.json` controls what may be called. With `readonly: true`, only entries marked `readonly: true` are allowed; `defaultPolicy: "deny"` rejects anything unlisted; the `deny` list beats the allow-list, and `*` works anywhere in a pattern.

```jsonc
{ "readonly": true,
  "defaultPolicy": "deny",
  "functions": [ { "name": "RFC_READ_TABLE", "readonly": true } ],
  "deny": [ "RFC_ABAP_*" ] }
```

配置查找顺序依次为：`-Dsap.rfc.mcp.config.dir`、环境变量 `SAP_RFC_MCP_CONFIG_DIR`、当前工作目录下的 `config/`、最后是 classpath。

Configuration is looked up in this order: `-Dsap.rfc.mcp.config.dir`, the `SAP_RFC_MCP_CONFIG_DIR` environment variable, `config/` under the working directory, and finally the classpath.

---

## SAP 侧函数 / ABAP-side FMs（可选）

`sap/` 下有 4 个 ABAP 函数，复制进 SE37 就能用，安装步骤和依赖的结构体定义见 `sap/README-安装说明.md`。不装也能用，只是少一些读源码和复杂查表的能力，标准 FM（`RFC_READ_TABLE`、`DDIF_FIELDINFO_GET` 等）仍然可用。

Four ABAP function modules live under `sap/`; paste them into SE37 and they work. Setup steps and required structures are in `sap/README-安装说明.md`. Installing them is optional: without them you simply lose source-reading and complex-select capability, while standard FMs (`RFC_READ_TABLE`, `DDIF_FIELDINFO_GET`, etc.) remain available.

| FM | Description |
|---|---|
| `ZRFC_AGENT_FM_LIST` | 按通配符、开发类搜函数 / list FMs by pattern or dev class |
| `ZRFC_AGENT_FM_READ` | 读函数模块源码 / read function module source |
| `ZRFC_AGENT_REPORT_READ` | 读报表、程序源码 / read report or program source |
| `ZRFC_AGENT_SQL_SELECT` | 增强动态查表：JOIN、聚合、GROUP BY / enhanced dynamic select |

---

## 限制 / Limitations

MCP 协议只实现了 `initialize`、`ping`、`tools/list`、`tools/call` 四个方法。SAP 连接是懒初始化的，首次调用工具时才建立，因此配置写错不会导致服务启动失败，而是在第一次调用时报错。

Only four MCP methods are implemented: `initialize`, `ping`, `tools/list`, and `tools/call`. The SAP connection is lazy — it is established on the first tool call, so a bad configuration does not break startup; the error surfaces on that first call instead.
