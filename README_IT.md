# LC_FILE_LOADER

Classe ABAP generica e riutilizzabile per caricare un file CSV, XLS o XLSX — dal PC locale dell'utente oppure da un path AL11 sul server applicativo — in una tabella di righe, dove **ogni riga contiene già i suoi campi separati** (`tt_rows` / `ty_row-fields`). Il CSV viene letto in binario con **rilevamento automatico dell'encoding** e suddiviso in campi con un parser **quote-aware** (stile RFC 4180); l'Excel mappa direttamente le celle nei campi. La mappatura sulle strutture di business è lasciata al chiamante.

---

## Funzionalità

- Supporto formati **CSV**, **XLS** e **XLSX**
- Supporto sorgente **locale (frontend)** e **server (AL11)**
- Rilevamento automatico del tipo di file dall'estensione (case-insensitive)
- **Rilevamento automatico dell'encoding** del CSV: BOM (UTF-8 / UTF-16 LE/BE) → UTF-8 senza BOM → codepage di fallback configurabile (default Windows-1252). L'import è indifferente a come è arrivato il file.
- **Normalizzazione dei fine-riga**: CRLF (Windows), LF (Unix) e CR isolato (vecchi Mac/alcuni tool) vengono tutti gestiti.
- **Parser CSV quote-aware (RFC 4180)**: i campi racchiusi tra virgolette possono contenere il separatore; le virgolette doppie `""` valgono una `"` letterale. Un export Excel→CSV viene letto correttamente.
- Output a **campi già separati**, identico per CSV ed Excel: il chiamante riceve righe di campi e non deve fare lo `SPLIT`.
- Separatore CSV configurabile (default `';'`).
- Codepage di fallback configurabile per i CSV non UTF-8.
- Opzione di **salto della riga di intestazione**.
- Segnalazione errori tramite parametro `ev_error` in EXPORTING — nessun `MESSAGE` fisso, nessuna eccezione da gestire.

---

## API pubblica

### Tipi

```abap
TYPES: tt_fields TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
TYPES: BEGIN OF ty_row,
         fields TYPE tt_fields,
       END OF ty_row.
TYPES: tt_rows TYPE STANDARD TABLE OF ty_row WITH DEFAULT KEY.
```

`et_data` è una `tt_rows`: una entry per riga sorgente, e ogni entry ha `fields`, la tabella dei suoi campi già separati.

### Costanti

| Costante | Valore | Significato |
|---|---|---|
| `gc_source_local` | `'L'` | Legge dal PC dell'utente (usa i servizi GUI) |
| `gc_source_server` | `'S'` | Legge da un path AL11 sul server applicativo |

### Metodo: `LOAD_FILE`

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

| Parametro | Direzione | Descrizione |
|---|---|---|
| `iv_path` | IN | Path completo del file (locale o server AL11) |
| `iv_source` | IN | `gc_source_local` oppure `gc_source_server` |
| `iv_separator` | IN | Delimitatore di campo del **CSV**. Default `';'`. Non usato per Excel (le celle sono già strutturate). |
| `iv_skip_header` | IN | Se `abap_true`, la prima riga viene rimossa dall'output |
| `iv_fallback_cp` | IN | Codepage usata quando il CSV non ha BOM e non è UTF-8 valido. Default `'1160'` (Windows-1252). |
| `et_data` | OUT | Una riga per ogni riga sorgente; ogni riga contiene i suoi campi (`fields`) |
| `ev_error` | OUT | Vuoto in caso di successo. Contiene un messaggio descrittivo in caso di errore. |

---

## Design interno

| Metodo privato | Scopo |
|---|---|
| `detect_file_type` | Estrae l'estensione tramite regex, restituisce `'CSV'`, `'XLSX'`, `'XLS'` o `'UNKNOWN'` |
| `read_local_binary` | Legge un file binario locale tramite `gui_upload` (`filetype = 'BIN'`) e converte in xstring con `SCMS_BINARY_TO_XSTRING`. Usato sia per CSV che per Excel. |
| `read_server_binary` | Legge un file binario server tramite `OPEN DATASET BINARY MODE` e converte in xstring. Usato sia per CSV che per Excel. |
| `csv_xstring_to_rows` | Decodifica (auto-encoding) + normalizza i fine-riga + spezza ogni riga in campi |
| `detect_and_decode` | Rileva l'encoding (BOM → test UTF-8 → fallback) e decodifica l'xstring in stringa |
| `is_utf8` | `abap_true` se i byte sono UTF-8 valido (decodifica stretta) |
| `to_string` | Decodifica con codepage nota, saltando i byte del BOM; i byte non mappabili diventano `'#'` |
| `parse_csv_line` | Spezza una riga CSV in campi, quote-aware (RFC 4180) |
| `excel_xstring_to_rows` | Parsea l'xstring con `cl_fdt_xl_spreadsheet`, cicla sul primo foglio e mappa ogni cella in un campo |

### Uniformità dell'output

Sia CSV che Excel producono la stessa forma di output: una `tt_rows` dove ogni entry ha i campi già separati:

```
et_data[ 1 ]-fields = ( "valore1" "valore2" "valore3" )
```

Questo significa che il chiamante usa la stessa logica — leggere `<row>-fields[ n ]` — indipendentemente dal formato originale del file, **senza fare lo `SPLIT`** e senza preoccuparsi del separatore o dell'encoding.

---

## Note e limitazioni

- **File locali**: richiedono una sessione SAP GUI attiva (`cl_gui_frontend_services`). **Non disponibili in modalità batch** (`sy-batch = abap_true`). Aggiungere un controllo prima di chiamare la classe se il programma può girare in background.
- **XLS lato server**: `cl_fdt_xl_spreadsheet` supporta principalmente XLSX (Office Open XML). Il supporto XLS dipende dalla release SAP. In caso di errore di parsing, `ev_error` conterrà un messaggio descrittivo.
- La classe legge sempre il **primo foglio** del file Excel. Per scegliere un foglio specifico, estendere `excel_xstring_to_rows` aggiungendo un parametro per il nome o l'indice del foglio.
- **Campi quotati multi-riga**: il parser CSV gestisce virgolette, separatore interno e `""`, ma **non** un a-capo dentro un campo quotato (caso RFC valido ma raro nei CSV gestionali), perché le righe vengono prima separate sui fine-riga. Se servisse, va sostituito lo split-poi-parse con un parser in singola passata sull'intero testo.
- **UTF-16 senza BOM** non viene rilevato (decadrebbe sul fallback). È un caso raro: gli export UTF-16 includono quasi sempre il BOM.
- L'approccio `ev_error` è stato scelto rispetto alle eccezioni per mantenere semplice il codice del chiamante. Verificare sempre `ev_error IS NOT INITIAL` prima di usare `et_data`.

---

## Esempi di utilizzo

### Esempio 1 — CSV locale

```abap
DATA: lo_loader TYPE REF TO lc_file_loader,
      lt_rows   TYPE lc_file_loader=>tt_rows,
      lv_error  TYPE string.

CREATE OBJECT lo_loader.

lo_loader->load_file(
  EXPORTING
    iv_path        = 'C:\dati\import.csv'
    iv_source      = lc_file_loader=>gc_source_local
    iv_separator   = ';'              " delimitatore del CSV
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_rows
    ev_error       = lv_error ).

IF lv_error IS NOT INITIAL.
  MESSAGE lv_error TYPE 'E'.
ENDIF.

" lt_rows contiene ora una riga per record, con i campi già separati, es.
" lt_rows[ 1 ]-fields = ( "Mario" "Rossi" "1990" )
```

### Esempio 2 — XLSX su server AL11

```abap
" Per Excel il separatore non serve: le celle sono già strutturate.
lo_loader->load_file(
  EXPORTING
    iv_path        = '/dati/import/prodotti.xlsx'
    iv_source      = lc_file_loader=>gc_source_server
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_rows
    ev_error       = lv_error ).
```

### Esempio 3 — CSV con codepage di fallback diversa

```abap
" CSV senza BOM e non UTF-8, scritto in Europa centrale (Windows-1250).
lo_loader->load_file(
  EXPORTING
    iv_path        = '/dati/import/listino.csv'
    iv_source      = lc_file_loader=>gc_source_server
    iv_separator   = ','
    iv_fallback_cp = '1404'           " codepage SAP per Windows-1250
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_rows
    ev_error       = lv_error ).
```

### Esempio 4 — Lettura dell'output

```abap
DATA: lv_campo1 TYPE string,
      lv_campo2 TYPE string.

LOOP AT lt_rows ASSIGNING FIELD-SYMBOL(<ls_riga>).
  " i campi sono già separati: niente SPLIT
  lv_campo1 = VALUE #( <ls_riga>-fields[ 1 ] OPTIONAL ).
  lv_campo2 = VALUE #( <ls_riga>-fields[ 2 ] OPTIONAL ).

  " mappare sui propri campi di business qui
ENDLOOP.
```

> `VALUE #( ... OPTIONAL )` restituisce stringa vuota se il campo non esiste, evitando l'eccezione su righe con meno colonne del previsto.

---

## Programma di esempio completo

Report ABAP autonomo che definisce `lc_file_loader` come classe locale e la usa per importare un elenco di persone da un file CSV o XLSX e visualizzarlo in un ALV grid.

```abap
*&---------------------------------------------------------------------*
*& Report  ZDEMO_FILE_LOADER
*& Programma demo per LC_FILE_LOADER
*&---------------------------------------------------------------------*
REPORT zdemo_file_loader.

*----------------------------------------------------------------------*
* Classe locale: LC_FILE_LOADER
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
        ev_error = |Estensione file non supportata: { iv_path }|.

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
      ev_error = |Errore lettura file binario locale: { iv_path } (subrc { sy-subrc })|.
      RETURN.
    ENDIF.

    IF lv_xlen <= 0.
      ev_error = |File vuoto: { iv_path }|.
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
      ev_error = |Errore conversione dati binari in xstring: { iv_path }|.
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
      ev_error = |Errore apertura file binario server: { iv_path }|.
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
      ev_error = |File vuoto: { iv_path }|.
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
      ev_error = |Errore conversione dati binari in xstring: { iv_path }|.
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

    " Normalizza i fine-riga: CRLF (Windows) -> LF, poi CR isolato (vecchi Mac) -> LF
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
        ev_error = 'Errore apertura file Excel: formato non supportato (verificare che il file sia un XLSX valido o XLS compatibile)'.
        RETURN.
    ENDTRY.

    lo_excel->if_fdt_doc_spreadsheet~get_worksheet_names(
      IMPORTING worksheet_names = lt_sheets ).

    IF lt_sheets IS INITIAL.
      ev_error = 'Nessun foglio trovato nel file Excel'.
      RETURN.
    ENDIF.

    READ TABLE lt_sheets INTO lv_sheet INDEX 1.

    lo_data = lo_excel->if_fdt_doc_spreadsheet~get_itab_from_worksheet( lv_sheet ).
    IF lo_data IS INITIAL.
      ev_error = |Impossibile leggere il foglio "{ lv_sheet }"|.
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
* Tipi
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_persona,
         nome         TYPE string,
         cognome      TYPE string,
         data_nascita TYPE string,
       END OF ty_persona.

*----------------------------------------------------------------------*
* Dati globali
*----------------------------------------------------------------------*
DATA: gt_persone TYPE STANDARD TABLE OF ty_persona,
      gv_error   TYPE string.

*----------------------------------------------------------------------*
* Selection screen
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS: p_rb1 RADIOBUTTON GROUP grb DEFAULT 'X',   " file locale
              p_rb2 RADIOBUTTON GROUP grb.               " file server
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
* Gestione selection screen
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
* Logica principale
*----------------------------------------------------------------------*
START-OF-SELECTION.

  " modalità batch: file locale non consentito
  IF sy-batch = abap_true AND p_rb1 = abap_true.
    MESSAGE 'Il caricamento da file locale non è disponibile in modalità batch.' TYPE 'E'.
  ENDIF.

  " --- caricamento file ---
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
      iv_separator   = p_sep          " usato solo per il CSV
      iv_skip_header = CONV abap_bool( p_head )
    IMPORTING
      et_data        = lt_rows
      ev_error       = gv_error ).

  IF gv_error IS NOT INITIAL.
    MESSAGE gv_error TYPE 'E'.
  ENDIF.

  IF lt_rows IS INITIAL.
    MESSAGE 'Nessun dato trovato nel file.' TYPE 'I'.
    RETURN.
  ENDIF.

  " --- mappatura righe (campi già separati, niente SPLIT) ---
  DATA ls_persona TYPE ty_persona.

  LOOP AT lt_rows ASSIGNING FIELD-SYMBOL(<ls_riga>).
    CLEAR ls_persona.
    ls_persona-nome         = VALUE #( <ls_riga>-fields[ 1 ] OPTIONAL ).
    ls_persona-cognome      = VALUE #( <ls_riga>-fields[ 2 ] OPTIONAL ).
    ls_persona-data_nascita = VALUE #( <ls_riga>-fields[ 3 ] OPTIONAL ).
    APPEND ls_persona TO gt_persone.
  ENDLOOP.

  " --- visualizzazione ALV ---
  cl_salv_table=>factory(
    IMPORTING
      r_salv_table = DATA(lo_alv)
    CHANGING
      t_table      = gt_persone ).

  lo_alv->get_columns( )->set_optimize( abap_true ).
  lo_alv->display( ).
```

> **Formato file atteso (CSV o XLSX):**
> ```
> Nome;Cognome;DataNascita
> Mario;Rossi;1990-05-12
> Laura;Bianchi;1985-11-30
> ```
>
> Con il parser quote-aware, un CSV come questo viene letto correttamente (la virgola dentro le virgolette **non** spezza il campo):
> ```
> Nome;Cognome;Note
> Mario;Rossi;"Cliente storico; pagatore puntuale"
> ```
