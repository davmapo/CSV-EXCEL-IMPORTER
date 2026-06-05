# LC_FILE_LOADER

A generic, reusable ABAP class that loads a CSV, XLS, or XLSX file — from either the user's local PC or an AL11 application server path — into a table of rows, where **each row already holds its separated fields** (`tt_rows` / `ty_row-fields`). CSV is read in binary with **automatic encoding detection** and split into fields by a **quote-aware** parser (RFC 4180 style); Excel maps cells directly to fields. Mapping to business structures is left to the caller.

---

## Features

- Supports **CSV**, **XLS**, and **XLSX** file formats
- Supports both **local (frontend)** and **server (AL11)** file sources
- Automatic file type detection from the extension (case-insensitive)
- **Automatic CSV encoding detection**: BOM (UTF-8 / UTF-16 LE/BE) → UTF-8 without BOM → configurable fallback codepage (default Windows-1252). The import is indifferent to how the file arrived.
- **Line-ending normalization**: CRLF (Windows), LF (Unix), and a lone CR (classic Mac / some tools) are all handled.
- **Quote-aware CSV parser (RFC 4180)**: quoted fields may contain the separator; a doubled quote `""` is a literal `"`. An Excel→CSV export is read correctly.
- **Pre-split fields** output, identical for CSV and Excel: the caller gets rows of fields and never has to `SPLIT`.
- Configurable CSV separator (default `';'`).
- Configurable fallback codepage for non-UTF-8 CSVs.
- Optional **header row skipping**.
- Error reporting via an `ev_error` exporting parameter — no hard `MESSAGE` calls, no exceptions to handle.

---

## Public API

### Types

```abap
TYPES: tt_fields TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
TYPES: BEGIN OF ty_row,
         fields TYPE tt_fields,
       END OF ty_row.
TYPES: tt_rows TYPE STANDARD TABLE OF ty_row WITH DEFAULT KEY.
```

`et_data` is a `tt_rows`: one entry per source row, and each entry has `fields`, the table of its already-separated fields.

### Constants

| Constant | Value | Meaning |
|---|---|---|
| `gc_source_local` | `'L'` | Read from the user's local PC (uses GUI services) |
| `gc_source_server` | `'S'` | Read from an AL11 application server path |

### Method: `LOAD_FILE`

```abap
METHODS load_file
  IMPORTING
    iv_path        TYPE string
    iv_source      TYPE c
    iv_separator   TYPE c             DEFAULT ';'
    iv_skip_header TYPE abap_bool     DEFAULT abap_false
    iv_fallback_cp TYPE abap_encoding DEFAULT '1160'
  EXPORTING
    et_data        TYPE tt_rows
    ev_error       TYPE string.
```

| Parameter | Direction | Description |
|---|---|---|
| `iv_path` | IN | Full file path (local or AL11 server) |
| `iv_source` | IN | `gc_source_local` or `gc_source_server` |
| `iv_separator` | IN | **CSV** field delimiter. Default `';'`. Not used for Excel (cells are already structured). |
| `iv_skip_header` | IN | If `abap_true`, the first row is removed from the output |
| `iv_fallback_cp` | IN | Codepage used when the CSV has no BOM and is not valid UTF-8. Default `'1160'` (Windows-1252). |
| `et_data` | OUT | One row per source row; each row holds its fields (`fields`) |
| `ev_error` | OUT | Empty on success. Contains a descriptive message on failure. |

---

## Internal Design

| Private method | Purpose |
|---|---|
| `detect_file_type` | Extracts the extension via regex, returns `'CSV'`, `'XLSX'`, `'XLS'`, or `'UNKNOWN'` |
| `read_local_binary` | Reads a local binary file via `gui_upload` (`filetype = 'BIN'`) and converts to xstring using `SCMS_BINARY_TO_XSTRING`. Used for both CSV and Excel. |
| `read_server_binary` | Reads a server binary file via `OPEN DATASET BINARY MODE` and converts to xstring. Used for both CSV and Excel. |
| `csv_xstring_to_rows` | Decodes (auto-encoding) + normalizes line endings + splits each line into fields |
| `detect_and_decode` | Detects the encoding (BOM → UTF-8 test → fallback) and decodes the xstring to a string |
| `is_utf8` | `abap_true` if the bytes are valid UTF-8 (strict decode) |
| `to_string` | Decodes with a known codepage, skipping BOM bytes; non-mappable bytes become `'#'` |
| `parse_csv_line` | Splits a CSV line into fields, quote-aware (RFC 4180) |
| `excel_xstring_to_rows` | Parses the xstring with `cl_fdt_xl_spreadsheet`, loops over the first worksheet, and maps each cell to a field |

### Output consistency

Both CSV and Excel produce the same output shape: a `tt_rows` where every entry holds its already-separated fields:

```
et_data[ 1 ]-fields = ( "value1" "value2" "value3" )
```

This means the caller uses the same logic — reading `<row>-fields[ n ]` — regardless of the original file format, **without any `SPLIT`** and without worrying about the separator or the encoding.

---

## Notes and Limitations

- **Local files** require an active SAP GUI session (`cl_gui_frontend_services`). They are **not available in batch mode** (`sy-batch = abap_true`). Add a check before calling the class if your program may run in background.
- **XLS server-side**: `cl_fdt_xl_spreadsheet` primarily targets XLSX (Office Open XML). XLS support depends on the SAP release. If parsing fails, `ev_error` will contain a descriptive message.
- The class always reads the **first worksheet** of an Excel file. If you need a specific sheet, extend `excel_xstring_to_rows` to accept a sheet name or index.
- **Multi-line quoted fields**: the CSV parser handles quotes, an embedded separator, and `""`, but **not** a newline inside a quoted field (a valid RFC case but rare in business CSVs), because lines are split on line endings first. If you need it, replace the split-then-parse approach with a single-pass parser over the whole text.
- **UTF-16 without a BOM** is not detected (it would fall back). This is rare: UTF-16 exports almost always include the BOM.
- The `ev_error` approach was chosen over exceptions to keep caller code simple. Always check `ev_error IS NOT INITIAL` before using `et_data`.

---

## Usage Examples

### Example 1 — Local CSV

```abap
DATA: lo_loader TYPE REF TO lc_file_loader,
      lt_rows   TYPE lc_file_loader=>tt_rows,
      lv_error  TYPE string.

CREATE OBJECT lo_loader.

lo_loader->load_file(
  EXPORTING
    iv_path        = 'C:\data\import.csv'
    iv_source      = lc_file_loader=>gc_source_local
    iv_separator   = ';'              " CSV delimiter
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_rows
    ev_error       = lv_error ).

IF lv_error IS NOT INITIAL.
  MESSAGE lv_error TYPE 'E'.
ENDIF.

" lt_rows now contains one row per record, with fields already separated, e.g.
" lt_rows[ 1 ]-fields = ( "John" "Doe" "1990" )
```

### Example 2 — Server XLSX

```abap
" For Excel the separator is not needed: cells are already structured.
lo_loader->load_file(
  EXPORTING
    iv_path        = '/data/imports/products.xlsx'
    iv_source      = lc_file_loader=>gc_source_server
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_rows
    ev_error       = lv_error ).
```

### Example 3 — CSV with a different fallback codepage

```abap
" CSV without BOM and not UTF-8, written in Central Europe (Windows-1250).
lo_loader->load_file(
  EXPORTING
    iv_path        = '/data/imports/pricelist.csv'
    iv_source      = lc_file_loader=>gc_source_server
    iv_separator   = ','
    iv_fallback_cp = '1404'           " SAP codepage for Windows-1250
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_rows
    ev_error       = lv_error ).
```

### Example 4 — Reading the output

```abap
DATA: lv_field1 TYPE string,
      lv_field2 TYPE string.

LOOP AT lt_rows ASSIGNING FIELD-SYMBOL(<ls_row>).
  " fields are already separated: no SPLIT
  lv_field1 = VALUE #( <ls_row>-fields[ 1 ] OPTIONAL ).
  lv_field2 = VALUE #( <ls_row>-fields[ 2 ] OPTIONAL ).

  " map to your own business structure here
ENDLOOP.
```

> `VALUE #( ... OPTIONAL )` returns an empty string when the field does not exist, avoiding an exception on rows with fewer columns than expected.

---

## Complete Example Program

The following is a self-contained ABAP report that defines `lc_file_loader` as a local class and uses it to import a person list from a CSV or XLSX file and display it in an ALV grid.

```abap
*&---------------------------------------------------------------------*
*& Report  ZDEMO_FILE_LOADER
*& Demo program for LC_FILE_LOADER
*&---------------------------------------------------------------------*
REPORT zdemo_file_loader.

*----------------------------------------------------------------------*
* Local class: LC_FILE_LOADER
*----------------------------------------------------------------------*
CLASS lc_file_loader DEFINITION FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    TYPES: tt_fields TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
    TYPES: BEGIN OF ty_row,
             fields TYPE tt_fields,
           END OF ty_row.
    TYPES: tt_rows TYPE STANDARD TABLE OF ty_row WITH DEFAULT KEY.

    CONSTANTS:
      gc_source_local  TYPE c LENGTH 1 VALUE 'L',
      gc_source_server TYPE c LENGTH 1 VALUE 'S'.

    METHODS:
      load_file
        IMPORTING
          iv_path        TYPE string
          iv_source      TYPE c
          iv_separator   TYPE c             DEFAULT ';'
          iv_skip_header TYPE abap_bool     DEFAULT abap_false
          iv_fallback_cp TYPE abap_encoding DEFAULT '1160'
        EXPORTING
          et_data        TYPE tt_rows
          ev_error       TYPE string.

  PRIVATE SECTION.

    CONSTANTS:
      lc_cp_utf8    TYPE abap_encoding VALUE '4110',
      lc_cp_utf16le TYPE abap_encoding VALUE '4103',
      lc_cp_utf16be TYPE abap_encoding VALUE '4102'.
    CONSTANTS:
      lc_bom_utf8    TYPE x LENGTH 3 VALUE 'EFBBBF',
      lc_bom_utf16le TYPE x LENGTH 2 VALUE 'FFFE',
      lc_bom_utf16be TYPE x LENGTH 2 VALUE 'FEFF'.

    METHODS:
      detect_file_type
        IMPORTING iv_path        TYPE string
        RETURNING VALUE(rv_type) TYPE string,

      read_local_binary
        IMPORTING iv_path    TYPE string
        EXPORTING ev_xstring TYPE xstring
                  ev_error   TYPE string,

      read_server_binary
        IMPORTING iv_path    TYPE string
        EXPORTING ev_xstring TYPE xstring
                  ev_error   TYPE string,

      csv_xstring_to_rows
        IMPORTING iv_xstring     TYPE xstring
                  iv_separator   TYPE c
                  iv_skip_header TYPE abap_bool
                  iv_fallback_cp TYPE abap_encoding
        EXPORTING et_data        TYPE tt_rows
                  ev_error       TYPE string,

      detect_and_decode
        IMPORTING iv_xdata       TYPE xstring
                  iv_fallback_cp TYPE abap_encoding
        RETURNING VALUE(rv_text) TYPE string,

      is_utf8
        IMPORTING iv_xdata        TYPE xstring
        RETURNING VALUE(rv_valid) TYPE abap_bool,

      to_string
        IMPORTING iv_xdata       TYPE xstring
                  iv_cp          TYPE abap_encoding
                  iv_skip        TYPE i DEFAULT 0
        RETURNING VALUE(rv_text) TYPE string,

      parse_csv_line
        IMPORTING iv_line          TYPE string
                  iv_separator     TYPE c
        RETURNING VALUE(rt_fields) TYPE tt_fields,

      excel_xstring_to_rows
        IMPORTING iv_xstring     TYPE xstring
                  iv_skip_header TYPE abap_bool
        EXPORTING et_data        TYPE tt_rows
                  ev_error       TYPE string.

ENDCLASS.


CLASS lc_file_loader IMPLEMENTATION.

  METHOD load_file.
    CLEAR: et_data, ev_error.

    DATA(lv_type) = detect_file_type( iv_path ).
    DATA lv_xstring TYPE xstring.

    CASE lv_type.

      WHEN 'CSV'.
        IF iv_source = gc_source_local.
          read_local_binary(
            EXPORTING iv_path    = iv_path
            IMPORTING ev_xstring = lv_xstring
                      ev_error   = ev_error ).
        ELSE.
          read_server_binary(
            EXPORTING iv_path    = iv_path
            IMPORTING ev_xstring = lv_xstring
                      ev_error   = ev_error ).
        ENDIF.

        IF ev_error IS INITIAL AND lv_xstring IS NOT INITIAL.
          csv_xstring_to_rows(
            EXPORTING iv_xstring     = lv_xstring
                      iv_separator   = iv_separator
                      iv_skip_header = iv_skip_header
                      iv_fallback_cp = iv_fallback_cp
            IMPORTING et_data        = et_data
                      ev_error       = ev_error ).
        ENDIF.

      WHEN 'XLSX' OR 'XLS'.
        IF iv_source = gc_source_local.
          read_local_binary(
            EXPORTING iv_path    = iv_path
            IMPORTING ev_xstring = lv_xstring
                      ev_error   = ev_error ).
        ELSE.
          read_server_binary(
            EXPORTING iv_path    = iv_path
            IMPORTING ev_xstring = lv_xstring
                      ev_error   = ev_error ).
        ENDIF.

        IF ev_error IS INITIAL AND lv_xstring IS NOT INITIAL.
          excel_xstring_to_rows(
            EXPORTING iv_xstring     = lv_xstring
                      iv_skip_header = iv_skip_header
            IMPORTING et_data        = et_data
                      ev_error       = ev_error ).
        ENDIF.

      WHEN OTHERS.
        ev_error = |Unsupported file extension: { iv_path }|.

    ENDCASE.
  ENDMETHOD.


  METHOD detect_file_type.
    DATA: lv_ext TYPE string.

    FIND REGEX '\.([^.]+)$' IN iv_path SUBMATCHES lv_ext.
    IF sy-subrc = 0.
      TRANSLATE lv_ext TO UPPER CASE.
      CASE lv_ext.
        WHEN 'CSV'.   rv_type = 'CSV'.
        WHEN 'XLSX'.  rv_type = 'XLSX'.
        WHEN 'XLS'.   rv_type = 'XLS'.
        WHEN OTHERS.  rv_type = 'UNKNOWN'.
      ENDCASE.
    ELSE.
      rv_type = 'UNKNOWN'.
    ENDIF.
  ENDMETHOD.


  METHOD read_local_binary.
    CLEAR: ev_xstring, ev_error.
    DATA: lt_raw  TYPE TABLE OF x255,
          lv_xlen TYPE i.

    cl_gui_frontend_services=>gui_upload(
      EXPORTING
        filename                = iv_path
        filetype                = 'BIN'
      IMPORTING
        filelength              = lv_xlen
      CHANGING
        data_tab                = lt_raw
      EXCEPTIONS
        file_open_error         = 1
        file_read_error         = 2
        no_batch                = 3
        gui_refuse_filetransfer = 4
        invalid_type            = 5
        no_authority            = 6
        unknown_error           = 7
        bad_data_format         = 8
        header_not_allowed      = 9
        separator_not_allowed   = 10
        header_too_long         = 11
        unknown_dp_error        = 12
        access_denied           = 13
        dp_out_of_memory        = 14
        disk_full               = 15
        dp_timeout              = 16
        not_supported_by_gui    = 17
        error_no_gui            = 18
        OTHERS                  = 19 ).

    IF sy-subrc <> 0.
      ev_error = |Error reading local binary file: { iv_path } (subrc { sy-subrc })|.
      RETURN.
    ENDIF.

    IF lv_xlen <= 0.
      ev_error = |File is empty: { iv_path }|.
      RETURN.
    ENDIF.

    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING
        input_length = lv_xlen
      IMPORTING
        buffer       = ev_xstring
      TABLES
        binary_tab   = lt_raw
      EXCEPTIONS
        failed       = 1
        OTHERS       = 2.

    IF sy-subrc <> 0.
      ev_error = |Error converting binary data to xstring: { iv_path }|.
    ENDIF.
  ENDMETHOD.


  METHOD read_server_binary.
    CLEAR: ev_xstring, ev_error.
    DATA: lt_raw  TYPE TABLE OF x255,
          ls_raw  TYPE x255,
          lv_xlen TYPE i,
          lv_clen TYPE i.

    OPEN DATASET iv_path FOR INPUT IN BINARY MODE.
    IF sy-subrc <> 0.
      ev_error = |Error opening server binary file: { iv_path }|.
      RETURN.
    ENDIF.

    lv_xlen = 0.
    DO.
      CLEAR ls_raw.
      READ DATASET iv_path INTO ls_raw ACTUAL LENGTH lv_clen.
      IF lv_clen > 0.
        APPEND ls_raw TO lt_raw.
        lv_xlen = lv_xlen + lv_clen.
      ENDIF.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.
    ENDDO.

    CLOSE DATASET iv_path.

    IF lv_xlen <= 0.
      ev_error = |File is empty: { iv_path }|.
      RETURN.
    ENDIF.

    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING
        input_length = lv_xlen
      IMPORTING
        buffer       = ev_xstring
      TABLES
        binary_tab   = lt_raw
      EXCEPTIONS
        failed       = 1
        OTHERS       = 2.

    IF sy-subrc <> 0.
      ev_error = |Error converting binary data to xstring: { iv_path }|.
    ENDIF.
  ENDMETHOD.


  METHOD csv_xstring_to_rows.
    CLEAR: et_data, ev_error.

    DATA: lt_lines TYPE STANDARD TABLE OF string,
          lv_lf    TYPE string,
          lv_cr    TYPE string.

    DATA(lv_text) = detect_and_decode( iv_xdata       = iv_xstring
                                       iv_fallback_cp = iv_fallback_cp ).

    lv_lf = cl_abap_char_utilities=>newline.
    lv_cr = substring( val = cl_abap_char_utilities=>cr_lf off = 0 len = 1 ).

    " Normalize line endings: CRLF (Windows) -> LF, then a lone CR (classic Mac) -> LF
    REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf IN lv_text WITH lv_lf.
    REPLACE ALL OCCURRENCES OF lv_cr IN lv_text WITH lv_lf.

    SPLIT lv_text AT lv_lf INTO TABLE lt_lines.

    IF iv_skip_header = abap_true AND lines( lt_lines ) > 0.
      DELETE lt_lines INDEX 1.
    ENDIF.

    LOOP AT lt_lines INTO DATA(lv_line).
      IF lv_line IS INITIAL.
        CONTINUE.
      ENDIF.
      APPEND VALUE #( fields = parse_csv_line( iv_line      = lv_line
                                               iv_separator = iv_separator ) ) TO et_data.
    ENDLOOP.
  ENDMETHOD.


  METHOD detect_and_decode.
    DATA lv_head TYPE x LENGTH 4.
    DATA lv_cp   TYPE abap_encoding.
    DATA lv_skip TYPE i.

    IF iv_xdata IS INITIAL.
      RETURN.
    ENDIF.

    lv_head = iv_xdata.

    IF lv_head(3) = lc_bom_utf8.
      lv_cp = lc_cp_utf8.     lv_skip = 3.
    ELSEIF lv_head(2) = lc_bom_utf16le.
      lv_cp = lc_cp_utf16le.  lv_skip = 2.
    ELSEIF lv_head(2) = lc_bom_utf16be.
      lv_cp = lc_cp_utf16be.  lv_skip = 2.
    ELSEIF is_utf8( iv_xdata ) = abap_true.
      lv_cp = lc_cp_utf8.
    ELSE.
      lv_cp = iv_fallback_cp.
    ENDIF.

    rv_text = to_string( iv_xdata = iv_xdata iv_cp = lv_cp iv_skip = lv_skip ).
  ENDMETHOD.


  METHOD is_utf8.
    DATA lv_dummy TYPE string.
    TRY.
        cl_abap_conv_in_ce=>create(
          encoding    = lc_cp_utf8
          ignore_cerr = abap_false
          input       = iv_xdata
        )->read( IMPORTING data = lv_dummy ).
        rv_valid = abap_true.
      CATCH cx_sy_conversion_codepage
            cx_sy_codepage_converter_init
            cx_parameter_invalid_range
            cx_parameter_invalid_type.
        rv_valid = abap_false.
    ENDTRY.
  ENDMETHOD.


  METHOD to_string.
    DATA lo_conv TYPE REF TO cl_abap_conv_in_ce.
    TRY.
        lo_conv = cl_abap_conv_in_ce=>create(
          encoding    = iv_cp
          ignore_cerr = abap_true
          input       = iv_xdata ).
        IF iv_skip > 0.
          lo_conv->skip_x( iv_skip ).
        ENDIF.
        lo_conv->read( IMPORTING data = rv_text ).
      CATCH cx_sy_conversion_codepage
            cx_sy_codepage_converter_init
            cx_parameter_invalid_range
            cx_parameter_invalid_type.
        CLEAR rv_text.
    ENDTRY.
  ENDMETHOD.


  METHOD parse_csv_line.
    DATA: lv_len       TYPE i,
          lv_i         TYPE i,
          lv_j         TYPE i,
          lv_char      TYPE c LENGTH 1,
          lv_next      TYPE c LENGTH 1,
          lv_field     TYPE string,
          lv_in_quotes TYPE abap_bool VALUE abap_false.

    lv_len = strlen( iv_line ).
    IF lv_len = 0.
      RETURN.
    ENDIF.

    lv_i = 0.
    WHILE lv_i < lv_len.
      lv_char = iv_line+lv_i(1).

      CLEAR lv_next.
      lv_j = lv_i + 1.
      IF lv_j < lv_len.
        lv_next = iv_line+lv_j(1).
      ENDIF.

      IF lv_in_quotes = abap_true.
        IF lv_char = '"'.
          IF lv_next = '"'.
            lv_field = lv_field && '"'.
            lv_i = lv_i + 1.
          ELSE.
            lv_in_quotes = abap_false.
          ENDIF.
        ELSE.
          lv_field = lv_field && lv_char.
        ENDIF.
      ELSE.
        IF lv_char = '"'.
          lv_in_quotes = abap_true.
        ELSEIF lv_char = iv_separator.
          APPEND lv_field TO rt_fields.
          CLEAR lv_field.
        ELSE.
          lv_field = lv_field && lv_char.
        ENDIF.
      ENDIF.

      lv_i = lv_i + 1.
    ENDWHILE.

    APPEND lv_field TO rt_fields.
  ENDMETHOD.


  METHOD excel_xstring_to_rows.
    CLEAR: et_data, ev_error.

    DATA: lo_excel  TYPE REF TO cl_fdt_xl_spreadsheet,
          lt_sheets TYPE STANDARD TABLE OF string,
          lv_sheet  TYPE string,
          lo_data   TYPE REF TO data,
          ls_row    TYPE ty_row,
          lv_cell   TYPE string,
          lv_idx    TYPE i.

    FIELD-SYMBOLS: <lt_tab>  TYPE STANDARD TABLE,
                   <ls_row>  TYPE any,
                   <lv_cell> TYPE any.

    TRY.
        CREATE OBJECT lo_excel
          EXPORTING
            document_name = space
            xdocument     = iv_xstring.
      CATCH cx_fdt_excel_core.
        ev_error = 'Error opening Excel file: unsupported format (verify the file is a valid XLSX or compatible XLS)'.
        RETURN.
    ENDTRY.

    lo_excel->if_fdt_doc_spreadsheet~get_worksheet_names(
      IMPORTING worksheet_names = lt_sheets ).

    IF lt_sheets IS INITIAL.
      ev_error = 'No worksheets found in the Excel file'.
      RETURN.
    ENDIF.

    READ TABLE lt_sheets INTO lv_sheet INDEX 1.

    lo_data = lo_excel->if_fdt_doc_spreadsheet~get_itab_from_worksheet( lv_sheet ).
    IF lo_data IS INITIAL.
      ev_error = |Could not read worksheet "{ lv_sheet }"|.
      RETURN.
    ENDIF.

    ASSIGN lo_data->* TO <lt_tab>.
    CHECK <lt_tab> IS ASSIGNED.

    LOOP AT <lt_tab> ASSIGNING <ls_row>.
      CLEAR ls_row.
      lv_idx = 1.

      DO.
        ASSIGN COMPONENT lv_idx OF STRUCTURE <ls_row> TO <lv_cell>.
        IF sy-subrc <> 0.
          EXIT.
        ENDIF.

        lv_cell = <lv_cell>.
        APPEND lv_cell TO ls_row-fields.

        lv_idx = lv_idx + 1.
      ENDDO.

      APPEND ls_row TO et_data.
    ENDLOOP.

    IF iv_skip_header = abap_true.
      DELETE et_data INDEX 1.
    ENDIF.
  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Types
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_person,
         first_name TYPE string,
         last_name  TYPE string,
         birthdate  TYPE string,
       END OF ty_person.

*----------------------------------------------------------------------*
* Data
*----------------------------------------------------------------------*
DATA: gt_persons TYPE STANDARD TABLE OF ty_person,
      gv_error   TYPE string.

*----------------------------------------------------------------------*
* Selection screen
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS: p_rb1 RADIOBUTTON GROUP grb DEFAULT 'X',   " local
              p_rb2 RADIOBUTTON GROUP grb.               " server
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME.
  PARAMETERS: p_local TYPE rlgrap-filename MODIF ID loc,
              p_srv   TYPE rlgrap-filename MODIF ID srv,
              p_sep   TYPE c LENGTH 1 DEFAULT ';'.
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3.
  PARAMETERS p_head AS CHECKBOX DEFAULT ' '.
SELECTION-SCREEN END OF BLOCK b3.

*----------------------------------------------------------------------*
* Selection screen events
*----------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  LOOP AT SCREEN.
    CASE screen-group1.
      WHEN 'LOC'.
        screen-active = COND #( WHEN p_rb1 = 'X' THEN 1 ELSE 0 ).
        MODIFY SCREEN.
      WHEN 'SRV'.
        screen-active = COND #( WHEN p_rb2 = 'X' THEN 1 ELSE 0 ).
        MODIFY SCREEN.
    ENDCASE.
  ENDLOOP.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_local.
  CALL FUNCTION 'F4_FILENAME'
    EXPORTING  field_name = 'P_LOCAL'
    IMPORTING  file_name  = p_local.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_srv.
  CALL FUNCTION 'SAPDMCLSM_F4_SERVER_FILE'
    IMPORTING  serverfile       = p_srv
    EXCEPTIONS canceled_by_user = 1
               OTHERS           = 2.

*----------------------------------------------------------------------*
* Main
*----------------------------------------------------------------------*
START-OF-SELECTION.

  " batch mode: local file not allowed
  IF sy-batch = abap_true AND p_rb1 = abap_true.
    MESSAGE 'Local file upload is not available in batch mode.' TYPE 'E'.
  ENDIF.

  " --- load file ---
  DATA: lo_loader TYPE REF TO lc_file_loader,
        lt_rows   TYPE lc_file_loader=>tt_rows,
        lv_path   TYPE string,
        lv_source TYPE c LENGTH 1.

  CREATE OBJECT lo_loader.

  IF p_rb1 = 'X'.
    lv_path   = p_local.
    lv_source = lc_file_loader=>gc_source_local.
  ELSE.
    lv_path   = p_srv.
    lv_source = lc_file_loader=>gc_source_server.
  ENDIF.

  lo_loader->load_file(
    EXPORTING
      iv_path        = lv_path
      iv_source      = lv_source
      iv_separator   = p_sep          " used for CSV only
      iv_skip_header = CONV abap_bool( p_head )
    IMPORTING
      et_data        = lt_rows
      ev_error       = gv_error ).

  IF gv_error IS NOT INITIAL.
    MESSAGE gv_error TYPE 'E'.
  ENDIF.

  IF lt_rows IS INITIAL.
    MESSAGE 'No data found in the file.' TYPE 'I'.
    RETURN.
  ENDIF.

  " --- map rows (fields already separated, no SPLIT) ---
  DATA ls_person TYPE ty_person.

  LOOP AT lt_rows ASSIGNING FIELD-SYMBOL(<ls_row>).
    CLEAR ls_person.
    ls_person-first_name = VALUE #( <ls_row>-fields[ 1 ] OPTIONAL ).
    ls_person-last_name  = VALUE #( <ls_row>-fields[ 2 ] OPTIONAL ).
    ls_person-birthdate  = VALUE #( <ls_row>-fields[ 3 ] OPTIONAL ).
    APPEND ls_person TO gt_persons.
  ENDLOOP.

  " --- display in ALV ---
  cl_salv_table=>factory(
    IMPORTING
      r_salv_table = DATA(lo_alv)
    CHANGING
      t_table      = gt_persons ).

  lo_alv->get_columns( )->set_optimize( abap_true ).
  lo_alv->display( ).
```

> **Expected file format (CSV or XLSX):**
> ```
> FirstName;LastName;Birthdate
> John;Doe;1990-05-12
> Jane;Smith;1985-11-30
> ```
>
> Thanks to the quote-aware parser, a CSV like this is read correctly (the comma inside the quotes does **not** split the field):
> ```
> FirstName;LastName;Notes
> John;Doe;"Long-time customer; pays on time"
> ```
