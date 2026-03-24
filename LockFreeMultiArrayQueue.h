// MIT License
// Copyright (c) 2026 Vít Procházka
//
// LockFreeMultiArrayQueue in C++ (header-only)
//
// (the core operations of the LockFreeMultiArrayQueue are implemented in the assembly file)

#include <string>
#include <stdexcept>

extern "C" int lock_free_multi_array_queue_enqueue(uint64_t*, uint64_t);
extern "C" int lock_free_multi_array_queue_dequeue(uint64_t*, uint64_t*);

template <class T>
class LockFreeMultiArrayQueue
{
    static constexpr uint64_t PADDING = 10;  // 10 = 80/8 (must be aligned with the assembly file)

    std::string name;       // name of the Queue (practical in bigger projects with many Queues)
    uint64_t* queueStruct;  // the structure of the Queue: for the memory layout see the assembly file

public :

    static std::string getClassName() { return "LockFreeMultiArrayQueue"; }

    // Constructor: validate parameters and create the structure of the Queue
    //
    // parameters:
    //    p_name                   name of the Queue
    //    p_firstArraySize         size of the first array (allocated up-front)
    //    p_cntAllowedExtensions   -1 = max. capacity "unlimited", 0 or higher = limit on how many times the Queue can extend
    //
    LockFreeMultiArrayQueue(
        std::string p_name
       ,uint64_t p_firstArraySize
       ,int p_cntAllowedExtensions
    )
    : name(p_name)
    {
        if (p_firstArraySize < 1) {
            throw std::invalid_argument(
            getClassName() + " " + name + ": p_firstArraySize is less than 1"
            );
        }

        if (p_cntAllowedExtensions < -1) {
            throw std::invalid_argument(
            getClassName() + " " + name + ": p_cntAllowedExtensions has invalid value"
            );
        }

        if (0xFC00'0000'0000'0000uL & p_firstArraySize) {  // in the structure we need to accommodate it into 58 bits
            throw std::invalid_argument(
            getClassName() + " " + name + ": p_firstArraySize is beyond a 58-bit value"
            );
        }

        uint8_t cntAllowedExtensions = 0;
        for (uint64_t arraySize = p_firstArraySize ;;)
        {
            if ((0 <= p_cntAllowedExtensions) && (p_cntAllowedExtensions == cntAllowedExtensions)) break;
            arraySize <<= 1;  // times two
            if (0xFC00'0000'0000'0000uL & (arraySize - 1)) break;  // in the structure we write up to (arraySize - 1) into 58 bits
            cntAllowedExtensions ++;
        }

        if ((0 <= p_cntAllowedExtensions) && (cntAllowedExtensions < p_cntAllowedExtensions)) {
            throw std::invalid_argument(
            getClassName() + " " + name + ": (arraySize - 1) would grow beyond a 58-bit value"
            );
        }

        uint64_t queueStructTillRings0Size = 4 + (3*PADDING) + (2*cntAllowedExtensions);
        uint64_t queueStructTillReaderPosSize = queueStructTillRings0Size + PADDING + (2*p_firstArraySize);  // one element = 2x8 byte
        uint64_t queueStructSize = queueStructTillReaderPosSize + 2 + PADDING;

        queueStruct = (uint64_t*) calloc(queueStructSize, 8);  // allocates zero-initialized memory

        if (NULL == queueStruct) {
            throw std::runtime_error(
            getClassName() + " " + name + ": calloc() in the constructor failed"
            );
        }
        if (0x0000'0000'0000'000FuL & ((uint64_t) queueStruct)) {
            throw std::runtime_error(
            getClassName() + " " + name + ": The memory block returned by calloc() in the constructor was not 16-byte aligned"
            );
        }

        queueStruct[1 + PADDING] = 0xFFFF'FFFF'FFFF'FF00uL;  // writerPositionRound: auto-test overflow "soon"
        queueStruct[2 + (2*PADDING)] = ((p_firstArraySize << 6) | cntAllowedExtensions);
        queueStruct[3 + (2*PADDING)] = (uint64_t) &(queueStruct[queueStructTillRings0Size]);  // pointer to rings[0][0]
        queueStruct[1 + queueStructTillReaderPosSize] = 0xFFFF'FFFF'FFFF'FF00uL;  // readerPositionRound: auto-test overflow "soon"
    }

    // Destructor: free all dynamically allocated memory
    ~LockFreeMultiArrayQueue()
    {
        uint8_t cntAllowedExtensions = (0x0000'0000'0000'003FuL & queueStruct[2 + (2*PADDING)]);
        for (uint8_t i = 1; i <= cntAllowedExtensions; i++)  // start with 1 because rings[0] is part of queueStruct
        {
            uint64_t ring = queueStruct[3 + (2*PADDING) + i];
            if (ring) free((void*) ring);
        }
        free(queueStruct);
    }

    // get the name of the Queue
    std::string getName() { return name; }

    // it is possible to get the queueStruct for working with the Queue directly (i.e. not through this C++ template)
    uint64_t* getQueueStruct() { return queueStruct; }

    // lock-free enqueue
    //
    // parameters:
    //    p_value            the pointer to enqueue (must be not null (because null is used to signal Queue is empty on dequeue))
    //    p_exceptionIfFull  true = throw exception if Queue is full, false = report Queue is full via return value
    //
    // return values:
    //    0  Enqueue success
    //    1  Queue is full (if not instructed (via p_exceptionIfFull) to throw exception on Queue is full)
    //
    int enqueue(T* p_value, bool p_exceptionIfFull)
    {
        if (NULL == p_value) {
            throw std::invalid_argument(
            getClassName() + " " + name + ": Enqueued p_value is null"
            );
        }

        int result = lock_free_multi_array_queue_enqueue(queueStruct, (uint64_t) p_value);  // see the assembly file

        if (0 == result) {  // Enqueue success
            return result;
        } else if (1 == result) {  // Queue is full
            if (p_exceptionIfFull) {
                throw std::runtime_error(
                getClassName() + " " + name + ": Queue is full"
                );
            } else {
                return result;
            }
        } else if (-10 == result) {
            throw std::runtime_error(
            getClassName() + " " + name + ": The stack was not 16-byte aligned before calling this function"
            );
        } else if (-11 == result) {
            throw std::runtime_error(
            getClassName() + " " + name + ": calloc() failed"
            );
        } else if (-12 == result) {
            throw std::runtime_error(
            getClassName() + " " + name + ": The memory block returned by calloc() was not 16-byte aligned"
            );
        } else {
            throw std::runtime_error(
            getClassName() + " " + name + ": Unknown enqueue return value"
            );
        }
    }

    // lock-free dequeue
    //
    // return values:
    //    not null  the dequeued pointer
    //    null      Queue is empty
    //
    T* dequeue()
    {
        uint64_t dequeued;
        int result = lock_free_multi_array_queue_dequeue(queueStruct, &dequeued);  // see the assembly file

        if (0 == result) {  // Dequeue success
            return (T*) dequeued;
        } else if (2 == result) {  // Queue is empty
            return NULL;
        } else if (-10 == result) {  // the below allocation-related errors can occur on dequeue too due to extension helping
            throw std::runtime_error(
            getClassName() + " " + name + ": The stack was not 16-byte aligned before calling this function"
            );
        } else if (-11 == result) {
            throw std::runtime_error(
            getClassName() + " " + name + ": calloc() failed"
            );
        } else if (-12 == result) {
            throw std::runtime_error(
            getClassName() + " " + name + ": The memory block returned by calloc() was not 16-byte aligned"
            );
        } else {
            throw std::runtime_error(
            getClassName() + " " + name + ": Unknown dequeue return value"
            );
        }
    }
};

