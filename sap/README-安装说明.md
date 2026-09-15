# SAP 侧安装操作单（BASIS 700）

4 个 RFC 函数，复制进 SE37 即可用，按顺序装。经典语法，700 可直接激活。

## 本目录文件

| 文件 | 函数 | 用途 |
|------|------|------|
| `ZRFC_AGENT_FM_READ.abap` | 读单个函数模块源码 | 函数名 → 函数组/程序/包含程序 + 源码 |
| `ZRFC_AGENT_FM_LIST.abap` | 按通配符/开发类列函数 | agent 搜同类对象（路由） |
| `ZRFC_AGENT_REPORT_READ.abap` | 读报表/程序源码 | 抓现有报表 |
| `ZRFC_AGENT_SQL_SELECT.abap` | 增强版动态查表 | 替代 RFC_READ_TABLE：JOIN/聚合/GROUP BY/子查询 |

> **要点**：函数组=`TFDIR.PNAME` 去 `SAPL` 前缀；函数名→包含程序名用标准 FM
> `RS_FUNCTION_POOL_CONTENTS`；源码用 `READ REPORT` 读。`ET_SOURCE` 行类型必须是 **CHAR255**
> （数据元素 `ZRFC_AGENT_LINE`），否则源行超 72 会报 `READ_REPORT_LINE_TOO_LONG`。

## 结构字段定义（SE11 建）

| 结构 | 组件 | 类型/长度 | 说明 |
|------|------|-----------|------|
| `ZRFC_AGENT_LINE` | LINE | CHAR 255 | 源码行（FM_READ/FM_LIST/REPORT_READ 共用） |
| `ZAG_LINE_FMLIST` | FMNAME | CHAR 30 | 函数名 |
| | FMGROUP | CHAR 30 | 函数组 |
| | PROGRAM | CHAR 40 | 主程序（SAPLxxx） |
| | INCLUDE | CHAR 40 | 包含程序名 |
| | DEVCLASS | CHAR 30 | 开发类 |

> `ZRFC_AGENT_SQL_SELECT` **零 DDIC 依赖**：结果走 STRING 导出参数（JSON），
> 无 TABLES 参数，不需要建任何结构。

## 步骤

1. **SE11 建结构 `ZRFC_AGENT_LINE`**（一次）：加字段 `LINE`，类型 CHAR、长度 255。（备选：建数据元素 `ZRFC_AGENT_LINE`=CHAR255；此时组件名=`ZRFC_AGENT_LINE`，node 侧取值字段名跟着改，本项目默认用结构方案 `LINE`。）
2. **SE11 建结构 `ZAG_LINE_FMLIST`**（一次，FM_LIST 需要）：字段见上表。
3. **SE37 建函数组**：如 `ZRFC_AGENT`，选你们自己的 Z 开发类。
4. **SE37 逐一建函数模块**：函数组选 `ZRFC_AGENT`，**勾选“远程调用(Remote-Enabled Module)”**，参数按各文件头部 `*"*"` 注释块照抄，源码整段替换为文件内容，保存激活。
5. **授权检查**（agent 的 RFC 账号）：`S_RFC`(RFC_TYPE=FUGR、RFC_NAME=`ZRFC_AGENT`、ACTVT=16)；读仓库源码还要 `S_DEVELOP`(ACTVT=1 Display)。开发账号与 RFC 账号建议分开。
6. **冒烟测试**（SE37 F8 或 node 侧）：
   - `ZRFC_AGENT_FM_LIST`：`IV_PATTERN='RFC%'` → 返回 `RFC_PING` 等；留空=全部
   - `ZRFC_AGENT_FM_READ`：`IV_FUNCNAME='RFC_PING'` → `EV_SUBRC=0`，`ET_SOURCE` 有内容
   - `ZRFC_AGENT_REPORT_READ`：`IV_PROGNAME='BCALV_GRID_DEMO'` → `EV_SUBRC=0`
   - `ZRFC_AGENT_SQL_SELECT`：`IV_FIELDS='VBELN,NETWR,ERDAT'`、`IV_FROM='VBAK'`、`IV_WHERE="VKORG = '1000'"`、`IV_UP_TO=10` → `EV_SUBRC=0`，`EV_JSON` 含 3 列元数据（NETWR 为 P 型）和 ≤10 行数据

## 常用兜底

| 问题 | 处理 |
|------|------|
| `RS_FUNCTION_POOL_CONTENTS` 失败 | 改调标准 FM `RPY_FUNCTIONMODULE_READ` 取源码 |
| 源行 >255（极少） | `READ REPORT` 截断不报错，node 侧容忍 |
| 中文源码乱码 | 非 Unicode 系统锁定代码页，读写统一 |
| 想抓表结构/数据/函数签名 | 无需装 Z 函数，直接调标准 FM（下表） |

| 需求 | 标准 FM |
|------|---------|
| 函数接口签名 | `RFC_GET_FUNCTION_INTERFACE` |
| 函数源码（替代） | `RPY_FUNCTIONMODULE_READ` |
| 报表源码（替代） | `RPY_PROGRAM_READ` |
| 表结构 / 表数据 | `DDIF_FIELDINFO_GET` / `RFC_READ_TABLE` |
| 连通性 | `RFC_PING` |

## 输出对照（node 侧取值）

- `ZRFC_AGENT_FM_READ` → `EV_SUBRC`(0/4/8)、`EV_FUNCGROUP`、`EV_PROGRAM`、`EV_INCLUDE`、`EV_MSG`、`ET_SOURCE[]`
- `ZRFC_AGENT_FM_LIST` → `ET_FM[]`（FMNAME/FMGROUP/PROGRAM/INCLUDE/DEVCLASS，INCLUDE 为完整包含程序名）
- `ZRFC_AGENT_REPORT_READ` → `EV_SUBRC`、`EV_MSG`、`ET_SOURCE[]`

> 源行尾随空格填充，node 侧 `LINE.trimEnd()` 后再用。

## ZRFC_AGENT_SQL_SELECT 专章

替代 `RFC_READ_TABLE`：单表 + WHERE 拼行（≤72 字符/行，LIKE 静默 0 行）那套限制全部消失。
一次调用支持 **JOIN / 聚合 / GROUP BY / HAVING / WHERE 子查询 / DISTINCT / ORDER BY**。

### 参数

| 参数 | 类型/默认 | 说明 |
|------|-----------|------|
| `IV_FIELDS` | STRING，`'*'` | SELECT 列表。`'*'` 仅单表；聚合列**必须加 AS 别名** |
| `IV_FROM` | STRING | FROM 子句整段（含 JOIN/ON/别名），如 `vbak AS a INNER JOIN vbap AS b ON a~vbeln = b~vbeln` |
| `IV_WHERE` | STRING | WHERE 子句（可含子查询），留空=不过滤 |
| `IV_GROUP_BY` | STRING | GROUP BY 列表 |
| `IV_HAVING` | STRING | HAVING 条件 |
| `IV_ORDER_BY` | STRING | 动态 ORDER BY 仅允许列名/别名（700 限制，不能写表达式） |
| `IV_UP_TO` | I，10000 | 行数上限；0=尽量全取（硬上限 50 万） |
| `IV_DISTINCT` | CHAR01 | `X`=加 DISTINCT（也可在 IV_FIELDS 内嵌 `DISTINCT`） |
| `EV_JSON` | STRING | **结果本体**：完整 JSON（元数据+行数据，见下方结构） |
| `EV_SUBRC/EV_MSG` | | 0=成功；4=入参非法（EV_MSG 说明）；8=SQL 错误（异常文本） |
| `EV_ROWCOUNT/EV_COLCOUNT` | I | 行数/列数 |

### 示例（node/JCo 侧 sap_jco_call）

```json
// 两表 JOIN + SUM + GROUP BY
{ "funcname": "ZRFC_AGENT_SQL_SELECT",
  "params": {
    "IV_FIELDS":   "a~VBELN AS VBELN, b~POSNR AS POSNR, SUM( b~NETWR ) AS NETWR",
    "IV_FROM":     "vbak AS a INNER JOIN vbap AS b ON a~vbeln = b~vbeln",
    "IV_WHERE":    "a~vkorg = '1000'",
    "IV_GROUP_BY": "a~vbeln, b~posnr",
    "IV_UP_TO":    100 } }
```

### 解析（node 侧）

直接 `JSON.parse(EV_JSON)`：

```json
{"colcount":3, "rowcount":10,
 "fields":[{"name":"VBELN","type":"C","length":10,"decimals":0}, ...],
 "rows":[["0010025604", 123456.50, "20240101"], ...]}
```

- `fields` 里 `type`：`I`整数 / `P`小数(DECIMALS 位) / `F`浮点 / `D`=YYYYMMDD / `T`=HHMMSS / `C`/`N` / `g`=STRING(RAW 输出十六进制)
- 数值列（I/P/F）不带引号，可直接当 number；日期/字符串列带引号
- 字符串已转义 `\ " \n \r \t`，`JSON.parse` 直接可用
- 数字按 DDIC 精度格式化（无前导零，带小数点）；NUMC/单据号保留前导零（字符串）
- 长度限制：ABAP STRING 理论上限 2GB，实际受 RFC 工作进程内存 + JCo 的 JVM 堆限制；
  建议 `IV_UP_TO` 控制在 1 万~10 万行；超大结果集用 IV_UP_TO + WHERE 翻页分批取

### 实测结果（2026-09 本系统实测）

| 场景 | 结果 |
|------|------|
| 单表多列 + WHERE + UP TO | ✅ 类型全对（C/N/D/P 保精度） |
| `'*'` 单表全字段展开（T001 77 列） | ✅ |
| INNER JOIN + SUM + GROUP BY | ✅ |
| COUNT(*) / MAX / DISTINCT / HAVING | ✅ |
| JOIN + GROUP BY + HAVING + ORDER BY 组合 | ✅ |
| WHERE 子查询（`IN (SELECT...)` / `= (SELECT...)`） | ❌ 动态 WHERE 解析器不支持，改 JOIN 或分两步查 |
| ORDER BY `ASC`/`DESC` | ❌ 动态 ORDER BY 仅列名，方向客户端排 |

### 兜底

| 问题 | 处理 |
|------|------|
| `EV_SUBRC=4` 聚合列必须加 AS 别名 | `SUM( b~NETWR ) AS NETWR`，不带别名 INTO CORRESPONDING FIELDS 会静默丢列 |
| JOIN 想用 `'*'` | 不支持，显式列字段；单表才能 `'*'`（自动展开全字段） |
| `ORDER BY SUM(...)` 或 `ORDER BY X DESC` 报错 | 700 动态 ORDER BY 只认列名/别名，排序/方向客户端处理 |
| WHERE 里写子查询报 `无法解释值 'SELECT'` | 本系统动态 WHERE 不支持子查询，改 JOIN 或分两步查 |
| FROM 内嵌套 SELECT 不支持 | 700 Open SQL 无派生表，改 JOIN 或分两步查 |
