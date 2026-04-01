# Lock-Free Multi-Array Queue

The existence of a 128-bit Compare-And-Swap (CAS) instruction (CMPXCHG16B) allows for a truly lock-free implementation
of the garbage-free Multi-Array Queue (presented in 2024 in [Multi-Array Queue](https://github.com/MultiArrayQueue/MultiArrayQueue)).

The 128-bit CAS instruction enables Comparing-And-Swapping of a 64-bit value/payload (typically a 64-bit pointer) **together**
with other 64 bits of necessary metadata (especially the round number to prevent ABA) in **one** atomic instruction.

This work has been inspired by the [Michael & Scott Queue](https://www.cs.rochester.edu/~scott/papers/1996_PODC_queues.pdf)
in the sense that the linearization operation is the writing the payload to the array and moving the writer position forward
can be helped by other threads.

<img src="https://MultiArrayQueue.github.io/Diagram_LockFreeMultiArrayQueue.png" height="600">

## New Interactive Simulator of the Lock-Free Queue

[Get acquainted here](https://MultiArrayQueue.github.io/Simulator_LockFreeMultiArrayQueue.html)

## Implementation

In short: There are **three implementations** aligned with each other: a Spin model, the JavaScript Simulator,
and a real implementation in assembly/C++.

In long: The algorithms have first been designed and verified as a model for the [Spin model checker](https://spinroot.com)
(for computer-aided simulations and exhaustive verifications). The Spin model file is the primary source of information
and comments on the algorithms as such.

After that the [JavaScript Simulator](https://MultiArrayQueue.github.io/Simulator_LockFreeMultiArrayQueue.html)
has been developed (for teaching and visual/manual simulations and verifications).

As for a "real" implementation:

* In Java the CMPXCHG16B is not accessible (neither in .NET).
* In C++ the CMPXCHG16B is accessible but for various reasons (the teaching perspective, full control over the program code
  versus relying on what the given C++ compiler would indeed produce) this path was not chosen.
* Assembly for x86-64 (under both Linux and Windows ABI) was seen as the most attractive option:
  The core operations **enqueue** and **dequeue** have been implemented in x86-64 assembly, wrapped in a thin C++ layer
  that - besides adding items like the constructor and the destructor - exposes the overall work as a C++ template.

## More details

The Lock-Free Multi-Array Queue is a linearizable multiple-writer multiple-reader lock-free FIFO Queue.

In the steady state (i.e. no Queue extensions (anymore)), the Lock-Free Multi-Array Queue is both lock-free as well as garbage-free.

The extension operations, however, cannot in principle be made both lock-free and garbage-free at the same time:
Lock-free means that more than one writer thread can consider to extend the Queue.
Each of these competing threads then prepares (allocates) memory for the new ring and tries to CAS it into the **rings** array.
The memory of the winning thread goes into use, but the loosing threads have to free the allocated memory again.
In other words: A strict garbage-freedom has to be sacrificed in this case.

Other differences and optimizations over the original [Multi-Array Queues](https://github.com/MultiArrayQueue/MultiArrayQueue) exist:

Each array element is now accompanyied by 64-bit metadata, which contains the essential round number to prevent ABA
and the diversion info (so no searching the **diversions** array is needed anymore at each enqueue/dequeue).
This 64-bit metadata however effectively doubles the memory consumption by this Lock-Free Queue.

The enqueueing of new elements and the (decisions about) implanting of new diversions have been integrated
into **one** 128-bit CAS instruction. This implies a change in the semantics of the diversions:
Instead of the "divert to new ring before this element" semantics,
the Lock-Free Queue now uses the "divert to new ring after this element" semantics.

Another difference over the original Multi-Array Queues is that the writer/readerPositions now point to
"next to enqueue/next to dequeue" elements (instead of originally "last enqueued/last dequeued" elements).

## Performance

Performance-wise, this Queue is lagging by circa 40% behind the other Multi-Array Queues.
This is somehow consistent with other sources on the Internet that report that CMPXCHG16B
(as a "heavier" instruction) is slower than CMPXCHG8B by around the same factor.

Besides the raw performance, however, the latency distribution is an important factor too.
What is known about lock-free (but not wait-free) algorithms is that under high contention they have a theoretically infinite tail
in the latency distribution (i.e. the linearization CAS may fail unlimited number of times for any given thread).

## Development status

 * Currently (2026) this code is only for academic interest, not for production use.
 * Reviews, tests and comments are welcome.
 * Should you have found a concurrency counterexample, please attach to your ticket your Spin input + trail file
   or the trail from the JavaScript Simulator that leads to the issue.
   *As with other similar algorithms, an eventual counterexample could be either fixable or unfixable
   (in which case the whole algorithm would have to be discarded).*
 * Do not send me Pull Requests - the code is small so I want to maintain it single-handedly.

## License

MIT License

