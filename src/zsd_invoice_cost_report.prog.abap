REPORT zsd_invoice_cost_report.

*-----------------------------------------------------------------------
* SAP S/4HANA 2020 On-Premise - Invoice / GST / Production Cost
* Classic ABAP + standard sales and production BAPIs. No CDS / AMDP.
*
* Sales: BAPISDORDER_GETDETAILEDLIST - distinct SOs, batched.
* Production: BAPI_PRODORD_GET_DETAIL - distinct PP orders, cached.
* Billing/GST/cost: bulk Open SQL; no SELECT inside invoice loop.
*
* VALIDATE WITH BUSINESS BEFORE UAT:
* - CGST/SGST/IGST KSCHL and inactive/statistical treatment;
* - MARC-STEUC is current material master, not historical HSN/SAC;
* - CO03 cost categories, signs, ledger, posting-date cutoff;
* - Direct MTO links first, then AFPO project-stock WBS/material/plant;
* - WBS matches are candidates; validate origin before financial UAT;
* - Multiple linked orders are listed; costs remain blank without one order;
* - Costs are full production-order cost; not allocated to invoice.
* - WBS link alone cannot prove source of delivered/issued project stock;
*   do not interpret a candidate as validated invoice-level provenance.
* - Empty cost G/L ranges / no PP order leave CO03 amounts unavailable.
* - Customer GSTIN is current KNA1 master, not historical snapshot.
* - Blank CO G/L ranges skip cost lookup (billing/BAPI test mode).
* - Commercial invoice mapping to GSTR1 Docno is NOT yet confirmed.
* - P_REFNO tests VBRK-XBLNR, not guaranteed to be official no.
*-----------------------------------------------------------------------

TABLES: vbrk, acdoca.

CONSTANTS:
  gc_sales_pack TYPE i VALUE 200,
  gc_cost_pack  TYPE i VALUE 500.

SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE text-001.
  SELECT-OPTIONS:
    s_fkdat FOR vbrk-fkdat OBLIGATORY,
    s_vkorg FOR vbrk-vkorg,
    s_vbeln FOR vbrk-vbeln.
  PARAMETERS p_refno AS CHECKBOX DEFAULT space.
SELECTION-SCREEN END OF BLOCK b01.
SELECTION-SCREEN SKIP 1.

SELECTION-SCREEN BEGIN OF BLOCK b02 WITH FRAME TITLE text-002.
  PARAMETERS:
    p_cgst TYPE kschl DEFAULT 'JOCG',
    p_sgst TYPE kschl DEFAULT 'JOSG',
    p_igst TYPE kschl DEFAULT 'JOIG'.
SELECTION-SCREEN END OF BLOCK b02.
SELECTION-SCREEN SKIP 1.

SELECTION-SCREEN BEGIN OF BLOCK b03 WITH FRAME TITLE text-003.
  PARAMETERS:
    p_ledger TYPE acdoca-rldnr DEFAULT '0L',
    p_cdate  TYPE sy-datum DEFAULT '99991231'.
  SELECT-OPTIONS:
    s_matgl FOR acdoca-racct,
    s_ovhgl FOR acdoca-racct.
SELECTION-SCREEN END OF BLOCK b03.

TYPES: BEGIN OF ty_out,
         sno              TYPE i,
         month_text       TYPE char7,
         invoice_no       TYPE vbrk-vbeln,
         invoice_ref      TYPE vbrk-xblnr,
         invoice_date     TYPE vbrk-fkdat,
         bill_to          TYPE kunnr,
         ship_to          TYPE kunnr,
         bill_name        TYPE kna1-name1,
         ship_name        TYPE kna1-name1,
         gstin            TYPE kna1-stcd3,
         customer_po      TYPE vbkd-bstkd,
         sales_order      TYPE vbak-vbeln,
         order_date       TYPE vbak-audat,
         hsn_sac          TYPE marc-steuc,
         item_no          TYPE vbrp-posnr,
         material         TYPE vbrp-matnr,
         description      TYPE vbrp-arktx,
         quantity         TYPE vbrp-fkimg,
         unit_rate_fc     TYPE p LENGTH 16 DECIMALS 5,
         taxable_fc       TYPE vbrp-netwr,
         currency         TYPE vbrk-waerk,
         exchange_rate    TYPE vbrk-kurrf,
         local_currency   TYPE t001-waers,
         cost_currency    TYPE t001-waers,
         taxable_lc       TYPE p LENGTH 16 DECIMALS 2,
         cgst             TYPE p LENGTH 16 DECIMALS 2,
         sgst             TYPE p LENGTH 16 DECIMALS 2,
         igst             TYPE p LENGTH 16 DECIMALS 2,
         accounting_doc   TYPE vbrk-belnr,
         material_cost    TYPE p LENGTH 16 DECIMALS 2,
         overhead         TYPE p LENGTH 16 DECIMALS 2,
         total_cost       TYPE p LENGTH 16 DECIMALS 2,
         production_order TYPE c LENGTH 120,
         prod_material    TYPE mara-matnr,
         prod_plant       TYPE werks_d,
         prod_bapi_status TYPE char24,
         so_bapi_status   TYPE char24,
         wbs_no           TYPE prps-posid,
         link_status      TYPE char24,
         cost_status      TYPE char24,
         conv_status      TYPE char20,
         " Technical helper fields, hidden in ALV.
         knumv            TYPE vbrk-knumv,
         bukrs            TYPE vbrk-bukrs,
         sales_item       TYPE vbrp-aupos,
         plant            TYPE vbrp-werks,
         reference_doc    TYPE vbrp-vgbel,
         fiscal_year      TYPE vbrk-gjahr,
         wbs_internal     TYPE vbap-ps_psp_pnr,
         primary_order    TYPE aufnr,
       END OF ty_out.

* Exactly 31 visible columns, in the business Template sheet sequence.
* The existing TY_OUT retains technical fields for internal processing.
TYPES: BEGIN OF ty_alv,
         sno              TYPE i,
         month_text       TYPE char7,
         invoice_no       TYPE char20,
         invoice_date     TYPE vbrk-fkdat,
         bill_to          TYPE kunnr,
         ship_to          TYPE kunnr,
         bill_name        TYPE kna1-name1,
         ship_name        TYPE kna1-name1,
         gstin            TYPE kna1-stcd3,
         customer_po      TYPE vbkd-bstkd,
         sales_order      TYPE vbak-vbeln,
         order_date       TYPE vbak-audat,
         hsn_sac          TYPE marc-steuc,
         item_no          TYPE vbrp-posnr,
         material         TYPE vbrp-matnr,
         description      TYPE vbrp-arktx,
         quantity         TYPE vbrp-fkimg,
         unit_rate_fc     TYPE p LENGTH 16 DECIMALS 5,
         taxable_fc       TYPE vbrp-netwr,
         currency         TYPE vbrk-waerk,
         exchange_rate    TYPE vbrk-kurrf,
         taxable_lc       TYPE p LENGTH 16 DECIMALS 2,
         cgst             TYPE p LENGTH 16 DECIMALS 2,
         sgst             TYPE p LENGTH 16 DECIMALS 2,
         igst             TYPE p LENGTH 16 DECIMALS 2,
         accounting_doc   TYPE vbrk-belnr,
         material_cost    TYPE p LENGTH 16 DECIMALS 2,
         overhead         TYPE p LENGTH 16 DECIMALS 2,
         total_cost       TYPE p LENGTH 16 DECIMALS 2,
         production_order TYPE c LENGTH 120,
         wbs_no           TYPE prps-posid,
       END OF ty_alv.
TYPES ty_t_alv TYPE STANDARD TABLE OF ty_alv WITH EMPTY KEY.

TYPES ty_t_out TYPE STANDARD TABLE OF ty_out WITH EMPTY KEY.

TYPES: BEGIN OF ty_partner,
         vbeln TYPE vbpa-vbeln,
         posnr TYPE vbpa-posnr,
         parvw TYPE vbpa-parvw,
         kunnr TYPE vbpa-kunnr,
       END OF ty_partner.
TYPES ty_t_partner TYPE STANDARD TABLE OF ty_partner WITH EMPTY KEY.
TYPES: BEGIN OF ty_delivery,
         vbeln TYPE likp-vbeln,
         kunnr TYPE likp-kunnr,
       END OF ty_delivery.
TYPES: BEGIN OF ty_kunnr_key,
         kunnr TYPE kna1-kunnr,
       END OF ty_kunnr_key.
TYPES: BEGIN OF ty_customer,
         kunnr TYPE kna1-kunnr,
         name1 TYPE kna1-name1,
         stcd3 TYPE kna1-stcd3,
       END OF ty_customer.
TYPES: BEGIN OF ty_sales,
         vbeln TYPE vbak-vbeln,
         audat TYPE vbak-audat,
       END OF ty_sales.
TYPES: BEGIN OF ty_vbkd,
         vbeln TYPE vbkd-vbeln,
         posnr TYPE vbkd-posnr,
         bstkd TYPE vbkd-bstkd,
       END OF ty_vbkd.
TYPES: BEGIN OF ty_sales_item,
         vbeln      TYPE vbap-vbeln,
         posnr      TYPE vbap-posnr,
         ps_psp_pnr TYPE vbap-ps_psp_pnr,
       END OF ty_sales_item.
TYPES: BEGIN OF ty_wbs,
         pspnr TYPE prps-pspnr,
         posid TYPE prps-posid,
       END OF ty_wbs.
TYPES: BEGIN OF ty_marc,
         matnr TYPE marc-matnr,
         werks TYPE marc-werks,
         steuc TYPE marc-steuc,
       END OF ty_marc.
TYPES: BEGIN OF ty_company,
         bukrs TYPE t001-bukrs,
         waers TYPE t001-waers,
       END OF ty_company.
TYPES: BEGIN OF ty_tax,
         knumv TYPE prcd_elements-knumv,
         kposn TYPE prcd_elements-kposn,
         cgst  TYPE p LENGTH 16 DECIMALS 2,
         sgst  TYPE p LENGTH 16 DECIMALS 2,
         igst  TYPE p LENGTH 16 DECIMALS 2,
       END OF ty_tax.
TYPES: BEGIN OF ty_so_order,
         kdauf     TYPE afpo-kdauf,
         kdpos     TYPE afpo-kdpos,
         aufnr     TYPE afpo-aufnr,
         ambiguous TYPE abap_bool,
         order_text TYPE c LENGTH 120,
       END OF ty_so_order.
TYPES: BEGIN OF ty_so_key,
         kdauf TYPE afpo-kdauf,
         kdpos TYPE afpo-kdpos,
       END OF ty_so_key.
TYPES: BEGIN OF ty_wbs_key,
         projn TYPE afpo-projn,
         matnr TYPE afpo-matnr,
         werks TYPE afpo-dwerk,
       END OF ty_wbs_key.
TYPES: BEGIN OF ty_wbs_order,
         projn TYPE afpo-projn,
         matnr TYPE afpo-matnr,
         werks TYPE afpo-dwerk,
         aufnr TYPE afpo-aufnr,
         ambiguous TYPE abap_bool,
         order_text TYPE c LENGTH 120,
       END OF ty_wbs_order.
TYPES: BEGIN OF ty_cost,
         aufnr    TYPE aufnr,
         waers    TYPE t001-waers,
         material TYPE p LENGTH 16 DECIMALS 2,
         overhead TYPE p LENGTH 16 DECIMALS 2,
       END OF ty_cost.
TYPES: BEGIN OF ty_bapi_check,
         aufnr    TYPE aufnr,
         error    TYPE abap_bool,
         material TYPE mara-matnr,
         plant    TYPE werks_d,
       END OF ty_bapi_check.
TYPES ty_t_sales_key TYPE STANDARD TABLE OF sales_key WITH EMPTY KEY.

TYPES ty_t_order_rng TYPE RANGE OF aufnr.
TYPES ty_t_cond_rng  TYPE RANGE OF kschl.

DATA:
  gt_out      TYPE ty_t_out,
  gt_alv      TYPE ty_t_alv,
  gt_sales    TYPE HASHED TABLE OF ty_sales WITH UNIQUE KEY vbeln,
  gt_business TYPE HASHED TABLE OF ty_vbkd
                   WITH UNIQUE KEY vbeln posnr,
  gt_tax      TYPE HASHED TABLE OF ty_tax WITH UNIQUE KEY knumv kposn,
  gt_so_order TYPE HASHED TABLE OF ty_so_order
                      WITH UNIQUE KEY kdauf kdpos,
  gt_wbs_order TYPE HASHED TABLE OF ty_wbs_order
                     WITH UNIQUE KEY projn matnr werks,
  gt_cost     TYPE HASHED TABLE OF ty_cost WITH UNIQUE KEY aufnr,
  gt_check    TYPE HASHED TABLE OF ty_bapi_check
                      WITH UNIQUE KEY aufnr.

AT SELECTION-SCREEN.
  IF p_cgst = p_sgst OR p_cgst = p_igst OR p_sgst = p_igst.
    MESSAGE 'CGST, SGST and IGST condition types must differ'
      TYPE 'E'.
  ENDIF.

START-OF-SELECTION.
  PERFORM get_billing.
  IF gt_out IS INITIAL.
    MESSAGE 'No billing items found' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.
  PERFORM read_sales_bapis.
  PERFORM enrich_documents.
  PERFORM collect_gst.
  PERFORM collect_order_links.
  PERFORM assign_order_links.
  PERFORM read_production_bapis.
  PERFORM collect_costs.
  PERFORM finalize_output.
  PERFORM display_report.

*-----------------------------------------------------------------------
* 1. One header/item query. Never do SELECT SINGLE in a billing loop.
*-----------------------------------------------------------------------
FORM get_billing.
  SELECT h~vbeln AS invoice_no,
         h~fkdat AS invoice_date,
         h~xblnr AS invoice_ref,
         h~waerk AS currency,
         h~kurrf AS exchange_rate,
         h~knumv AS knumv,
         h~bukrs AS bukrs,
         h~belnr AS accounting_doc,
         h~gjahr AS fiscal_year,
         i~posnr AS item_no,
         i~matnr AS material,
         i~arktx AS description,
         i~fkimg AS quantity,
         i~netwr AS taxable_fc,
         i~aubel AS sales_order,
         i~aupos AS sales_item,
         i~werks AS plant,
         i~vgbel AS reference_doc
    FROM vbrk AS h
    INNER JOIN vbrp AS i ON i~vbeln = h~vbeln
    WHERE h~fkdat IN @s_fkdat
      AND h~vkorg IN @s_vkorg
      AND h~vbeln IN @s_vbeln
      AND h~fksto = @space
    INTO CORRESPONDING FIELDS OF TABLE @gt_out.
ENDFORM.

*-----------------------------------------------------------------------
* 2. Sales-order BAPI: one call per PACKAGE of distinct order numbers.
*    Header document date and item/header customer PO from BAPI output.
*-----------------------------------------------------------------------
FORM read_sales_bapis.
  DATA lt_unique TYPE SORTED TABLE OF vbak-vbeln
                 WITH UNIQUE KEY table_line.
  DATA lt_docs TYPE ty_t_sales_key.

  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<bill>).
    IF <bill>-sales_order IS NOT INITIAL.
      INSERT <bill>-sales_order INTO TABLE lt_unique.
    ENDIF.
  ENDLOOP.

  LOOP AT lt_unique INTO DATA(lv_sales_order).
    APPEND VALUE sales_key( vbeln = lv_sales_order ) TO lt_docs.
    IF lines( lt_docs ) >= gc_sales_pack.
      PERFORM read_sales_package USING lt_docs.
      CLEAR lt_docs.
    ENDIF.
  ENDLOOP.

  IF lt_docs IS NOT INITIAL.
    PERFORM read_sales_package USING lt_docs.
  ENDIF.
ENDFORM.

FORM read_sales_package USING it_docs TYPE ty_t_sales_key.
  DATA lt_docs TYPE ty_t_sales_key.
  DATA ls_view TYPE order_view.
  DATA lt_headers TYPE STANDARD TABLE OF bapisdhd WITH EMPTY KEY.
  DATA lt_business TYPE STANDARD TABLE OF bapisdbusi WITH EMPTY KEY.

  lt_docs = it_docs.
  ls_view-header   = abap_true.
  ls_view-business = abap_true.

  CALL FUNCTION 'BAPISDORDER_GETDETAILEDLIST'
    EXPORTING
      i_bapi_view       = ls_view
    TABLES
      sales_documents   = lt_docs
      order_headers_out = lt_headers
      order_business_out = lt_business.

  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  LOOP AT lt_headers INTO DATA(ls_header).
    IF ls_header-doc_number IS INITIAL.
      CONTINUE.
    ENDIF.
    INSERT VALUE ty_sales(
      vbeln = ls_header-doc_number
      audat = ls_header-doc_date ) INTO TABLE gt_sales.
  ENDLOOP.

  LOOP AT lt_business INTO DATA(ls_business).
    IF ls_business-sd_doc IS INITIAL.
      CONTINUE.
    ENDIF.
    READ TABLE gt_business ASSIGNING FIELD-SYMBOL(<business>)
      WITH TABLE KEY vbeln = ls_business-sd_doc
                     posnr = ls_business-itm_number.
    IF sy-subrc <> 0.
      INSERT VALUE ty_vbkd(
        vbeln = ls_business-sd_doc
        posnr = ls_business-itm_number
        bstkd = ls_business-purch_no_c )
        INTO TABLE gt_business.
    ELSEIF <business>-bstkd IS INITIAL.
      <business>-bstkd = ls_business-purch_no_c.
    ENDIF.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* 3. Bulk customer, item, WBS, material and company code lookups.
*-----------------------------------------------------------------------
FORM enrich_documents.
  DATA lt_partner TYPE ty_t_partner.
  DATA lt_deliveries TYPE HASHED TABLE OF ty_delivery
                     WITH UNIQUE KEY vbeln.
  DATA lt_customer_keys TYPE SORTED TABLE OF ty_kunnr_key
                        WITH UNIQUE KEY kunnr.
  DATA lt_customer TYPE HASHED TABLE OF ty_customer
                   WITH UNIQUE KEY kunnr.
  DATA lt_item TYPE HASHED TABLE OF ty_sales_item
               WITH UNIQUE KEY vbeln posnr.
  DATA lt_wbs TYPE HASHED TABLE OF ty_wbs WITH UNIQUE KEY pspnr.
  DATA lt_marc TYPE HASHED TABLE OF ty_marc
               WITH UNIQUE KEY matnr werks.
  DATA lt_company TYPE HASHED TABLE OF ty_company
                  WITH UNIQUE KEY bukrs.
  DATA lv_bill TYPE kunnr.
  DATA lv_ship TYPE kunnr.
  DATA ls_customer TYPE ty_customer.

  " Billing header/item partners. Item values take precedence.
  SELECT vbeln, posnr, parvw, kunnr
    FROM vbpa
    FOR ALL ENTRIES IN @gt_out
    WHERE vbeln = @gt_out-invoice_no
      AND ( posnr = '000000' OR posnr = @gt_out-item_no )
      AND ( parvw = 'RE' OR parvw = 'WE' )
    INTO TABLE @lt_partner.

  " Sales-order partner fallback, for invoices with no VBPA partners.
  SELECT vbeln, posnr, parvw, kunnr
    FROM vbpa
    FOR ALL ENTRIES IN @gt_out
    WHERE vbeln = @gt_out-sales_order
      AND ( posnr = '000000' OR posnr = @gt_out-sales_item )
      AND ( parvw = 'RE' OR parvw = 'WE' )
    APPENDING TABLE @lt_partner.

  DELETE lt_partner WHERE kunnr IS INITIAL.
  SORT lt_partner BY vbeln posnr parvw kunnr.
  DELETE ADJACENT DUPLICATES FROM lt_partner
    COMPARING vbeln posnr parvw.

  " If the invoice is delivery-related, its preceding document may
  " be a delivery. No match is returned for other document types.
  SELECT vbeln, kunnr
    FROM likp
    FOR ALL ENTRIES IN @gt_out
    WHERE vbeln = @gt_out-reference_doc
    INTO TABLE @lt_deliveries.

  LOOP AT lt_partner INTO DATA(ls_partner).
    IF ls_partner-kunnr IS NOT INITIAL.
      INSERT VALUE #( kunnr = ls_partner-kunnr )
        INTO TABLE lt_customer_keys.
    ENDIF.
  ENDLOOP.
  LOOP AT lt_deliveries INTO DATA(ls_delivery).
    IF ls_delivery-kunnr IS NOT INITIAL.
      INSERT VALUE #( kunnr = ls_delivery-kunnr )
        INTO TABLE lt_customer_keys.
    ENDIF.
  ENDLOOP.
  IF lt_customer_keys IS NOT INITIAL.
    SELECT kunnr, name1, stcd3 FROM kna1
      FOR ALL ENTRIES IN @lt_customer_keys
      WHERE kunnr = @lt_customer_keys-kunnr
      INTO TABLE @lt_customer.
  ENDIF.

  SELECT vbeln, posnr, ps_psp_pnr FROM vbap
    FOR ALL ENTRIES IN @gt_out
    WHERE vbeln = @gt_out-sales_order
      AND posnr = @gt_out-sales_item
    INTO TABLE @lt_item.

  IF lt_item IS NOT INITIAL.
    SELECT pspnr, posid FROM prps
      FOR ALL ENTRIES IN @lt_item
      WHERE pspnr = @lt_item-ps_psp_pnr
      INTO TABLE @lt_wbs.
  ENDIF.

  SELECT matnr, werks, steuc FROM marc
    FOR ALL ENTRIES IN @gt_out
    WHERE matnr = @gt_out-material
      AND werks = @gt_out-plant
    INTO TABLE @lt_marc.

  SELECT bukrs, waers FROM t001
    FOR ALL ENTRIES IN @gt_out
    WHERE bukrs = @gt_out-bukrs
    INTO TABLE @lt_company.

  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<out>).
    CLEAR: lv_bill, lv_ship.
    PERFORM find_document_partner
      USING lt_partner <out>-invoice_no <out>-item_no
            <out>-sales_order <out>-sales_item 'RE'
      CHANGING lv_bill.
    PERFORM find_document_partner
      USING lt_partner <out>-invoice_no <out>-item_no
            <out>-sales_order <out>-sales_item 'WE'
      CHANGING lv_ship.

    " Delivery header is a last fallback for Ship-to only.
    IF lv_ship IS INITIAL.
      READ TABLE lt_deliveries INTO ls_delivery
        WITH TABLE KEY vbeln = <out>-reference_doc.
      IF sy-subrc = 0.
        lv_ship = ls_delivery-kunnr.
      ENDIF.
    ENDIF.

    <out>-bill_to = lv_bill.
    <out>-ship_to = lv_ship.
    IF lv_bill IS NOT INITIAL.
      READ TABLE lt_customer INTO ls_customer
        WITH TABLE KEY kunnr = lv_bill.
      IF sy-subrc = 0.
        <out>-bill_name = ls_customer-name1.
        <out>-gstin = ls_customer-stcd3.
      ENDIF.
    ENDIF.
    IF lv_ship IS NOT INITIAL.
      READ TABLE lt_customer INTO ls_customer
        WITH TABLE KEY kunnr = lv_ship.
      IF sy-subrc = 0.
        <out>-ship_name = ls_customer-name1.
      ENDIF.
    ENDIF.

    IF <out>-sales_order IS NOT INITIAL.
      READ TABLE gt_sales INTO DATA(ls_so)
        WITH TABLE KEY vbeln = <out>-sales_order.
      IF sy-subrc = 0.
        <out>-order_date = ls_so-audat.
        <out>-so_bapi_status = 'SALES BAPI OK'.
      ELSE.
        <out>-so_bapi_status = 'SALES BAPI NO DATA'.
      ENDIF.

      READ TABLE gt_business INTO DATA(ls_business)
        WITH TABLE KEY vbeln = <out>-sales_order
                       posnr = <out>-sales_item.
      IF sy-subrc <> 0 OR ls_business-bstkd IS INITIAL.
        CLEAR ls_business.
        READ TABLE gt_business INTO ls_business
          WITH TABLE KEY vbeln = <out>-sales_order
                         posnr = '000000'.
      ENDIF.
      IF sy-subrc = 0.
        <out>-customer_po = ls_business-bstkd.
      ENDIF.
    ELSE.
      <out>-so_bapi_status = 'NO SALES ORDER'.
    ENDIF.

    READ TABLE lt_item INTO DATA(ls_item)
      WITH TABLE KEY vbeln = <out>-sales_order
                     posnr = <out>-sales_item.
    IF sy-subrc = 0 AND ls_item-ps_psp_pnr IS NOT INITIAL.
      READ TABLE lt_wbs INTO DATA(ls_wbs)
        WITH TABLE KEY pspnr = ls_item-ps_psp_pnr.
      IF sy-subrc = 0.
        <out>-wbs_no = ls_wbs-posid.
        <out>-wbs_internal = ls_item-ps_psp_pnr.
      ENDIF.
    ENDIF.

    READ TABLE lt_marc INTO DATA(ls_marc)
      WITH TABLE KEY matnr = <out>-material
                     werks = <out>-plant.
    IF sy-subrc = 0.
      <out>-hsn_sac = ls_marc-steuc.
    ENDIF.

    READ TABLE lt_company INTO DATA(ls_company)
      WITH TABLE KEY bukrs = <out>-bukrs.
    IF sy-subrc = 0.
      <out>-local_currency = ls_company-waers.
    ENDIF.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* Billing item > billing header > sales item > sales header.
* Never assume Sold-to is Bill-to or Ship-to.
*-----------------------------------------------------------------------
FORM find_document_partner
  USING it_partner TYPE ty_t_partner
        iv_bill TYPE vbrk-vbeln
        iv_bill_item TYPE vbrp-posnr
        iv_sales TYPE vbak-vbeln
        iv_sales_item TYPE vbap-posnr
        iv_function TYPE vbpa-parvw
  CHANGING cv_customer TYPE kunnr.
  DATA ls_partner TYPE ty_partner.
  CLEAR cv_customer.

  READ TABLE it_partner INTO ls_partner
    WITH KEY vbeln = iv_bill posnr = iv_bill_item
             parvw = iv_function BINARY SEARCH.
  IF sy-subrc <> 0.
    READ TABLE it_partner INTO ls_partner
      WITH KEY vbeln = iv_bill posnr = '000000'
               parvw = iv_function BINARY SEARCH.
  ENDIF.
  IF sy-subrc <> 0 AND iv_sales IS NOT INITIAL.
    READ TABLE it_partner INTO ls_partner
      WITH KEY vbeln = iv_sales posnr = iv_sales_item
               parvw = iv_function BINARY SEARCH.
  ENDIF.
  IF sy-subrc <> 0 AND iv_sales IS NOT INITIAL.
    READ TABLE it_partner INTO ls_partner
      WITH KEY vbeln = iv_sales posnr = '000000'
               parvw = iv_function BINARY SEARCH.
  ENDIF.
  IF sy-subrc = 0.
    cv_customer = ls_partner-kunnr.
  ENDIF.
ENDFORM.

*-----------------------------------------------------------------------
* 4. Bulk item GST. Include active statistical taxes if configured.
*    Confirm KINAK/KSTAT and conditions in VF03 and with SD/Tax.
*-----------------------------------------------------------------------
FORM collect_gst.
  DATA lt_conditions TYPE ty_t_cond_rng.
  APPEND VALUE #( sign = 'I' option = 'EQ' low = p_cgst )
         TO lt_conditions.
  APPEND VALUE #( sign = 'I' option = 'EQ' low = p_sgst )
         TO lt_conditions.
  APPEND VALUE #( sign = 'I' option = 'EQ' low = p_igst )
         TO lt_conditions.

  SELECT knumv, kposn, kschl, kwert, kinak
    FROM prcd_elements
    FOR ALL ENTRIES IN @gt_out
    WHERE knumv = @gt_out-knumv
      AND kposn = @gt_out-item_no
      AND kschl IN @lt_conditions
    INTO TABLE @DATA(lt_conditions_raw).

  LOOP AT lt_conditions_raw INTO DATA(ls_condition).
    " Exclude inactive conditions. Statistical tax condition treatment
    " depends on customer's pricing procedure; not excluded blindly.
    IF ls_condition-kinak IS NOT INITIAL.
      CONTINUE.
    ENDIF.

    READ TABLE gt_tax ASSIGNING FIELD-SYMBOL(<tax>)
      WITH TABLE KEY knumv = ls_condition-knumv
                     kposn = ls_condition-kposn.
    IF sy-subrc <> 0.
      INSERT VALUE ty_tax( knumv = ls_condition-knumv
                           kposn = ls_condition-kposn )
        INTO TABLE gt_tax ASSIGNING <tax>.
    ENDIF.

    CASE ls_condition-kschl.
      WHEN p_cgst.
        <tax>-cgst = <tax>-cgst + ls_condition-kwert.
      WHEN p_sgst.
        <tax>-sgst = <tax>-sgst + ls_condition-kwert.
      WHEN p_igst.
        <tax>-igst = <tax>-igst + ls_condition-kwert.
    ENDCASE.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* 5. Production order derivation: direct sales order + WBS fallback.
*    Multiple orders are listed; no arbitrary costing assignment.
*-----------------------------------------------------------------------
FORM collect_order_links.
  DATA lt_so_keys TYPE SORTED TABLE OF ty_so_key
                       WITH UNIQUE KEY kdauf kdpos.
  DATA lt_afpo_so TYPE STANDARD TABLE OF ty_so_order WITH EMPTY KEY.
  DATA lt_wbs_keys TYPE SORTED TABLE OF ty_wbs_key
                        WITH UNIQUE KEY projn matnr werks.
  DATA lv_formatted TYPE c LENGTH 12.

  "1. Strongest relationship: production-order sales-order assignment.
  "Only select populated sales order/item keys (no blank FAE terms).
  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<item>).
    IF <item>-sales_order IS NOT INITIAL
       AND <item>-sales_item IS NOT INITIAL.
      INSERT VALUE ty_so_key(
        kdauf = <item>-sales_order
        kdpos = <item>-sales_item ) INTO TABLE lt_so_keys.
    ENDIF.
  ENDLOOP.
  IF lt_so_keys IS NOT INITIAL.
    SELECT kdauf, kdpos, aufnr
      FROM afpo
      FOR ALL ENTRIES IN @lt_so_keys
      WHERE kdauf = @lt_so_keys-kdauf
        AND kdpos = @lt_so_keys-kdpos
      INTO CORRESPONDING FIELDS OF TABLE @lt_afpo_so.
  ENDIF.
  SORT lt_afpo_so BY kdauf kdpos aufnr.
  DELETE ADJACENT DUPLICATES FROM lt_afpo_so
    COMPARING kdauf kdpos aufnr.

  LOOP AT lt_afpo_so INTO DATA(ls_so).
    IF ls_so-kdauf IS INITIAL OR ls_so-aufnr IS INITIAL.
      CONTINUE.
    ENDIF.
    lv_formatted = |{ ls_so-aufnr ALPHA = OUT }|.
    READ TABLE gt_so_order ASSIGNING FIELD-SYMBOL(<so>)
      WITH TABLE KEY kdauf = ls_so-kdauf kdpos = ls_so-kdpos.
    IF sy-subrc <> 0.
      INSERT VALUE ty_so_order(
        kdauf = ls_so-kdauf kdpos = ls_so-kdpos
        aufnr = ls_so-aufnr order_text = lv_formatted )
        INTO TABLE gt_so_order.
    ELSEIF <so>-aufnr <> ls_so-aufnr.
      <so>-ambiguous = abap_true.
      CONCATENATE <so>-order_text lv_formatted
        INTO <so>-order_text SEPARATED BY ' / '.
    ENDIF.
  ENDLOOP.

  "2. Project-order candidate from WBS + SAME material + SAME plant.
  "A WBS relationship alone is NOT proof that production supplied the
  "invoiced stock. No match means leave Production Order/CO03 blank.
  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<bill>).
    IF <bill>-wbs_internal IS NOT INITIAL
       AND <bill>-material IS NOT INITIAL
       AND <bill>-plant IS NOT INITIAL.
      INSERT VALUE ty_wbs_key(
        projn = <bill>-wbs_internal
        matnr = <bill>-material
        werks = <bill>-plant ) INTO TABLE lt_wbs_keys.
    ENDIF.
  ENDLOOP.

  IF lt_wbs_keys IS INITIAL.
    RETURN.
  ENDIF.

  SELECT projn, matnr, dwerk, aufnr
    FROM afpo
    FOR ALL ENTRIES IN @lt_wbs_keys
    WHERE projn = @lt_wbs_keys-projn
      AND matnr = @lt_wbs_keys-matnr
      AND dwerk = @lt_wbs_keys-werks
    INTO TABLE @DATA(lt_afpo_wbs).
  SORT lt_afpo_wbs BY projn matnr dwerk aufnr.
  DELETE ADJACENT DUPLICATES FROM lt_afpo_wbs
    COMPARING projn matnr dwerk aufnr.

  LOOP AT lt_afpo_wbs INTO DATA(ls_wbs).
    IF ls_wbs-projn IS INITIAL OR ls_wbs-aufnr IS INITIAL.
      CONTINUE.
    ENDIF.
    lv_formatted = |{ ls_wbs-aufnr ALPHA = OUT }|.
    READ TABLE gt_wbs_order ASSIGNING FIELD-SYMBOL(<wbs>)
      WITH TABLE KEY projn = ls_wbs-projn
                     matnr = ls_wbs-matnr
                     werks = ls_wbs-dwerk.
    IF sy-subrc <> 0.
      INSERT VALUE ty_wbs_order(
        projn = ls_wbs-projn matnr = ls_wbs-matnr
        werks = ls_wbs-dwerk aufnr = ls_wbs-aufnr
        order_text = lv_formatted ) INTO TABLE gt_wbs_order.
    ELSEIF <wbs>-aufnr <> ls_wbs-aufnr.
      <wbs>-ambiguous = abap_true.
      CONCATENATE <wbs>-order_text lv_formatted
        INTO <wbs>-order_text SEPARATED BY ' / '.
    ENDIF.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* Determine link once, keeping all candidates visible but never selecting
* an arbitrary order if several exist for the same invoice item.
*-----------------------------------------------------------------------
FORM assign_order_links.
  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<bill>).
    CLEAR: <bill>-production_order, <bill>-primary_order,
           <bill>-link_status.

    READ TABLE gt_so_order INTO DATA(ls_so)
      WITH TABLE KEY kdauf = <bill>-sales_order
                     kdpos = <bill>-sales_item.
    IF sy-subrc = 0.
      <bill>-production_order = ls_so-order_text.
      IF ls_so-ambiguous = abap_true.
        <bill>-link_status = 'MULTIPLE DIRECT ORDERS'.
      ELSE.
        <bill>-primary_order = ls_so-aufnr.
        <bill>-link_status = 'DIRECT MTO'.
      ENDIF.
      CONTINUE.
    ENDIF.

    IF <bill>-wbs_internal IS NOT INITIAL.
      READ TABLE gt_wbs_order INTO DATA(ls_wbs)
        WITH TABLE KEY projn = <bill>-wbs_internal
                       matnr = <bill>-material
                       werks = <bill>-plant.
      IF sy-subrc = 0.
        <bill>-production_order = ls_wbs-order_text.
        IF ls_wbs-ambiguous = abap_true.
          <bill>-link_status = 'MULTIPLE WBS ORDERS'.
        ELSE.
          <bill>-primary_order = ls_wbs-aufnr.
          <bill>-link_status = 'WBS MAT/PLANT CANDIDATE'.
        ENDIF.
        CONTINUE.
      ENDIF.
    ENDIF.
    <bill>-link_status = 'NO LINKED PROD ORDER'.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* 6. Cost selection by batches and cost element with DB aggregation.
*    Material vs OH classification is selection-screen configurable.
*    Amounts are in ACDOCA-HSL company-code currency, ledger-specific.
*    HSL amounts are only summed in the PP order company code.
*    This is NOT guaranteed equivalent to the configured CO03 layout.
*-----------------------------------------------------------------------
FORM collect_costs.
  DATA lt_unique TYPE SORTED TABLE OF aufnr WITH UNIQUE KEY table_line.
  DATA lt_range TYPE ty_t_order_rng.

  " Do not query all G/Ls when the ranges are empty.
  " Allow billing/BAPI testing before CO mappings are ready.
  IF s_matgl[] IS INITIAL OR s_ovhgl[] IS INITIAL.
    RETURN.
  ENDIF.

  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<bill>).
    IF <bill>-primary_order IS NOT INITIAL.
      INSERT <bill>-primary_order INTO TABLE lt_unique.
    ENDIF.
  ENDLOOP.

  LOOP AT lt_unique INTO DATA(lv_order).
    APPEND VALUE #( sign = 'I' option = 'EQ' low = lv_order )
      TO lt_range.
    IF lines( lt_range ) >= gc_cost_pack.
      PERFORM read_cost_package USING lt_range.
      CLEAR lt_range.
    ENDIF.
  ENDLOOP.

  IF lt_range IS NOT INITIAL.
    PERFORM read_cost_package USING lt_range.
  ENDIF.
ENDFORM.

FORM read_cost_package USING it_range TYPE ty_t_order_rng.
  SELECT a~aufnr, a~racct, c~waers, SUM( a~hsl ) AS amount
    FROM acdoca AS a
    INNER JOIN aufk AS o ON o~aufnr = a~aufnr
    INNER JOIN t001 AS c ON c~bukrs = o~bukrs
    WHERE a~aufnr IN @it_range
      AND a~rbukrs = o~bukrs
      AND a~rldnr = @p_ledger
      AND a~budat <= @p_cdate
      AND ( a~racct IN @s_matgl OR a~racct IN @s_ovhgl )
    GROUP BY a~aufnr, a~racct, c~waers
    INTO TABLE @DATA(lt_amounts).

  LOOP AT lt_amounts INTO DATA(ls_amount).
    READ TABLE gt_cost ASSIGNING FIELD-SYMBOL(<cost>)
      WITH TABLE KEY aufnr = ls_amount-aufnr.
    IF sy-subrc <> 0.
      INSERT VALUE ty_cost( aufnr = ls_amount-aufnr
                            waers = ls_amount-waers )
        INTO TABLE gt_cost ASSIGNING <cost>.
    ENDIF.
    " If G/L ranges overlap, classify in material first;
    " overlapping ranges must be corrected before UAT.
    IF ls_amount-racct IN s_matgl.
      <cost>-material = <cost>-material + ls_amount-amount.
    ELSEIF ls_amount-racct IN s_ovhgl.
      <cost>-overhead = <cost>-overhead + ls_amount-amount.
    ENDIF.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* Production-order BAPI: one call per distinct order; header is cached.
* Does not expose CO03 actual-cost category totals.
*-----------------------------------------------------------------------
FORM read_production_bapis.
  DATA lt_unique TYPE SORTED TABLE OF aufnr WITH UNIQUE KEY table_line.
  DATA ls_objects TYPE bapi_pp_order_objects.
  DATA ls_return TYPE bapiret2.
  DATA lt_header TYPE STANDARD TABLE OF bapi_order_header1
                 WITH EMPTY KEY.
  DATA ls_check TYPE ty_bapi_check.

  ls_objects-header = abap_true.

  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<bill>).
    IF <bill>-primary_order IS NOT INITIAL.
      INSERT <bill>-primary_order INTO TABLE lt_unique.
    ENDIF.
  ENDLOOP.

  LOOP AT lt_unique INTO DATA(lv_order).
    CLEAR: ls_return, lt_header, ls_check.
    ls_check-aufnr = lv_order.

    CALL FUNCTION 'BAPI_PRODORD_GET_DETAIL'
      EXPORTING
        number        = lv_order
        order_objects = ls_objects
      IMPORTING
        return        = ls_return
      TABLES
        header        = lt_header.

    IF sy-subrc <> 0 OR ls_return-type = 'E'
       OR ls_return-type = 'A' OR lt_header IS INITIAL.
      ls_check-error = abap_true.
    ELSE.
      READ TABLE lt_header INTO DATA(ls_header) INDEX 1.
      IF sy-subrc = 0.
        ls_check-material = ls_header-material.
        ls_check-plant    = ls_header-production_plant.
      ENDIF.
    ENDIF.

    INSERT ls_check INTO TABLE gt_check.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* 7. Assemble output in memory; no SELECT inside loop.
*-----------------------------------------------------------------------
FORM finalize_output.
  DATA lv_sno TYPE i.
  DATA lv_rate TYPE tcurr-ukurs.
  DATA lv_read_tcurr TYPE c LENGTH 1.
  DATA lv_local TYPE p LENGTH 16 DECIMALS 2.

  SORT gt_out BY invoice_no item_no.

  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<out>).
    lv_sno = lv_sno + 1.
    <out>-sno = lv_sno.
    <out>-month_text =
      |{ <out>-invoice_date(4) }-{ <out>-invoice_date+4(2) }|.

    IF <out>-quantity IS NOT INITIAL.
      <out>-unit_rate_fc = <out>-taxable_fc / <out>-quantity.
    ENDIF.

    READ TABLE gt_tax INTO DATA(ls_tax)
      WITH TABLE KEY knumv = <out>-knumv kposn = <out>-item_no.
    IF sy-subrc = 0.
      <out>-cgst = ls_tax-cgst.
      <out>-sgst = ls_tax-sgst.
      <out>-igst = ls_tax-igst.
    ENDIF.

    "Production order was determined before the BAPI and cost bulk reads.
    "When several orders match, display them but do not allocate costs.
    IF <out>-primary_order IS NOT INITIAL.
      READ TABLE gt_cost INTO DATA(ls_cost)
        WITH TABLE KEY aufnr = <out>-primary_order.
      IF sy-subrc = 0.
        <out>-material_cost = ls_cost-material.
        <out>-overhead = ls_cost-overhead.
        <out>-total_cost = ls_cost-material + ls_cost-overhead.
        <out>-cost_currency = ls_cost-waers.
        IF <out>-link_status = 'WBS MAT/PLANT CANDIDATE'.
          <out>-cost_status = 'WBS COST - VERIFY ORIGIN'.
        ELSE.
          <out>-cost_status = 'COST GL SUM - VERIFY'.
        ENDIF.
      ELSE.
        IF s_matgl[] IS INITIAL OR s_ovhgl[] IS INITIAL.
          <out>-cost_status = 'COST GL NOT SET'.
        ELSE.
          <out>-cost_status = 'NO MATCHED COST POSTING'.
        ENDIF.
      ENDIF.
      READ TABLE gt_check INTO DATA(ls_check)
        WITH TABLE KEY aufnr = <out>-primary_order.
      IF sy-subrc <> 0 OR ls_check-error = abap_true.
        <out>-prod_bapi_status = 'PROD BAPI NO DATA'.
      ELSE.
        <out>-prod_material = ls_check-material.
        <out>-prod_plant    = ls_check-plant.
        <out>-prod_bapi_status = 'PROD BAPI OK'.
      ENDIF.
    ELSE.
      <out>-cost_status = 'NO ORDER DETERMINED'.
      <out>-prod_bapi_status = 'NO SINGLE ORDER LINK'.
    ENDIF.

    " Document currency vs company-code currency. Use the SAP currency
    " FM, preserving VBRK-KURRF when supplied. For accounting-exact
    " conversion, reconcile with FI posted document and its rates.
    IF <out>-local_currency IS INITIAL.
      <out>-conv_status = 'NO LOCAL CURRENCY'.
    ELSEIF <out>-currency = <out>-local_currency.
      <out>-taxable_lc = <out>-taxable_fc.
      <out>-conv_status = 'SAME CURRENCY'.
    ELSE.
      CLEAR: lv_local, lv_rate, lv_read_tcurr.
      IF <out>-exchange_rate IS NOT INITIAL.
        lv_rate = <out>-exchange_rate.
        lv_read_tcurr = space.
      ELSE.
        lv_read_tcurr = 'X'.
      ENDIF.

      CALL FUNCTION 'CONVERT_TO_LOCAL_CURRENCY'
        EXPORTING
          date             = <out>-invoice_date
          foreign_amount   = <out>-taxable_fc
          foreign_currency = <out>-currency
          local_currency   = <out>-local_currency
          rate             = lv_rate
          type_of_rate     = 'M'
          read_tcurr       = lv_read_tcurr
        IMPORTING
          local_amount     = lv_local
        EXCEPTIONS
          no_rate_found    = 1
          overflow         = 2
          no_factors_found = 3
          no_spread_found  = 4
          derived_2_times = 5
          OTHERS          = 6.
      IF sy-subrc = 0.
        <out>-taxable_lc = lv_local.
        <out>-conv_status = 'CONVERTED'.
      ELSE.
        CLEAR <out>-taxable_lc.
        <out>-conv_status = 'CONVERSION ERROR'.
      ENDIF.
    ENDIF.
  ENDLOOP.
ENDFORM.

*-----------------------------------------------------------------------
* 8. Existing SALV display. Do not sum order-level cost over invoices.
*-----------------------------------------------------------------------
*------------------------------------------------------------------------
* 8. Business ALV: exact 31-column template, no technical status fields.
*------------------------------------------------------------------------
FORM build_business_alv.
  CLEAR gt_alv.
  LOOP AT gt_out INTO DATA(ls_out).
    DATA ls_alv TYPE ty_alv.
    CLEAR ls_alv.
    MOVE-CORRESPONDING ls_out TO ls_alv.

    " Only use XBLNR when the user explicitly chooses to test it.
    " Never assume it is the official GST/commercial invoice number.
    IF p_refno = abap_true AND ls_out-invoice_ref IS NOT INITIAL.
      ls_alv-invoice_no = ls_out-invoice_ref.
    ELSE.
      ls_alv-invoice_no = |{ ls_out-invoice_no ALPHA = OUT }|.
    ENDIF.
    APPEND ls_alv TO gt_alv.
  ENDLOOP.
ENDFORM.

FORM display_report.
  PERFORM build_business_alv.
  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = DATA(lo_alv)
        CHANGING  t_table      = gt_alv ).
      lo_alv->get_functions( )->set_all( abap_true ).
      lo_alv->get_columns( )->set_optimize( abap_true ).
      lo_alv->get_display_settings( )->set_list_header(
        'Sales Invoice and Production Cost Report' ).

      " Long texts are business headings; medium and short are compact
      " alternatives for SAP GUI column display. Field order is TY_ALV.
      TYPES: BEGIN OF ty_heading,
               field  TYPE lvc_fname,
               long   TYPE scrtext_l,
               medium TYPE scrtext_m,
               short  TYPE scrtext_s,
             END OF ty_heading.
      DATA lt_headings TYPE STANDARD TABLE OF ty_heading
                       WITH EMPTY KEY.
      lt_headings = VALUE #(
        ( field = 'SNO'              long = 'S.No.'                     medium = 'S.No.'           short = 'S.No.' )
        ( field = 'MONTH_TEXT'       long = 'Month'                     medium = 'Month'           short = 'Month' )
        ( field = 'INVOICE_NO'       long = 'Invoice No'                medium = 'Invoice No'      short = 'Invoice' )
        ( field = 'INVOICE_DATE'     long = 'Invoice Date'              medium = 'Invoice Date'    short = 'Inv. Date' )
        ( field = 'BILL_TO'          long = 'Customer code (Bill to)'   medium = 'Bill-to code'    short = 'Bill-to' )
        ( field = 'SHIP_TO'          long = 'Customer code (Ship to)'   medium = 'Ship-to code'    short = 'Ship-to' )
        ( field = 'BILL_NAME'        long = 'Customer Name (Bill to)'   medium = 'Bill-to Name'    short = 'Bill Name' )
        ( field = 'SHIP_NAME'        long = 'Customer Name (Ship to)'   medium = 'Ship-to Name'    short = 'Ship Name' )
        ( field = 'GSTIN'            long = 'Customer GSTIN'            medium = 'Customer GSTIN'  short = 'GSTIN' )
        ( field = 'CUSTOMER_PO'      long = 'Reference (Customer PO No.)'   medium = 'Customer PO'     short = 'PO Ref.' )
        ( field = 'SALES_ORDER'      long = 'Sale order No'             medium = 'Sales Order'     short = 'Sales Ord' )
        ( field = 'ORDER_DATE'       long = 'Sale Order Date'           medium = 'SO Date'         short = 'SO Date' )
        ( field = 'HSN_SAC'          long = 'HSN/SAC'                   medium = 'HSN/SAC'         short = 'HSN/SAC' )
        ( field = 'ITEM_NO'          long = 'Item No'                   medium = 'Item No'         short = 'Item' )
        ( field = 'MATERIAL'         long = 'Material Code'             medium = 'Material Code'   short = 'Material' )
        ( field = 'DESCRIPTION'      long = 'Description of Goods'     medium = 'Description'     short = 'Description' )
        ( field = 'QUANTITY'         long = 'Qty'                       medium = 'Qty'             short = 'Qty' )
        ( field = 'UNIT_RATE_FC'     long = 'Unit Rate in FC'           medium = 'Unit Rate FC'    short = 'Rate FC' )
        ( field = 'TAXABLE_FC'       long = 'Taxable Value in FC'       medium = 'Taxable FC'      short = 'Taxable FC' )
        ( field = 'CURRENCY'         long = 'Currency'                  medium = 'Currency'        short = 'Currency' )
        ( field = 'EXCHANGE_RATE'    long = 'Ex Rate'                   medium = 'Ex Rate'         short = 'Ex Rate' )
        ( field = 'TAXABLE_LC'       long = 'Taxable Value in LC'       medium = 'Taxable LC'      short = 'Taxable LC' )
        ( field = 'CGST'             long = 'CGST'                      medium = 'CGST'            short = 'CGST' )
        ( field = 'SGST'             long = 'SGST'                      medium = 'SGST'            short = 'SGST' )
        ( field = 'IGST'             long = 'IGST'                      medium = 'IGST'            short = 'IGST' )
        ( field = 'ACCOUNTING_DOC'   long = 'Accounting Doc.No.'        medium = 'Accounting Doc'  short = 'Acct Doc' )
        ( field = 'MATERIAL_COST'    long = 'CO03 MATERIAL ACTUAL COST' medium = 'CO03 Material'   short = 'Mat Cost' )
        ( field = 'OVERHEAD'         long = 'CO03 OVERHEAD'             medium = 'CO03 Overhead'   short = 'Overhead' )
        ( field = 'TOTAL_COST'       long = 'Total CO03'               medium = 'Total CO03'      short = 'Total Cost' )
        ( field = 'PRODUCTION_ORDER' long = 'Production Order No'      medium = 'Production Ord'  short = 'Prod.Order' )
        ( field = 'WBS_NO'           long = 'WBS No'                    medium = 'WBS No'          short = 'WBS' ) ).

      LOOP AT lt_headings INTO DATA(ls_heading).
        TRY.
            DATA(lo_col) = lo_alv->get_columns( )->get_column(
              ls_heading-field ).
            lo_col->set_long_text( ls_heading-long ).
            lo_col->set_medium_text( ls_heading-medium ).
            lo_col->set_short_text( ls_heading-short ).
          CATCH cx_salv_not_found.
        ENDTRY.
      ENDLOOP.

      "No attributable PP order / no matching cost posting: show blank
      "instead of a misleading 0.00 in the three CO03 ALV columns.
      TRY.
          lo_alv->get_columns( )->get_column( 'MATERIAL_COST'
            )->set_zero( abap_false ).
          lo_alv->get_columns( )->get_column( 'OVERHEAD'
            )->set_zero( abap_false ).
          lo_alv->get_columns( )->get_column( 'TOTAL_COST'
            )->set_zero( abap_false ).
        CATCH cx_salv_not_found.
      ENDTRY.

      lo_alv->display( ).
    CATCH cx_salv_msg INTO DATA(lx_salv).
      MESSAGE lx_salv->get_text( ) TYPE 'I'.
  ENDTRY.
ENDFORM.
