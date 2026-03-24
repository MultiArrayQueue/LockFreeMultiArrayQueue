// MIT License
// Copyright (c) 2026 Vít Procházka
//
// Basic test of the LockFreeMultiArrayQueue
//
// How to build and run:
//
// 1) Build the assembly file into object files for Windows and Linux:
//
//    nasm -fwin64 -o LockFreeMultiArrayQueue.obj LockFreeMultiArrayQueue.asm
//    nasm -felf64 -o LockFreeMultiArrayQueue.o LockFreeMultiArrayQueue.asm
//
// 2) Under Windows (Microsoft Visual C++): In "x64 Native Tools Command Prompt for VS":
//
//    cl LockFreeMultiArrayQueueBasicTest.cpp LockFreeMultiArrayQueue.obj
//    .\LockFreeMultiArrayQueueBasicTest.exe
//
// 3) Under Linux:
//
//    g++ -Wall -o LockFreeMultiArrayQueueBasicTest LockFreeMultiArrayQueueBasicTest.cpp LockFreeMultiArrayQueue.o
//    ./LockFreeMultiArrayQueueBasicTest
//

#include "LockFreeMultiArrayQueue.h"
#include "LockFreeMultiArrayQueuePrinter.h"

int main(int argc, char *argv[])
{
    uint64_t FIRST_ARRAY_SIZE = 1;
    int      CNT_ALLOWED_EXTENSIONS = 3;
    uint64_t MAXIMUM_CAPACITY = (1+2+4+8);  // SUM( SIZES OF ALL ARRAYS )

    uint64_t nextToEnqueue = 0;
    uint64_t nextToDequeue = 0;

    LockFreeMultiArrayQueue<void> queue("testQueue", FIRST_ARRAY_SIZE, CNT_ALLOWED_EXTENSIONS);

    // the C++ template was used just to construct the Queue, then we test the Queue directly (i.e. by calling the assembly)
    uint64_t* queueStruct = queue.getQueueStruct();

    LockFreeMultiArrayQueuePrinter::print(queueStruct);

    char str[3];
    for (;;)
    {
        printf("\nNext operation: 1=enqueue, 0=dequeue, q=quit\n");
        fgets(str, 3, stdin);

        if ('q' == *str) break;
        else if ('1' == *str)
        {
            int result = lock_free_multi_array_queue_enqueue(queueStruct, nextToEnqueue);
            if (1 == result) {
                printf("\nQueue is full\n\n");
                if ((nextToDequeue + MAXIMUM_CAPACITY) != nextToEnqueue) {
                    printf("******* Queue full balance broken *******\n");
                    break;
                }
            } else if (0 == result) {
                printf("\nEnqueued %" PRIu64 "\n\n", nextToEnqueue);
                nextToEnqueue ++;
            } else {
                printf("******* Unexpected result %d from enqueue *******\n", result);
                break;
            }
            LockFreeMultiArrayQueuePrinter::print(queueStruct);
        }
        else if ('0' == *str)
        {
            uint64_t dequeued;
            int result = lock_free_multi_array_queue_dequeue(queueStruct, &dequeued);
            if (2 == result) {
                printf("\nQueue is empty\n\n");
                if (nextToEnqueue != nextToDequeue) {
                    printf("******* Queue empty balance broken *******\n");
                    break;
                }
            } else if (0 == result) {
                printf("\nDequeued %" PRIu64 "\n\n", dequeued);
                if (nextToDequeue == dequeued) {
                    nextToDequeue ++;
                } else {
                    printf("******* FIFO order broken *******\n");
                    break;
                }
            } else {
                printf("******* Unexpected result %d from dequeue *******\n", result);
                break;
            }
            LockFreeMultiArrayQueuePrinter::print(queueStruct);
        }
    }
}

