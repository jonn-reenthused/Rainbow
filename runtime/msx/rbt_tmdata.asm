; ============================================================================
; rbt_tmdata_asm - tilemap state + map query (shared by tilemap engine)
; Var layouts documented in rbt_tilemap.asm. Bank vars kept for source
; parity — pg_in/out are no-op stubs when the bank module is absent.
; ============================================================================

rbt_tm_tiles    defw 0          ; tileset base
rbt_tm_bmp      defw 0          ; bitmaps (tiles+1)
rbt_tm_tattr    defw 0          ; attr table (tiles+1+8n)
rbt_tm_tflags   defw 0          ; flag table (tiles+1+9n)
rbt_tm_n        defb 0          ; tile count
rbt_tm_tbank    defb #ff        ; tileset bank (#ff = resident)
rbt_tm_map      defw 0          ; map base
rbt_tm_mbank    defb #ff        ; map bank (#ff = resident)
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

; ----------------------------------------------------------------------------
; rbt_tm_mapat - B=mx, C=my -> A = tile id (0 when out of bounds).
; Clobbers DE,HL.
; ----------------------------------------------------------------------------
rbt_tm_mapat:
        ld      a,b
        ld      hl,rbt_tm_mw
        cp      (hl)
        jr      nc,_oob
        ld      a,c
        ld      hl,rbt_tm_mh
        cp      (hl)
        jr      nc,_oob
        ; addr = cells + my*mw + mx
        ld      a,c
        ld      hl,rbt_tm_mw
        ld      e,(hl)
        ld      d,0
        ld      hl,0
        or      a
        jr      z,_row
_mul    add     hl,de
        dec     a
        jr      nz,_mul
_row    ld      d,0
        ld      e,b
        add     hl,de
        ld      de,(rbt_tm_cells)
        add     hl,de
        ld      a,(hl)
        ret
_oob    xor     a
        ret

; ----------------------------------------------------------------------------
; rbt_tm_on - tilemap in use? A = 1 when a map is set (sprite compositor
; on other platforms queries this; MSX keeps it for parity)
; ----------------------------------------------------------------------------
rbt_tm_on:
        ld      a,(rbt_tm_map)
        or      a
        ret
