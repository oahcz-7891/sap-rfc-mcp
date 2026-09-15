FUNCTION ZRFC_AGENT_FM_READ.
*"----------------------------------------------------------------------
*"*"本地接口:
*"  IMPORTING
*"     VALUE(IV_FUNCNAME) TYPE  RS38L_FNAM
*"  EXPORTING
*"     VALUE(EV_SUBRC) TYPE  SYSUBRC
*"     VALUE(EV_FUNCGROUP) TYPE  TLIBG-AREA
*"     VALUE(EV_PROGRAM) TYPE  PROGNAME
*"     VALUE(EV_INCLUDE) TYPE  PROGNAME
*"     VALUE(EV_MSG) TYPE  CHAR200
*"  TABLES
*"      ET_SOURCE STRUCTURE  ZRFC_AGENT_LINE
*"----------------------------------------------------------------------
* 读函数模块源码(BASIS 700 兼容,经典语法)
*
* 原理(不依赖 TFDIR 的 GROUP/INCLUDE 字段——这两个字段名各发行版不同):
*   1) TFDIR.PNAME 取程序名(如 SAPLZGR) → 函数组 = 去掉 SAPL 前缀(类型 TLIBG-AREA)
*   2) 标准 FM RS_FUNCTION_POOL_CONTENTS 得 "函数名→包含程序" 完整映射
*   3) READ REPORT 读 REPOSRC —— 官方语句,只读,无副作用,
*      不触发传输/激活/工作台锁
*
* 行类型 ZRFC_AGENT_LINE = CHAR255:
*   源行可能超过 72 字符,若行类型 < 实际行长会抛 READ_REPORT_LINE_TOO_LONG,
*   255 是 READ REPORT 支持的上限,能覆盖所有源行。
*
* 返回约定:
*   EV_SUBRC = 0  成功
*   EV_SUBRC = 4  函数模块在 TFDIR 中不存在
*   EV_SUBRC = 8  获取/读取失败(函数组不一致、包含程序不可读等)

  TYPES: BEGIN OF ty_fm_inc,
           funcname TYPE rs38l_fnam,
           include  TYPE progname,
         END OF ty_fm_inc.

  DATA: lt_functab TYPE TABLE OF rs38l_incl,
        ls_functab TYPE rs38l_incl,
        ls_fm_inc  TYPE ty_fm_inc,
        lv_pname   TYPE progname,
        lv_group   TYPE tlibg-area.

  CLEAR: ev_subrc, ev_funcgroup, ev_program, ev_include, ev_msg.
  REFRESH et_source.
  ev_subrc = 0.

* 1) 程序名 + 函数组
  SELECT SINGLE pname FROM tfdir INTO lv_pname
    WHERE funcname = iv_funcname.
  IF sy-subrc <> 0.
    ev_subrc = 4.
    CONCATENATE 'Function module not found in TFDIR: ' iv_funcname INTO ev_msg.
    EXIT.
  ENDIF.
  ev_program = lv_pname.
  IF lv_pname(4) = 'SAPL'.
    lv_group = lv_pname+4.
  ELSE.
    lv_group = lv_pname.
  ENDIF.
  ev_funcgroup = lv_group.

* 2) 函数名 → 包含程序(RS_FUNCTION_POOL_CONTENTS,老经典 FM)
  CALL FUNCTION 'RS_FUNCTION_POOL_CONTENTS'
    EXPORTING
      function_pool           = lv_group
    TABLES
      functab                 = lt_functab
    EXCEPTIONS
      function_pool_not_found = 1
      OTHERS                  = 2.
  IF sy-subrc <> 0.
    ev_subrc = 8.
    CONCATENATE 'RS_FUNCTION_POOL_CONTENTS failed for group: ' lv_group INTO ev_msg.
    EXIT.
  ENDIF.

  LOOP AT lt_functab INTO ls_functab.
    IF ls_functab-funcname = iv_funcname.
      ls_fm_inc-include = ls_functab-include.
      EXIT.
    ENDIF.
  ENDLOOP.
  IF ls_fm_inc-include IS INITIAL.
    ev_subrc = 8.
    CONCATENATE 'Include for function not found: ' iv_funcname INTO ev_msg.
    EXIT.
  ENDIF.
  ev_include = ls_fm_inc-include.

* 3) 读源码(行类型 ZRFC_AGENT_LINE = CHAR255,容纳超长源行)
  READ REPORT ev_include INTO et_source.
  IF sy-subrc <> 0.
    ev_subrc = 8.
    CONCATENATE 'Source include not readable: ' ev_include INTO ev_msg.
    EXIT.
  ENDIF.
  CONCATENATE 'OK (include: ' ev_include ')' INTO ev_msg.
ENDFUNCTION.