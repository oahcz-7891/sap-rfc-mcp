package saprfcmcp;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sap.conn.jco.JCoDestination;
import com.sap.conn.jco.JCoDestinationManager;
import com.sap.conn.jco.JCoException;
import com.sap.conn.jco.JCoFunction;
import com.sap.conn.jco.JCoMetaData;
import com.sap.conn.jco.JCoParameterList;
import com.sap.conn.jco.JCoRecord;
import com.sap.conn.jco.JCoStructure;
import com.sap.conn.jco.JCoTable;
import com.sap.conn.jco.ext.DestinationDataEventListener;
import com.sap.conn.jco.ext.DestinationDataProvider;
import com.sap.conn.jco.ext.Environment;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

import javax.servlet.http.HttpServletRequest;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * SAP RFC MCP 服务（单文件）—— MCP over HTTP + SSE，结构对齐 McpController01。
 *
 * <pre>
 * GET  /sap-rfc-mcp   建立 SSE 长连接，下发 endpoint 事件
 * POST /sap-rfc-mcp   发送 JSON-RPC（带 ?sessionId=xxx 时响应经 SSE 推回）
 *
 * 工具：sap_ping / sap_list / sap_describe / sap_call
 * 配置：config/sap.json（连接）、config/whitelist.json（函数白名单）
 *       默认相对工作目录，可用 -Dsap.rfc.mcp.config.dir=... 或 SAP_RFC_MCP_CONFIG_DIR 覆盖，
 *       找不到时回退 classpath:/saprfcmcp/。
 *
 * 客户端配置（Claude Desktop / Cursor / Qoder 等）：
 *   URL: http://localhost:8080/sap-rfc-mcp    传输: SSE
 * </pre>
 *
 * 依赖：sapjco3.jar + sapjco3.dll（-Djava.library.path 指向 dll）、Jackson（Spring 自带）。
 * 注意：本类在 package saprfcmcp，若应用的组件扫描不覆盖该包，请在启动类加
 *      {@code @ComponentScan(basePackages = {"你的包", "saprfcmcp"})} 或 {@code @Import(SapRfcMcpController.class)}。
 */
@RestController
public class SapRfcMcpController {

    private static final String PROTOCOL_VERSION = "2024-11-05";

    private static final ObjectMapper MAP = new ObjectMapper();

    /** sessionId -> SSE 长连接 */
    private final Map<String, SseEmitter> sessions = new ConcurrentHashMap<String, SseEmitter>();

    // ------------------------------------------------------------------
    // 懒初始化的 SAP 状态（首次调用时加载，避免启动即失败）
    // ------------------------------------------------------------------
    private volatile boolean inited = false;
    private volatile boolean rulesLoaded = false;
    private String destinationName = "SAP";
    private JCoDestination destination;
    private final List<Rule> rules = new ArrayList<Rule>();
    private final List<String> denyPatterns = new ArrayList<String>();
    private String defaultPolicy = "deny";
    private boolean readonly = false;

    private static final class Rule {
        final String name;
        final boolean readonly;

        Rule(String name, boolean readonly) {
            this.name = name;
            this.readonly = readonly;
        }
    }

    // ==================================================================
    // 1. MCP 传输层（SSE + JSON-RPC 分发）
    // ==================================================================

    @GetMapping(value = "/sap-rfc-mcp", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter sse(HttpServletRequest request,
                          @RequestParam(value = "sessionId", required = false) String sessionId) {
        String id = (sessionId == null || sessionId.trim().isEmpty())
                ? UUID.randomUUID().toString().replace("-", "")
                : sessionId;

        SseEmitter emitter = new SseEmitter(0L);
        sessions.put(id, emitter);
        emitter.onCompletion(new Runnable() {
            public void run() {
                sessions.remove(id);
            }
        });
        emitter.onTimeout(new Runnable() {
            public void run() {
                sessions.remove(id);
            }
        });
        emitter.onError(new java.util.function.Consumer<Throwable>() {
            public void accept(Throwable t) {
                sessions.remove(id);
            }
        });

        try {
            String base = request.getRequestURL().toString().replace(request.getRequestURI(), "");
            emitter.send(SseEmitter.event().name("endpoint")
                    .data(base + "/sap-rfc-mcp?sessionId=" + id));
        } catch (IOException e) {
            sessions.remove(id);
        }
        return emitter;
    }

    @PostMapping(value = "/sap-rfc-mcp", consumes = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<Void> message(@RequestParam(value = "sessionId", required = false) String sessionId,
                                        @RequestBody JsonNode body) {
        SseEmitter emitter = sessions.get(sessionId);
        if (emitter == null) {
            return ResponseEntity.badRequest().build();
        }
        String method = body.path("method").asText("");
        if (method.startsWith("notifications/")) {
            return ResponseEntity.accepted().build();
        }
        ObjectNode response;
        try {
            response = dispatch(body);
        } catch (Throwable t) {
            response = error(body.get("id"), -32603, "Internal error: " + t.getMessage());
        }
        try {
            emitter.send(SseEmitter.event().name("message").data(response.toString()));
        } catch (IOException e) {
            sessions.remove(sessionId);
            return ResponseEntity.status(500).build();
        }
        return ResponseEntity.accepted().build();
    }

    private ObjectNode dispatch(JsonNode body) {
        String method = body.path("method").asText("");
        JsonNode id = body.get("id");
        if ("initialize".equals(method)) {
            return result(id, initialize(body.path("params")));
        }
        if ("ping".equals(method)) {
            return result(id, MAP.createObjectNode());
        }
        if ("tools/list".equals(method)) {
            return result(id, toolsList());
        }
        if ("tools/call".equals(method)) {
            return result(id, toolsCall(body.path("params")));
        }
        return error(id, -32601, "Method not found: " + method);
    }

    private ObjectNode initialize(JsonNode params) {
        ObjectNode result = MAP.createObjectNode();
        String pv = params.path("protocolVersion").asText("");
        result.put("protocolVersion", pv.isEmpty() ? PROTOCOL_VERSION : pv);
        result.putObject("capabilities").putObject("tools");
        ObjectNode info = result.putObject("serverInfo");
        info.put("name", "sap-rfc-mcp");
        info.put("version", "1.0.0");
        return result;
    }

    // ==================================================================
    // 2. 工具定义
    // ==================================================================

    private ObjectNode toolsList() {
        ObjectNode result = MAP.createObjectNode();
        ArrayNode tools = result.putArray("tools");

        tools.add(tool("sap_ping", "测试 SAP 连通性（RFC_PING）。无需参数。",
                schema()));

        ObjectNode listSchema = schema();
        prop(listSchema, "pattern", "string", "可选，按函数名子串过滤（不区分大小写）。");
        tools.add(tool("sap_list", "列出 config/whitelist.json 里允许调用的函数模块（不发 RFC）。"
                + "注意：输出的是白名单里的原始条目，通配符（如 ZRFC_AGENT_*）不会展开成真实函数名；"
                + "要查 SAP 里真实存在哪些函数，用 sap_call 调 ZRFC_AGENT_FM_LIST。",
                listSchema));

        ObjectNode describeSchema = schema();
        prop(describeSchema, "funcname", "string", "函数模块名，如 RFC_READ_TABLE。");
        required(describeSchema, "funcname");
        tools.add(tool("sap_describe", "查看函数模块签名（import/export/changing/tables 字段名、类型、长度）。函数需在白名单内。",
                describeSchema));

        ObjectNode callSchema = schema();
        prop(callSchema, "funcname", "string", "函数模块名，如 RFC_READ_TABLE。必须已在 config/whitelist.json 里放行。");
        ObjectNode paramsProp = callSchema.with("properties").putObject("params");
        paramsProp.put("type", "object");
        paramsProp.put("description", "函数参数 { 参数名: 值|对象|数组 }；单值/结构/表按 SAP 元数据自动识别。");
        required(callSchema, "funcname");
        tools.add(tool("sap_call", "调用白名单内的任意 remote-enabled 函数模块；白名单外的函数会被拒绝。"
                + "参数名不确定时，先用 sap_describe 取签名。",
                callSchema));

        return result;
    }

    private ObjectNode tool(String name, String description, ObjectNode inputSchema) {
        ObjectNode t = MAP.createObjectNode();
        t.put("name", name);
        t.put("description", description);
        t.set("inputSchema", inputSchema);
        return t;
    }

    private ObjectNode schema() {
        ObjectNode s = MAP.createObjectNode();
        s.put("type", "object");
        s.putObject("properties");
        s.putArray("required");
        return s;
    }

    private void prop(ObjectNode schema, String name, String type, String description) {
        ObjectNode p = schema.with("properties").putObject(name);
        p.put("type", type);
        p.put("description", description);
    }

    private void required(ObjectNode schema, String... names) {
        for (String n : names) {
            schema.withArray("required").add(n);
        }
    }

    // ==================================================================
    // 3. 工具执行
    // ==================================================================

    private ObjectNode toolsCall(JsonNode params) {
        String tool = params.path("name").asText("");
        JsonNode args = params.path("arguments");
        try {
            if ("sap_ping".equals(tool)) {
                return toolResult(ping());
            }
            if ("sap_list".equals(tool)) {
                return toolResult(list(args.path("pattern").asText(null)));
            }
            if ("sap_describe".equals(tool)) {
                return toolResult(describe(args.path("funcname").asText("")));
            }
            if ("sap_call".equals(tool)) {
                return toolResult(call(args.path("funcname").asText(""), args.get("params")));
            }
            return toolError("未知工具: " + tool);
        } catch (Throwable t) {
            return toolError(String.valueOf(t.getMessage()));
        }
    }

    private ObjectNode toolResult(JsonNode result) {
        ObjectNode r = MAP.createObjectNode();
        r.putArray("content").addObject().put("type", "text")
                .put("text", result.toString());
        r.put("isError", false);
        return r;
    }

    private ObjectNode toolError(String message) {
        ObjectNode r = MAP.createObjectNode();
        r.putArray("content").addObject().put("type", "text").put("text", message);
        r.put("isError", true);
        return r;
    }

    // ==================================================================
    // 4. SAP：连接 / 白名单 / RFC 调用
    // ==================================================================

    /** sap_list 与 sap_call 都靠它——SAP 没起、连不上时白名单也得能读出来。 */
    private synchronized void ensureRules() {
        if (rulesLoaded) return;
        try {
            JsonNode wl = loadConfig("whitelist.json");
            defaultPolicy = wl.path("defaultPolicy").asText("deny");
            readonly = wl.path("readonly").asBoolean(false);
            for (JsonNode fn : wl.path("functions")) {
                rules.add(new Rule(
                        norm(fn.path("name").asText("")),
                        fn.path("readonly").asBoolean(false)));
            }
            for (JsonNode d : wl.path("deny")) {
                denyPatterns.add(norm(d.asText("")));
            }
            rulesLoaded = true;
        } catch (Exception e) {
            throw new IllegalStateException("白名单加载失败: " + e.getMessage(), e);
        }
    }

    private synchronized void ensureInit() {
        ensureRules();
        if (inited) return;
        try {
            JsonNode sap = loadConfig("sap.json");
            destinationName = sap.path("destination").asText("SAP");
            final Properties props = new Properties();
            props.setProperty("jco.client.ashost", expand(sap.path("ashost").asText("")));
            props.setProperty("jco.client.sysnr", expand(sap.path("sysnr").asText("00")));
            props.setProperty("jco.client.client", expand(sap.path("client").asText("")));
            props.setProperty("jco.client.user", expand(sap.path("user").asText("")));
            props.setProperty("jco.client.passwd", expand(sap.path("passwd").asText("")));
            props.setProperty("jco.client.lang", expand(sap.path("lang").asText("ZH")));
            props.setProperty("jco.destination.pool_capacity", "3");
            props.setProperty("jco.destination.peak_limit", "10");

            try {
                Environment.registerDestinationDataProvider(new Provider(destinationName, props));
            } catch (Exception ignore) {
                // 已注册过 provider：沿用现有的（本进程内只注册一次）
            }
            destination = JCoDestinationManager.getDestination(destinationName);
            inited = true;
        } catch (Exception e) {
            throw new IllegalStateException("SAP MCP 初始化失败: " + e.getMessage(), e);
        }
    }

    private ObjectNode ping() {
        ensureInit();
        try {
            destination.ping();
            ObjectNode o = MAP.createObjectNode();
            o.put("ok", true);
            o.put("message", "RFC_PING succeeded");
            o.put("destination", destination.getDestinationID());
            return o;
        } catch (JCoException e) {
            throw new IllegalStateException("SAP 连接失败: " + e.getMessage(), e);
        }
    }

    /** 列白名单放行范围。只读本地配置，不发任何 RFC（ensureRules 而非 ensureInit）。 */
    private ObjectNode list(String pattern) {
        ensureRules();
        String p = pattern == null ? "" : pattern.trim().toUpperCase(Locale.ROOT);
        ObjectNode out = MAP.createObjectNode();
        out.put("defaultPolicy", defaultPolicy);
        out.put("readonly", readonly);
        ArrayNode arr = out.putArray("functions");
        for (Rule r : rules) {
            if (p.isEmpty() || r.name.contains(p)) {
                ObjectNode o = arr.addObject();
                o.put("name", r.name);
                o.put("readonly", r.readonly);
            }
        }
        ArrayNode deny = out.putArray("deny");
        for (String d : denyPatterns) deny.add(d);
        return out;
    }

    private ObjectNode describe(String funcname) {
        ensureInit();
        String reason = check(funcname);
        if (reason != null) {
            throw new IllegalStateException("POLICY_DENIED: " + reason);
        }
        try {
            JCoFunction f = destination.getRepository().getFunction(funcname);
            if (f == null) {
                throw new IllegalStateException("函数不存在: " + funcname);
            }
            ObjectNode out = MAP.createObjectNode();
            out.put("funcname", norm(funcname));
            addMeta(out, "import", f.getImportParameterList());
            addMeta(out, "export", f.getExportParameterList());
            addMeta(out, "changing", f.getChangingParameterList());
            addMeta(out, "tables", f.getTableParameterList());
            return out;
        } catch (JCoException e) {
            throw new IllegalStateException("SAP 错误: " + e.getMessage(), e);
        }
    }

    private ObjectNode call(String funcname, JsonNode params) {
        ensureInit();
        String reason = check(funcname);
        if (reason != null) {
            throw new IllegalStateException("POLICY_DENIED: " + reason);
        }
        try {
            JCoFunction f = destination.getRepository().getFunction(funcname);
            if (f == null) {
                throw new IllegalStateException("函数不存在: " + funcname);
            }
            if (params != null && params.isObject()) {
                Iterator<Map.Entry<String, JsonNode>> it = params.fields();
                while (it.hasNext()) {
                    Map.Entry<String, JsonNode> e = it.next();
                    fillParam(f, e.getKey(), e.getValue());
                }
            }
            f.execute(destination);

            ObjectNode out = MAP.createObjectNode();
            JCoParameterList il = f.getImportParameterList();
            JCoParameterList el = f.getExportParameterList();
            JCoParameterList cl = f.getChangingParameterList();
            JCoParameterList tl = f.getTableParameterList();
            if (il != null && il.getFieldCount() > 0) out.set("import", serializeRecord(il));
            if (el != null && el.getFieldCount() > 0) out.set("export", serializeRecord(el));
            if (cl != null && cl.getFieldCount() > 0) out.set("changing", serializeRecord(cl));
            if (tl != null && tl.getFieldCount() > 0) out.set("tables", serializeRecord(tl));
            return out;
        } catch (JCoException e) {
            throw new IllegalStateException("SAP 错误: " + e.getMessage(), e);
        }
    }

    // ==================================================================
    // 5. 白名单
    // ==================================================================

    /** 返回 null 表示放行，否则返回拒绝原因。 */
    private String check(String funcname) {
        String name = norm(funcname);
        if (name.isEmpty()) return "函数名为空";
        for (String d : denyPatterns) {
            if (!d.isEmpty() && match(d, name)) return "命中黑名单: " + name;
        }
        Rule rule = findRule(name);
        if (rule == null) {
            if ("allow".equalsIgnoreCase(defaultPolicy)) return null;
            return "不在白名单: " + name + "（请加入 config/whitelist.json）";
        }
        if (readonly && !rule.readonly) {
            return "只读模式: " + name + " 未标 readonly:true";
        }
        return null;
    }

    private Rule findRule(String name) {
        Rule best = null;
        int bestLen = -1;
        for (Rule r : rules) {
            if (r.name.indexOf('*') < 0) {
                if (r.name.equals(name)) return r;   // 精确条目优先
            } else if (match(r.name, name) && r.name.length() > bestLen) {
                best = r;                            // 通配条目取最长的
                bestLen = r.name.length();
            }
        }
        return best;
    }

    /** glob：`*` 可出现在任意位置（不再只支持尾部通配），逐段转义后整体匹配。 */
    private static boolean match(String pattern, String name) {
        String p = norm(pattern);
        String n = norm(name);
        if (p.indexOf('*') < 0) return p.equals(n);
        StringBuilder re = new StringBuilder();
        for (String part : p.split("\\*", -1)) {
            if (re.length() > 0) re.append(".*");
            re.append(java.util.regex.Pattern.quote(part));
        }
        return n.matches(re.toString());
    }

    private static String norm(String s) {
        return s == null ? "" : s.trim().toUpperCase(Locale.ROOT);
    }

    // ==================================================================
    // 6. 配置加载
    // ==================================================================

    private JsonNode loadConfig(String name) throws IOException {
        String dir = System.getProperty("sap.rfc.mcp.config.dir");
        if (dir == null || dir.trim().isEmpty()) dir = System.getenv("SAP_RFC_MCP_CONFIG_DIR");
        if (dir == null || dir.trim().isEmpty()) dir = "config";
        File f = new File(dir, name);
        if (f.isFile()) {
            return MAP.readTree(f);
        }
        InputStream in = getClass().getClassLoader().getResourceAsStream("saprfcmcp/" + name);
        if (in == null) in = getClass().getClassLoader().getResourceAsStream(name);
        if (in != null) {
            try {
                return MAP.readTree(in);
            } finally {
                in.close();
            }
        }
        throw new IOException("找不到配置 " + f.getAbsolutePath()
                + "（可用 -Dsap.rfc.mcp.config.dir=... 指定目录，或放到 classpath:/saprfcmcp/）");
    }

    /** 支持 ${ENV} 与 ${ENV:-默认值}。 */
    private static String expand(String v) {
        if (v == null || v.indexOf("${") < 0) return v;
        StringBuilder sb = new StringBuilder();
        int i = 0;
        while (i < v.length()) {
            int s = v.indexOf("${", i);
            if (s < 0) {
                sb.append(v.substring(i));
                break;
            }
            sb.append(v, i, s);
            int e = v.indexOf('}', s + 2);
            if (e < 0) {
                sb.append(v.substring(s));
                break;
            }
            String key = v.substring(s + 2, e).trim();
            String def = null;
            int c = key.indexOf(":-");
            if (c >= 0) {
                def = key.substring(c + 2);
                key = key.substring(0, c).trim();
            }
            String val = System.getenv(key);
            if (val == null) val = System.getProperty(key);
            if (val == null) val = def;
            sb.append(val == null ? "" : val);
            i = e + 1;
        }
        return sb.toString();
    }

    // ==================================================================
    // 7. JCo：连接 Provider + 填参 + 序列化（自 JcoBridge.java 搬运）
    // ==================================================================

    private static final class Provider implements DestinationDataProvider {
        private final String name;
        private final Properties props;

        Provider(String name, Properties props) {
            this.name = name;
            this.props = props;
        }

        public Properties getDestinationProperties(String destName) {
            if (!name.equals(destName)) {
                throw new IllegalArgumentException("未知 destination: " + destName);
            }
            Properties p = new Properties();
            p.putAll(props);
            return p;
        }

        public boolean supportsEvents() {
            return false;
        }

        public void setDestinationDataEventListener(DestinationDataEventListener listener) {
            // no events
        }
    }

    private static void fillParam(JCoFunction f, String name, JsonNode v) throws JCoException {
        JCoParameterList[] lists = new JCoParameterList[] {
                f.getImportParameterList(), f.getChangingParameterList(), f.getTableParameterList()
        };
        for (JCoParameterList pl : lists) {
            if (pl == null) continue;
            JCoMetaData md = pl.getMetaData();
            if (md.hasField(name)) {
                if (md.isTable(name)) {
                    JCoTable t = pl.getTable(name);
                    if (v.isArray()) {
                        for (JsonNode row : v) {
                            t.appendRow();
                            fillRecord(t, row);
                        }
                    } else if (v.isObject()) {
                        t.appendRow();
                        fillRecord(t, v);
                    }
                } else if (md.isStructure(name)) {
                    JCoStructure st = pl.getStructure(name);
                    if (v.isObject()) fillRecord(st, v);
                } else {
                    pl.setValue(name, jsonToValue(v));
                }
                return;
            }
        }
        throw new IllegalStateException("函数元数据里没有参数: " + name);
    }

    private static void fillRecord(JCoRecord rec, JsonNode obj) {
        JCoMetaData md = rec.getMetaData();
        Iterator<Map.Entry<String, JsonNode>> it = obj.fields();
        while (it.hasNext()) {
            Map.Entry<String, JsonNode> e = it.next();
            String name = e.getKey();
            JsonNode v = e.getValue();
            if (md.isTable(name)) {
                JCoTable t = rec.getTable(name);
                if (v.isArray()) {
                    for (JsonNode row : v) {
                        t.appendRow();
                        fillRecord(t, row);
                    }
                } else if (v.isObject()) {
                    t.appendRow();
                    fillRecord(t, v);
                }
            } else if (md.isStructure(name)) {
                JCoStructure st = rec.getStructure(name);
                if (v.isObject()) fillRecord(st, v);
            } else {
                rec.setValue(name, jsonToValue(v));
            }
        }
    }

    private static ObjectNode serializeRecord(JCoRecord rec) {
        ObjectNode o = MAP.createObjectNode();
        JCoMetaData md = rec.getMetaData();
        for (int i = 0; i < md.getFieldCount(); i++) {
            String name = md.getName(i);
            if (md.isTable(name)) {
                o.set(name, serializeTable(rec.getTable(name)));
            } else if (md.isStructure(name)) {
                o.set(name, serializeRecord(rec.getStructure(name)));
            } else {
                o.put(name, rec.getString(name));
            }
        }
        return o;
    }

    private static ArrayNode serializeTable(JCoTable t) {
        ArrayNode arr = MAP.createArrayNode();
        for (int r = 0; r < t.getNumRows(); r++) {
            t.setRow(r);
            arr.add(serializeRecord(t));
        }
        return arr;
    }

    private static Object jsonToValue(JsonNode v) {
        if (v == null || v.isNull()) return "";
        if (v.isTextual()) return v.asText();
        if (v.isBoolean()) return v.asBoolean();
        if (v.isIntegralNumber()) return v.asLong();
        if (v.isNumber()) return v.asDouble();
        return v.toString();
    }

    private static void addMeta(ObjectNode out, String key, JCoParameterList pl) {
        if (pl == null || pl.getMetaData().getFieldCount() == 0) return;
        out.set(key, describeMeta(pl.getMetaData()));
    }

    private static ArrayNode describeMeta(JCoMetaData md) {
        ArrayNode arr = MAP.createArrayNode();
        for (int i = 0; i < md.getFieldCount(); i++) {
            String name = md.getName(i);
            ObjectNode o = MAP.createObjectNode();
            o.put("name", name);
            o.put("type", md.getTypeAsString(i));
            o.put("length", md.getLength(i));
            o.put("decimals", md.getDecimals(i));
            if (md.isTable(name)) {
                o.put("kind", "table");
                o.set("fields", describeMeta(md.getRecordMetaData(i)));
            } else if (md.isStructure(name)) {
                o.put("kind", "structure");
                o.set("fields", describeMeta(md.getRecordMetaData(i)));
            } else {
                o.put("kind", "scalar");
            }
            arr.add(o);
        }
        return arr;
    }

    // ==================================================================
    // 8. JSON-RPC 响应构造
    // ==================================================================

    private ObjectNode result(JsonNode id, JsonNode result) {
        ObjectNode o = MAP.createObjectNode();
        o.put("jsonrpc", "2.0");
        if (id != null) o.set("id", id);
        o.set("result", result);
        return o;
    }

    private ObjectNode error(JsonNode id, int code, String message) {
        ObjectNode o = MAP.createObjectNode();
        o.put("jsonrpc", "2.0");
        if (id != null) o.set("id", id);
        ObjectNode err = o.putObject("error");
        err.put("code", code);
        err.put("message", message);
        return o;
    }
}
