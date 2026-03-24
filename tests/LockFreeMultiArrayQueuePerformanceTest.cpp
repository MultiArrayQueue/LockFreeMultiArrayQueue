// MIT License
// Copyright (c) 2026 Vít Procházka
//
// Performance test of the LockFreeMultiArrayQueue
//
// Measured is the number of dequeue/enqueue pairs per second.
// At the end there are checks for no messages lost or duplicated.
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
//    cl /W4 /EHsc LockFreeMultiArrayQueuePerformanceTest.cpp LockFreeMultiArrayQueue.obj
//    .\LockFreeMultiArrayQueuePerformanceTest.exe 1 3 8 0
//
// 3) Under Linux:
//
//    g++ -Wall -pthread -o LockFreeMultiArrayQueuePerformanceTest LockFreeMultiArrayQueuePerformanceTest.cpp LockFreeMultiArrayQueue.o
//    ./LockFreeMultiArrayQueuePerformanceTest 1 3 8 0
//

#include <atomic>
#include <thread>
#include <vector>
#include "LockFreeMultiArrayQueue.h"
#include "LockFreeMultiArrayQueuePrinter.h"

#define CURRENT_MILLIS (std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count())
#define SLEEP_MILLIS std::this_thread::sleep_for(std::chrono::milliseconds(1))

// Class for the usable messages which will be enqueued/dequeued (more precisely: the pointers to them)
class PerformanceTestMessage
{
    uint64_t sequenceNumber;
public :
    PerformanceTestMessage(uint64_t p_sequenceNumber) : sequenceNumber(p_sequenceNumber) {};
    uint64_t getSequenceNumber() {return sequenceNumber;}
};

LockFreeMultiArrayQueue<PerformanceTestMessage>* queue;

std::atomic_uint64_t allocCounter;  // atomic counter of allocated (by any thread) messages
std::atomic_uint64_t perfCounter;  // atomic counter of dequeue/enqueue pairs (by all threads)

/*
 * The function run by the threads
 */
void performanceTestTask(int threadNo, int64_t stopThreadsMillis)
{
    try {
        PerformanceTestMessage* message;
        uint64_t ownIterations = 0;

        // test time every 1024 iterations and stop after stopThreadsMillis
        for (; ((0 != (ownIterations & 0x0000'0000'0000'03FFuL)) || (CURRENT_MILLIS < stopThreadsMillis)) ;)
        {
            // dequeue message
            message = queue -> dequeue();

            // if Queue was empty, allocate a new message
            if (NULL == message)
            {
                message = new PerformanceTestMessage(allocCounter ++);
                printf("thread %d allocated [%" PRIu64 "]\n", threadNo, message -> getSequenceNumber());
            }

            // enqueue message (with p_exceptionIfFull = true because we want to stop on eventual Queue is full
            // (because Queue is full would result in missing messages that would be detected in the final checks))
            queue -> enqueue(message, true);

            // increment counters
            perfCounter ++;
            ownIterations ++;
        }

        uint64_t ownIterations6 = ownIterations / 1'000'000;
                 ownIterations -= (ownIterations6 * 1'000'000);
        uint64_t ownIterations3 = ownIterations / 1'000;
                 ownIterations -= (ownIterations3 * 1'000);
        printf("thread %d stopped after no of iterations: %3" PRIu64 " %03" PRIu64 " %03" PRIu64 "\n",
               threadNo, ownIterations6, ownIterations3, ownIterations);
    }
    catch (const std::exception &e)
    {
        printf("Exception caught: %s\n", e.what());
    }
}

/*
 * Main class
 */
int main(int argc, char *argv[])
{
    try
    {
        uint64_t firstArraySize;
        int      cntAllowedExtensions;
        int      numberOfThreads;
        uint64_t preAllocatedMessages;

        // handle command-line args
        try
        {
            if (5 == argc)
            {
                firstArraySize = std::stoul(argv[1]);
                cntAllowedExtensions = std::stoi(argv[2]);
                numberOfThreads = std::stoi(argv[3]);
                preAllocatedMessages = std::stoul(argv[4]);
            }
            else throw std::invalid_argument("argc != 5");
        }
        catch (const std::exception &e)
        {
            printf("Exception caught: %s\n", e.what());
            printf("usage: LockFreeMultiArrayQueuePerformanceTest <firstArraySize> <cntAllowedExtensions>"
                                                                " <numberOfThreads> <preAllocatedMessages>\n");
            throw;
        }

        queue = new LockFreeMultiArrayQueue<PerformanceTestMessage>("testQueue", firstArraySize, cntAllowedExtensions);

        allocCounter = 0;
        perfCounter = 0;

        // set times of the phases of the test
        int64_t initMillis = CURRENT_MILLIS;
        int64_t beginMeasureMillis = initMillis + 2000;  // start measuring (delayed to reach steady state)
        int64_t endMeasureMillis   = initMillis + 3000;  // stop measuring (after 1 second)
        int64_t stopThreadsMillis  = initMillis + 4000;  // the time at which all threads should stop
        int64_t postStopMillis     = initMillis + 5000;  // start checking after all threads have stopped for sure

        printf("------- testing -------\n");

        // pre-allocate messages
        if (0 < preAllocatedMessages)
        {
            printf("pre-allocating:");
            for (uint64_t i = 0; i < preAllocatedMessages; i ++)
            {
                PerformanceTestMessage* message = new PerformanceTestMessage(allocCounter ++);
                printf(" [%" PRIu64 "]", message -> getSequenceNumber());
                queue -> enqueue(message, true);  // same remark on p_exceptionIfFull as above
            }
            printf("\n");
        }

        // start the threads
        for (int i = 0; i < numberOfThreads; i ++)
        {
            std::thread t(performanceTestTask, i, stopThreadsMillis);
            t.detach();
        }
        printf("%d threads started, millis: %" PRId64 "\n", numberOfThreads, (CURRENT_MILLIS - initMillis));

        // wait until beginMeasureMillis and then capture the value of perfCounter
        for (; CURRENT_MILLIS < beginMeasureMillis ;) {
            SLEEP_MILLIS;
        }

        printf("begin measure time, millis: %" PRId64 "\n", (CURRENT_MILLIS - initMillis));
        uint64_t perfCounterStart = perfCounter;

        // wait until endMeasureMillis and then capture and print the performance result
        for (; CURRENT_MILLIS < endMeasureMillis;) {
            SLEEP_MILLIS;
        }

        printf("end measure time, millis: %" PRId64 "\n", (CURRENT_MILLIS - initMillis));

        uint64_t perfCount = (perfCounter - perfCounterStart);
        uint64_t perfCount6 = perfCount / 1'000'000;
                 perfCount -= (perfCount6 * 1'000'000);
        uint64_t perfCount3 = perfCount / 1'000;
                 perfCount -= (perfCount3 * 1'000);
        printf("dequeue/enqueue pairs: %3" PRIu64 " %03" PRIu64 " %03" PRIu64 "\n", perfCount6, perfCount3, perfCount);

        // wait until postStopMillis
        for (; CURRENT_MILLIS < postStopMillis ;) {
            SLEEP_MILLIS;
        }

        // check
        //
        // due to the non-deterministic scheduling and preempting of the threads,
        // the messages in the Queue will not be in any meaningful order,
        // but no message may be missing and no message may be duplicated!

        LockFreeMultiArrayQueuePrinter::print(queue -> getQueueStruct());

        printf("start checking, millis: %" PRId64 "\n", (CURRENT_MILLIS - initMillis));

        printf("number of messages allocated: %" PRIu64 "\n", allocCounter.load());
        std::vector<bool> checkArray(allocCounter);

        printf("remained in Queue:");
        PerformanceTestMessage* message;
        for (; NULL != (message = queue -> dequeue()) ;)
        {
            if (checkArray[message -> getSequenceNumber()]) {
                printf("******* Message [%" PRIu64 "] is duplicated *******\n", message -> getSequenceNumber());
                throw std::runtime_error("******* Message is duplicated *******");
            } else {
                checkArray[message -> getSequenceNumber()] = true;
                printf(" [%" PRIu64 "]", message -> getSequenceNumber());
            }
            delete message;
        }
        delete queue;
        printf("\n");

        for (uint64_t i = 0; i < allocCounter; i ++) {
            if (! checkArray[i]) {
              printf("******* Message [%" PRIu64 "] is missing *******\n", i);
              throw std::runtime_error("******* Message is missing *******");
            }
        }
        printf("checking finished ok\n");
    }
    catch (const std::exception &e)
    {
        printf("Exception caught: %s\n", e.what());
    }
}

