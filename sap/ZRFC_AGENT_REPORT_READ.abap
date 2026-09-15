FUNCTION ZRFC_AGENT_REPORT_READ.
*"----------------------------------------------------------------------
*"*"本地接口:
*"  IMPORTING
*"     VALUE(IV_PROGNAME) TYPE  PROGNAME
*"  EXPORTING
*"     VALUE(EV_SUBRC) TYPE  SYSUBRC
*"     VALUE(EV_MSG) TYPE  CHAR200
*"  TABLES
*"      ET_SOURCE STRUCTURE  ZRFC_AGENT_LINE
*"----------------------------------------------------------------------
* 读报表/程序源码(BASIS 700 兼容,经典语法)
* 原理:READ REPORT 直接读 REPOSRC,官方语句,只读,无副作用。
* 行类型 ZRFC_AGENT_LINE = CHAR255:源行可能超过 72 字符,
* 255 是 READ REPORT 支持的上限(行类型不足会抛 READ_REPORT_LINE_TOO_LONG)。
*
* 返回约定:
*   EV_SUBRC = 0  成功
*   EV_SUBRC = 8  程序不存在或不可读(授权不足/对象损坏等)

  CLEAR: ev_subrc, ev_msg.
  REFRESH et_source.
  ev_subrc = 0.

  READ REPORT iv_progname INTO et_source.
  IF sy-subrc <> 0.
    ev_subrc = 8.
    CONCATENATE 'Report not readable: ' iv_progname INTO ev_msg.
  ELSE.
    ev_msg = 'OK'.
  ENDIF.
ENDFUNCTION.