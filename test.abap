  METHOD process_newpolicy.
**-----------------------------------------------------------------------------------------*
** Created by: AA451018 , Martin Slooter
** Date of creation: 04.01.2022
**-----------------------------------------------------------------------------------------*
** Description:
**
**
**-----------------------------------------------------------------------------------------*
** Change history:
**-----------------------------------------------------------------------------------------*
** <user_id>, <Full name>                                             date: <dd.mm.yyyy>
** Change Reason: <Defect-ID / OSS / ...>
** Description:
**
**
**-----------------------------------------------------------------------------------------*
    DATA lr_zrgp_task_utils  TYPE REF TO /achcr/cl_zrgp_task_utils.
    DATA lv_zrgp_task_status TYPE string.
    DATA lr_zrgp_linkedpol   TYPE REF TO /achcr/cl_zrgp_linkedpol.
    DATA mr_crm_task_order   TYPE REF TO /achcr/if_crm_order.
    DATA lv_task_guid        TYPE crmt_object_guid.

    lr_zrgp_task_utils = NEW /achcr/cl_zrgp_task_utils( ir_crm_order = mr_crm_order
                                                        lt_zrgp_params = mt_zrgp_params ).

    "Get the GUID of the active task if available for the business partner (ZZPOL_HO/ZZORGPLI)
    TRY.
        lv_task_guid = is_active_task( ).
      CATCH /achcr/cx_dma_exception INTO DATA(lr_dma_exception).
        "Fill the logging
        RAISE EXCEPTION TYPE /achcr/cx_dma_exception.
    ENDTRY.
    "Only read task order object if active task is found, else a new task should be created
    IF lv_task_guid IS NOT INITIAL.
      mr_crm_task_order = NEW /achcr/cl_crm_order( ).
      mr_crm_task_order->read_order( iv_guid      = lv_task_guid
                                     iv_read_mode = /achcr/if_dma_constants=>gc_read_order_full ).

      mr_crm_task_order->get_current_order_status( IMPORTING ev_user_status = DATA(lv_user_status) ).

      "Determine ACTIVE or INACTIVE Zorgplichttask: E0001/E0002/E0008 -> Active zorgplichttaak; "E0007/E0003 -> Inactive zorgplichttaak
      IF lv_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_open OR lv_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_paused.
        lv_zrgp_task_status = 'ACTIVE'.
      ELSEIF lv_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_in_process.
        lv_zrgp_task_status = 'ACTIVENEW'.
      ELSEIF lv_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_finished OR lv_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_canceled.
        lv_zrgp_task_status = 'INACTIVE'.
      ENDIF.
    ELSE.
      lv_zrgp_task_status = 'NEW'.
    ENDIF.

    "Get the data from the zorgplicht assignment block (/ACHCR/ZRGP_POL).
    lr_zrgp_linkedpol = NEW /achcr/cl_zrgp_linkedpol( ).
    mt_zrgp_pol = lr_zrgp_linkedpol->get_data( lv_zrgp_task_guid = lv_task_guid ).

    "Determine zorgplicht date
    DATA(lv_zrgp_date) = determine_zrgp_date( ).
    DATA(lv_zrgp_date_ts) = convert_date_to_timestamp( iv_date = lv_zrgp_date ).

    "Determine zorgplicht task close date
    DATA(lv_zrgp_close_date) = determine_zrgp_close_date( iv_zrgp_date = lv_zrgp_date ).
    DATA(lv_zrgp_close_date_ts) = convert_date_to_timestamp( iv_date = lv_zrgp_close_date ).

    IF line_exists( mt_zrgp_params[ zrgp_param = 'ZRGP_LATEST' ] ).
      DATA(lv_zrgp_latest) = mt_zrgp_params[ zrgp_param = 'ZRGP_LATEST' ]-zrgp_param_value.
    ENDIF.

    CASE lv_zrgp_task_status.
      WHEN 'NEW'.
        "No zorgplicht task should be created, because zorgplicht date is later than zorgplicht latest
        IF lv_zrgp_date > lv_zrgp_latest.
          INSERT VALUE #( type   = 'E'
                      id     = '/ACHCR/ZORGPLICHT'
                      number = '011'
                      message_v1 = 'zrgp_date > zrgp_latest' ) INTO TABLE mt_zrgp_log.
          RETURN.
        ELSE.
          "Create new task
          DATA(ls_created_task) = lr_zrgp_task_utils->create_task( iv_zrgp_date_ts       = lv_zrgp_date_ts
                                                                   iv_zrgp_close_date_ts = lv_zrgp_close_date_ts ).
          lv_task_guid = ls_created_task-guid.
          IF lv_task_guid IS NOT INITIAL.
            add_ref_to_linkedpol( lv_task_guid = lv_task_guid ).
          ENDIF.
        ENDIF.
      WHEN 'ACTIVE'.
        "Add reference to new policy in /ACHCR/ZRGP_POL
        add_ref_to_linkedpol( lv_task_guid = lv_task_guid ).

        "==============================
        "If active task is paused: resume task
        IF lv_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_paused OR lv_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_open.
          lr_zrgp_task_utils->update_task( EXPORTING iv_task_guid       = lv_task_guid
                                                     iv_zrgp_date       = lv_zrgp_date_ts
                                                     iv_new_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_open ).

        ENDIF.
      WHEN 'ACTIVENEW'.
        "Add reference to new policy in /ACHCR/ZRGP_POL with linkstat=NEW
        add_ref_to_linkedpol( lv_task_guid    = lv_task_guid
                              iv_new_linkstat = abap_true ).

        "Update task with new zrgp_date
        lr_zrgp_task_utils->update_task( EXPORTING iv_task_guid       = lv_task_guid
                                                   iv_zrgp_date       = lv_zrgp_date_ts
                                                   iv_new_user_status = /achcr/if_zrgp_constants=>gc_zrgp_task_status_in_process ).
      WHEN OTHERS.
        "Do nothing
    ENDCASE.

    "Run LAST_ZRGP_DATE always at the end of the process
    IF lv_task_guid IS NOT INITIAL AND lv_zrgp_latest IS NOT INITIAL.
      process_last_zrgp_date( iv_task_guid = lv_task_guid ).
    ENDIF.

  ENDMETHOD.