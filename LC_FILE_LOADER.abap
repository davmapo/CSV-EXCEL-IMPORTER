"! <p class="shorttext">Generic file loader - CSV / XLS / XLSX</p>
"! Loads a local (frontend) or server (AL11) file into a generic string table.
"! Each entry in the output table corresponds to one row of the source file.
"! For CSV the raw line is returned unchanged; the caller splits it using its own separator.
"! For Excel (XLS/XLSX) each row is reconstructed by joining cell values with IV_SEPARATOR.
"! Parsing and business logic are left entirely to the caller.
CLASS lc_file_loader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    TYPES: tt_raw TYPE STANDARD TABLE OF string WITH DEFAULT KEY.

    CONSTANTS:
      gc_source_local  TYPE c LENGTH 1 VALUE 'L',
      gc_source_server TYPE c LENGTH 1 VALUE 'S'.

    METHODS:
      "! Load a file into a generic string table.
      "! @parameter iv_path        | Full path (local PC or AL11 server)
      "! @parameter iv_source      | GC_SOURCE_LOCAL ('L') or GC_SOURCE_SERVER ('S')
      "! @parameter iv_separator   | Cell separator used when converting Excel rows to strings (default ';')
      "! @parameter iv_skip_header | If ABAP_TRUE, the first row is removed from the output
      "! @parameter et_data        | Output: one string per row
      "! @parameter ev_error       | Empty on success; error description on failure
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
