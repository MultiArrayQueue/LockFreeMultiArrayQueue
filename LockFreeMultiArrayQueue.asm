; ----------------------------------------------------------------------------------------
; MIT License
; Copyright (c) 2026 Vít Procházka
;
; The core operations of the LockFreeMultiArrayQueue implemented in x86-64 assembly.
;
; The primary source of explanations and comments on the Lock-Free Multi-Array Queue algorithms themselves
; is the Promela model for Spin. The comments here are relevant mainly for the implementation in assembly.
;
; The jump/goto labels are aligned as much as possible between this assembly file,
; the model for Spin and the visual model in JavaScript.
;
; Memory layout of the LockFreeMultiArrayQueue structure (start 16-byte aligned):
;
; PADDING: 0 bytes for a dense packing, 80 bytes for some performance increase (due to reduction of cache sharing,
;          the value has been found by measurements)
;
; 1x 128 bit: writerPosition (the first memory hot-spot)
;    - bits 71:127  round   (57 bits)
;    - bits 64:70   zeros   (7 bits)
;    - bits 6:63    ix      (58 bits)
;    - bits 0:5     rix     (6 bits)
;
; PADDING bytes (see above)
;
; 1x 64 bit: CNT_ALLOWED_EXTENSIONS, FIRST_ARRAY_SIZE
;    - bits 6:63    FIRST_ARRAY_SIZE       (58 bits)
;    - bits 0:5     CNT_ALLOWED_EXTENSIONS (6 bits)
;
; (1 + CNT_ALLOWED_EXTENSIONS) times 64 bit: rings array
;    - bits 0:63    pointer to array (64 bits)
;
; (CNT_ALLOWED_EXTENSIONS) times 64 bit: diversions array
;   - bits 6:63     ix (58 bits)
;   - bits 0:5      rix (6 bits)
;
; PADDING bytes (see above)
;
; (FIRST_ARRAY_SIZE) times 128 bit: rings[0] (first array of elements (note that its start is again 16-byte aligned))
;   - bits 64:127   value/payload (64 bits)
;   - bits 7:63     round (57 bits)
;   - bit  6        dirty flag (1 bit)
;   - bits 0:5      divertToRix (6 bits)
;
; PADDING bytes (see above)
;
; 1x 128 bit: readerPosition (the second memory hot-spot: as much apart from writerPosition as possible due to cache sharing)
;   (same layout as writerPosition)
;
; PADDING bytes (see above)
;
; (end of structure)
;
; For maximum efficiency, as many as possible local variables are in registers (to minimize pushing/popping to/from the stack):
;
; xmm0      - bits 64:127  to preserve rbx
;           - bits 0:63    address of readerPosition
; xmm1    origWriter (same layout as writerPosition)
; xmm2    writer     (same layout as writerPosition)
; xmm3    origReader (same layout as writerPosition)
; xmm4    reader     (same layout as writerPosition)
; xmm5    element    (same layout as element)
; r8      "this" pointer
; r9      value/payload to enqueue, address for dequeued value/payload
; r10     constants
;           - bits 6:63   FIRST_ARRAY_SIZE (58 bits)
;           - bits 0:5    CNT_ALLOWED_EXTENSIONS (6 bits)
; r11     other local variables
;           - bits 8:63   unused (56 bits)
;           - bit 7       flag from where extension help was entered (+ where to jump back) (1 bit)
;           - bit 6       linearized flag (1 bit)
;           - bits 0:5    divertToRixNew (6 bits)
; rdi     between read element and element CAS: address of element
;         in the extension helping: address of rings[new rix]
; rsi     address of readerPosition, except of free use in extension helping (after which it is restored from xmm0)
;
; rax, rbx, rcx, rdx:
;         except where explicitly declared: working registers used as locally as possible (+ not across code blocks)
;         this allows for independent checking of each assembly block against the Spin model
;
; The ABIs mandate the callee to preserve (or not use) the following registers:
;
; Windows:      rbx, rsp, rbp, rsi, rdi, r12, r13, r14, r15, xmm6:xmm15
; Linux:        rbx, rsp, rbp,           r12, r13, r14, r15
;
; How to build (for Windows/for Linux):
;
;   nasm -fwin64 -o LockFreeMultiArrayQueue.obj LockFreeMultiArrayQueue.asm
;   nasm -felf64 -o LockFreeMultiArrayQueue.o LockFreeMultiArrayQueue.asm
; ----------------------------------------------------------------------------------------

%define PADDING 80

          global    lock_free_multi_array_queue_enqueue
          global    lock_free_multi_array_queue_dequeue

          extern    calloc
          extern    free

          section   .text

        ; ____ _  _ ____ _  _ ____ _  _ ____
        ; |___ |\ | |  | |  | |___ |  | |___
        ; |___ | \| |_\| |__| |___ |__| |___
        ;
        ; parameter                      Windows ABI   Linux ABI
        ; ------------------------------------------------------
        ; 1. "this" pointer              rcx           rdi
        ; 2. value/payload to enqueue    rdx           rsi
        ;
        ; return values (rax for both Windows and Linux)
        ; ------------------------------------------------------
        ; 0  Enqueue success
        ; 1  Queue is full
        ; -10  The stack was not 16-byte aligned before calling this function
        ; -11  calloc() failed
        ; -12  The memory block returned by calloc() was not 16-byte aligned

lock_free_multi_array_queue_enqueue :

%ifidn __?OUTPUT_FORMAT?__, win64
          mov       [rsp+8], rcx                ; first argument into shadow space
          mov       [rsp+16], rdx               ; second argument into shadow space
          mov       r8, rcx                     ; first argument: "this" pointer
          mov       r9, rdx                     ; second argument: value/payload to enqueue
          push      rsi                         ; preserve rsi
          push      rdi                         ; preserve rdi
%elifidn __?OUTPUT_FORMAT?__, elf64
          mov       r8, rdi                     ; first argument: "this" pointer
          mov       r9, rsi                     ; second argument: value/payload to enqueue
%else
%fatal Output format __?OUTPUT_FORMAT?__ is not implemented
%endif
          pinsrq    xmm0, rbx, 1                ; preserve rbx

          mov       r10, [r8+2*PADDING+16]      ; CNT_ALLOWED_EXTENSIONS, FIRST_ARRAY_SIZE

          mov       rsi, r10                    ; prepare address of readerPosition
          and       rsi, 0x0000_0000_0000_003f  ; isolate CNT_ALLOWED_EXTENSIONS
          mov       rax, r10
          shr       rax, 6                      ; isolate FIRST_ARRAY_SIZE
          add       rsi, rax
          shl       rsi, 4                      ; (2 x 8 x CNT_ALLOWED_EXTENSIONS) + (16 x FIRST_ARRAY_SIZE)
          add       rsi, r8
          add       rsi, 4*PADDING+32
          ; offset 32=8*4, with 4=2+1 +1 (due to (1+CNT_ALLOWED_EXTENSIONS))
          pinsrq    xmm0, rsi, 0                ; save address of readerPosition

enqueue_read_writer :

          ; No waterproof guarantees for atomicity of 16-byte reads exist (and reading via cmpxchg16b is expensive)
          ; https://stackoverflow.com/questions/7646018/sse-instructions-which-cpus-can-do-atomic-16b-memory-operations
          ; therefore implemented via three 8-byte reads in the style:
          ; read 8 bytes with round -> read the other 8 bytes -> check the 8 bytes with round.
          ; Theoretically it can be reasoned/modeled whether the overall algorithm can live without atomic 16-byte reads,
          ; or at least some of them, but this is now out-of-scope.

          mov       rcx, [r8+PADDING+8]         ; load writerPosition round from memory
enqueue_repeat_read_writer :
              mov       rax, rcx
              lfence
              mov       rbx, [r8+PADDING]           ; load writerPosition's rix,ix from memory
              lfence
              mov       rcx, [r8+PADDING+8]         ; for checking of writerPosition round
              xor       rax, rcx                    ; test if equals: then we have a valid 16-byte snapshot
              jnz       enqueue_repeat_read_writer  ; otherwise repeat
          pinsrq    xmm1, rbx, 0
          pinsrq    xmm1, rcx, 1
          movdqa    xmm2, xmm1                  ; origWriter into writer

enqueue_read_reader :

          mov       rcx, [rsi+8]                ; load readerPosition round from memory
enqueue_repeat_read_reader :
              mov       rax, rcx
              lfence
              mov       rbx, [rsi]                  ; load readerPosition's rix,ix from memory
              lfence
              mov       rcx, [rsi+8]                ; for checking of readerPosition round
              xor       rax, rcx                    ; test if equals: then we have a valid 16-byte snapshot
              jnz       enqueue_repeat_read_reader  ; otherwise repeat
          pinsrq    xmm3, rbx, 0
          pinsrq    xmm3, rcx, 1
          movdqa    xmm4, xmm3                  ; origReader into reader

          pextrq    rcx, xmm2, 0                ; writerRix,writerIx
          pextrq    rbx, xmm4, 0                ; readerRix,readerIx
          xor       rbx, rcx                    ; test (writerRix == readerRix) && (writerIx == readerIx))
          jnz       enqueue_read_element        ; if not equals: continue to enqueue_read_element
              pextrq    rcx, xmm2, 1                ; if equals: get writerRound
              pextrq    rbx, xmm4, 1                ; readerRound
              add       rbx, 0x0000_0000_0000_0080  ; (1 + readerRound) (overflow is ok)
              mov       rax, 1                      ; prepare signalization for Queue is full
              xor       rbx, rcx                    ; test (writerRound == (1 + readerRound))
              jz       common_return                ; equals && equals: Queue is full
              ; otherwise continue

enqueue_read_element :

          pextrq    rbx, xmm2, 0                ; obtain writerRix,writerIx
          mov       rax, rbx
          and       rax, 0x0000_0000_0000_003f  ; isolate writerRix
          mov       rdi, [r8+2*PADDING+24+8*rax] ; address of rings[writerRix][0]
          ; offset 24=8*3, with 3=2+1
          shr       rbx, 6                      ; isolate writerIx
          shl       rbx, 4                      ; 16 * writerIx
          add       rdi, rbx                    ; rdi = address of rings[writerRix][writerIx]

          mov       rcx, [rdi]                  ; load element's divertToRix,dirty,round from memory
enqueue_repeat_read_element :
              mov       rax, rcx
              lfence
              mov       rbx, [rdi+8]                ; load element's value from memory
              lfence
              mov       rcx, [rdi]                  ; for checking of element's divertToRix,dirty,round
              xor       rax, rcx                    ; test if equals: then we have a valid 16-byte snapshot
              jnz       enqueue_repeat_read_element ; otherwise repeat
          pinsrq    xmm5, rcx, 0
          pinsrq    xmm5, rbx, 1
          xor       r11, r11                    ; clear other local variables

          pextrq    rdx, xmm2, 1                ; writerRound
          pextrq    rcx, xmm5, 0                ; element's divertToRix,dirty,round
          mov       rbx, rcx
          and       rbx, 0xffff_ffff_ffff_ff80  ; isolate elementRound
          add       rbx, 0x0000_0000_0000_0080  ; (1 + elementRound) (overflow is ok)
          xor       rbx, rdx                    ; test (writerRound == (1 + elementRound))
          jz        enqueue_check_if_new_diversion  ; if equals
              test      rcx, 0x0000_0000_0000_0040  ; if not equals: test element's dirty flag
              jnz       enqueue_extension_help      ; (i.e. not equals && dirty true): go straight to extension finish helping
              ; otherwise continue

enqueue_check_if_new_diversion :

          pextrq    rax, xmm5, 0                ; element's divertToRix,dirty,round
          test      rax, 0x0000_0000_0000_003f  ; test divertToRix to see if there is a diversion on the element
          jnz       enqueue_element_cas         ; diversion already there
              pextrq    rbx, xmm2, 0                ; testNextWriterRix,testNextWriterIx
enqueue_check_if_new_div_loop :
                  mov       rcx, rbx
                  and       rcx, 0x0000_0000_0000_003f  ; isolate testNextWriterRix
                  mov       rdx, rbx
                  shr       rdx, 6                      ; isolate testNextWriterIx
                  inc       rdx                         ; testNextWriterIx++ (also handles the (1+ix) after load from diversions[])
                  mov       rax, r10
                  shr       rax, 6                      ; isolate FIRST_ARRAY_SIZE
                  shl       rax, cl                     ; FIRST_ARRAY_SIZE * 2^writerRix
                  xor       rax, rdx                    ; test (testNextWriterIx == (FIRST_ARRAY_SIZE * 2^testNextWriterRix))
                  jnz       enqueue_check_if_new_div_reader_hit_test ; if not equals: cascade of returns ends, test hitting the reader
                      test      rcx, rcx                    ; otherwise (equals): test testNextWriterRix
                      jnz       enqueue_check_if_new_div_real_div_return ; a "real" diversions[] return if (0 != testNextWriterRix)
                          xor       rcx, rcx                    ; otherwise (implicit return): testNextWriterRix = 0
                          xor       rdx, rdx                    ; testNextWriterIx = 0
                          jmp       enqueue_check_if_new_div_reader_hit_test ; cascade of returns ends, test hitting the reader
enqueue_check_if_new_div_real_div_return :
                          mov       rax, r10
                          and       rax, 0x0000_0000_0000_003f  ; isolate CNT_ALLOWED_EXTENSIONS
                          add       rax, rcx                    ; add testNextWriterRix
                          mov       rbx, [r8+2*PADDING+24+8*rax] ; rbx = diversions[testNextWriterRix - 1]
                          ; offset 24=8*3, with 3=2+1 +1 (due to (1+CNT_ALLOWED_EXTENSIONS)) -1 (due to (testNextWriterRix - 1))
                          jmp       enqueue_check_if_new_div_loop
enqueue_check_if_new_div_reader_hit_test :
              pextrq    rax, xmm4, 0                ; readerRix,readerIx
enqueue_check_if_new_div_reader_hit_test_loop :
                  mov       rbx, rdx                    ; compose rbx back
                  shl       rbx, 6
                  or        rbx, rcx
                  xor       rbx, rax                    ; test (readerRix == testNextWriterRix) && (readerIx == testNextWriterIx)
                  jz        enqueue_check_if_new_diversion_yes ; reader hit: stop with a positive find
                      mov       rbx, [r8+2*PADDING+24+8*rcx] ; otherwise: address of rings[testNextWriterRix][0]
                      ; offset 24=8*3, with 3=2+1
                      shl       rdx, 4                      ; 16 * testNextWriterIx
                      mov       rcx, [rbx+rdx]              ; load element's divertToRix,dirty,round from memory
                      xor       rdx, rdx                    ; rdx = testNextWriterIx = 0
                      and       rcx, 0x0000_0000_0000_003f  ; isolate divertToRix
                      jz        enqueue_element_cas         ; stop if zero (risk off), otherwise rcx = testNextWriterRix = divertToRix
                          mov       rbx, [r8+2*PADDING+24+8*rcx] ; address of rings[divertToRix][0]
                          ; offset 24=8*3, with 3=2+1
                          test      rbx, rbx                    ; test (null == rings[divertToRix])
                          jz        enqueue_element_cas         ; the new ring is not yet allocated, stop
                          jmp       enqueue_check_if_new_div_reader_hit_test_loop ; continue testing

enqueue_check_if_new_diversion_yes :

          mov       rdx, r10
          and       rdx, 0x0000_0000_0000_003f  ; isolate CNT_ALLOWED_EXTENSIONS
          xor       rcx, rcx                    ; counter = 0
enqueue_check_if_new_diversion_search :
              mov       rax, rcx
              mov       rbx, [r8+2*PADDING+24+8*rcx] ; load rings[counter]
              ; offset 24=8*3, with 3=2+1
              test      rbx, rbx                    ; test (null == rings[counter])
              jz        enqueue_check_if_new_diversion_end  ; found the first free ring, divertToRixNew is in rax
              xor       rax, rdx                    ; test (CNT_ALLOWED_EXTENSIONS == counter)
              jz        enqueue_check_if_new_diversion_end  ; end of loop without a find: divertToRixNew = rax = 0
              inc       rcx                         ; counter++
              jmp       enqueue_check_if_new_diversion_search
enqueue_check_if_new_diversion_end :
          or        r11, rax                    ; write divertToRixNew = rax (previous value == 0, so "or" is ok)

enqueue_element_cas :

          pextrq    rbx, xmm2, 1                ; writerRound
          or        rbx, 0x0000_0000_0000_0040  ; combine writerRound with dirty flag = true
          pextrq    rax, xmm5, 0                ; element's divertToRix,dirty,round
          or        rax, r11                    ; combine with other local variables due to divertToRixNew
          and       rax, 0x0000_0000_0000_003f  ; isolate (divertToRixNew | element's divertToRix)
          or        rbx, rax                    ; combine writerRound and dirty flag with (divertToRixNew | element's divertToRix)
          mov       rcx, r9                     ; value/payload to enqueue
          pextrq    rax, xmm5, 0                ; element's original divertToRix,dirty,round
          pextrq    rdx, xmm5, 1                ; element's original value
          lock cmpxchg16b [rdi]
          jz enqueue_element_cas_success
          pinsrq    xmm5, rax, 0                ; CAS failed: save element's divertToRix (the memory value)
          pinsrq    xmm5, rdx, 1
          jmp       enqueue_element_cas_after
enqueue_element_cas_success :
          pinsrq    xmm5, rbx, 0                ; CAS succeeded: save element's divertToRix (the written one)
          pinsrq    xmm5, rcx, 1
          or        r11, 0x0000_0000_0000_0040  ; set the linearized flag
enqueue_element_cas_after :

enqueue_extension_help :

          pextrq    rdi, xmm5, 0                ; element's divertToRix,dirty,round
          and       rdi, 0x0000_0000_0000_003f  ; isolate divertToRix
          jz        enqueue_extension_help_after ; do nothing if (0 == divertToRix)
          shl       rdi, 3                      ; times 8
          add       rdi, r8
          add       rdi, 2*PADDING+24           ; rdi = address of rings[divertToRix]
          ; offset 24=8*3, with 3=2+1
          mov       rax, [rdi]
          test      rax, rax                    ; test (null == rings[divertToRix])
          jnz       enqueue_extension_help_after ; do nothing if not null, i.e. if the extension helping is already finished
          pextrq    rdx, xmm2, 0                ; otherwise: load writerRix,writerIx into rdx for the extension help code
          or        r11, 0x0000_0000_0000_0080  ; set flag from where extension help was entered (1 = from enqueue)
          jmp       extension_help_part_1       ; try to help the extension
enqueue_extension_help_after :

enqueue_writer_cas :

          pextrq    rbx, xmm5, 0                ; element's divertToRix,dirty,round
          and       rbx, 0x0000_0000_0000_003f  ; isolate elementDivertToRix and see if there is a diversion on the element
          jnz       enqueue_writer_cas_cas      ; diversion yes: rbx = (writerRix,writerIx) = (elementDivertToRix,0)
              pextrq    rbx, xmm2, 0                ; diversion no: get writerRix,writerIx
enqueue_writer_cas_div_ret_loop :
                  mov       rcx, rbx
                  and       rcx, 0x0000_0000_0000_003f  ; isolate writerRix
                  mov       rdx, rbx
                  shr       rdx, 6                      ; isolate writerIx
                  inc       rdx                         ; writerIx++ (also handles the (1+ix) after load from diversions[])
                  mov       rax, r10
                  shr       rax, 6                      ; isolate FIRST_ARRAY_SIZE
                  shl       rax, cl                     ; FIRST_ARRAY_SIZE * 2^writerRix
                  xor       rax, rdx                    ; test (writerIx == (FIRST_ARRAY_SIZE * 2^writerRix))
                  jnz       enqueue_writer_cas_inc_cas  ; if not equals: break loop
                      test      rcx, rcx                    ; otherwise (equals): test writerRix
                      jnz       enqueue_writer_cas_real_div_return ; a "real" diversions[] return if (0 != writerRix)
                          xor       rbx, rbx                    ; otherwise (implicit return): rbx = (writerRix,writerIx) = (0,0)
                          pextrq    rax, xmm2, 1                ; writerRound
                          add       rax, 0x0000_0000_0000_0080  ; writerRound++ (overflow is ok)
                          pinsrq    xmm2, rax, 1                ; save writerRound
                          jmp       enqueue_writer_cas_cas      ; break loop
enqueue_writer_cas_real_div_return :
                          mov       rax, r10
                          and       rax, 0x0000_0000_0000_003f  ; isolate CNT_ALLOWED_EXTENSIONS
                          add       rax, rcx                    ; add writerRix
                          mov       rbx, [r8+2*PADDING+24+8*rax] ; rbx = diversions[writerRix - 1]
                          ; offset 24=8*3, with 3=2+1 +1 (due to (1+CNT_ALLOWED_EXTENSIONS)) -1 (due to (writerRix - 1))
                          jmp       enqueue_writer_cas_div_ret_loop ; continue loop
enqueue_writer_cas_inc_cas :
              mov       rbx, rdx                    ; compose rbx back
              shl       rbx, 6
              or        rbx, rcx
enqueue_writer_cas_cas :
          pinsrq    xmm2, rbx, 0                ; save writerRix,writerIx and keep it in rbx
          pextrq    rcx, xmm2, 1                ; writerRound
          pextrq    rax, xmm1, 0                ; origWriterRix,origWriterIx
          pextrq    rdx, xmm1, 1                ; origWriterRound
          lock cmpxchg16b [r8+PADDING]
          jz        enqueue_writer_cas_success  ; CAS success
          pinsrq    xmm2, rax, 0                ; CAS failed: save writerRix,writerIx (the memory value)
          pinsrq    xmm2, rdx, 1                ; save writerRound (the memory value)
enqueue_writer_cas_success :
          movdqa    xmm1, xmm2                  ; save writer into new origWriter
          test      r11, 0x0000_0000_0000_0040  ; test the linearized flag
          jz        enqueue_writer_start_anew   ; if false: start anew
          xor       rax, rax                    ; if true: enqueue done, prepare signalization for Enqueue success
          jmp       common_return
enqueue_writer_start_anew :
          pextrq    rcx, xmm2, 1                ; writerRound
          pextrq    rbx, xmm4, 1                ; readerRound
          mov       rax, rbx
          xor       rax, rcx                    ; test if (writerRound == readerRound)
          jz        enqueue_writer_start_anew_same_round
               add       rbx, 0x0000_0000_0000_0080  ; otherwise: (1 + readerRound) (overflow is ok)
               xor       rbx, rcx                    ; test if (writerRound == (1 + readerRound))
               jnz       enqueue_read_reader         ; not same round && not previous round: re-read readerPosition
                      pextrq    rcx, xmm2, 0                ; reader in previous round: get writerRix,writerIx
                      pextrq    rbx, xmm4, 0                ; readerRix,readerIx
                      mov       rax, rbx
                      xor       rax, rcx                    ; test if (writerRix,writerIx) == (readerRix,readerIx)
                      and       rax, 0x0000_0000_0000_003f  ; isolate only the rix part
                      jnz       enqueue_read_reader         ; if (writerRix != readerRix): re-read readerPosition
                          shr       rcx, 6                      ; previous round && same rix: isolate writerIx
                          shr       rbx, 6                      ; isolate readerIx
                          inc       rcx                         ; (1 + writerIx)
                          sub       rcx, rbx                    ; test if ((1 + writerIx) < readerIx)
                          jc        enqueue_read_element        ; if yes: can omit re-reading readerPosition
                          jmp       enqueue_read_reader         ; otherwise: re-read readerPosition
enqueue_writer_start_anew_same_round :
              pextrq    rax, xmm4, 0                ; readerRix,readerIx
              shr       rax, 6                      ; isolate readerIx
              jnz       enqueue_read_element        ; (0 != readerIx): can omit re-reading readerPosition
                  pextrq    rdx, xmm2, 0                ; readerIx at 0: get writerRix,writerIx
                  mov       rcx, rdx
                  and       rcx, 0x0000_0000_0000_003f  ; isolate writerRix
                  shr       rdx, 6                      ; isolate writerIx
                  inc       rdx                         ; the future testNextWriterIx++
                  mov       rax, r10
                  shr       rax, 6                      ; isolate FIRST_ARRAY_SIZE
                  shl       rax, cl                     ; FIRST_ARRAY_SIZE * 2^writerRix
                  xor       rax, rdx                    ; test (future testNextWriterIx == (FIRST_ARRAY_SIZE * 2^writerRix))
                  jnz       enqueue_read_element        ; next step not beyond end of ring: can omit re-reading readerPosition
                  jmp       enqueue_read_reader         ; otherwise: re-read readerPosition

common_return :                                 ; return value is in rax (for both Windows and Linux)

          pextrq    rbx, xmm0, 1                ; restore rbx

%ifidn __?OUTPUT_FORMAT?__, win64
          pop       rdi                         ; restore rdi
          pop       rsi                         ; restore rsi
%endif
          ret

        ; ___  ____ ____ _  _ ____ _  _ ____
        ; |  \ |___ |  | |  | |___ |  | |___
        ; |__/ |___ |_\| |__| |___ |__| |___
        ;
        ; parameter                      Windows ABI   Linux ABI
        ; ------------------------------------------------------
        ; 1. "this" pointer              rcx           rdi
        ; 2. address for dequeued value  rdx           rsi
        ;
        ; return values (rax for both Windows and Linux)
        ; ------------------------------------------------------
        ; 0  Dequeue success (the dequeued value/payload has been written to the passed address)
        ; 2  Queue is empty
        ; -10  The stack was not 16-byte aligned before calling this function
        ; -11  calloc() failed
        ; -12  The memory block returned by calloc() was not 16-byte aligned

lock_free_multi_array_queue_dequeue :

%ifidn __?OUTPUT_FORMAT?__, win64
          mov       [rsp+8], rcx                ; first argument into shadow space
          mov       [rsp+16], rdx               ; second argument into shadow space
          mov       r8, rcx                     ; first argument: "this" pointer
          mov       r9, rdx                     ; second argument: address for dequeued value
          push      rsi                         ; preserve rsi
          push      rdi                         ; preserve rdi
%elifidn __?OUTPUT_FORMAT?__, elf64
          mov       r8, rdi                     ; first argument: "this" pointer
          mov       r9, rsi                     ; second argument: address for dequeued value
%endif
          pinsrq    xmm0, rbx, 1                ; preserve rbx

          mov       r10, [r8+2*PADDING+16]      ; CNT_ALLOWED_EXTENSIONS, FIRST_ARRAY_SIZE

          mov       rsi, r10                    ; prepare address of readerPosition
          and       rsi, 0x0000_0000_0000_003f  ; isolate CNT_ALLOWED_EXTENSIONS
          mov       rax, r10
          shr       rax, 6                      ; isolate FIRST_ARRAY_SIZE
          add       rsi, rax
          shl       rsi, 4                      ; (2 x 8 x CNT_ALLOWED_EXTENSIONS) + (16 x FIRST_ARRAY_SIZE)
          add       rsi, r8
          add       rsi, 4*PADDING+32
          ; offset 32=8*4, with 4=2+1 +1 (due to (1+CNT_ALLOWED_EXTENSIONS))
          pinsrq    xmm0, rsi, 0                ; save address of readerPosition

dequeue_read_reader :

          mov       rcx, [rsi+8]                ; load readerPosition round from memory
dequeue_repeat_read_reader :
              mov       rax, rcx
              lfence
              mov       rbx, [rsi]                  ; load readerPosition's rix,ix from memory
              lfence
              mov       rcx, [rsi+8]                ; for checking of readerPosition round
              xor       rax, rcx                    ; test if equals: then we have a valid 16-byte snapshot
              jnz       dequeue_repeat_read_reader  ; otherwise repeat
          pinsrq    xmm3, rbx, 0
          pinsrq    xmm3, rcx, 1
          movdqa    xmm4, xmm3                  ; origReader into reader

dequeue_read_element :

          pextrq    rbx, xmm4, 0                ; obtain readerRix,readerIx
          mov       rax, rbx
          and       rax, 0x0000_0000_0000_003f  ; isolate readerRix
          mov       rdi, [r8+2*PADDING+24+8*rax] ; address of rings[readerRix][0]
          ; offset 24=8*3, with 3=2+1
          shr       rbx, 6                      ; isolate readerIx
          shl       rbx, 4                      ; 16 * readerIx
          add       rdi, rbx                    ; rdi = address of rings[readerRix][readerIx]

          mov       rcx, [rdi]                  ; load element's divertToRix,dirty,round from memory
dequeue_repeat_read_element :
              mov       rax, rcx
              lfence
              mov       rbx, [rdi+8]                ; load element's value from memory
              lfence
              mov       rcx, [rdi]                  ; for checking of element's divertToRix,dirty,round
              xor       rax, rcx                    ; test if equals: then we have a valid 16-byte snapshot
              jnz       dequeue_repeat_read_element ; otherwise repeat
          pinsrq    xmm5, rcx, 0
          pinsrq    xmm5, rbx, 1
          xor       r11, r11                    ; clear other local variables

          pextrq    rdx, xmm4, 1                ; readerRound
          pextrq    rcx, xmm5, 0                ; element's divertToRix,dirty,round
          mov       rbx, rcx
          and       rbx, 0xffff_ffff_ffff_ff80  ; isolate elementRound
          add       rbx, 0x0000_0000_0000_0080  ; (1 + elementRound) (overflow is ok)
          mov       rax, 2                      ; prepare signalization for Queue is empty
          xor       rbx, rdx                    ; test (readerRound == (1 + elementRound))
          jz        common_return               ; if equals: return with Queue is empty
              test      rcx, 0x0000_0000_0000_0040  ; if not equals: test element's dirty flag
              jz        common_return               ; if false: return with Queue is empty
              ; otherwise (i.e. if not equals && dirty true): continue

dequeue_extension_help :

          pextrq    rdi, xmm5, 0                ; element's divertToRix,dirty,round
          and       rdi, 0x0000_0000_0000_003f  ; isolate divertToRix
          jz        dequeue_extension_help_after ; do nothing if (0 == divertToRix)
          shl       rdi, 3                      ; times 8
          add       rdi, r8
          add       rdi, 2*PADDING+24           ; rdi = address of rings[divertToRix]
          ; offset 24=8*3, with 3=2+1
          mov       rax, [rdi]
          test      rax, rax                    ; test (null == rings[divertToRix])
          jnz       dequeue_extension_help_after ; do nothing if not null, i.e. if the extension helping is already finished
          pextrq    rdx, xmm4, 0                ; otherwise: load readerRix,readerIx into rdx for the extension help code
          jmp       extension_help_part_1       ; try to help the extension
dequeue_extension_help_after :

dequeue_reader_cas :

          pextrq    rbx, xmm5, 0                ; element's divertToRix,dirty,round
          and       rbx, 0x0000_0000_0000_003f  ; isolate elementDivertToRix and see if there is a diversion on the element
          jnz       dequeue_reader_cas_cas      ; diversion yes: rbx = (readerRix,readerIx) = (elementDivertToRix,0)
              pextrq    rbx, xmm4, 0                ; diversion no: get readerRix,readerIx
dequeue_reader_cas_div_ret_loop :
                  mov       rcx, rbx
                  and       rcx, 0x0000_0000_0000_003f  ; isolate readerRix
                  mov       rdx, rbx
                  shr       rdx, 6                      ; isolate readerIx
                  inc       rdx                         ; readerIx++ (also handles the (1+ix) after load from diversions[])
                  mov       rax, r10
                  shr       rax, 6                      ; isolate FIRST_ARRAY_SIZE
                  shl       rax, cl                     ; FIRST_ARRAY_SIZE * 2^readerRix
                  xor       rax, rdx                    ; test (readerIx == (FIRST_ARRAY_SIZE * 2^readerRix))
                  jnz       dequeue_reader_cas_inc_cas  ; if not equals: break loop
                      test      rcx, rcx                    ; otherwise (equals): test readerRix
                      jnz       dequeue_reader_cas_real_div_return ; a "real" diversions[] return if (0 != readerRix)
                          xor       rbx, rbx                    ; otherwise (implicit return): rbx = (readerRix,readerIx) = (0,0)
                          pextrq    rax, xmm4, 1                ; readerRound
                          add       rax, 0x0000_0000_0000_0080  ; readerRound++ (overflow is ok)
                          pinsrq    xmm4, rax, 1                ; save readerRound
                          jmp       dequeue_reader_cas_cas      ; break loop
dequeue_reader_cas_real_div_return :
                          mov       rax, r10
                          and       rax, 0x0000_0000_0000_003f  ; isolate CNT_ALLOWED_EXTENSIONS
                          add       rax, rcx                    ; add readerRix
                          mov       rbx, [r8+2*PADDING+24+8*rax] ; rbx = diversions[readerRix - 1]
                          ; offset 24=8*3, with 3=2+1 +1 (due to (1+CNT_ALLOWED_EXTENSIONS)) -1 (due to (readerRix - 1))
                          jmp       dequeue_reader_cas_div_ret_loop ; continue loop
dequeue_reader_cas_inc_cas :
              mov       rbx, rdx                    ; compose rbx back
              shl       rbx, 6
              or        rbx, rcx
dequeue_reader_cas_cas :
          pinsrq    xmm4, rbx, 0                ; save readerRix,readerIx and keep it in rbx
          pextrq    rcx, xmm4, 1                ; readerRound
          pextrq    rax, xmm3, 0                ; origReaderRix,origReaderIx
          pextrq    rdx, xmm3, 1                ; origReaderRound
          lock cmpxchg16b [rsi]
          jz        dequeue_reader_cas_success  ; CAS success
          pinsrq    xmm4, rax, 0                ; CAS failed: save readerRix,readerIx (the memory value)
          pinsrq    xmm4, rdx, 1                ; save readerRound (the memory value)
          movdqa    xmm3, xmm4                  ; save reader into new origReader
          jmp       dequeue_read_element        ; start anew but omit re-reading of the reader position
dequeue_reader_cas_success :
          pextrq    [r9], xmm5, 1               ; CAS success: dequeue done, write the element's value
          xor       rax, rax                    ; prepare signalization for Dequeue success

          jmp       common_return

        ; ____ _  _ ___ ____ _  _ ____ _ ____ _  _    _  _ ____ _    ___
        ; |___  \/   |  |___ |\ | [__  | |  | |\ |    |__| |___ |    |__]
        ; |___ _/\_  |  |___ | \| ___] | |__| | \|    |  | |___ |___ |

extension_help_part_1 :

          ; rdx must contain writerRix,writerIx if entered from enqueue, or readerRix,readerIx if entered from dequeue
          ; r11 must contain the flag from where the extension help was entered (1 = from enqueue, 0 = from dequeue)

          mov       rax, r10
          and       rax, 0x0000_0000_0000_003f  ; isolate CNT_ALLOWED_EXTENSIONS
          shl       rax, 3                      ; times 8
          mov       rsi, rdi                    ; address of rings[divertToRix]
          add       rsi, rax                    ; rsi = offset from rdi to point to diversions[divertToRix - 1]
          ; offset = 8 x (- divertToRix + (1 + CNT_ALLOWED_EXTENSIONS) + (divertToRix - 1)) = 8 x CNT_ALLOWED_EXTENSIONS
          mov       ebx, edx                    ; lower half of rdx goes to ebx
          shr       rdx, 32
          mov       ecx, edx                    ; upper half of rdx goes to ecx
          xor       eax, eax                    ; expected (rix,ix) == (0,0)
          xor       edx, edx
          lock cmpxchg8b [rsi]  ; the 8-byte CAS on diversions[divertToRix - 1]
                                ; if it succeeded, then fine, if it failed, then somebody else did it, which is also fine
                                ; (if the diversion is at (0,0), then this CAS may succeed several times (not an issue))
extension_help_part_2 :

          mov       rax, -10                    ; prepare signalization for The stack was not 16-byte aligned
          mov       rbx, rsp
          add       rbx, 8                      ; offset the return address (8 bytes) that was pushed
          test      rbx, 0x0000_0000_0000_000f  ; test if the stack was 16-byte aligned before calling this function
          jnz       common_return               ; if not aligned

          push      r8                          ; (push one 8 byte register first to align the stack to 16 bytes)
          sub       rsp, 16
          movdqa    [rsp], xmm0                 ; push all our stuff to stack before calling external C functions
          sub       rsp, 16                     ; (because we have to consider the C functions "total destroyers")
          movdqa    [rsp], xmm1                 ; (at the same time: here we are not on the main path of the program)
          sub       rsp, 16
          movdqa    [rsp], xmm2
          sub       rsp, 16
          movdqa    [rsp], xmm3
          sub       rsp, 16
          movdqa    [rsp], xmm4
          sub       rsp, 16
          movdqa    [rsp], xmm5
          push      r9
          push      r10
          push      r11
          push      rdi                         ; note that the stack is now 16-byte aligned

          pextrq    rcx, xmm5, 0                ; element divertToRix,dirty,round
          and       rcx, 0x0000_0000_0000_003f  ; isolate divertToRix
          mov       rbx, r10
          shr       rbx, 6                      ; isolate FIRST_ARRAY_SIZE
          shl       rbx, cl                     ; FIRST_ARRAY_SIZE * 2^divertToRix

          mov       rax, [rdi]                  ; Test here once again that the new ring is not yet allocated
          test      rax, rax                    ; to reduce unnecessary allocations as much as possible.
          jnz       extension_help_part_2_pop   ; Not null: somebody else did it in the meantime, so we can avoid the allocation
                                                ; (+ the non-null pointer from somebody else (in rax) will not trigger our tests).
; ------------------------------
%ifidn __?OUTPUT_FORMAT?__, win64
          sub       rsp, 32                     ; prepare shadow space (note that the stack is now 16-byte aligned)
          mov       rcx, rbx                    ; first argument: number of elements = FIRST_ARRAY_SIZE * 2^divertToRix
          mov       rdx, 16                     ; second argument: element size
%elifidn __?OUTPUT_FORMAT?__, elf64
          mov       rdi, rbx                    ; first argument: number of elements = FIRST_ARRAY_SIZE * 2^divertToRix
          mov       rsi, 16                     ; second argument: element size
%endif
          call      calloc                      ; call calloc(): return value (pointer to allocated memory) is in rax

%ifidn __?OUTPUT_FORMAT?__, win64
          add       rsp, 32                     ; remove shadow space again
%endif
; ------------------------------

          test      rax, rax                    ; test if calloc() output == null
          jz        extension_help_part_2_pop   ; if not null: go ahead, if null: jump and keep null in rax to re-trigger the test

          test      rax, 0x0000_0000_0000_000f  ; test if calloc() output is 16-byte aligned
          jz        extension_help_part_2_cas   ; if ok: jump to the CAS, if not ok: free it again + re-trigger the test

; ------------------------------
%ifidn __?OUTPUT_FORMAT?__, win64
          sub       rsp, 32                     ; prepare shadow space (note that the stack is now 16-byte aligned)
          mov       rcx, rax                    ; first argument: memory to be freed
%elifidn __?OUTPUT_FORMAT?__, elf64
          mov       rdi, rax                    ; first argument: memory to be freed
%endif
          call      free                        ; call free(): no return value

%ifidn __?OUTPUT_FORMAT?__, win64
          add       rsp, 32                     ; remove shadow space again
%endif
; ------------------------------

          mov      rax, 0x0000_0000_0000_000f   ; the memory is now freed, put into rax a value that will re-trigger the test
          jmp      extension_help_part_2_pop

extension_help_part_2_cas :

          mov       rdi, [rsp]                  ; refresh rdi (that we need below) from stack
          mov       rsi, rax                    ; save rax in rsi
          mov       ebx, eax                    ; lower half of rax goes to ebx
          shr       rax, 32
          mov       ecx, eax                    ; upper half of rax goes to ecx
          xor       eax, eax                    ; expected rings[divertToRix] == null
          xor       edx, edx
          lock cmpxchg8b [rdi]                  ; the 8-byte CAS on rings[divertToRix]
          mov       rax, rsi                    ; restore rax from rsi
          jz        extension_help_part_2_pop   ; CAS success: memory is now in use, do not free it again
                                                ; CAS failed: somebody else did it: we have to free the memory again (pity)
; ------------------------------
%ifidn __?OUTPUT_FORMAT?__, win64
          sub       rsp, 32                     ; prepare shadow space (note that the stack is now 16-byte aligned)
          mov       rcx, rax                    ; first argument: memory to be freed
%elifidn __?OUTPUT_FORMAT?__, elf64
          mov       rdi, rax                    ; first argument: memory to be freed
%endif
          call      free                        ; call free(): no return value

%ifidn __?OUTPUT_FORMAT?__, win64
          add       rsp, 32                     ; remove shadow space again
%endif
; ------------------------------

          mov      rax, 0x0000_0000_0000_0010   ; the memory is now freed, put into rax a value that will not trigger the tests

extension_help_part_2_pop :

          pop       rdi                         ; pop all our stuff back from the stack after having called external C functions
          pop       r11
          pop       r10
          pop       r9
          movdqa    xmm5, [rsp]
          add       rsp, 16
          movdqa    xmm4, [rsp]
          add       rsp, 16
          movdqa    xmm3, [rsp]
          add       rsp, 16
          movdqa    xmm2, [rsp]
          add       rsp, 16
          movdqa    xmm1, [rsp]
          add       rsp, 16
          movdqa    xmm0, [rsp]
          add       rsp, 16
          pop       r8

          pextrq    rsi, xmm0, 0                ; restore address of readerPosition into rsi

          mov       rbx, rax                    ; repeat the tests on the calloc() output here (after the pops)
          mov       rax, -11                    ; prepare signalization for calloc() failed
          test      rbx, rbx                    ; test if calloc() output == null
          jz        common_return               ; if null
          mov       rax, -12                    ; prepare signalization for Memory block not 16-byte aligned
          test      rbx, 0x0000_0000_0000_000f  ; test if the memory block returned by calloc() was 16-byte aligned
          jnz       common_return               ; if not aligned

extension_help_jump_back :

          test      r11, 0x0000_0000_0000_0080  ; flag from where the extension help was entered
          jnz       enqueue_extension_help_after ; 1 = from enqueue
          jmp       dequeue_extension_help_after ; 0 = from dequeue

; end

