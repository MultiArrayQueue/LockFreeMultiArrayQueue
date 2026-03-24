// MIT License
// Copyright (c) 2026 Vít Procházka
//
// Class for inspection of the LockFreeMultiArrayQueue
//
// Used only during the debugging/testing phase.

#include <inttypes.h>

class LockFreeMultiArrayQueuePrinter
{
    static constexpr uint64_t PADDING = 10;  // 10 = 80/8 (must be aligned with the assembly file)

public :

    static void print(uint64_t* queueStruct)
    {
        uint64_t firstArraySize       = (queueStruct[2 + (2*PADDING)] >> 6);
        uint8_t  cntAllowedExtensions = (queueStruct[2 + (2*PADDING)] & 0x0000'0000'0000'003FuL);
        uint64_t readerPositionOffset = 4 + (4*PADDING) + (2*cntAllowedExtensions) + (2*firstArraySize);
        printf("FIRST_ARRAY_SIZE: %" PRIu64 "  CNT_ALLOWED_EXTENSIONS: %" PRIu8 "\n", firstArraySize, cntAllowedExtensions);
        uint64_t writerPositionRound = (queueStruct[1 + PADDING] >> 7);
        uint8_t  writerPositionRix   = (queueStruct[PADDING] & 0x0000'0000'0000'003FuL);
        uint64_t writerPositionIx    = (queueStruct[PADDING] >> 6);
        printf("writerPosition (round,rix,ix): (0x%" PRIx64 ",%" PRIu8 ",%" PRIu64 ")\n", writerPositionRound, writerPositionRix, writerPositionIx);
        uint64_t readerPositionRound = (queueStruct[1 + readerPositionOffset] >> 7);
        uint8_t readerPositionRix    = (queueStruct[readerPositionOffset] & 0x0000'0000'0000'003FuL);
        uint64_t readerPositionIx    = (queueStruct[readerPositionOffset] >> 6);
        printf("readerPosition (round,rix,ix): (0x%" PRIx64 ",%" PRIu8 ",%" PRIu64 ")\n", readerPositionRound, readerPositionRix, readerPositionIx);

        uint64_t arraySize = firstArraySize;
        for (uint8_t i = 0; i <= cntAllowedExtensions; i ++) {
            uint64_t ring = queueStruct[3 + (2*PADDING) + i];
            printf("rings[%" PRIu8 "]=0x%" PRIx64 "\n", i, ring);
            if (ring) {
                for (uint64_t j = 0; j < arraySize; j ++) {
                    uint64_t jr = arraySize - 1 - j;
                    uint64_t metadata = ((uint64_t*) ring)[2*jr];
                    uint8_t divertToRix = (metadata & 0x0000'0000'0000'003FuL);
                    bool dirty = (metadata & 0x0000'0000'0000'0040uL);
                    uint64_t round = (metadata >> 7);
                    uint64_t value = ((uint64_t*) ring)[1 + (2*jr)];
                    printf("    rings[%" PRIu8 "][%" PRIu64 "]:  divertToRix=%" PRIu8 "   dirty=%d   round=0x%015" PRIx64 "   value=0x%" PRIx64 "\n",
                           i, jr, divertToRix, dirty, round, value);
                }
            }
            arraySize <<= 1;
        }
        for (uint8_t i = 1; i <= cntAllowedExtensions; i++) {
            uint64_t diversion = queueStruct[3 + (2*PADDING) + cntAllowedExtensions + i];
            uint8_t rix = (diversion & 0x0000'0000'0000'003FuL);
            uint64_t ix = (diversion >> 6);
            printf("diversions[%" PRIu8 " - 1]:  rix=%" PRIu8 "   ix=%" PRIu64 "\n", i, rix, ix);
        }
    }
};

