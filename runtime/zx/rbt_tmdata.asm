; ============================================================================
; rbt_tmdata_asm - tilemap state + map query (shared by tilemap engine and the
; sprite compositor). Var layouts documented in rbt_tilemap.asm.
; ============================================================================

rbt_tm_tiles    defw 0          ; tileset base
rbt_tm_bmp      defw 0          ; bitmaps (tiles+1)
rbt_tm_tattr    defw 0          ; attr table (tiles+1+8n)
rbt_tm_tflags   defw 0          ; flag table (tiles+1+9n)
rbt_tm_n        defb 0          ; tile count
rbt_tm_tbank    defb #ff        ; tileset bank (#ff = resident, 128K)
rbt_tm_map      defw 0          ; map base
rbt_tm_mbank    defb #ff        ; map bank (#ff = resident, 128K)
rbt_tm_tprev    defb 0          ; pg guard save (tileset)
rbt_tm_mprev    defb 0          ; pg guard save (map)
rbt_tm_cells    defw 0          ; map cells (map+2)
rbt_tm_mw       defb 0          ; map width
rbt_tm_mh       defb 0          ; map height
rbt_tm_vx       defb 0
rbt_tm_vy       defb 0
rbt_tm_vw       defb 32
rbt_tm_vh       defb 24
rbt_tm_camx     defb 0
rbt_tm_camy     defb 0
rbt_tm_r        defb 0
rbt_tm_c        defb 0
rbt_tm_dir      defb 0
rbt_tm_steps    defb 0
rbt_tm_cnt      defb 0
rbt_tm_tid      defb 0
rbt_ct_c0       defb 0
rbt_ct_c1       defb 0
rbt_ct_r0       defb 0
rbt_ct_r1       defb 0
rbt_ct_r        defb 0
rbt_ct_c        defb 0

; ----------------------------------------------------------------------------
; rbt_tm_mapat - B=mx, C=my -> A = tile id (0 when out of bounds). Clobbers DE,HL.
; ----------------------------------------------------------------------------
rbt_tm_mapat:
        ld      hl,rbt_tm_mprev
        ld      a,(rbt_tm_mbank)
        call    rbt_pg_in       ; page map bank (no-op when resident)
        call    _mab
        ld      hl,rbt_tm_mprev
        jp      rbt_pg_out      ; restores bank; preserves A = tile id

_mab    push    bc
        ld      a,(rbt_tm_mw)
        cp      b
        jr      c,_ma0
        jr      z,_ma0          ; mx >= w
        ld      a,(rbt_tm_mh)
        cp      c
        jr      c,_ma0
        jr      z,_ma0          ; my >= h
        ld      hl,(rbt_tm_cells)
        ld      a,c
        or      a
        jr      z,_addx
        ld      b,a             ; loop my times
        ld      a,(rbt_tm_mw)
        ld      e,a
        ld      d,0             ; DE = w
_mal    add     hl,de
        djnz    _mal
_addx   pop     bc
        ld      e,b
        ld      d,0
        add     hl,de
        ld      a,(hl)
        ret
_ma0    pop     bc
        xor     a
        ret
