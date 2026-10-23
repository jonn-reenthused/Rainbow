; ============================================================================
; rbt_bank_asm - 6128 memory paging + disc bank loader (Amstrad CPC)
;
; The 6128's second 64K is four 16K pages (physical banks 4-7) mapped by
; the gate array MMR into the #4000-#7FFF window. Resident code lives at
; #8000 (physical bank 2) and the screen stays at #C000 (bank 3) so
; banked assets can page through #4000 without evicting either.
;
; MMR writes go to port #7Fxx (bits 7:6 = 11 -> MMR function):
;   #C0   = normal linear mapping (banks 0,1,2,3)
;   #C4+n = physical bank 4+n at #4000-#7FFF
; A 464 ignores these writes (no secondary RAM), but the module is only
; linked on cpc6128 builds anyway. The MMR is user domain: no firmware
; routine writes it, so a bank stays paged across interrupts and firmware
; calls (only the RMR rom enables get far-called).
;
; rbt_bank     - A = physical bank (4-7) to page in, or an MMR byte >= #C0
;                written raw (the restore path passes shadow bytes through).
;                rbt_cur_bank holds the last byte written.
; rbt_copybank - copy a banked asset into resident RAM:
;                A = bank, HL = src (#4000 window), DE = dst, BC = len
;                pages the bank in, LDIRs, restores the previous mapping
;                (dst must be outside #4000-#7FFF)
; rbt_pg_in    - A = bank byte (#FF = resident), HL -> save byte. Pages in.
; rbt_pg_out   - HL -> save byte. Restores the saved mapping.
; rbt_bankload - loads BANK<n>.BIN into each bank named in rbt_bankfiles
;                (emitted by the compiler). Called once from rbt_start.
; ============================================================================

FW_CAS_IN_OPEN  equ #bc77       ; HL = filename, B = len, DE = 2k work buffer
FW_CAS_IN_CLOSE equ #bc7a
FW_CAS_IN_DIR   equ #bc83       ; HL = load address
FW_KL_INIT_BACK equ #bcce       ; C = rom select, DE/HL = memory pool bounds

rbt_bank:
        push    bc
        cp      #c0
        jr      nc,_wr                  ; already an MMR byte
        or      #c0                     ; bank 4-7 -> config #c4-#c7
_wr     ld      (rbt_cur_bank),a
        ld      bc,#7f00
        out     (c),a                   ; MMR: ram bank at #4000
        pop     bc
        ret

rbt_copybank:
        di                              ; the firmware ISR owns the alt
        push    af                      ; registers AND rewrites the MMR
        ld      a,(rbt_cur_bank)        ; via a stale shadow value, so a
        ld      (rbt_cb_prev),a         ; bank must stay paged across the
        pop     af                      ; whole transfer atomically
        call    rbt_bank
        ldir                            ; hl -> de, bc bytes
        ld      a,(rbt_cb_prev)
        call    rbt_bank                ; restore previous mapping
        ei
        ret

rbt_cur_bank    db #c0                  ; last MMR byte written (#c0 = normal)
rbt_cb_prev     db 0                    ; copybank mapping save byte

; ----------------------------------------------------------------------------
; rbt_bankload - pull each banked-asset blob off disc into its RAM bank.
; rbt_bankfiles is emitted by the compiler: defb bank, defm "BANKn.BIN"
; records terminated by defb #ff. Files are AMSDOS binaries written by
; the .dsk packager.
;
; MC_START_PROGRAM (the firmware call that execs a RUN'd binary) shuts
; down all expansion ROMs, so AMSDOS's hook on the cassette vectors is
; gone and CAS_IN_OPEN would prompt for tape. KL_INIT_BACK on rom 7
; reinstalls it first. The memory pool is capped at #3fff so AMSDOS's
; work area can't sit under the #4000-#7fff bank window.
;
; Each file is loaded directly into its bank: the MMR pages the bank at
; #4000 before CAS IN DIRECT - the PAL is user domain so the firmware
; leaves the mapping alone - then #c0 restores the base 64k. The 2k
; cassette work buffer sits at #2000, outside the window. A missing
; file just skips its bank.
;
; Cart builds (RBT_CART) can't open files at all - each bank blob is a
; 16K cart page instead (page 0 is this resident code, blobs take pages
; 1..n in bank order). The compiler emits rbt_cartfiles: defb bank,
; defb page, defw size records, #FF-terminated. Selecting a page via
; the ROM-select port (id >= #80 -> cart block) plus RMR upper-rom-on
; makes it readable at #C000 while the RAM bank is paged at #4000, so
; the copy is a plain LDIR - no trampoline needed since the code page
; stays mapped at #0000. Screen RAM at #C000 is write-through under the
; ROM so the display is unaffected.
; ----------------------------------------------------------------------------
        if      RBT_CART
rbt_bankload:
        ld      hl,rbt_cartfiles
_cfl    ld      a,(hl)          ; bank id, #FF = end of table
        cp      #ff
        jr      z,_cfd
        inc     hl
        call    rbt_bank        ; page the RAM bank at #4000
        ld      a,(hl)          ; cart page -> upper ROM window
        inc     hl
        or      #80
        ld      bc,#df00
        out     (c),a
        ld      a,(rbt_rmr)     ; UR=0: cart page readable at #C000
        and     #f7
        ld      bc,#7f00
        out     (c),a
        ld      e,(hl)          ; DE = blob size (always <= #4000)
        inc     hl
        ld      d,(hl)
        inc     hl
        push    hl
        ld      b,d
        ld      c,e
        ld      hl,#c000
        ld      de,#4000
        ldir                    ; cart page -> RAM bank
        ld      a,(rbt_rmr)     ; UR=1: upper ROM back off
        or      #08
        ld      bc,#7f00
        out     (c),a
        pop     hl
        jr      _cfl
_cfd    ld      a,#c0
        jp      rbt_bank        ; restore normal mapping (ret)
        else
rbt_bankload:
        ld      de,#0040                ; first usable byte of memory
        ld      hl,#3fff                ; pool top: below the bank window
        ld      c,7                     ; AMSDOS rom select
        call    FW_KL_INIT_BACK
        ld      hl,rbt_bankfiles
_bfl    ld      a,(hl)                  ; bank id, #FF = end of table
        cp      #ff
        jr      z,_bfd
        push    hl                      ; record start
        inc     hl
        ld      b,9                     ; "BANKn.BIN"
        ld      de,#2000                ; work buffer outside the window
        call    FW_CAS_IN_OPEN
        pop     hl                      ; record start
        jr      nc,_bfn                 ; open failed -> next record
        push    hl
        ld      a,(hl)                  ; bank id
        call    rbt_bank                ; page it at #4000
        ld      hl,#4000
        call    FW_CAS_IN_DIR           ; data lands in the bank directly
        ld      a,#c0
        call    rbt_bank                ; normal mapping
        call    FW_CAS_IN_CLOSE
        pop     hl
_bfn    inc     hl                      ; past bank byte
        ld      de,9                    ; past filename -> next record
        add     hl,de
        jr      _bfl
_bfd    ld      a,#c0
        jp      rbt_bank                ; restore normal mapping (ret)
        endif

; ----------------------------------------------------------------------------
; rbt_pg_in / rbt_pg_out - nestable page guard for banked data access.
;
; pg_in:  A = bank byte (#FF = resident, nothing to page), HL -> save byte.
;         Stores the current MMR byte in (HL) and pages the given bank in.
;         Preserves all registers.
; pg_out: HL -> the same save byte. Restores the saved mapping.
;         Preserves all registers (including A).
;
; Guards nest correctly as long as each call site uses its own save byte.
; On 464 builds (no bank module) the compiler emits ret stubs; bank bytes
; are always #FF there so pg_in would early-out anyway.
; ----------------------------------------------------------------------------
rbt_pg_in:
        di                      ; atomic: a mid-guard ISR would restore
        push    af              ; the kernel's stale RMR shadow and
        ld      a,(rbt_cur_bank); unmap the bank under us
        ld      (hl),a          ; save previous mapping
        pop     af
        inc     a
        jp      z,rbt_pg_out    ; #FF = resident: restore ei and out
        dec     a
        jp      rbt_bank

rbt_pg_out:
        push    af
        ld      a,(hl)
        call    rbt_bank
        pop     af
        ei
        ret
