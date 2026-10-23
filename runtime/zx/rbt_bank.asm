; ============================================================================
; rbt_bank_asm - 128K memory paging
;
; Banked assets load into the 0xC000 window of banks 0,1,3,4,6,7
; (banks 5/2 stay resident at 0x4000/0x8000). port #7FFD:
;   bits 0-2 = RAM page at C000, bit 3 = shadow screen (unused),
;   bit 4 = ROM (0 = 128K editor, kept), bit 5 = paging lock (never set).
;
; rbt_bank     - A = bank to page in (0-7); updates rbt_cur_bank
; rbt_copybank - copy a banked asset into resident RAM:
;                A = bank, HL = src (0xC000 window), DE = dst, BC = len
;                pages the bank in, LDIRs, restores the previous bank
; ============================================================================

rbt_bank:
        push    bc
        and     7
        or      RBT_BANKROM     ; keep the right ROM paged (bit 4):
                                ; #10 on 128K (48K ROM), #00 on +3
                                ; (editor ROM0 carries the DOS jump
                                ; block; ROM1 is the syntax half)
        if      RBT_BANKM
        ld      (RBT_BANKM),a   ; +3: the ROM restores paging from this
                                ; sysvar — keep it truthful or an IM1
                                ; handler could unpick our bank mid-read
        endif
        ld      (rbt_cur_bank),a
        ld      bc,#7ffd
        out     (c),a
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

rbt_cur_bank    db 0

; ----------------------------------------------------------------------------
; rbt_pg_in / rbt_pg_out - nestable page guard for banked data access.
;
; pg_in:  A = bank byte (#FF = resident, nothing to page), HL -> save byte.
;         Stores the current bank in (HL) and pages the given bank in.
;         Preserves all registers.
; pg_out: HL -> the same save byte. Pages the saved bank back.
;         Preserves all registers (including A).
;
; Guards nest correctly as long as each call site uses its own save byte.
; On 48K builds (no bank module) the compiler emits ret stubs; bank bytes
; are always #FF there so pg_in would early-out anyway.
; ----------------------------------------------------------------------------
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
