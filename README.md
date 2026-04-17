# LC_FILE_LOADER

A generic, reusable ABAP class that loads a CSV, XLS, or XLSX file — from either the user's local PC or an AL11 application server path — into a plain `STANDARD TABLE OF string`. Each entry in the output table represents one raw row of the source file. Parsing and business logic are left entirely to the caller.

---

## Features

- Supports **CSV**, **XLS**, and **XLSX** file formats
- Supports both **local (frontend)** and **server (AL11)** file sources
- Automatic file type detection from the extension (case-insensitive)
- Optional **header row skipping**
- Configurable **cell separator** for Excel output (cells are joined into a single string per row, matching the CSV raw format)
- Error reporting via an `ev_error` exporting parameter — no hard `MESSAGE` calls, no exceptions to handle
- No fixed types: output is always `tt_raw` (`TABLE OF string`), fully independent of any business structure

---

## Public API

### Types

```abap
TYPES: tt_raw TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
```

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
    iv_separator   TYPE c DEFAULT ';'
    iv_skip_header TYPE abap_bool DEFAULT abap_false
  EXPORTING
    et_data        TYPE tt_raw
    ev_error       TYPE string.
```

| Parameter | Direction | Description |
|---|---|---|
| `iv_path` | IN | Full file path (local or AL11 server) |
| `iv_source` | IN | `gc_source_local` or `gc_source_server` |
| `iv_separator` | IN | Separator used to join Excel cells into a string. Default `';'`. Ignored for CSV (raw lines are returned as-is). |
| `iv_skip_header` | IN | If `abap_true`, the first row is removed from the output |
| `et_data` | OUT | One string per file row |
| `ev_error` | OUT | Empty on success. Contains a descriptive message on failure. |

---

## Internal Design

| Private method | Purpose |
|---|---|
| `detect_file_type` | Extracts the extension via regex, returns `'CSV'`, `'XLSX'`, `'XLS'`, or `'UNKNOWN'` |
| `load_local_csv` | Reads a local CSV via `cl_gui_frontend_services=>gui_upload` (`filetype = 'ASC'`) |
| `load_server_csv` | Reads a server CSV via `OPEN DATASET TEXT MODE ENCODING DEFAULT WITH SMART LINEFEED` |
| `read_local_binary` | Reads a local binary file via `gui_upload` (`filetype = 'BIN'`) and converts to xstring using `SCMS_BINARY_TO_XSTRING` |
| `read_server_binary` | Reads a server binary file via `OPEN DATASET BINARY MODE` and converts to xstring |
| `excel_xstring_to_strings` | Parses the xstring with `cl_fdt_xl_spreadsheet`, loops over the first worksheet, and joins each row's cells with `iv_separator` |

### Output consistency

Both CSV and Excel produce the same output shape: a `TABLE OF string` where every entry looks like:

```
"value1;value2;value3"
```

This means the caller can use the same `SPLIT ... AT separator INTO TABLE` logic regardless of the original file format.

---

## Notes and Limitations

- **Local files** require an active SAP GUI session (`cl_gui_frontend_services`). They are **not available in batch mode** (`sy-batch = abap_true`). Add a check before calling the class if your program may run in background.
- **XLS server-side**: `cl_fdt_xl_spreadsheet` primarily targets XLSX (Office Open XML). XLS support depends on the SAP release. If parsing fails, `ev_error` will contain a descriptive message.
- The class always reads the **first worksheet** of an Excel file. If you need a specific sheet, extend `excel_xstring_to_strings` to accept a sheet name or index.
- The `ev_error` approach was chosen over exceptions to keep caller code simple. Always check `ev_error IS NOT INITIAL` before using `et_data`.

---

## Usage Examples

### Example 1 — Local CSV

```abap
DATA: lo_loader TYPE REF TO lc_file_loader,
      lt_raw    TYPE lc_file_loader=>tt_raw,
      lv_error  TYPE string.

CREATE OBJECT lo_loader.

lo_loader->load_file(
  EXPORTING
    iv_path        = 'C:\data\import.csv'
    iv_source      = lc_file_loader=>gc_source_local
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_raw
    ev_error       = lv_error ).

IF lv_error IS NOT INITIAL.
  MESSAGE lv_error TYPE 'E'.
ENDIF.

" lt_raw now contains one string per data row, e.g. "John;Doe;1990"
```

### Example 2 — Server XLSX

```abap
lo_loader->load_file(
  EXPORTING
    iv_path        = '/data/imports/products.xlsx'
    iv_source      = lc_file_loader=>gc_source_server
    iv_separator   = ';'
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_raw
    ev_error       = lv_error ).
```

### Example 3 — Parsing the output

```abap
DATA: lt_fields TYPE STANDARD TABLE OF string,
      lv_field1 TYPE string,
      lv_field2 TYPE string.

LOOP AT lt_raw ASSIGNING FIELD-SYMBOL(<lv_row>).
  CLEAR lt_fields.
  SPLIT <lv_row> AT ';' INTO TABLE lt_fields.

  READ TABLE lt_fields INDEX 1 INTO lv_field1.
  READ TABLE lt_fields INDEX 2 INTO lv_field2.

  " map to your own business structure here
ENDLOOP.
```

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

    TYPES: tt_raw TYPE STANDARD TABLE OF string WITH DEFAULT KEY.

    CONSTANTS:
      gc_source_local  TYPE c LENGTH 1 VALUE 'L',
      gc_source_server TYPE c LENGTH 1 VALUE 'S'.

    METHODS:
      load_file
        IMPORTING
          iv_path        TYPE string
          iv_source      TYPE c
          iv_separator   TYPE c DEFAULT ';'
          iv_skip_header TYPE abap_bool DEFAULT abap_false
        EXPORTING
          et_data        TYPE tt_raw
          ev_error       TYPE string.

  PRIVATE SECTION.

    METHODS:
      detect_file_type
        IMPORTING
          iv_path        TYPE string
        RETURNING
          VALUE(rv_type) TYPE string,

      load_local_csv
        IMPORTING
          iv_path        TYPE string
          iv_skip_header TYPE abap_bool
        EXPORTING
          et_data        TYPE tt_raw
          ev_error       TYPE string,

      load_server_csv
        IMPORTING
          iv_path        TYPE string
          iv_skip_header TYPE abap_bool
        EXPORTING
          et_data        TYPE tt_raw
          ev_error       TYPE string,

      read_local_binary
        IMPORTING
          iv_path    TYPE string
        EXPORTING
          ev_xstring TYPE xstring
          ev_error   TYPE string,

      read_server_binary
        IMPORTING
          iv_path    TYPE string
        EXPORTING
          ev_xstring TYPE xstring
          ev_error   TYPE string,

      excel_xstring_to_strings
        IMPORTING
          iv_xstring     TYPE xstring
          iv_separator   TYPE c
          iv_skip_header TYPE abap_bool
        EXPORTING
          et_data        TYPE tt_raw
          ev_error       TYPE string.

ENDCLASS.


CLASS lc_file_loader IMPLEMENTATION.

  METHOD load_file.
    CLEAR: et_data, ev_error.

    DATA(lv_type) = detect_file_type( iv_path ).

    CASE lv_type.

      WHEN 'CSV'.
        IF iv_source = gc_source_local.
          load_local_csv(
            EXPORTING iv_path        = iv_path
                      iv_skip_header = iv_skip_header
            IMPORTING et_data        = et_data
                      ev_error       = ev_error ).
        ELSE.
          load_server_csv(
            EXPORTING iv_path        = iv_path
                      iv_skip_header = iv_skip_header
            IMPORTING et_data        = et_data
                      ev_error       = ev_error ).
        ENDIF.

      WHEN 'XLSX' OR 'XLS'.
        DATA: lv_xstring TYPE xstring.

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
          excel_xstring_to_strings(
            EXPORTING iv_xstring     = lv_xstring
                      iv_separator   = iv_separator
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


  METHOD load_local_csv.
    CLEAR: et_data, ev_error.

    cl_gui_frontend_services=>gui_upload(
      EXPORTING
        filename                = iv_path
        filetype                = 'ASC'
      CHANGING
        data_tab                = et_data
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
      ev_error = |Error opening local CSV file: { iv_path } (subrc { sy-subrc })|.
      RETURN.
    ENDIF.

    IF iv_skip_header = abap_true.
      DELETE et_data INDEX 1.
    ENDIF.
  ENDMETHOD.


  METHOD load_server_csv.
    CLEAR: et_data, ev_error.
    DATA: lv_line TYPE string.

    OPEN DATASET iv_path FOR INPUT IN TEXT MODE ENCODING DEFAULT WITH SMART LINEFEED.
    IF sy-subrc <> 0.
      ev_error = |Error opening server CSV file: { iv_path }|.
      RETURN.
    ENDIF.

    DO.
      READ DATASET iv_path INTO lv_line.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.
      APPEND lv_line TO et_data.
    ENDDO.

    CLOSE DATASET iv_path.

    IF iv_skip_header = abap_true.
      DELETE et_data INDEX 1.
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
          lv_xlen TYPE i.

    OPEN DATASET iv_path FOR INPUT IN BINARY MODE.
    IF sy-subrc <> 0.
      ev_error = |Error opening server binary file: { iv_path }|.
      RETURN.
    ENDIF.

    lv_xlen = 0.
    DO.
      CLEAR ls_raw.
      READ DATASET iv_path INTO ls_raw.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.
      APPEND ls_raw TO lt_raw.
      lv_xlen = lv_xlen + xstrlen( ls_raw ).
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


  METHOD excel_xstring_to_strings.
    CLEAR: et_data, ev_error.

    DATA: lo_excel  TYPE REF TO cl_fdt_xl_spreadsheet,
          lt_sheets TYPE STANDARD TABLE OF string,
          lv_sheet  TYPE string,
          lo_data   TYPE REF TO data,
          lv_row    TYPE string,
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
      CLEAR: lv_row, lv_idx.
      lv_idx = 1.

      DO.
        ASSIGN COMPONENT lv_idx OF STRUCTURE <ls_row> TO <lv_cell>.
        IF sy-subrc <> 0.
          EXIT.
        ENDIF.

        lv_cell = <lv_cell>.

        IF lv_idx = 1.
          lv_row = lv_cell.
        ELSE.
          lv_row = lv_row && iv_separator && lv_cell.
        ENDIF.

        lv_idx = lv_idx + 1.
      ENDDO.

      APPEND lv_row TO et_data.
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
        lt_raw    TYPE lc_file_loader=>tt_raw,
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
      iv_separator   = p_sep
      iv_skip_header = CONV abap_bool( p_head )
    IMPORTING
      et_data        = lt_raw
      ev_error       = gv_error ).

  IF gv_error IS NOT INITIAL.
    MESSAGE gv_error TYPE 'E'.
  ENDIF.

  IF lt_raw IS INITIAL.
    MESSAGE 'No data found in the file.' TYPE 'I'.
    RETURN.
  ENDIF.

  " --- parse rows ---
  DATA: lt_fields  TYPE STANDARD TABLE OF string,
        ls_person  TYPE ty_person.

  LOOP AT lt_raw ASSIGNING FIELD-SYMBOL(<lv_row>).
    CLEAR: ls_person, lt_fields.
    SPLIT <lv_row> AT p_sep INTO TABLE lt_fields.

    READ TABLE lt_fields INDEX 1 INTO ls_person-first_name.
    READ TABLE lt_fields INDEX 2 INTO ls_person-last_name.
    READ TABLE lt_fields INDEX 3 INTO ls_person-birthdate.

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
