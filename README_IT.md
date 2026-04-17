# LC_FILE_LOADER

Classe ABAP generica e riutilizzabile per caricare un file CSV, XLS o XLSX — dal PC locale dell'utente oppure da un path AL11 sul server applicativo — in una semplice `STANDARD TABLE OF string`. Ogni entry della tabella di output rappresenta una riga grezza del file sorgente. Il parsing e la logica di business sono lasciati interamente al chiamante.

---

## Funzionalità

- Supporto formati **CSV**, **XLS** e **XLSX**
- Supporto sorgente **locale (frontend)** e **server (AL11)**
- Rilevamento automatico del tipo di file dall'estensione (case-insensitive)
- Opzione di **salto della riga di intestazione**
- **Separatore celle** configurabile per l'output Excel (le celle vengono unite in una stringa per riga, identica al formato CSV grezzo)
- Segnalazione errori tramite parametro `ev_error` in EXPORTING — nessun `MESSAGE` fisso, nessuna eccezione da gestire
- Nessun tipo fisso: l'output è sempre `tt_raw` (`TABLE OF string`), completamente indipendente da qualsiasi struttura di business

---

## API pubblica

### Tipi

```abap
TYPES: tt_raw TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
```

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
    iv_separator   TYPE c DEFAULT ';'
    iv_skip_header TYPE abap_bool DEFAULT abap_false
  EXPORTING
    et_data        TYPE tt_raw
    ev_error       TYPE string.
```

| Parametro | Direzione | Descrizione |
|---|---|---|
| `iv_path` | IN | Path completo del file (locale o server AL11) |
| `iv_source` | IN | `gc_source_local` oppure `gc_source_server` |
| `iv_separator` | IN | Separatore usato per unire le celle Excel in una stringa. Default `';'`. Ignorato per CSV (le righe vengono restituite così come sono). |
| `iv_skip_header` | IN | Se `abap_true`, la prima riga viene rimossa dall'output |
| `et_data` | OUT | Una stringa per ogni riga del file |
| `ev_error` | OUT | Vuoto in caso di successo. Contiene un messaggio descrittivo in caso di errore. |

---

## Design interno

| Metodo privato | Scopo |
|---|---|
| `detect_file_type` | Estrae l'estensione tramite regex, restituisce `'CSV'`, `'XLSX'`, `'XLS'` o `'UNKNOWN'` |
| `load_local_csv` | Legge un CSV locale tramite `cl_gui_frontend_services=>gui_upload` (`filetype = 'ASC'`) |
| `load_server_csv` | Legge un CSV server tramite `OPEN DATASET TEXT MODE ENCODING DEFAULT WITH SMART LINEFEED` |
| `read_local_binary` | Legge un file binario locale tramite `gui_upload` (`filetype = 'BIN'`) e converte in xstring con `SCMS_BINARY_TO_XSTRING` |
| `read_server_binary` | Legge un file binario server tramite `OPEN DATASET BINARY MODE` e converte in xstring |
| `excel_xstring_to_strings` | Parsea l'xstring con `cl_fdt_xl_spreadsheet`, cicla sul primo foglio e unisce le celle di ogni riga con `iv_separator` |

### Uniformità dell'output

Sia CSV che Excel producono la stessa forma di output: una `TABLE OF string` dove ogni entry ha questo aspetto:

```
"valore1;valore2;valore3"
```

Questo significa che il chiamante può usare la stessa logica `SPLIT ... AT separatore INTO TABLE` indipendentemente dal formato originale del file.

---

## Note e limitazioni

- **File locali**: richiedono una sessione SAP GUI attiva (`cl_gui_frontend_services`). **Non disponibili in modalità batch** (`sy-batch = abap_true`). Aggiungere un controllo prima di chiamare la classe se il programma può girare in background.
- **XLS lato server**: `cl_fdt_xl_spreadsheet` supporta principalmente XLSX (Office Open XML). Il supporto XLS dipende dalla release SAP. In caso di errore di parsing, `ev_error` conterrà un messaggio descrittivo.
- La classe legge sempre il **primo foglio** del file Excel. Per scegliere un foglio specifico, estendere `excel_xstring_to_strings` aggiungendo un parametro per il nome o l'indice del foglio.
- L'approccio `ev_error` è stato scelto rispetto alle eccezioni per mantenere semplice il codice del chiamante. Verificare sempre `ev_error IS NOT INITIAL` prima di usare `et_data`.

---

## Esempi di utilizzo

### Esempio 1 — CSV locale

```abap
DATA: lo_loader TYPE REF TO lc_file_loader,
      lt_raw    TYPE lc_file_loader=>tt_raw,
      lv_error  TYPE string.

CREATE OBJECT lo_loader.

lo_loader->load_file(
  EXPORTING
    iv_path        = 'C:\dati\import.csv'
    iv_source      = lc_file_loader=>gc_source_local
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_raw
    ev_error       = lv_error ).

IF lv_error IS NOT INITIAL.
  MESSAGE lv_error TYPE 'E'.
ENDIF.

" lt_raw contiene ora una stringa per riga dati, es. "Mario;Rossi;1990"
```

### Esempio 2 — XLSX su server AL11

```abap
lo_loader->load_file(
  EXPORTING
    iv_path        = '/dati/import/prodotti.xlsx'
    iv_source      = lc_file_loader=>gc_source_server
    iv_separator   = ';'
    iv_skip_header = abap_true
  IMPORTING
    et_data        = lt_raw
    ev_error       = lv_error ).
```

### Esempio 3 — Parsing dell'output

```abap
DATA: lt_fields TYPE STANDARD TABLE OF string,
      lv_campo1 TYPE string,
      lv_campo2 TYPE string.

LOOP AT lt_raw ASSIGNING FIELD-SYMBOL(<lv_riga>).
  CLEAR lt_fields.
  SPLIT <lv_riga> AT ';' INTO TABLE lt_fields.

  READ TABLE lt_fields INDEX 1 INTO lv_campo1.
  READ TABLE lt_fields INDEX 2 INTO lv_campo2.

  " mappare sui propri campi di business qui
ENDLOOP.
```

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
      ev_error = |Errore apertura file CSV locale: { iv_path } (subrc { sy-subrc })|.
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
      ev_error = |Errore apertura file CSV server: { iv_path }|.
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
          lv_xlen TYPE i.

    OPEN DATASET iv_path FOR INPUT IN BINARY MODE.
    IF sy-subrc <> 0.
      ev_error = |Errore apertura file binario server: { iv_path }|.
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
    MESSAGE 'Nessun dato trovato nel file.' TYPE 'I'.
    RETURN.
  ENDIF.

  " --- parsing righe ---
  DATA: lt_fields  TYPE STANDARD TABLE OF string,
        ls_persona TYPE ty_persona.

  LOOP AT lt_raw ASSIGNING FIELD-SYMBOL(<lv_riga>).
    CLEAR: ls_persona, lt_fields.
    SPLIT <lv_riga> AT p_sep INTO TABLE lt_fields.

    READ TABLE lt_fields INDEX 1 INTO ls_persona-nome.
    READ TABLE lt_fields INDEX 2 INTO ls_persona-cognome.
    READ TABLE lt_fields INDEX 3 INTO ls_persona-data_nascita.

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
