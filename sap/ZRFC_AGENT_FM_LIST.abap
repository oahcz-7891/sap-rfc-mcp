FUNCTION ZRFC_AGENT_FM_LIST.
*"----------------------------------------------------------------------
*"*"本地接口:
*"  IMPORTING
*"     VALUE(IV_PATTERN) TYPE  CHAR30
*"     VALUE(IV_DEVCLASS) TYPE  DEVCLASS
*"  TABLES
*"      ET_FM STRUCTURE  ZAG_LINE_FMLIST
*"----------------------------------------------------------------------
* 按名字通配符(可选)+ 开发类(可选)列出函数模块,供 agent 搜索同类对象。
* 输出字段:FMNAME 函数名 / FMGROUP 函数组 / PROGRAM 程序名 /
*          INCLUDE 包含程序(完整名) / DEVCLASS 开发类
*
* 模式写法:Open SQL 的 LIKE 只认 % 和 _;本 FM 自动把 * 转成 %,
* 所以 IV_PATTERN 传 'Z*' 或 'Z%' 效果一致;留空 = 全部。
*
* 700 兼容要点:
*   - TFDIR 只有 FUNCNAME/PNAME/INCLUDE(4位短后缀),没有 GROUP 字段,
*     函数组由 PNAME 去掉 SAPL 前缀推导;
*   - FM→包含程序完整名用标准 FM RS_FUNCTION_POOL_CONTENTS(按组缓存,
*     不重复拉);开发类映射一次批量装入内表,避免 N+1 查询。
*
* 返回约定:无匹配时 ET_FM 为空,不算错误。

  TYPES: BEGIN OF ty_devmap,
           obj_name  TYPE char40,
           devclass  TYPE devclass,
         END OF ty_devmap.
  TYPES: BEGIN OF ty_incmap,
           funcname TYPE rs38l_fnam,
           include  TYPE progname,
         END OF ty_incmap.
  TYPES: BEGIN OF ty_grp,
           group TYPE tlibg-area,
         END OF ty_grp.

  DATA: lv_pat      TYPE char30,
        lt_devmap   TYPE STANDARD TABLE OF ty_devmap,
        ls_devmap   TYPE ty_devmap,
        lt_functab  TYPE TABLE OF rs38l_incl,
        ls_functab  TYPE rs38l_incl,
        lt_incmap   TYPE STANDARD TABLE OF ty_incmap,
        ls_incmap   TYPE ty_incmap,
        lt_grpdone  TYPE STANDARD TABLE OF ty_grp,
        ls_grpdone  TYPE ty_grp,
        lv_funcname TYPE rs38l_fnam,
        lv_pname    TYPE progname,
        lv_group    TYPE tlibg-area,
        lv_devclass TYPE devclass,
        ls_efm      LIKE LINE OF et_fm.

  REFRESH et_fm.
  IF iv_pattern IS INITIAL.
    lv_pat = '%'.
  ELSE.
    lv_pat = iv_pattern.
    REPLACE ALL OCCURRENCES OF '*' IN lv_pat WITH '%'.
  ENDIF.

* 1) 函数组 -> 开发类 映射(TADIR 中函数组对象类型 = FUGR,函数组名即 OBJ_NAME)
  SELECT obj_name devclass
         INTO CORRESPONDING FIELDS OF TABLE lt_devmap
         FROM tadir
         WHERE pgmid  = 'R3TR'
           AND object = 'FUGR'.
* 2) 扫 TFDIR(只取可靠字段 FUNCNAME/PNAME)
  SELECT funcname pname
         INTO (lv_funcname, lv_pname)
         FROM tfdir
         WHERE funcname LIKE lv_pat
         ORDER BY funcname.

*    函数组 = 程序名去掉 SAPL 前缀
    IF lv_pname(4) = 'SAPL'.
      lv_group = lv_pname+4.
    ELSE.
      lv_group = lv_pname.
    ENDIF.

*    该函数组首次遇到才拉 FM→包含程序 映射(缓存)
    READ TABLE lt_grpdone INTO ls_grpdone
                    WITH KEY group = lv_group
                    TRANSPORTING NO FIELDS.
    IF sy-subrc <> 0.
      REFRESH lt_functab.
      CALL FUNCTION 'RS_FUNCTION_POOL_CONTENTS'
        EXPORTING
          function_pool           = lv_group
        TABLES
          functab                 = lt_functab
        EXCEPTIONS
          function_pool_not_found = 1
          OTHERS                  = 2.
      IF sy-subrc = 0.
        LOOP AT lt_functab INTO ls_functab.
          ls_incmap-funcname = ls_functab-funcname.
          ls_incmap-include  = ls_functab-include.
          APPEND ls_incmap TO lt_incmap.
        ENDLOOP.
      ENDIF.
      ls_grpdone-group = lv_group.
      APPEND ls_grpdone TO lt_grpdone.
    ENDIF.

*    包含程序查找
    CLEAR ls_incmap.
    READ TABLE lt_incmap INTO ls_incmap
                    WITH KEY funcname = lv_funcname.
    IF sy-subrc <> 0.
      CLEAR ls_incmap-include.
    ENDIF.

*    开发类
    CLEAR ls_devmap.
    READ TABLE lt_devmap INTO ls_devmap
                    WITH KEY obj_name = lv_group.
    IF sy-subrc = 0.
      lv_devclass = ls_devmap-devclass.
    ELSE.
      lv_devclass = space.
    ENDIF.

*    开发类过滤(可选,支持通配符 * + )
    IF iv_devclass IS NOT INITIAL.
      IF NOT lv_devclass CP iv_devclass.
        CONTINUE.
      ENDIF.
    ENDIF.

    CLEAR ls_efm.
    ls_efm-fmname   = lv_funcname.
    ls_efm-fmgroup  = lv_group.
    ls_efm-program  = lv_pname.
    ls_efm-include  = ls_incmap-include.
    ls_efm-devclass = lv_devclass.
    APPEND ls_efm TO et_fm.
  ENDSELECT.
ENDFUNCTION.