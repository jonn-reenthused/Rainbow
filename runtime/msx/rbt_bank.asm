; ============================================================================
; rbt_bank - ASCII16 megaROM paging. Bank 0 is resident at #4000-#7FFF
; (bootstrap + code + resident assets); banked assets live in banks 1+
; and page into that window by writing the bank number to the #6000
; mapper register (a memory write, not a port out). The program runs
; from RAM at #8000, so paging the window mid-execution never touches
; running code.
;
; rbt_bank     - A = bank to page into the #4000 window; tracks rbt_cur_bank
; rbt_copybank - A = bank, HL = src (#4000 window), DE = dst, BC = len:
;                pages the bank in, LDIRs, restores the previous bank
; rbt_pg_in/out - nestable page guard (same contract as the zx version)
; ============================================================================

rbt_bank:
        push    bc
        ld      (rbt_cur_bank),a
        ld      (#6000),a       ; ASCII16 page-1 bank register
        pop     bc
        ret

rbt_copybank:
        ex      af,af'                  ; save requested bank
        ld      a,(rbt_cur_bank)
        ex      af,af'                  ; a = new bank, af' = previous
        call    rbt_bank
        ldir                            ; hl -> de, bc bytes
        ex      af,af'
        jp      rbt_bank                ; restore previous bank

rbt_pg_in:
        push    af
        ld      a,(rbt_cur_bank)
        ld      (hl),a          ; save previous bank
        pop     af
        inc     a
        ret     z               ; #FF = resident: nothing to page
        dec     a
        jp      rbt_bank

rbt_pg_out:
        push    af
        ld      a,(hl)
        call    rbt_bank
        pop     af
        ret

rbt_cur_bank    db 0
