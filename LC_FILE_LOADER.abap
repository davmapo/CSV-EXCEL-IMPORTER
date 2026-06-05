"! <p class="shorttext">Generic file loader - CSV / XLS / XLSX</p>
"! Loads a local (frontend) or server (AL11) file into a table of rows,
"! where each row is a table of already-separated fields (TT_ROWS / TY_ROW-FIELDS).
"! CSV is read in BINARY with automatic encoding detection (BOM -> UTF-8 -> fallback
"! codepage) and parsed quote-aware (RFC 4180 style); IV_SEPARATOR is the CSV field
"! delimiter. Excel (XLS/XLSX) cells are mapped directly to fields, so the separator
"! is not used for Excel. Mapping to business structures is left to the caller.
CLASS lc_file_loader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

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
      "! Load a file into a table of rows, each row holding its separated fields.
      "! @parameter iv_path        | Full path (local PC or AL11 server)
      "! @parameter iv_source      | GC_SOURCE_LOCAL ('L') or GC_SOURCE_SERVER ('S')
      "! @parameter iv_separator   | CSV field delimiter (default ';'). Not used for Excel.
      "! @parameter iv_skip_header | If ABAP_TRUE, the first row is removed from the output
      "! @parameter iv_fallback_cp | Codepage used when the CSV is neither BOM-tagged nor
      "!                             valid UTF-8 (default '1160' = Windows-1252)
      "! @parameter et_data        | Output: one row per source line, each with its fields
      "! @parameter ev_error       | Empty on success; error description on failure
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

    " SAP codepages used for decoding
    CONSTANTS:
      lc_cp_utf8    TYPE abap_encoding VALUE '4110',
      lc_cp_utf16le TYPE abap_encoding VALUE '4103',
      lc_cp_utf16be TYPE abap_encoding VALUE '4102'.
    " Byte-Order-Marks
    CONSTANTS:
      lc_bom_utf8    TYPE x LENGTH 3 VALUE 'EFBBBF',
      lc_bom_utf16le TYPE x LENGTH 2 VALUE 'FFFE',
      lc_bom_utf16be TYPE x LENGTH 2 VALUE 'FEFF'.

    METHODS:
      detect_file_type
        IMPORTING
          iv_path        TYPE string
        RETURNING
          VALUE(rv_type) TYPE string,

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

      " CSV: decode (auto-encoding) + normalize line endings + quote-aware field split
      csv_xstring_to_rows
        IMPORTING
          iv_xstring     TYPE xstring
          iv_separator   TYPE c
          iv_skip_header TYPE abap_bool
          iv_fallback_cp TYPE abap_encoding
        EXPORTING
          et_data        TYPE tt_rows
          ev_error       TYPE string,

      " Detect the encoding (BOM -> UTF-8 -> fallback) and decode to a string
      detect_and_decode
        IMPORTING
          iv_xdata       TYPE xstring
          iv_fallback_cp TYPE abap_encoding
        RETURNING
          VALUE(rv_text) TYPE string,

      " True if the bytes are valid UTF-8 (strict decode attempt)
      is_utf8
        IMPORTING
          iv_xdata        TYPE xstring
        RETURNING
          VALUE(rv_valid) TYPE abap_bool,

      " Decode with a known codepage, skipping IV_SKIP leading bytes (BOM).
      " Non-mappable bytes become '#' (no exception).
      to_string
        IMPORTING
          iv_xdata       TYPE xstring
          iv_cp          TYPE abap_encoding
          iv_skip        TYPE i DEFAULT 0
        RETURNING
          VALUE(rv_text) TYPE string,

      " Split one CSV line into fields, RFC 4180 quote-aware
      parse_csv_line
        IMPORTING
          iv_line          TYPE string
          iv_separator     TYPE c
        RETURNING
          VALUE(rt_fields) TYPE tt_fields,

      " Excel: map each worksheet row's cells directly to fields
      excel_xstring_to_rows
        IMPORTING
          iv_xstring     TYPE xstring
          iv_skip_header TYPE abap_bool
        EXPORTING
          et_data        TYPE tt_rows
          ev_error       TYPE string.

ENDCLASS.


CLASS lc_file_loader IMPLEMENTATION.

  METHOD load_file.
    CLEAR: et_data, ev_error.

    DATA(lv_type) = detect_file_type( iv_path ).
    DATA lv_xstring TYPE xstring.

    CASE lv_type.

      WHEN 'CSV'.
        " CSV is now read in binary too, so encoding can be auto-detected
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

    " Decode bytes with the detected encoding: the import is indifferent to how the
    " CSV arrived (ANSI / UTF-8 / UTF-16, with or without BOM).
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
      " skip completely empty lines (trailing newline, blank lines)
      IF lv_line IS INITIAL.
        CONTINUE.
      ENDIF.
      APPEND VALUE #( fields = parse_csv_line( iv_line      = lv_line
                                               iv_separator = iv_separator ) ) TO et_data.
    ENDLOOP.
  ENDMETHOD.


  METHOD detect_and_decode.
    " First bytes in a fixed-length 'x' field: unlike 'xstring', offset/length are
    " allowed here, so a BOM can be recognized.
    DATA lv_head TYPE x LENGTH 4.
    DATA lv_cp   TYPE abap_encoding.
    DATA lv_skip TYPE i.

    IF iv_xdata IS INITIAL.
      RETURN.
    ENDIF.

    lv_head = iv_xdata.   " first 4 bytes (00-padded if the file is shorter)

    IF lv_head(3) = lc_bom_utf8.
      lv_cp = lc_cp_utf8.     lv_skip = 3.
    ELSEIF lv_head(2) = lc_bom_utf16le.
      lv_cp = lc_cp_utf16le.  lv_skip = 2.
    ELSEIF lv_head(2) = lc_bom_utf16be.
      lv_cp = lc_cp_utf16be.  lv_skip = 2.
    ELSEIF is_utf8( iv_xdata ) = abap_true.
      lv_cp = lc_cp_utf8.     " UTF-8 without BOM
    ELSE.
      lv_cp = iv_fallback_cp. " not UTF-8 -> fallback (default Windows-1252)
    ENDIF.

    rv_text = to_string( iv_xdata = iv_xdata iv_cp = lv_cp iv_skip = lv_skip ).
  ENDMETHOD.


  METHOD is_utf8.
    " STRICT UTF-8 decode (ignore_cerr = abap_false): READ raises
    " cx_sy_conversion_codepage on the first invalid byte -> not UTF-8.
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
    " "Committed" decode: ignore_cerr = abap_true -> non-mappable bytes -> '#'.
    " skip_x skips the iv_skip BOM bytes before reading the content.
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
    " RFC 4180-style CSV parser (quote-aware), one line at a time:
    "  - the separator only counts OUTSIDE quotes
    "  - "" inside a quoted field = one literal "
    "  - the delimiting quotes are not kept in the value
    " Note: a newline inside a quoted field is NOT handled (rare in business CSVs):
    "       the line already arrives split by the caller.
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

      " one-char look-ahead, only within bounds (avoids out-of-range access)
      CLEAR lv_next.
      lv_j = lv_i + 1.
      IF lv_j < lv_len.
        lv_next = iv_line+lv_j(1).
      ENDIF.

      IF lv_in_quotes = abap_true.
        IF lv_char = '"'.
          IF lv_next = '"'.             " doubled quote ("") -> one literal "
            lv_field = lv_field && '"'.
            lv_i = lv_i + 1.            " skip the second quote
          ELSE.
            lv_in_quotes = abap_false.  " closing quote
          ENDIF.
        ELSE.
          lv_field = lv_field && lv_char.
        ENDIF.
      ELSE.
        IF lv_char = '"'.
          lv_in_quotes = abap_true.     " opening quote
        ELSEIF lv_char = iv_separator.
          APPEND lv_field TO rt_fields.
          CLEAR lv_field.
        ELSE.
          lv_field = lv_field && lv_char.
        ENDIF.
      ENDIF.

      lv_i = lv_i + 1.
    ENDWHILE.

    " last field
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

    " use the first worksheet
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
