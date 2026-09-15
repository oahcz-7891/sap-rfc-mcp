FUNCTION ZRFC_AGENT_SQL_SELECT.
*"----------------------------------------------------------------------
*"*"本地接口:
*"  IMPORTING
*"     VALUE(IV_FIELDS) TYPE  STRING DEFAULT '*'
*"     VALUE(IV_FROM) TYPE  STRING
*"     VALUE(IV_WHERE) TYPE  STRING OPTIONAL
*"     VALUE(IV_GROUP_BY) TYPE  STRING OPTIONAL
*"     VALUE(IV_HAVING) TYPE  STRING OPTIONAL
*"     VALUE(IV_ORDER_BY) TYPE  STRING OPTIONAL
*"     VALUE(IV_UP_TO) TYPE  I DEFAULT 10000
*"     VALUE(IV_DISTINCT) TYPE  CHAR01 DEFAULT SPACE
*"  EXPORTING
*"     VALUE(EV_SUBRC) TYPE  SYSUBRC
*"     VALUE(EV_MSG) TYPE  CHAR200
*"     VALUE(EV_ROWCOUNT) TYPE  I 
*"     VALUE(EV_COLCOUNT) TYPE  I
*"     VALUE(EV_JSON) TYPE  STRING
*"----------------------------------------------------------------------
* 增强版动态查表 RFC(BASIS 700 兼容,经典语法) —— 替代 RFC_READ_TABLE
*
* 零 DDIC 依赖: 无 TABLES 参数(不需要先建任何 SE11 结构),SE37 直接建函数激活。
*
* 能力(700 Open SQL 动态 token 全支持):
*   - 多表 JOIN(INNER/LEFT OUTER,支持 表 AS 别名 与隐式别名)
*   - 字段别名 AS / 聚合 SUM MAX MIN AVG COUNT / DISTINCT
*   - GROUP BY / HAVING / ORDER BY(动态 ORDER BY 仅允许列名或别名,
*     不允许表达式 —— 700 限制)
*   - WHERE 内子查询(整段写在 IV_WHERE 即可)
*   - UP TO n ROWS(0=尽量全取,硬上限 50 万行)
*
* 不支持(700 Open SQL 本身没有):
*   - FROM 内派生表/CTE/@宿主变量/表达式计算列
*     -> 行间计算取回后客户端处理
*
* 类型推导(JSON fields 元数据 + 输出格式化):
*   表~字段 或 单表字段 -> DD03L 真实类型(数字/日期保精度)
*   SUM/MAX/MIN/AVG(字段) -> 源字段类型;  COUNT(*) -> I
*   JOIN 别名字段先查 "表 AS 别名" 映射,查不到则 STRING
*
* 安全: 只读;输入含 FOR UPDATE 或分号直接拒绝(EV_SUBRC=4)。
*
* 返回约定:
*   EV_SUBRC=0 成功, EV_MSG='OK: n rows'
*   EV_SUBRC=4 入参非法(EV_MSG 说明);  8=SQL 错误(EV_MSG=异常文本)
*   EV_JSON: 一个完整 JSON(元数据+行数据一起):
*     {"rowcount":N,"colcount":M,
*      "fields":[{"name":"VBELN","type":"C","length":10,"decimals":0},...],
*      "rows":[["0010025604",123456.50,"20240101"],...]}
*     typekind: C N D T I P F g(STRING)
*     数值列(I/P/F)不引号;其它列字符串并转义 \ " 换行 CR TAB
*
* 使用注意:
*   - 聚合列必须加 AS 别名: SUM( b~NETWR ) AS NETWR(否则 EV_SUBRC=4)
*   - '*' 仅支持单表;JOIN 必须显式列出字段
*----------------------------------------------------------------------

  TYPES: BEGIN OF ty_col,
           name     TYPE c LENGTH 30,
           typekind TYPE c LENGTH 1,   " C N D T I P F g(STRING)
           leng     TYPE i,
           decimals TYPE i,
           outlen   TYPE i,
         END OF ty_col,
         BEGIN OF ty_alias,
           alias TYPE c LENGTH 30,
           tab   TYPE c LENGTH 30,
         END OF ty_alias.

  DATA: lt_cols    TYPE STANDARD TABLE OF ty_col,
        ls_col     TYPE ty_col,
        lt_alias   TYPE STANDARD TABLE OF ty_alias,
        ls_alias   TYPE ty_alias,
        lt_toks    TYPE STANDARD TABLE OF string,
        lt_ftoks   TYPE STANDARD TABLE OF string,
        lt_where   TYPE STANDARD TABLE OF string,
        lt_group   TYPE STANDARD TABLE OF string,
        lt_having  TYPE STANDARD TABLE OF string,
        lt_order   TYPE STANDARD TABLE OF string,
        lt_parts   TYPE STANDARD TABLE OF string,
        lt_lines   TYPE STANDARD TABLE OF string,
        lt_rows    TYPE STANDARD TABLE OF string,
        lt_cells   TYPE STANDARD TABLE OF string,
        lt_comp    TYPE cl_abap_structdescr=>component_table,
        ls_comp    TYPE cl_abap_structdescr=>component,
        lo_struct  TYPE REF TO cl_abap_structdescr,
        lo_table   TYPE REF TO cl_abap_tabledescr,
        lo_data    TYPE REF TO data,
        lo_ex      TYPE REF TO cx_root,
        lv_fields_tok TYPE string,
        lv_from_tok   TYPE string,
        lv_from_up    TYPE string,
        lv_tabname    TYPE c LENGTH 30,
        lv_tok     TYPE string,
        lv_next    TYPE string,
        lv_prev    TYPE string,
        lv_expr    TYPE string,
        lv_inner   TYPE string,
        lv_func    TYPE c LENGTH 10,
        lv_tab     TYPE c LENGTH 30,
        lv_fld     TYPE c LENGTH 30,
        lv_dt      TYPE dd03l-datatype,
        lv_dl      TYPE dd03l-leng,
        lv_dd      TYPE dd03l-decimals,
        lv_ok      TYPE c LENGTH 1,
        lv_elem    TYPE REF TO cl_abap_elemdescr,
        lv_name    TYPE c LENGTH 30,
        lv_jnum    TYPE c LENGTH 3,
        lv_str     TYPE string,
        lv_up      TYPE string,
        lv_char    TYPE c LENGTH 1,
        lv_seg     TYPE c LENGTH 1024,
        lv_numstr  TYPE c LENGTH 12,
        lv_comma   TYPE c LENGTH 1 VALUE ',',
        lv_acc     TYPE c LENGTH 255,
        lv_alen    TYPE i,
        lv_numchars TYPE c LENGTH 13 VALUE '0123456789.+-',
        lv_sp      TYPE c LENGTH 1,
        lv_j0      TYPE i,
        lv_jt      TYPE i,
        lv_i       TYPE i,
        lv_j       TYPE i,
        lv_p       TYPE i,
        lv_p1      TYPE i,
        lv_p2      TYPE i,
        lv_in_q    TYPE i,
        lv_rows    TYPE i,
        lv_n       TYPE i,
        lv_distinct TYPE c LENGTH 1.

  FIELD-SYMBOLS: <lt_tab> TYPE STANDARD TABLE,
                 <ls_row> TYPE any,
                 <lv_val> TYPE any.

  CLEAR: ev_subrc, ev_msg, ev_rowcount, ev_colcount.
  lv_sp = space.

* ---- 1) 入参安全检查 ------------------------------------------------
  lv_from_tok = iv_from.
  CONDENSE lv_from_tok.
  lv_from_up = lv_from_tok.
  TRANSLATE lv_from_up TO UPPER CASE.
  WHILE lv_from_up CP '*.'.
    lv_i = strlen( lv_from_up ) - 1.
    lv_from_up = lv_from_up+0(lv_i).
    lv_from_tok = lv_from_tok+0(lv_i).
  ENDWHILE.
  CONDENSE: lv_from_up, lv_from_tok.

  IF lv_from_up IS INITIAL.
    ev_subrc = 4.
    ev_msg = 'IV_FROM 不能为空'.
    RETURN.
  ENDIF.
  IF lv_from_up CS 'FOR UPDATE' OR iv_where CS 'FOR UPDATE'.
    ev_subrc = 4.
    ev_msg = '禁止 FOR UPDATE(本函数只读)'.
    RETURN.
  ENDIF.
  IF iv_where CS ';' OR iv_fields CS ';' OR iv_from CS ';'.
    ev_subrc = 4.
    ev_msg = '禁止分号(仅单条 SELECT)'.
    RETURN.
  ENDIF.

* ---- 2) SELECT 列表 token(可内嵌 DISTINCT) --------------------------
  lv_fields_tok = iv_fields.
  CONDENSE lv_fields_tok.
  IF lv_fields_tok IS INITIAL.
    lv_fields_tok = '*'.
  ENDIF.
  lv_up = lv_fields_tok.
  TRANSLATE lv_up TO UPPER CASE.
  IF lv_up CP 'DISTINCT *'.
    lv_i = strlen( lv_fields_tok ) - 9.
    lv_fields_tok = lv_fields_tok+9(lv_i).
    CONDENSE lv_fields_tok.
    lv_distinct = 'X'.
  ENDIF.
  IF iv_distinct = 'X'.
    lv_distinct = 'X'.
  ENDIF.

* ---- 3) FROM 别名映射 + 单表识别(用于 a~fld 类型推导) ----------------
  SPLIT lv_from_up AT space INTO TABLE lt_ftoks.
  DELETE lt_ftoks WHERE table_line IS INITIAL.
* 单表名(FROM 只有一个 token 且无 ~/括号时);用于 '*' 展开与类型推导
* 注意:不能用 NS ' ' 判断 —— CS/NS 类比较会忽略模式串尾随空格,
* NS ' ' 恒为假(实测);改用 token 数=1 判断
  DESCRIBE TABLE lt_ftoks LINES lv_n.
  IF lv_n = 1 AND lv_from_up NS '~' AND lv_from_up NS '('.
    lv_tabname = lv_from_up.
  ENDIF.
  LOOP AT lt_ftoks INTO lv_tok.
    lv_i = sy-tabix.
    lv_p = lv_i + 1.
    READ TABLE lt_ftoks INTO lv_next INDEX lv_p.
    IF sy-subrc <> 0.
      CLEAR lv_next.
    ENDIF.
    IF lv_tok = 'AS'.
*     "表 AS 别名"
      lv_p = lv_i - 1.
      READ TABLE lt_ftoks INTO lv_prev INDEX lv_p.
      IF sy-subrc = 0 AND lv_next IS NOT INITIAL
         AND lv_prev NP '*~*' AND lv_prev NS '('.
        CLEAR ls_alias.
        ls_alias-alias = lv_next.
        ls_alias-tab   = lv_prev.
        APPEND ls_alias TO lt_alias.
      ENDIF.
    ELSEIF lv_tok NP '*~*' AND lv_tok NS '('
           AND lv_next IS NOT INITIAL AND lv_next <> 'AS'.
*     隐式别名: "vbak a"(下一 token 不是关键字/表达式)
      IF lv_next <> 'INNER' AND lv_next <> 'JOIN'
         AND lv_next <> 'LEFT' AND lv_next <> 'OUTER'
         AND lv_next <> 'RIGHT' AND lv_next <> 'ON'
         AND lv_next <> 'AND' AND lv_next <> 'OR'
         AND lv_next <> '=' AND lv_next <> '<>'
         AND lv_next NP '*~*' AND lv_next NS '('
         AND lv_tok <> 'INNER' AND lv_tok <> 'JOIN'
         AND lv_tok <> 'LEFT' AND lv_tok <> 'OUTER'
         AND lv_tok <> 'RIGHT' AND lv_tok <> 'ON'
         AND lv_tok <> 'AND' AND lv_tok <> 'OR'.
        CLEAR ls_alias.
        ls_alias-alias = lv_next.
        ls_alias-tab   = lv_tok.
        APPEND ls_alias TO lt_alias.
      ENDIF.
    ENDIF.
  ENDLOOP.

* ---- 4) 字段 token 列表(以下全部在 TRY 内,转储转为可读错误) ---------
  TRY.
  REFRESH lt_toks.
  IF lv_fields_tok = '*'.
    IF lv_tabname IS INITIAL.
      ev_subrc = 4.
      ev_msg = 'JOIN 查询请显式列出字段并加 AS 别名'.
      RETURN.
    ENDIF.
    SELECT fieldname FROM dd03l INTO lv_str
      WHERE tabname = lv_tabname AND fieldname NOT LIKE '.%'
        AND datatype <> 'RSTR'
      ORDER BY fieldname.
      APPEND lv_str TO lt_toks.
    ENDSELECT.
  ELSE.
*   按逗号切分(单引号内逗号不切)
*   注意:不能用 CONCATENATE 逐字符累积 —— 它丢弃每个源的尾随空格,
*   单空格字符作源时被整段丢弃,token 内空格会全部消失(实测)!
    lv_i = 0.
    lv_in_q = 0.
    CLEAR lv_acc.
    CLEAR lv_alen.
    lv_j = strlen( lv_fields_tok ).
    WHILE lv_i < lv_j.
      lv_char = lv_fields_tok+lv_i(1).
      IF lv_char = ''''.
        lv_in_q = 1 - lv_in_q.
      ENDIF.
      IF lv_char = ',' AND lv_in_q = 0.
        APPEND lv_acc TO lt_toks.
        CLEAR lv_acc.
        CLEAR lv_alen.
      ELSEIF lv_alen < 254.
        lv_acc+lv_alen(1) = lv_char.
        lv_alen = lv_alen + 1.
      ENDIF.
      lv_i = lv_i + 1.
    ENDWHILE.
    IF lv_alen > 0.
      APPEND lv_acc TO lt_toks.
    ENDIF.
  ENDIF.

* ---- 5) 逐列解析: 列名 + 类型 ---------------------------------------
  LOOP AT lt_toks INTO lv_tok.
    CONDENSE lv_tok.
    IF lv_tok IS INITIAL.
      CONTINUE.
    ENDIF.
    WHILE lv_tok CP '*.'.
      lv_j = strlen( lv_tok ) - 1.
      lv_tok = lv_tok+0(lv_j).
      CONDENSE lv_tok.
    ENDWHILE.

    lv_up = lv_tok.
    TRANSLATE lv_up TO UPPER CASE.
    CLEAR: ls_col, ls_comp, lv_name, lv_tab, lv_fld, lv_func, lv_elem.

*   5a) 拆词定别名(弃用 FIND —— 本系统会裁剪模式串尾随空格,
*       ' AS ' 变 ' AS' 导致 fdpos 错乱;改用分词比较)
    SPLIT lv_up AT space INTO TABLE lt_ftoks.
    DELETE lt_ftoks WHERE table_line IS INITIAL.
    DESCRIBE TABLE lt_ftoks LINES lv_n.
    CLEAR lv_name.
    IF lv_n >= 3.
      lv_p = lv_n - 1.
      READ TABLE lt_ftoks INTO lv_str INDEX lv_p.
      IF lv_str = 'AS'.
        lv_p = lv_n.
        READ TABLE lt_ftoks INTO lv_name INDEX lv_p.
        IF sy-subrc <> 0.
          CLEAR lv_name.
        ENDIF.
        REFRESH lt_parts.
        lv_i = 1.
        lv_p = lv_n - 1.
        WHILE lv_i < lv_p.
          lv_j = lv_i.
          READ TABLE lt_ftoks INTO lv_str INDEX lv_j.
          APPEND lv_str TO lt_parts.
          lv_i = lv_i + 1.
        ENDWHILE.
      ENDIF.
    ENDIF.
    CONCATENATE LINES OF lt_parts INTO lv_expr SEPARATED BY space.
    IF lv_expr IS INITIAL.
      CONCATENATE LINES OF lt_ftoks INTO lv_expr SEPARATED BY space.
    ENDIF.

*   5b) 类型推导
    IF lv_expr CP '*(*)*'.
*     聚合/函数列 —— 手动扫描括号位置(本系统 FIND 对部分模式不可靠)
      lv_j = strlen( lv_expr ).
      lv_p1 = lv_j.
      lv_p2 = lv_j.
      lv_i = 0.
      WHILE lv_i < lv_j.
        IF lv_expr+lv_i(1) = '('.
          IF lv_p1 = lv_j.
            lv_p1 = lv_i.
          ENDIF.
        ENDIF.
        IF lv_expr+lv_i(1) = ')'.
          IF lv_p2 = lv_j.
            lv_p2 = lv_i.
          ENDIF.
        ENDIF.
        lv_i = lv_i + 1.
      ENDWHILE.
      IF lv_p1 >= lv_j OR lv_p2 >= lv_j OR lv_p2 <= lv_p1.
        ev_subrc = 4.
        CONCATENATE '聚合表达式括号缺失或不匹配: ' lv_tok INTO ev_msg SEPARATED BY space.
        RETURN.
      ENDIF.
      IF lv_p1 > 0.
        lv_func = lv_expr+0(lv_p1).
        CONDENSE lv_func.
      ENDIF.
      lv_j = lv_p2 - lv_p1 - 1.
      IF lv_j > 0.
        lv_p = lv_p1 + 1.
        lv_inner = lv_expr+lv_p(lv_j).
        SHIFT lv_inner LEFT.
        CONDENSE lv_inner.
        IF lv_inner CP 'DISTINCT *'.
          SHIFT lv_inner BY 9 PLACES LEFT.
          CONDENSE lv_inner.
        ENDIF.
      ENDIF.

      IF lv_func = 'COUNT'.
        ls_col-typekind = 'I'.
        ls_col-leng = 4.
        ls_col-outlen = 11.
        lv_elem = cl_abap_elemdescr=>get_i( ).
      ELSE.
*       源字段类型
        IF lv_inner CS '~'.
          SPLIT lv_inner AT '~' INTO lv_tab lv_fld.
          CONDENSE: lv_tab, lv_fld.
          READ TABLE lt_alias INTO ls_alias WITH KEY alias = lv_tab.
          IF sy-subrc = 0.
            lv_tab = ls_alias-tab.
          ENDIF.
        ELSEIF lv_tabname IS NOT INITIAL.
          lv_tab = lv_tabname.
          lv_fld = lv_inner.
        ENDIF.
        TRANSLATE: lv_tab TO UPPER CASE, lv_fld TO UPPER CASE.
        IF lv_tab IS NOT INITIAL AND lv_fld IS NOT INITIAL
           AND lv_fld <> '*'.
          PERFORM read_dd03l USING lv_tab lv_fld
                            CHANGING lv_dt lv_dl lv_dd lv_ok.
          IF lv_ok = 'X'.
            PERFORM map_type USING lv_dt lv_dl lv_dd
                      CHANGING ls_col-typekind ls_col-leng
                               ls_col-decimals ls_col-outlen lv_elem.
          ENDIF.
        ENDIF.
        IF lv_elem IS INITIAL.
*         推导不出 -> STRING
          ls_col-typekind = 'g'.
          lv_elem = cl_abap_elemdescr=>get_string( ).
        ENDIF.
      ENDIF.
      IF lv_name IS INITIAL.
        ev_subrc = 4.
        CONCATENATE '聚合/函数列必须加 AS 别名: ' lv_tok
          INTO ev_msg SEPARATED BY space.
        RETURN.
      ENDIF.
    ELSEIF lv_expr CS '~'.
*     表(或别名)~字段
      SPLIT lv_expr AT '~' INTO lv_tab lv_fld.
      CONDENSE: lv_tab, lv_fld.
      READ TABLE lt_alias INTO ls_alias WITH KEY alias = lv_tab.
      IF sy-subrc = 0.
        lv_tab = ls_alias-tab.
      ENDIF.
      TRANSLATE: lv_tab TO UPPER CASE, lv_fld TO UPPER CASE.
      PERFORM read_dd03l USING lv_tab lv_fld
                        CHANGING lv_dt lv_dl lv_dd lv_ok.
      IF lv_ok = 'X'.
        PERFORM map_type USING lv_dt lv_dl lv_dd
                  CHANGING ls_col-typekind ls_col-leng
                           ls_col-decimals ls_col-outlen lv_elem.
      ELSE.
        ls_col-typekind = 'g'.
        lv_elem = cl_abap_elemdescr=>get_string( ).
      ENDIF.
      IF lv_name IS INITIAL.
        lv_name = lv_fld.
      ENDIF.
    ELSE.
*     普通字段
      IF lv_tabname IS NOT INITIAL.
        lv_fld = lv_expr.
        TRANSLATE lv_fld TO UPPER CASE.
        PERFORM read_dd03l USING lv_tabname lv_fld
                          CHANGING lv_dt lv_dl lv_dd lv_ok.
        IF lv_ok = 'X'.
          PERFORM map_type USING lv_dt lv_dl lv_dd
                    CHANGING ls_col-typekind ls_col-leng
                             ls_col-decimals ls_col-outlen lv_elem.
        ENDIF.
      ENDIF.
      IF lv_elem IS INITIAL.
        ls_col-typekind = 'g'.
        lv_elem = cl_abap_elemdescr=>get_string( ).
      ENDIF.
      IF lv_name IS INITIAL.
        lv_name = lv_expr.
        TRANSLATE lv_name TO UPPER CASE.
      ENDIF.
    ENDIF.

    IF lv_name IS INITIAL.
      lv_name = 'VALUE'.
    ENDIF.

*   5c) 列名清洗(合法 ABAP 名,<=30)
    lv_j = strlen( lv_name ).
    lv_i = 0.
    WHILE lv_i < lv_j AND lv_i < 30.
      lv_char = lv_name+lv_i(1).
      IF lv_char CA 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'.
      ELSE.
        lv_name+lv_i(1) = '_'.
      ENDIF.
      lv_i = lv_i + 1.
    ENDWHILE.
    IF strlen( lv_name ) > 30.
      lv_name = lv_name(30).
    ENDIF.
    IF lv_name IS INITIAL.
      lv_name = 'VALUE'.
    ENDIF.
    lv_char = lv_name(1).
    IF lv_char CA '0123456789_'.
      CONCATENATE 'C' lv_name INTO lv_name.
      lv_name = lv_name(30).
    ENDIF.

*   5d) 重名去重
    lv_j = 2.
    lv_i = 0.
    WHILE lv_i = 0.
      READ TABLE lt_cols WITH KEY name = lv_name TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        lv_i = 1.
      ELSE.
        lv_jnum = lv_j.
        CONCATENATE ls_col-name '_' lv_jnum INTO lv_name.
        IF strlen( lv_name ) > 30.
          lv_name = lv_name(30).
        ENDIF.
        lv_j = lv_j + 1.
      ENDIF.
    ENDWHILE.

    ls_col-name  = lv_name.
    ls_comp-name = lv_name.
    ls_comp-type = lv_elem.
    APPEND ls_col TO lt_cols.
    APPEND ls_comp TO lt_comp.
  ENDLOOP.

  DESCRIBE TABLE lt_cols LINES ev_colcount.
  IF ev_colcount = 0.
    ev_subrc = 4.
    ev_msg = '字段列表解析结果为空'.
    RETURN.
  ENDIF.

* ---- 6) RTTS 建动态内表 ---------------------------------------------
  lo_struct = cl_abap_structdescr=>create( lt_comp ).
  lo_table  = cl_abap_tabledescr=>create(
                p_line_type  = lo_struct
                p_table_kind = cl_abap_tabledescr=>tablekind_std ).
  CREATE DATA lo_data TYPE HANDLE lo_table.
  ASSIGN lo_data->* TO <lt_tab>.

* ---- 7) 动态子句(空 = 忽略该子句) -----------------------------------
  REFRESH: lt_where, lt_group, lt_having, lt_order.
  lv_str = iv_where.
  CONDENSE lv_str.
  IF lv_str IS NOT INITIAL. APPEND lv_str TO lt_where. ENDIF.
  lv_str = iv_group_by.
  CONDENSE lv_str.
  IF lv_str IS NOT INITIAL.
*   按逗号切,每列一行(动态 token 用 itab 传,绕开字面量空格问题)
    SPLIT lv_str AT lv_comma INTO TABLE lt_parts.
    LOOP AT lt_parts INTO lv_tok.
      CONDENSE lv_tok.
      IF lv_tok IS NOT INITIAL.
        APPEND lv_tok TO lt_group.
      ENDIF.
    ENDLOOP.
  ENDIF.
  lv_str = iv_having.
  CONDENSE lv_str.
  IF lv_str IS NOT INITIAL. APPEND lv_str TO lt_having. ENDIF.
  lv_str = iv_order_by.
  CONDENSE lv_str.
  IF lv_str IS NOT INITIAL.
    SPLIT lv_str AT lv_comma INTO TABLE lt_parts.
    LOOP AT lt_parts INTO lv_tok.
      CONDENSE lv_tok.
      IF lv_tok IS NOT INITIAL.
        APPEND lv_tok TO lt_order.
      ENDIF.
    ENDLOOP.
  ENDIF.

  lv_rows = iv_up_to.
  IF lv_rows <= 0.
    lv_rows = 500000.
  ELSEIF lv_rows > 500000.
    lv_rows = 500000.
  ENDIF.

* ---- 8) 执行(只读) --------------------------------------------------
  TRY.
      IF lv_distinct = 'X'.
        SELECT DISTINCT (lt_toks) FROM (lv_from_tok)
          INTO CORRESPONDING FIELDS OF TABLE <lt_tab>
          UP TO lv_rows ROWS
          WHERE (lt_where)
          GROUP BY (lt_group)
          HAVING (lt_having)
          ORDER BY (lt_order).
      ELSE.
        SELECT (lt_toks) FROM (lv_from_tok)
          INTO CORRESPONDING FIELDS OF TABLE <lt_tab>
          UP TO lv_rows ROWS
          WHERE (lt_where)
          GROUP BY (lt_group)
          HAVING (lt_having)
          ORDER BY (lt_order).
      ENDIF.
    CATCH cx_sy_dynamic_osql_error INTO lo_ex.
      ev_subrc = 8.
      lv_str = lo_ex->get_text( ).
      ev_msg = lv_str.
      RETURN.
    CATCH cx_root INTO lo_ex.
      ev_subrc = 8.
      lv_str = lo_ex->get_text( ).
      ev_msg = lv_str.
      RETURN.
  ENDTRY.

* ---- 9) EV_JSON(元数据+行数据都在 JSON 里) ---------------------------
* 先取行数(JSON 组装要用)
  DESCRIBE TABLE <lt_tab> LINES ev_rowcount.
* ===== 拼 EV_JSON =====
    REFRESH lt_lines.
*   fields 数组
    REFRESH lt_parts.
    LOOP AT lt_cols INTO ls_col.
      CLEAR lv_str.
      lv_str = ls_col-name.
      SHIFT lv_str RIGHT DELETING TRAILING space.
      CONCATENATE '{"name":"' lv_str '","type":"'
        ls_col-typekind '",' INTO lv_str.
      CLEAR lv_seg.
      WRITE ls_col-leng TO lv_seg.
      SHIFT lv_seg LEFT DELETING LEADING space.
      CONCATENATE lv_str '"length":' lv_seg ',' INTO lv_str.
      CLEAR lv_seg.
      WRITE ls_col-decimals TO lv_seg.
      SHIFT lv_seg LEFT DELETING LEADING space.
      CONCATENATE lv_str '"decimals":' lv_seg '}' INTO lv_str.
      APPEND lv_str TO lt_parts.
    ENDLOOP.
    CONCATENATE LINES OF lt_parts INTO lv_str SEPARATED BY lv_comma.
    CONCATENATE '"fields":[' lv_str '],' INTO lv_str.
    APPEND lv_str TO lt_lines.

*   rows 数组
    REFRESH lt_rows.
    LOOP AT <lt_tab> ASSIGNING <ls_row>.
      REFRESH lt_cells.
      DO ev_colcount TIMES.
        ASSIGN COMPONENT sy-index OF STRUCTURE <ls_row> TO <lv_val>.
        IF sy-subrc <> 0.
          CONTINUE.
        ENDIF.
        READ TABLE lt_cols INTO ls_col INDEX sy-index.
        CLEAR lv_str.
        CASE ls_col-typekind.
          WHEN 'I' OR 'P' OR 'F'.
            CLEAR lv_str.
            lv_str = <lv_val>.
*           逐字符去首尾非数字字符(避开本系统空格模式的全部坑)
            lv_j0 = strlen( lv_str ).
            lv_j = lv_j0.
            lv_i = 0.
            WHILE lv_i < lv_j AND lv_str+lv_i(1) CN lv_numchars.
              lv_i = lv_i + 1.
            ENDWHILE.
            lv_p = lv_j - 1.
            WHILE lv_j > lv_i AND lv_str+lv_p(1) CN lv_numchars.
              lv_j = lv_p.
              lv_p = lv_j - 1.
            ENDWHILE.
            lv_jt = lv_j.
            IF lv_jt > lv_i.
              lv_p = lv_jt - lv_i.
              lv_str = lv_str+lv_i(lv_p).
            ELSE.
              CLEAR lv_str.
            ENDIF.
*           P 的负号在尾,移到头(JSON number 需要)
            lv_j = strlen( lv_str ).
            IF lv_j > 1.
              lv_p = lv_j - 1.
              IF lv_str+lv_p(1) = '-'.
                lv_j = lv_p.
                CONCATENATE '-' lv_str+0(lv_j) INTO lv_str.
              ENDIF.
            ENDIF.
          WHEN OTHERS.
            CLEAR lv_str.
            lv_str = <lv_val>.
            SHIFT lv_str RIGHT DELETING TRAILING space.
            PERFORM json_esc CHANGING lv_str.
            CONCATENATE '"' lv_str '"' INTO lv_str.
        ENDCASE.
        APPEND lv_str TO lt_cells.
      ENDDO.
      CONCATENATE LINES OF lt_cells INTO lv_str SEPARATED BY lv_comma.
      CONCATENATE '[' lv_str ']' INTO lv_str.
      APPEND lv_str TO lt_rows.
    ENDLOOP.
    CLEAR lv_str.
    CONCATENATE LINES OF lt_rows INTO lv_str SEPARATED BY lv_comma.
    CONCATENATE '"rows":[' lv_str ']' INTO lv_str.
    APPEND lv_str TO lt_lines.

*   组装: rowcount/colcount + fields + rows
    REFRESH lt_parts.
    CLEAR lv_seg.
    WRITE ev_rowcount TO lv_seg.
    SHIFT lv_seg LEFT DELETING LEADING space.
    CONCATENATE '"rowcount":' lv_seg ',' INTO lv_str.
    APPEND lv_str TO lt_parts.
    CLEAR lv_seg.
    WRITE ev_colcount TO lv_seg.
    SHIFT lv_seg LEFT DELETING LEADING space.
    CONCATENATE '"colcount":' lv_seg ',' INTO lv_str.
    APPEND lv_str TO lt_parts.
    APPEND LINES OF lt_lines TO lt_parts.
    CONCATENATE LINES OF lt_parts INTO ev_json.

  CATCH cx_sy_range_out_of_bounds INTO lo_ex.
    ev_subrc = 8.
    lv_str = lo_ex->get_text( ).
    CONCATENATE '字符串偏移越界:' lv_str INTO ev_msg SEPARATED BY space.
    RETURN.
  CATCH cx_root INTO lo_ex.
    ev_subrc = 8.
    lv_str = lo_ex->get_text( ).
    CONCATENATE '解析/输出异常: ' lv_str INTO ev_msg SEPARATED BY space.
    RETURN.
  ENDTRY.

  ev_subrc = 0.
  WRITE ev_rowcount TO lv_numstr.
  SHIFT lv_numstr LEFT DELETING LEADING space.
  CONCATENATE 'OK: ' lv_numstr ' rows' INTO ev_msg SEPARATED BY space.

ENDFUNCTION.

*----------------------------------------------------------------------
* 查 DD03L 字段定义(活动版本)
*----------------------------------------------------------------------
FORM read_dd03l USING p_tab TYPE dd03l-tabname
                      p_fld TYPE dd03l-fieldname
                CHANGING p_dt TYPE dd03l-datatype
                         p_len TYPE dd03l-leng
                         p_dec TYPE dd03l-decimals
                         p_ok TYPE c.
  CLEAR: p_dt, p_len, p_dec, p_ok.
  SELECT SINGLE datatype leng decimals FROM dd03l
    INTO (p_dt, p_len, p_dec)
    WHERE tabname = p_tab AND fieldname = p_fld AND as4local = 'A'.
  IF sy-subrc = 0.
    p_ok = 'X'.
  ENDIF.
ENDFORM.

*----------------------------------------------------------------------
* DDIC 类型 -> 元素描述符 + 输出元数据
*----------------------------------------------------------------------
FORM map_type USING p_dt TYPE dd03l-datatype p_len TYPE dd03l-leng
                    p_dec TYPE dd03l-decimals
              CHANGING p_tk TYPE c p_len2 TYPE i p_dec2 TYPE i
                       p_out TYPE i p_elem TYPE REF TO cl_abap_elemdescr.
  DATA: lv_len TYPE i,
        lv_dec TYPE i,
        lv_out TYPE i,
        lv_plen TYPE i,
        lo_el  TYPE REF TO cl_abap_elemdescr.

  lv_len = p_len.
  lv_dec = p_dec.
  IF lv_dec < 0.
    lv_dec = 0.
  ENDIF.

  CASE p_dt.
    WHEN 'INT1' OR 'INT2' OR 'INT4'.
      lv_out = 11.
      lo_el = cl_abap_elemdescr=>get_i( ).
      p_tk = 'I'.
    WHEN 'FLTP'.
      lv_out = 24.
      lo_el = cl_abap_elemdescr=>get_f( ).
      p_tk = 'F'.
    WHEN 'CURR' OR 'QUAN' OR 'DEC'.
      lv_plen = lv_len / 2 + 1.
      IF lv_plen < 1.  lv_plen = 1.   ENDIF.
      IF lv_plen > 16. lv_plen = 16.  ENDIF.
      IF lv_dec > 14.  lv_dec = 14.   ENDIF.
      lv_out = lv_len + 2.
      lo_el = cl_abap_elemdescr=>get_p( p_length = lv_plen
                                        p_decimals = lv_dec ).
      p_tk = 'P'.
      lv_len = lv_plen.
    WHEN 'DATS'.
      p_tk = 'D'.
      lv_len = 8.
      lv_out = 8.
      lo_el = cl_abap_elemdescr=>get_d( ).
    WHEN 'TIMS'.
      p_tk = 'T'.
      lv_len = 6.
      lv_out = 6.
      lo_el = cl_abap_elemdescr=>get_t( ).
    WHEN 'NUMC'.
      p_tk = 'N'.
      lv_out = lv_len.
      lo_el = cl_abap_elemdescr=>get_n( p_length = lv_len ).
    WHEN 'CHAR' OR 'LCHR' OR 'CLNT' OR 'CUKY' OR 'UNIT' OR 'SSTR'.
      IF lv_len > 4000 OR lv_len < 1.
        p_tk = 'g'.
        lv_out = 0.
        lv_len = 0.
        lo_el = cl_abap_elemdescr=>get_string( ).
      ELSE.
        p_tk = 'C'.
        lv_out = lv_len.
        lo_el = cl_abap_elemdescr=>get_c( p_length = lv_len ).
      ENDIF.
    WHEN OTHERS.
*     STRING/RAW/LRAW/未知 -> STRING(RAW 输出十六进制文本)
      p_tk = 'g'.
      lv_len = 0.
      lv_dec = 0.
      lv_out = 0.
      lo_el = cl_abap_elemdescr=>get_string( ).
  ENDCASE.

  p_len2 = lv_len.
  p_dec2 = lv_dec.
  p_out  = lv_out.
  p_elem = lo_el.
ENDFORM.

*----------------------------------------------------------------------
* JSON 字符串转义(\ " CRLF CR LF TAB)
* 注意顺序: 先转义反斜杠,再引号,再控制字符(后引入的 \ 不再被转义)
*----------------------------------------------------------------------
FORM json_esc CHANGING p_s TYPE string.
  DATA: lv_bs TYPE c LENGTH 1 VALUE '\',
        lv_quo TYPE c LENGTH 1 VALUE '"',
        lv_nl TYPE c LENGTH 1,
        lv_cr TYPE c LENGTH 1,
        lv_tab TYPE c LENGTH 1.

  lv_nl = cl_abap_char_utilities=>newline.
  lv_cr = cl_abap_char_utilities=>cr_lf(1).
  lv_tab = cl_abap_char_utilities=>horizontal_tab.

  REPLACE ALL OCCURRENCES OF lv_bs IN p_s WITH '\\'.
  REPLACE ALL OCCURRENCES OF lv_quo IN p_s WITH '\"'.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf
    IN p_s WITH '\r\n'.
  REPLACE ALL OCCURRENCES OF lv_cr IN p_s WITH '\r'.
  REPLACE ALL OCCURRENCES OF lv_nl IN p_s WITH '\n'.
  REPLACE ALL OCCURRENCES OF lv_tab IN p_s WITH '\t'.
ENDFORM.
